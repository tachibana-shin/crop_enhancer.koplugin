local ffi = require("ffi")
local logger = require("crop_enhancer_logger")
local settings = require("crop_enhancer_settings")

local now_ms, dbg = logger.now_ms, logger.dbg
local loadSetting = settings.loadSetting

--- Leptonica library handle (loaded once, LuaJIT caches table lookups)
--- @type table
local lev

local function ensureLeptonica()
  if lev then return end
  lev = ffi.loadlib("leptonica", "6")
end

--- Wrap a cdata pointer with a GC destructor.
local function _gc_ptr(p, destructor)
  return p and ffi.gc(p, destructor)
end

--- @param pix any
local function pixDestroy(pix)
  lev.pixDestroy(ffi.new('PIX *[1]', pix))
  ffi.gc(pix, nil)
end

--- @param box any
local function boxDestroy(box)
  lev.boxDestroy(ffi.new('BOX *[1]', box))
  ffi.gc(box, nil)
end

--- @param boxa any
local function boxaDestroy(boxa)
  lev.boxaDestroy(ffi.new('BOXA *[1]', boxa))
  ffi.gc(boxa, nil)
end

--- @param box any
local function boxGetGeometry(box)
  local geo = ffi.new('l_int32[4]')
  lev.boxGetGeometry(box, geo, geo + 1, geo + 2, geo + 3)
  return tonumber(geo[0]), tonumber(geo[1]), tonumber(geo[2]), tonumber(geo[3])
end

--- Iterator over boxes in a BOXA.
--- @param boxa any
--- @return fun(): any|nil
local function boxaIterBoxes(boxa)
  local count = lev.boxaGetCount(boxa)
  local index = 0
  return function()
    if index < count then
      local box = _gc_ptr(lev.boxaGetBox(boxa, index, lev.L_CLONE), boxDestroy)
      index = index + 1
      return box
    end
  end
end

--- Detect page content bounds using leptonica connected-component analysis.
--- @param kc any
--- @return number|nil x0
--- @return number|nil y0
--- @return number|nil x1
--- @return number|nil y1
local function enhancedCropBmp(kc)
  ensureLeptonica()
  local KOPTContext      = require("ffi/koptcontext")
  local k2pdfopt         = KOPTContext.k2pdfopt

  local threshold        = loadSetting("threshold")
  local border_max_width = loadSetting("border_max_width")
  local min_content_area = loadSetting("min_content_area")
  local margin_frac      = loadSetting("margin")

  local img_w            = kc.src.width
  local img_h            = kc.src.height
  local img_area         = img_w * img_h
  dbg("  src: %dx%d (%d px) bpp=%d thr=%d bw=%d ma=%d m=%.3f",
    img_w, img_h, img_area, kc.src.bpp, threshold, border_max_width, min_content_area, margin_frac)

  local t0 = now_ms()

  -- WILLUSBITMAP -> PIX
  local pixs = _gc_ptr(k2pdfopt.bitmap2pix(kc.src, 0, 0, img_w, img_h), pixDestroy)
  local t1 = now_ms()
  if pixs == nil then return nil end

  -- Get grayscale PIX (skip conversion if already 8bpp)
  local depth = lev.pixGetDepth(pixs)
  local pixg
  if depth == 32 then
    pixg = _gc_ptr(lev.pixConvertRGBToGrayFast(pixs), pixDestroy)
  elseif depth == 8 then
    pixg = pixs
  else
    pixg = _gc_ptr(lev.pixClone(pixs), pixDestroy)
  end
  local t2 = now_ms()
  if pixg == nil then return nil end

  -- Threshold -> binary (pixel >= threshold -> 1=bg, < threshold -> 0=content)
  local pix_binary = _gc_ptr(lev.pixThresholdToBinary(pixg, threshold), pixDestroy)
  local t3 = now_ms()
  if pix_binary == nil then return nil end

  -- Invert binary IN-PLACE (content->1, bg->0) -- O(w*h/8) bytes
  lev.pixInvert(pix_binary, pix_binary)
  local t4 = now_ms()

  -- Find connected components (bounding boxes only)
  local bb = _gc_ptr(lev.pixConnCompBB(pix_binary, 8), boxaDestroy)
  local t5 = now_ms()
  if bb == nil then return nil end

  local num_boxes = lev.boxaGetCount(bb)

  -- Filter components
  local min_x, min_y, max_x, max_y = img_w, img_h, 0, 0
  local found_content = false
  local kept = 0
  local idx = 0
  for box in boxaIterBoxes(bb) do
    idx = idx + 1
    local bx, by, bw, bh = boxGetGeometry(box)
    local touches_border = (bx <= border_max_width)
        or (by <= border_max_width)
        or (bx + bw >= img_w - border_max_width)
        or (by + bh >= img_h - border_max_width)

    if not touches_border then
      local area = bw * bh
      if area >= min_content_area then
        found_content = true
        kept = kept + 1
        if bx < min_x then min_x = bx end
        if by < min_y then min_y = by end
        if bx + bw > max_x then max_x = bx + bw end
        if by + bh > max_y then max_y = by + bh end
      end
    end
  end

  local t6 = now_ms()

  if not found_content then return nil end

  -- Apply margin
  local dpi = kc.dev_dpi
  local margin_px = margin_frac * dpi
  min_x = math.max(0, math.floor(min_x - margin_px))
  min_y = math.max(0, math.floor(min_y - margin_px))
  max_x = math.min(img_w - 1, math.ceil(max_x + margin_px))
  max_y = math.min(img_h - 1, math.ceil(max_y + margin_px))

  -- Sanity check
  if (max_x - min_x) / img_w < 0.1 and (max_y - min_y) / img_h < 0.1 then
    return nil
  end

  -- Store bbox and return zoom-adjusted
  kc.bbox.x0 = min_x
  kc.bbox.y0 = min_y
  kc.bbox.x1 = max_x
  kc.bbox.y1 = max_y

  local zoom = kc.zoom
  local x0, y0, x1, y1 = min_x / zoom, min_y / zoom, max_x / zoom, max_y / zoom

  dbg("  components: %d total, %d kept", num_boxes, kept)
  dbg("  TIME  bitmap2pix:  %.3f ms", t1 - t0)
  dbg("  TIME  grayscale:   %.3f ms", t2 - t1)
  dbg("  TIME  threshold:   %.3f ms", t3 - t2)
  dbg("  TIME  invert-bin:  %.3f ms", t4 - t3)
  dbg("  TIME  conncomp:    %.3f ms", t5 - t4)
  dbg("  TIME  filter:      %.3f ms", t6 - t5)
  dbg("  TIME  TOTAL:       %.3f ms", t6 - t0)
  dbg("  RESULT (%.1f,%.1f,%.1f,%.1f)", x0, y0, x1, y1)
  return x0, y0, x1, y1
end

--- Find the connected component containing a given position.
--- Same pipeline as enhancedCropBmp but returns a single panel, not merged bbox.
--- @param kc any
--- @param pos table  {x, y} in page coordinates
--- @return table|nil  {x, y, w, h} or nil
local function getEnhancedPanel(kc, pos)
  ensureLeptonica()
  local KOPTContext = require("ffi/koptcontext")
  local k2pdfopt    = KOPTContext.k2pdfopt

  local threshold        = loadSetting("threshold")
  local border_max_width = loadSetting("border_max_width")
  local min_content_area = loadSetting("min_content_area")

  local img_w = kc.src.width
  local img_h = kc.src.height

  local pixs = _gc_ptr(k2pdfopt.bitmap2pix(kc.src, 0, 0, img_w, img_h), pixDestroy)
  if pixs == nil then return nil end

  local depth = lev.pixGetDepth(pixs)
  local pixg
  if depth == 32 then
    pixg = _gc_ptr(lev.pixConvertRGBToGrayFast(pixs), pixDestroy)
  elseif depth == 8 then
    pixg = pixs
  else
    pixg = _gc_ptr(lev.pixClone(pixs), pixDestroy)
  end
  if pixg == nil then return nil end

  local pix_binary = _gc_ptr(lev.pixThresholdToBinary(pixg, threshold), pixDestroy)
  if pix_binary == nil then return nil end

  lev.pixInvert(pix_binary, pix_binary)

  local bb = _gc_ptr(lev.pixConnCompBB(pix_binary, 8), boxaDestroy)
  if bb == nil then return nil end

  local t0 = now_ms()

  local best_dist = math.huge
  local best_box = nil

  for box in boxaIterBoxes(bb) do
    local bx, by, bw, bh = boxGetGeometry(box)

    local touches_border = (bx <= border_max_width)
        or (by <= border_max_width)
        or (bx + bw >= img_w - border_max_width)
        or (by + bh >= img_h - border_max_width)

    if not touches_border and bw * bh >= min_content_area then
      local cx = bx + bw / 2
      local cy = by + bh / 2
      local dx = pos.x - cx
      local dy = pos.y - cy
      local dist = dx * dx + dy * dy

      if pos.x >= bx and pos.x <= bx + bw and pos.y >= by and pos.y <= by + bh then
        if dist < best_dist then
          best_dist = dist
          best_box = { x = bx, y = by, w = bw, h = bh }
        end
      end
    end
  end

  local t1 = now_ms()

  if best_box then
    dbg("  getEnhancedPanel pos=(%.0f,%.0f) -> {%d,%d,%d,%d} %.1fms",
      pos.x, pos.y, best_box.x, best_box.y, best_box.w, best_box.h, t1 - t0)
  else
    dbg("  getEnhancedPanel pos=(%.0f,%.0f) -> nil %.1fms", pos.x, pos.y, t1 - t0)
  end

  return best_box
end

return { enhancedCropBmp = enhancedCropBmp, getEnhancedPanel = getEnhancedPanel }
