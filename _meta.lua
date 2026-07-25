local _ = require("gettext")
local info = require("crop_enhancer_info")

return {
  fullname = _("Enhanced Crop"),
  version = info.version,
  description = _(
    "Replaces the built-in page crop algorithm with a more aggressive one that better handles borders and margins."),
}
