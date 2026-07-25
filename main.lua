local WidgetContainer = require("ui/widget/container/widgetcontainer")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local Document = require("document/document")
local CacheItem = require("cacheitem")
local DocCache = require("document/doccache")
local T = require("ffi/util").template

local i18n = require("crop_enhancer_i18n")
local _ = i18n.translate

local detect = require("crop_enhancer_detect")
local enhancedCropBmp, getEnhancedPanel = detect.enhancedCropBmp, detect.getEnhancedPanel
local settings = require("crop_enhancer_settings")
local loadSetting, saveSetting, SETTINGS_DEFAULTS = settings.loadSetting, settings.saveSetting,
    settings.SETTINGS_DEFAULTS

local logger = require("crop_enhancer_logger")
local now_ms, dbg = logger.now_ms, logger.dbg

--- @class CropEnhancer

local CropEnhancer = WidgetContainer:extend {
  name = "crop_enhancer",
  is_doc_only = true,
}

--- @type boolean
local crop_enhancer_enabled = true

local origGetAutoBBox = nil
local patched = false
local patched_panel = false

function CropEnhancer:init()
  dbg("init() lang=%s", i18n.getLang())
  self.ui.menu:registerToMainMenu(self)
  self:patchKoptOptions()

  if self.ui.document and self.ui.document.configurable then
    local key = "crop_enhancer"
    if self.ui.document.configurable[key] == nil then
      self.ui.document.configurable[key] = 1
    end
    crop_enhancer_enabled = self.ui.document.configurable[key] == 1

    local c = self.ui.document.configurable
    if c.crop_threshold == nil then c.crop_threshold = loadSetting("threshold") end
    if c.crop_border_max_width == nil then c.crop_border_max_width = loadSetting("border_max_width") end
    if c.crop_min_content_area == nil then c.crop_min_content_area = loadSetting("min_content_area") end
    if c.crop_margin == nil then c.crop_margin = loadSetting("margin") end

    dbg("  configurable.crop_enhancer=%s enabled=%s",
      tostring(self.ui.document.configurable[key]), tostring(crop_enhancer_enabled))
  end

  if not patched then
    local KoptInterface = self.ui.document.koptinterface
    if KoptInterface and KoptInterface.getAutoBBox then
      origGetAutoBBox = KoptInterface.getAutoBBox
      function KoptInterface:getAutoBBox(doc, pageno)
        dbg("getAutoBBox enabled=%s", tostring(crop_enhancer_enabled))
        if not crop_enhancer_enabled then
          return origGetAutoBBox(self, doc, pageno)
        end

        local t_start = now_ms()

        local native_size = Document.getNativePageDimensions(doc, pageno)
        local bbox = { x0 = 0, y0 = 0, x1 = native_size.w, y1 = native_size.h }
        local hash_list = { "enhanced_bbox" }
        self:getContextHash(doc, pageno, bbox, hash_list)
        local hash = table.concat(hash_list, "|")
        local cached = DocCache:check(hash)
        if cached then
          dbg("  cache hit (%.3f ms)", now_ms() - t_start)
          return cached.autobbox
        end

        local page = doc._document:openPage(pageno)
        local t_page = now_ms()

        local kc = self:createContext(doc, pageno, bbox)
        page:getPagePix(kc, doc.render_mode, doc.configurable.background_cleanup)
        local t_pix = now_ms()

        local x0, y0, x1, y1 = enhancedCropBmp(kc)
        local t_crop = now_ms()

        local w, h = native_size.w, native_size.h

        if x0 and ((x1 - x0) / w > 0.1 or (y1 - y0) / h > 0.1) then
          bbox.x0, bbox.y0, bbox.x1, bbox.y1 = x0, y0, x1, y1
        else
          x0, y0, x1, y1 = kc:getAutoBBox()
          if (x1 - x0) / w > 0.1 or (y1 - y0) / h > 0.1 then
            bbox.x0, bbox.y0, bbox.x1, bbox.y1 = x0, y0, x1, y1
          else
            bbox = Document.getPageBBox(doc, pageno)
          end
        end

        DocCache:insert(hash, CacheItem:new { autobbox = bbox, size = 160 })
        page:close()
        kc:free()

        local t_end = now_ms()
        dbg("  TIME  openPage:     %.3f ms", t_page - t_start)
        dbg("  TIME  getPagePix:   %.3f ms", t_pix - t_page)
        dbg("  TIME  leptonica:    %.3f ms  (see per-step above)", t_crop - t_pix)
        dbg("  TIME  full pipeline:%.3f ms", t_end - t_start)

        return bbox
      end

      patched = true
      dbg("  KoptInterface:getAutoBBox overridden")
    else
      dbg("  WARNING: KoptInterface not found (no koptinterface for this document?)")
    end
  end

  if not patched_panel then
    local KoptInterface = self.ui.document.koptinterface
    if KoptInterface and KoptInterface.getPanelFromPage then
      local origGetPanelFromPage = KoptInterface.getPanelFromPage
      function KoptInterface:getPanelFromPage(doc, pageno, pos)
        if not crop_enhancer_enabled then
          return origGetPanelFromPage(self, doc, pageno, pos)
        end

        local page_size = Document.getNativePageDimensions(doc, pageno)
        local bbox = { x0 = 0, y0 = 0, x1 = page_size.w, y1 = page_size.h }
        local kc = self:createContext(doc, pageno, bbox)
        kc:setZoom(1.0)
        local page = doc._document:openPage(pageno)
        page:getPagePix(kc, doc.render_mode, doc.configurable.background_cleanup)

        local panel = getEnhancedPanel(kc, pos)
        page:close()
        kc:free()

        if panel then
          return panel
        end

        return origGetPanelFromPage(self, doc, pageno, pos)
      end
      patched_panel = true
      dbg("  KoptInterface:getPanelFromPage overridden")
    end
  end

  self:onDispatcherRegisterActions()
end

function CropEnhancer:patchKoptOptions()
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
    toggle = { _("off"), _("on") },
    values = { 0, 1 },
    default_value = 1,
    event = "CropEnhancerToggle",
    args = { false, true },
    name_text_hold_callback = optionsutil.showValues,
    help_text = _([[Replaces the built-in auto-crop algorithm with connected component analysis.]]),
  })

  table.insert(crop_panel.options, {
    name = "crop_threshold",
    name_text = _("Threshold"),
    toggle = { "100", "128", "150", "180", "200", "220" },
    values = { 100, 128, 150, 180, 200, 220 },
    enabled_func = function(configurable)
      return configurable.crop_enhancer == 1
    end,
    default_value = SETTINGS_DEFAULTS.threshold,
    event = "CropEnhancerThreshold",
    args = { 100, 128, 150, 180, 200, 220 },
    more_options = true,
    more_options_param = {
      unit = "",
      value_step = 1,
      value_hold_step = 10,
      value_min = 50,
      value_max = 250,
      precision = "%d",
    },
    name_text_hold_callback = optionsutil.showValues,
    help_text = _([[Pixels darker than this value are considered content.]]),
  })

  table.insert(crop_panel.options, {
    name = "crop_border_max_width",
    name_text = _("Border Width"),
    toggle = { "0px", "1px", "2px", "3px", "5px", "8px", "10px" },
    values = { 0, 1, 2, 3, 5, 8, 10 },
    enabled_func = function(configurable)
      return configurable.crop_enhancer == 1
    end,
    default_value = SETTINGS_DEFAULTS.border_max_width,
    event = "CropEnhancerBorderWidth",
    args = { 0, 1, 2, 3, 5, 8, 10 },
    more_options = true,
    more_options_param = {
      unit = "px",
      value_step = 1,
      value_hold_step = 2,
      value_min = 0,
      value_max = 30,
      precision = "%d",
    },
    name_text_hold_callback = optionsutil.showValues,
    help_text = _([[Components within this many pixels of the edge are treated as border.]]),
  })

  table.insert(crop_panel.options, {
    name = "crop_min_content_area",
    name_text = _("Min Area"),
    toggle = { "10", "20", "50", "100", "200", "500" },
    values = { 10, 20, 50, 100, 200, 500 },
    enabled_func = function(configurable)
      return configurable.crop_enhancer == 1
    end,
    default_value = SETTINGS_DEFAULTS.min_content_area,
    event = "CropEnhancerMinArea",
    args = { 10, 20, 50, 100, 200, 500 },
    more_options = true,
    more_options_param = {
      unit = "px²",
      value_step = 10,
      value_hold_step = 50,
      value_min = 0,
      value_max = 500,
      precision = "%d",
    },
    name_text_hold_callback = optionsutil.showValues,
    help_text = _([[Components smaller than this are treated as noise.]]),
  })

  table.insert(crop_panel.options, {
    name = "crop_margin",
    name_text = _("Margin"),
    toggle = { "0%", "2%", "5%", "10%", "15%", "20%" },
    values = { 0, 0.02, 0.05, 0.10, 0.15, 0.20 },
    enabled_func = function(configurable)
      return configurable.crop_enhancer == 1
    end,
    default_value = SETTINGS_DEFAULTS.margin,
    event = "CropEnhancerMargin",
    args = { 0, 0.02, 0.05, 0.10, 0.15, 0.20 },
    more_options = true,
    more_options_param = {
      unit = "%",
      value_step = 0.01,
      value_hold_step = 0.05,
      value_min = 0,
      value_max = 0.30,
      precision = "%.2f",
    },
    name_text_hold_callback = optionsutil.showValues,
    help_text = _([[Extra margin around detected content.]]),
  })
end

function CropEnhancer:onDispatcherRegisterActions()
  local Dispatcher = require("dispatcher")
  Dispatcher:registerAction("crop_enhancer_toggle",
    { category = "none", event = "CropEnhancerToggle", title = _("Toggle Enhanced Crop"), general = true })
  Dispatcher:registerAction("crop_enhancer_threshold",
    { category = "none", event = "CropEnhancerThreshold", title = _("Crop Threshold"), general = true })
  Dispatcher:registerAction("crop_enhancer_border_width",
    { category = "none", event = "CropEnhancerBorderWidth", title = _("Crop Border Width"), general = true })
  Dispatcher:registerAction("crop_enhancer_min_area",
    { category = "none", event = "CropEnhancerMinArea", title = _("Crop Min Area"), general = true })
  Dispatcher:registerAction("crop_enhancer_margin",
    { category = "none", event = "CropEnhancerMargin", title = _("Crop Margin"), general = true })
end

function CropEnhancer:onCropEnhancerToggle(args)
  if args == true then
    crop_enhancer_enabled = true
  elseif args == false then
    crop_enhancer_enabled = false
  else
    crop_enhancer_enabled = not crop_enhancer_enabled
  end
  dbg("toggle -> %s", tostring(crop_enhancer_enabled))
  if self.ui.document and self.ui.document.configurable then
    self.ui.document.configurable.crop_enhancer = crop_enhancer_enabled and 1 or 0
  end
end

function CropEnhancer:onCropEnhancerThreshold(args)
  saveSetting("threshold", args)
  if self.ui.document and self.ui.document.configurable then
    self.ui.document.configurable.crop_threshold = args
  end
  dbg("threshold -> %d", args)
end

function CropEnhancer:onCropEnhancerBorderWidth(args)
  saveSetting("border_max_width", args)
  if self.ui.document and self.ui.document.configurable then
    self.ui.document.configurable.crop_border_max_width = args
  end
  dbg("border_max_width -> %d", args)
end

function CropEnhancer:onCropEnhancerMinArea(args)
  saveSetting("min_content_area", args)
  if self.ui.document and self.ui.document.configurable then
    self.ui.document.configurable.crop_min_content_area = args
  end
  dbg("min_content_area -> %d", args)
end

function CropEnhancer:onCropEnhancerMargin(args)
  saveSetting("margin", args)
  if self.ui.document and self.ui.document.configurable then
    self.ui.document.configurable.crop_margin = args
  end
  dbg("margin -> %.2f", args)
end

function CropEnhancer:addToMainMenu(menu_items)
  menu_items.crop_enhancer = {
    text = _("Enhanced Crop Settings"),
    sub_item_table = {
      {
        text = _("Enhanced Crop"),
        checked_func = function()
          return crop_enhancer_enabled
        end,
        callback = function()
          crop_enhancer_enabled = not crop_enhancer_enabled
          if self.ui.document and self.ui.document.configurable then
            self.ui.document.configurable.crop_enhancer = crop_enhancer_enabled and 1 or 0
          end
          dbg("menu toggle -> %s", tostring(crop_enhancer_enabled))
        end,
      },
      {
        text = _("Debug Log"),
        checked_func = function()
          return loadSetting("debug_log") == true
        end,
        callback = function()
          saveSetting("debug_log", not loadSetting("debug_log"))
          dbg("debug_log -> %s", tostring(loadSetting("debug_log")))
        end,
      },
      {
        text_func = function()
          return T(_("Threshold: %1"), loadSetting("threshold"))
        end,
        enabled_func = function()
          return crop_enhancer_enabled
        end,
        callback = function(touchmenu_instance)
          UIManager:show(SpinWidget:new {
            title_text = _("Crop Threshold"),
            info_text = _("Pixels darker than this value are considered content."),
            value = loadSetting("threshold"),
            default_value = SETTINGS_DEFAULTS.threshold,
            value_min = 50, value_max = 250,
            value_step = 5, value_hold_step = 20,
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
        text_func = function()
          return T(_("Border Width: %1 px"), loadSetting("border_max_width"))
        end,
        enabled_func = function()
          return crop_enhancer_enabled
        end,
        callback = function(touchmenu_instance)
          UIManager:show(SpinWidget:new {
            title_text = _("Border Max Width"),
            info_text = _("Components within this many pixels of the edge are treated as border."),
            value = loadSetting("border_max_width"),
            default_value = SETTINGS_DEFAULTS.border_max_width,
            value_min = 0, value_max = 30,
            value_step = 1, value_hold_step = 5,
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
        text_func = function()
          return T(_("Min Area: %1 px²"), loadSetting("min_content_area"))
        end,
        enabled_func = function()
          return crop_enhancer_enabled
        end,
        callback = function(touchmenu_instance)
          UIManager:show(SpinWidget:new {
            title_text = _("Min Content Area"),
            info_text = _("Components smaller than this are treated as noise."),
            value = loadSetting("min_content_area"),
            default_value = SETTINGS_DEFAULTS.min_content_area,
            value_min = 0, value_max = 500,
            value_step = 10, value_hold_step = 50,
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
        text_func = function()
          return T(_("Margin: %1%"), math.floor(loadSetting("margin") * 100))
        end,
        enabled_func = function()
          return crop_enhancer_enabled
        end,
        callback = function(touchmenu_instance)
          UIManager:show(SpinWidget:new {
            title_text = _("Crop Margin"),
            info_text = _("Extra margin around detected content."),
            value = math.floor(loadSetting("margin") * 100),
            default_value = math.floor(SETTINGS_DEFAULTS.margin * 100),
            value_min = 0, value_max = 30,
            value_step = 1, value_hold_step = 5,
            unit = "%", precision = "%1d",
            ok_always_enabled = true,
            callback = function(spin)
              saveSetting("margin", spin.value / 100)
              if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
          })
        end,
        keep_menu_open = true,
      },
      {
        text = _("About"),
        callback = function()
          local InfoMessage = require("ui/widget/infomessage")
          local info = require("crop_enhancer_info")
          UIManager:show(InfoMessage:new {
            title = _("Enhanced Crop"),
            text = T(_("%1\n\nVersion: %2\nAuthor: %3\nGitHub: %4"),
              _("Enhanced Crop — Connected component analysis for better page trimming."),
              info.version,
              info.author,
              info.github),
          })
        end,
      },
    },
  }
end

return CropEnhancer
