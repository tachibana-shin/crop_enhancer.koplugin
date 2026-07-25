local loadSetting = require("crop_enhancer_settings").loadSetting

--- @return number  Milliseconds since Lua epoch
local function now_ms()
  return os.clock() * 1000
end

--- @param fmt string  Format string
--- @param ... any     Format arguments
local function dbg(fmt, ...)
  if loadSetting("debug_log") then
    print("CropEnhancer: " .. fmt:format(...))
  end
end

return { now_ms = now_ms, dbg = dbg }
