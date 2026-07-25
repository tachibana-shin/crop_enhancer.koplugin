# AGENTS.md — crop_enhancer.koplugin

## What this plugin does

Replaces KOReader's built-in page auto-crop algorithm (`KoptInterface:getAutoBBox`) with
leptonica connected-component analysis. Better at ignoring thin borders, page-edge noise,
and scan artifacts that fool the original pixel-counting approach.

Target device: Kindle PW3 (Cortex-A9 1GHz, 512MB RAM). Performance matters.

## File structure

```
crop_enhancer.koplugin/
├── _meta.lua                    Plugin metadata (fullname, version, description)
├── crop_enhancer_info.lua       Version, author, GitHub URL
├── crop_enhancer_settings.lua   SETTINGS_DEFAULTS, loadSetting, saveSetting
├── crop_enhancer_logger.lua     dbg() (respects debug_log), now_ms()
├── crop_enhancer_detect.lua     Leptonica pipeline: bitmap2pix → threshold → invert → conncomp → bbox
├── crop_enhancer_i18n.lua       Lazy-loading translations from l10n/<lang>.lua
├── main.lua                     Plugin entry: UI, events, KoptInterface override, menu
└── l10n/
    ├── en.lua                   English
    ├── vi.lua                   Tiếng Việt
    ├── ja.lua                   日本語
    ├── zh.lua                   简体中文
    └── zh_TW.lua                繁體中文
```

## Dependency graph (no circular)

```
main.lua
  ├── crop_enhancer_i18n
  ├── crop_enhancer_settings
  ├── crop_enhancer_logger
  └── crop_enhancer_detect
        ├── crop_enhancer_settings
        └── crop_enhancer_logger
```

## Architecture

### Core override (`main.lua:55-119`)

The plugin monkey-patches `KoptInterface:getAutoBBox(doc, pageno)` — a plain Lua method
on a table. This is the only safe override point.

**Why not override the FFI cdata directly?**
LuaJIT FFI cdata metatypes are NOT patchable via `getmetatable`. The `KOPTContext_mt`
in `base/ffi/koptcontext.lua:81` creates a C metatype at line 595 — invisible to Lua.
`getmetatable(kc)` does NOT return the Lua table `KOPTContext_mt.__index`.

**Why `KoptInterface:getAutoBBox`?**
- It's a plain Lua method on `KoptInterface` (a table)
- Called by `ReaderKoptListener` during page zoom/scroll
- Has access to `doc`, `pageno`, and can create `KOPTContext`

### Fallback chain (`main.lua:90-98`)

```
enhancedCropBmp(kc)          -- leptonica connected components
  ↓ nil (no content found)
kc:getAutoBBox()             -- original KOPTContext method
  ↓ nil (too small)
Document.getPageBBox(doc)    -- KOReader fallback
```

### Settings flow

```
G_reader_settings (persistent)
  ↕ loadSetting / saveSetting        crop_enhancer_settings.lua
  ↕
configurable (per-document)          set in init() + every event handler
  ↕
KOPTContext fields                   read by enhancedCropBmp()
```

Settings are synced: `G_reader_settings` ↔ `configurable` on init and every event handler.

### Leptonica pipeline (`crop_enhancer_detect.lua`)

```
bitmap2pix(kc.src)           WILLUSBITMAP → PIX
  ↓
pixConvertRGBToGrayFast      32bpp → 8bpp (skip if already 8bpp)
  ↓
pixThresholdToBinary         grayscale → binary (threshold)
  ↓
pixInvert (in-place)         content→1, bg→0   O(w×h/8) bytes
  ↓
pixConnCompBB                connected components → BOXA of bounding boxes
  ↓
filter: discard              - border-touching (within border_max_width px)
                             - small (< min_content_area px²)
  ↓
merge kept boxes → bbox      + margin (fraction of DPI)
```

### i18n (`crop_enhancer_i18n.lua`)

- Reads `GetText.current_lang` from KOReader's gettext
- Lazy-loads `l10n/<lang>.lua` on first use, then cached
- Fallback: `vi_VN` → `vi` → English (msgid)
- Adding a language: just create `l10n/<2_letter_code>.lua`
- Module is named `crop_enhancer_i18n` (not `i18n`) to avoid namespace collisions

### UI injection (`main.lua:124-248`)

`patchKoptOptions()` injects 5 items into the `appbar.crop` panel in `koptoptions.lua`:
- Toggle (on/off) + 4 settings with `more_options` SpinWidget
- Each setting has `enabled_func` that disables when enhanced crop is off
- Uses `toggle` style (like `auto_straighten`) with text labels

### Dispatcher actions (`main.lua:250-262`)

5 actions registered for key/gesture binding:
- `crop_enhancer_toggle`
- `crop_enhancer_threshold`
- `crop_enhancer_border_width`
- `crop_enhancer_min_area`
- `crop_enhancer_margin`

### Events

| Event | Handler | Effect |
|---|---|---|
| `CropEnhancerToggle` | `onCropEnhancerToggle` | Toggle on/off |
| `CropEnhancerThreshold` | `onCropEnhancerThreshold` | Save threshold |
| `CropEnhancerBorderWidth` | `onCropEnhancerBorderWidth` | Save border_max_width |
| `CropEnhancerMinArea` | `onCropEnhancerMinArea` | Save min_content_area |
| `CropEnhancerMargin` | `onCropEnhancerMargin` | Save margin |

## Conventions

- **No comments in code** unless asked
- **No per-function `local lev = lev.pixFoo` caching** — LuaJIT already optimizes table lookups; only the library handle `lev` is cached
- **Binary invert** (`pixInvert` on binary) not grayscale — verified faster on Kindle PW3
- **`os.clock() * 1000`** for timing (ms). Use `now_ms()` from logger module
- **`dbg()` respects `debug_log`** setting — reads from `G_reader_settings` each call
- **ffi cdata types** → `any`/`table` in luaLS annotations (luaLS can't resolve `ffi.cdata*`)
- **ConfigDialog** `buttonprogress` reads `configurable[name]` for position; settings must be synced before UI renders

## Lint

```bash
luacheck plugins/crop_enhancer.koplugin/ --no-color
```

Expected: 0 warnings / 0 errors.

## Test images

`3.jpg`, `4.jpg`, `5.jpg` — WebP 900x1293, black borders 1-9px, internal margins.
Use these to verify trimming behavior.

## Key KOReader source references

| File | Lines | What |
|---|---|---|
| `base/ffi/koptcontext.lua` | 81, 595 | `KOPTContext_mt` — FFI metatype, NOT patchable |
| `base/ffi/koptcontext.lua` | 380-389 | Original `getAutoBBox()` on metatable |
| `base/ffi/leptonica_h.lua` | — | All leptonica FFI bindings |
| `frontend/document/koptinterface.lua` | 209-239 | `KoptInterface:getAutoBBox()` — override target |
| `frontend/document/koptinterface.lua` | 133-170 | `createContext()` — reads `doc.configurable` |
| `frontend/ui/data/koptoptions.lua` | 95-155 | `appbar.crop` panel — injection target |
| `frontend/apps/reader/modules/readerkoptlistener.lua` | 91-99 | `onConfigChange` sets `configurable[name]`, returns `true` |
| `frontend/ui/widget/configdialog.lua` | 597-617 | buttonprogress reads `configurable[name]` |
| `frontend/configurable.lua` | 30-43 | `loadDefaults()` iterates options |
