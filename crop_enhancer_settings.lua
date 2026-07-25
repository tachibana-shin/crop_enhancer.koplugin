--- @class CropEnhancerSettings
--- @field threshold        number  Grayscale threshold (0-255) for content detection
--- @field border_max_width number  Components within this many px of edge are border
--- @field min_content_area number  Minimum bounding-box area to count as content
--- @field margin           number  Extra margin around detected content (fraction of DPI)
--- @field debug_log        boolean Enable debug logging
local SETTINGS_DEFAULTS = {
  threshold = 180,
  border_max_width = 5,
  min_content_area = 50,
  margin = 0.05,
  debug_log = false,
}

--- @param key string  Setting key
--- @return number
local function loadSetting(key)
  local settings = G_reader_settings:readSetting("crop_enhancer", {})
  ---@diagnostic disable-next-line: return-type-mismatch
  return settings[key] ~= nil and settings[key] or SETTINGS_DEFAULTS[key]
end

local function saveSetting(key, value)
  local settings = G_reader_settings:readSetting("crop_enhancer", {})
  settings[key] = value
  G_reader_settings:saveSetting("crop_enhancer", settings)
end

return {
  SETTINGS_DEFAULTS = SETTINGS_DEFAULTS,
  loadSetting = loadSetting,
  saveSetting = saveSetting,
}
