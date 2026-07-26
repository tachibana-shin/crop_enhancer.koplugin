# Crop Enhancer Plugin for KOReader

Replaces KOReader's built-in page auto-crop algorithm with leptonica connected-component analysis. Better at ignoring thin borders, page-edge noise, and scan artifacts that fool the original pixel-counting approach.

## Features

- **Enhanced auto-crop** — leptonica connected-component analysis replaces the default `k2pdfopt_crop_bmp` pipeline. Detects content regions more accurately on scanned documents with thin borders or noise.
- **Panel zoom** — overrides `getPanelFromPage` with the same leptonica pipeline, finding the specific panel at the touch position.
- **Configurable** — threshold, border width, minimum content area, and margin are all adjustable via the bottom toolbar or Settings menu.
- **Dispatcher actions** — all settings are available as Dispatcher actions for key/gesture binding.
- **i18n** — English, Vietnamese, Japanese, Simplified Chinese, Traditional Chinese.

## Requirements

- KOReader (tested on Kindle PW3)
- Leptonica (bundled with KOReader)

## Installation

Copy `crop_enhancer.koplugin/` to `koreader/plugins/`:

```
koreader/plugins/crop_enhancer.koplugin/
```

## Settings

| Setting | Default | Description |
|---|---|---|
| Threshold | 180 | Grayscale threshold (0-255). Pixels below this are considered content. |
| Border max width | 5 | Components within this many pixels of the page edge are discarded. |
| Min content area | 50 | Minimum bounding-box area (px²) to count as content. |
| Margin | 0.05 | Extra margin around detected content (fraction of DPI). |
| Debug log | off | Print timing and pipeline details to the log. |

Access via: **Bottom toolbar (crop panel) > Enhanced Crop** or **Tools > Enhanced Crop Settings**.

## How it works

```
bitmap2pix(kc.src)
  → pixConvertRGBToGrayFast     (32bpp → 8bpp)
  → pixThresholdToBinary        (grayscale → binary)
  → pixInvert (in-place)        (content → 1, bg → 0)
  → pixConnCompBB               (connected components → bounding boxes)
  → filter: discard border-touching and small components
  → merge kept boxes → bbox
```

### Auto-crop (`getAutoBBox`)

Merges all kept components into a single bounding box. Falls back to the original KOPTContext method if leptonica finds nothing useful.

### Panel zoom (`getPanelFromPage`)

Returns the single connected component that contains the touch position. Falls back to the original KOReader panel detection if no matching component is found.

## License

This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://www.mozilla.org/MPL/2.0/.
