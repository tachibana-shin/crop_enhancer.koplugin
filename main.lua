local WidgetContainer = require("ui/widget/container/widgetcontainer")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local Document = require("document/document")
local CacheItem = require("cacheitem")
local DocCache = require("document/doccache")
local _ = require("gettext")
local T = require("ffi/util").template
local ffi = require("ffi")

local function dbg(fmt, ...)
    print("CropEnhancer: " .. fmt:format(...))
end

local CropEnhancer = WidgetContainer:extend{
    name = "crop_enhancer",
    is_doc_only = true,
}

local crop_enhancer_enabled = true

local SETTINGS_DEFAULTS = {
    threshold = 180,
    border_max_width = 5,
    min_content_area = 50,
    margin = 0.05,
}

local function loadSetting(key)
    local settings = G_reader_settings:readSetting("crop_enhancer", {})
    return settings[key] ~= nil and settings[key] or SETTINGS_DEFAULTS[key]
end

local function saveSetting(key, value)
    local settings = G_reader_settings:readSetting("crop_enhancer", {})
    settings[key] = value
    G_reader_settings:saveSetting("crop_enhancer", settings)
end

--- Leptonica helpers
local leptonica
local function ensureLeptonica()
    if not leptonica then
        leptonica = ffi.loadlib("leptonica", "6")
    end
    return leptonica
end

local function _gc_ptr(p, destructor)
    return p and ffi.gc(p, destructor)
end
local function pixDestroy(pix)
    local lev = ensureLeptonica()
    lev.pixDestroy(ffi.new('PIX *[1]', pix))
    ffi.gc(pix, nil)
end
local function boxDestroy(box)
    local lev = ensureLeptonica()
    lev.boxDestroy(ffi.new('BOX *[1]', box))
    ffi.gc(box, nil)
end
local function boxaDestroy(boxa)
    local lev = ensureLeptonica()
    lev.boxaDestroy(ffi.new('BOXA *[1]', boxa))
    ffi.gc(boxa, nil)
end
local function boxGetGeometry(box)
    local lev = ensureLeptonica()
    local geo = ffi.new('l_int32[4]')
    lev.boxGetGeometry(box, geo, geo + 1, geo + 2, geo + 3)
    return tonumber(geo[0]), tonumber(geo[1]), tonumber(geo[2]), tonumber(geo[3])
end
local function boxaIterBoxes(boxa, count)
    local lev = ensureLeptonica()
    count = count or lev.boxaGetCount(boxa)
    local index = 0
    return function()
        if index < count then
            local box = _gc_ptr(lev.boxaGetBox(boxa, index, lev.L_CLONE), boxDestroy)
            index = index + 1
            return box
        end
    end
end

--- Core enhanced crop algorithm using leptonica connected components.
-- Runs on the WILLUSBITMAP inside a KOPTContext (kc.src).
-- Returns x0, y0, x1, y1 in zoom-adjusted coordinates, or nil to signal fallback.
local function enhancedCropBmp(kc)
    local lev = ensureLeptonica()
    local KOPTContext = require("ffi/koptcontext")
    local k2pdfopt = KOPTContext.k2pdfopt

    local threshold = loadSetting("threshold")
    local border_max_width = loadSetting("border_max_width")
    local min_content_area = loadSetting("min_content_area")
    local margin_frac = loadSetting("margin")

    local img_w = kc.src.width
    local img_h = kc.src.height
    dbg("  src bitmap: %dx%d bpp=%d, threshold=%d, border_max=%d, min_area=%d, margin=%.3f",
        img_w, img_h, kc.src.bpp, threshold, border_max_width, min_content_area, margin_frac)

    -- Convert WILLUSBITMAP to Leptonica PIX
    local pixs = _gc_ptr(k2pdfopt.bitmap2pix(kc.src, 0, 0, img_w, img_h), pixDestroy)
    if pixs == nil then
        dbg("  -> bitmap2pix failed")
        return nil
    end
    dbg("  bitmap2pix ok, depth=%d", lev.pixGetDepth(pixs))

    -- Convert to grayscale if needed
    local pixg
    if lev.pixGetDepth(pixs) == 32 then
        pixg = _gc_ptr(lev.pixConvertRGBToGrayFast(pixs), pixDestroy)
    else
        pixg = _gc_ptr(lev.pixClone(pixs), pixDestroy)
    end
    if pixg == nil then return nil end

    -- Invert (dark content → bright), then threshold (bright → 1)
    local pix_inverted = _gc_ptr(lev.pixInvert(nil, pixg), pixDestroy)
    local pix_binary = _gc_ptr(lev.pixThresholdToBinary(pix_inverted, 255 - threshold), pixDestroy)
    if pix_binary == nil then
        dbg("  -> pixThresholdToBinary failed")
        return nil
    end

    -- Find connected components
    local bb = _gc_ptr(lev.pixConnCompBB(pix_binary, 8), boxaDestroy)
    if bb == nil then
        dbg("  -> pixConnCompBB failed")
        return nil
    end

    local num_boxes = lev.boxaGetCount(bb)
    dbg("  connected components found: %d", num_boxes)

    -- Filter: remove border-touching and small components
    local min_x, min_y, max_x, max_y = img_w, img_h, 0, 0
    local found_content = false
    local idx = 0
    for box in boxaIterBoxes(bb) do
        idx = idx + 1
        local bx, by, bw, bh = boxGetGeometry(box)
        local touches_border = (bx <= border_max_width)
            or (by <= border_max_width)
            or (bx + bw >= img_w - border_max_width)
            or (by + bh >= img_h - border_max_width)

        if touches_border then
            dbg("  component[%d]: x=%d y=%d w=%d h=%d (border)", idx, bx, by, bw, bh)
        else
            local area = bw * bh
            if area >= min_content_area then
                found_content = true
                dbg("  component[%d]: x=%d y=%d w=%d h=%d (kept)", idx, bx, by, bw, bh)
                if bx < min_x then min_x = bx end
                if by < min_y then min_y = by end
                if bx + bw > max_x then max_x = bx + bw end
                if by + bh > max_y then max_y = by + bh end
            else
                dbg("  component[%d]: x=%d y=%d w=%d h=%d (too small %d<%d)", idx, bx, by, bw, bh, area, min_content_area)
            end
        end
    end

    if not found_content then
        dbg("  -> no content found after filtering")
        return nil
    end

    -- Apply margin
    local dpi = kc.dev_dpi
    local margin_px = margin_frac * dpi
    min_x = math.max(0, math.floor(min_x - margin_px))
    min_y = math.max(0, math.floor(min_y - margin_px))
    max_x = math.min(img_w - 1, math.ceil(max_x + margin_px))
    max_y = math.min(img_h - 1, math.ceil(max_y + margin_px))

    -- Sanity check
    local content_w = max_x - min_x
    local content_h = max_y - min_y
    if content_w / img_w < 0.1 and content_h / img_h < 0.1 then
        dbg("  -> content too small (%dx%d vs %dx%d)", content_w, content_h, img_w, img_h)
        return nil
    end

    -- Store bbox in source coordinates
    kc.bbox.x0 = min_x
    kc.bbox.y0 = min_y
    kc.bbox.x1 = max_x
    kc.bbox.y1 = max_y

    local zoom = kc.zoom
    local x0, y0, x1, y1 = min_x / zoom, min_y / zoom, max_x / zoom, max_y / zoom
    dbg("  RESULT: bbox=(%d,%d,%d,%d) zoom=%.2f -> (%.1f,%.1f,%.1f,%.1f)",
        min_x, min_y, max_x, max_y, zoom, x0, y0, x1, y1)
    return x0, y0, x1, y1
end

-- Store original and replaced function references (module-level)
local origGetAutoBBox = nil
local patched = false

function CropEnhancer:init()
    dbg("init()")
    self.ui.menu:registerToMainMenu(self)
    self:patchKoptOptions()

    -- Set default in configurable
    if self.ui.document and self.ui.document.configurable then
        local key = "crop_enhancer"
        if self.ui.document.configurable[key] == nil then
            self.ui.document.configurable[key] = 1
        end
        crop_enhancer_enabled = self.ui.document.configurable[key] == 1
        dbg("  configurable.crop_enhancer = %s -> crop_enhancer_enabled = %s",
            tostring(self.ui.document.configurable[key]), tostring(crop_enhancer_enabled))
    end

    -- Override KoptInterface:getAutoBBox (plain Lua method on a table — safe to patch)
    if not patched then
        local KoptInterface = self.ui.document.koptinterface
        if KoptInterface and KoptInterface.getAutoBBox then
            origGetAutoBBox = KoptInterface.getAutoBBox
            function KoptInterface:getAutoBBox(doc, pageno)
                dbg("getAutoBBox called, crop_enhancer_enabled=%s", tostring(crop_enhancer_enabled))
                if not crop_enhancer_enabled then
                    dbg("  -> original (disabled)")
                    return origGetAutoBBox(self, doc, pageno)
                end

                -- Replicate the original method but replace the kc:getAutoBBox() call
                local native_size = Document.getNativePageDimensions(doc, pageno)
                local bbox = { x0 = 0, y0 = 0, x1 = native_size.w, y1 = native_size.h }
                local hash_list = { "enhanced_bbox" }
                self:getContextHash(doc, pageno, bbox, hash_list)
                local hash = table.concat(hash_list, "|")
                local cached = DocCache:check(hash)
                if cached then
                    dbg("  -> cached")
                    return cached.autobbox
                end

                local page = doc._document:openPage(pageno)
                local kc = self:createContext(doc, pageno, bbox)
                page:getPagePix(kc, doc.render_mode, doc.configurable.background_cleanup)

                local x0, y0, x1, y1 = enhancedCropBmp(kc)
                local w, h = native_size.w, native_size.h

                if x0 and (x1 - x0)/w > 0.1 or (y1 - y0)/h > 0.1 then
                    bbox.x0, bbox.y0, bbox.x1, bbox.y1 = x0, y0, x1, y1
                else
                    dbg("  -> enhanced result too small or failed, trying original kc:getAutoBBox()")
                    x0, y0, x1, y1 = kc:getAutoBBox()
                    if (x1 - x0)/w > 0.1 or (y1 - y0)/h > 0.1 then
                        bbox.x0, bbox.y0, bbox.x1, bbox.y1 = x0, y0, x1, y1
                    else
                        bbox = Document.getPageBBox(doc, pageno)
                    end
                end

                DocCache:insert(hash, CacheItem:new{ autobbox = bbox, size = 160 })
                page:close()
                kc:free()
                return bbox
            end
            patched = true
            dbg("  KoptInterface:getAutoBBox overridden")
        else
            dbg("  WARNING: KoptInterface not found (no koptinterface for this document?)")
        end
    end

    self:onDispatcherRegisterActions()
end

function CropEnhancer:patchKoptOptions()
    dbg("patchKoptOptions()")
    local KoptOptions = require("ui/data/koptoptions")
    local optionsutil = require("ui/data/optionsutil")

    local crop_panel
    for _, panel in ipairs(KoptOptions) do
        if panel.icon == "appbar.crop" then
            crop_panel = panel
            break
        end
    end
    if not crop_panel then return end

    for _, opt in ipairs(crop_panel.options) do
        if opt.name == "crop_enhancer" then return end
    end

    table.insert(crop_panel.options, {
        name = "crop_enhancer",
        name_text = _("Enhanced Crop"),
        toggle = {_("off"), _("on")},
        values = {0, 1},
        default_value = 1,
        event = "CropEnhancerToggle",
        args = {false, true},
        name_text_hold_callback = optionsutil.showValues,
        help_text = _([[Replaces the built-in auto-crop algorithm with a more aggressive one that uses connected component analysis to better detect content borders and margins.]]),
    })
end

function CropEnhancer:onDispatcherRegisterActions()
    local Dispatcher = require("dispatcher")
    Dispatcher:registerAction("crop_enhancer_toggle",
        {category="none", event="CropEnhancerToggle", title=_("Toggle Enhanced Crop"), general=true})
end

function CropEnhancer:onCropEnhancerToggle(args)
    dbg("onCropEnhancerToggle: args=%s (type=%s)", tostring(args), type(args))
    if args == true then
        crop_enhancer_enabled = true
    elseif args == false then
        crop_enhancer_enabled = false
    else
        crop_enhancer_enabled = not crop_enhancer_enabled
    end
    dbg("  crop_enhancer_enabled -> %s", tostring(crop_enhancer_enabled))
    if self.ui.document and self.ui.document.configurable then
        self.ui.document.configurable.crop_enhancer = crop_enhancer_enabled and 1 or 0
    end
end

function CropEnhancer:addToMainMenu(menu_items)
    menu_items.crop_enhancer = {
        text = _("Enhanced Crop Settings"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text = _("Crop Threshold"),
                text_func = function()
                    return T(_("Threshold: %1"), loadSetting("threshold"))
                end,
                callback = function(touchmenu_instance)
                    UIManager:show(SpinWidget:new{
                        title_text = _("Crop Threshold"),
                        info_text = _("Pixels darker than this value are considered content. Lower = more aggressive."),
                        value = loadSetting("threshold"),
                        default_value = SETTINGS_DEFAULTS.threshold,
                        value_min = 50,
                        value_max = 250,
                        value_step = 5,
                        value_hold_step = 20,
                        ok_always_enabled = true,
                        callback = function(spin)
                            saveSetting("threshold", spin.value)
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                    })
                end,
                keep_menu_open = true,
            },
            {
                text = _("Border Max Width"),
                text_func = function()
                    return T(_("Border Width: %1 px"), loadSetting("border_max_width"))
                end,
                callback = function(touchmenu_instance)
                    UIManager:show(SpinWidget:new{
                        title_text = _("Border Max Width"),
                        info_text = _("Components touching the image edge within this many pixels are treated as border and removed."),
                        value = loadSetting("border_max_width"),
                        default_value = SETTINGS_DEFAULTS.border_max_width,
                        value_min = 0,
                        value_max = 30,
                        value_step = 1,
                        value_hold_step = 5,
                        ok_always_enabled = true,
                        callback = function(spin)
                            saveSetting("border_max_width", spin.value)
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                    })
                end,
                keep_menu_open = true,
            },
            {
                text = _("Min Content Area"),
                text_func = function()
                    return T(_("Min Area: %1 px²"), loadSetting("min_content_area"))
                end,
                callback = function(touchmenu_instance)
                    UIManager:show(SpinWidget:new{
                        title_text = _("Min Content Area"),
                        info_text = _("Components smaller than this area (width × height) are treated as noise."),
                        value = loadSetting("min_content_area"),
                        default_value = SETTINGS_DEFAULTS.min_content_area,
                        value_min = 0,
                        value_max = 500,
                        value_step = 10,
                        value_hold_step = 50,
                        ok_always_enabled = true,
                        callback = function(spin)
                            saveSetting("min_content_area", spin.value)
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                    })
                end,
                keep_menu_open = true,
            },
            {
                text = _("Crop Margin"),
                text_func = function()
                    return T(_("Margin: %1 %%"), math.floor(loadSetting("margin") * 100))
                end,
                callback = function(touchmenu_instance)
                    UIManager:show(SpinWidget:new{
                        title_text = _("Crop Margin"),
                        info_text = _("Extra margin to add around the detected content (as fraction of page DPI)."),
                        value = math.floor(loadSetting("margin") * 100),
                        default_value = math.floor(SETTINGS_DEFAULTS.margin * 100),
                        value_min = 0,
                        value_max = 30,
                        value_step = 1,
                        value_hold_step = 5,
                        unit = "%",
                        precision = "%1d",
                        ok_always_enabled = true,
                        callback = function(spin)
                            saveSetting("margin", spin.value / 100)
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                    })
                end,
                keep_menu_open = true,
            },
        },
    }
end

return CropEnhancer
