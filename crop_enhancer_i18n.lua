--- i18n: Lazy-loading translations from l10n/<lang>.lua files.
--- Reads language from KOReader's gettext (GetText.current_lang).
--- Falls back to English (msgid) when no translation is found.

local GetText = require("gettext")

--- Plugin's l10n directory (derived from this file's path)
local SCRIPT_PATH = debug.getinfo(1, "S").source:match("@?(.*/)")
local L10N_DIR = SCRIPT_PATH .. "l10n/"

--- Cache: lang_code → { [msgid] = msgstr, ... }
--- @type table<string, table<string, string>>
local cache = {}

--- Try to load l10n/<lang>.lua, cache it.
--- @param lang string  Language code (e.g., "en", "vi")
--- @return table
local function loadLang(lang)
  if lang == "vi_VN" then
    lang = "vi"
  elseif lang == "ja_JP" then
    lang = "ja"
  end

  if cache[lang] then
    return cache[lang]
  end
  if lang == "en" or lang == "C" then
    cache[lang] = {} -- English = no-op, just use msgid
    return cache[lang]
  end
  local path = L10N_DIR .. lang .. ".lua"
  local ok, result = pcall(dofile, path)
  if ok and type(result) == "table" then
    cache[lang] = result
    return result
  end
  -- Fallback: try just the 2-letter code (e.g., "vi_VN" → "vi")
  local short = lang:match("^(%a%a)")
  if short and short ~= lang then
    return loadLang(short)
  end
  cache[lang] = {}
  return cache[lang]
end

--- Translate a string using KOReader's current language.
--- @param msgid string  English source string
--- @return string
local function translate(msgid)
  local lang = GetText.current_lang
  if lang == "C" or lang == "en" or lang == nil then
    return msgid
  end

  local t = loadLang(lang)
  return t[msgid] or msgid
end

--- Get current language code from KOReader.
--- @return string
local function getLang()
  return GetText.current_lang or "C"
end

--- Manually register a translation at runtime (for extensions).
--- @param lang string      Language code
--- @param msgid string     English source string
--- @param msgstr string    Translated string
local function registerTranslation(lang, msgid, msgstr)
  if not cache[lang] then
    cache[lang] = {}
  end
  cache[lang][msgid] = msgstr
end

return {
  getLang = getLang,
  translate = translate,
  registerTranslation = registerTranslation,
}
