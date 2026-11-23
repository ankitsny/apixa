# Apixa

A native macOS app for culling and developing a card full of photos. It stacks bursts and near-duplicates,
rates every shot, lets you keep or reject quickly, edits RAW and JPEG non-destructively, applies Sony
Creative Looks, and moves rejects to the Trash (undoable).

Built with SwiftUI, Vision and Core Image's RAW 9 decoder. No third-party dependencies.

- **Cull:** stacks of similar shots, automatic 1–5★ ratings with a full breakdown, keep / reject, best-of-stack pick.
- **Develop:** exposure, tone, curves, colour, noise reduction, crop and straighten, Apple's auto-enhance, before/after,
  histogram / RGB waveform / vectorscope.
- **Looks:** Sony Creative Looks learned from Sony's own renders, importable recipes, Picture Profiles, Apple photo filters.
- **Organise:** locations (bulk geotag, map heatmap), face naming, star ratings and locations written into files as metadata.
- **Safe:** originals are never modified beyond metadata, nothing is deleted (Trash only), and everything can be undone.

## Build

Requires **macOS 27**, Xcode 27 (or its Command Line Tools) and the Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`), which compiles the Core Image kernels in `Kernels/`.

```bash
./build.sh
open Apixa.app            # optionally: mv Apixa.app /Applications/
```

Builds in Swift 6 language mode with no third-party dependencies. `Compat.swift` aliases SwiftUI's `State`
property wrapper as `@ViewState`, because the macOS 27 SDK makes `@State` a macro whose plugin ships only
with full Xcode. Once Xcode is installed, `@ViewState` can go back to `@State`.

## Releases

Every push to `main` runs [`.github/workflows/release.yml`](.github/workflows/release.yml): it builds the app on a
macOS 27 runner, runs a smoke test, and publishes `Apixa-<version>.zip` as a GitHub release (version = the one in
`Info.plist` plus the run number, e.g. `1.0.12`). The build is ad-hoc signed and not notarized, so on first launch
right-click the app and choose Open.

## How it works

| Step | What |
|---|---|
| Pair | `DSC0012.ARW` + `DSC0012.JPG` in the same folder = one shot |
| Fingerprint | Vision feature print on a 1600px decode (RAW → embedded preview, ~10 ms/shot) |
| Stack | Sorted by EXIF capture time; consecutive shots within the **time gap** that look alike are grouped. The longer the gap between two shots, the more alike they must look, so a new composition starts a new stack. Runs off the main thread. |
| Rate | Face capture quality and aesthetics (both ranked within the folder) plus exposure, gated by an in-focus check measured on the frame and on the largest face. Stars are a rank within the folder (top 10% → 5★). The best of each stack gets 👑. Your own stars always win. |
| RAW 9 | Core Image's RAW 9 decoder (requested by raw value `"9"`/`"9.dng"`, falls back to the default decoder) for the RAW preview, edits and export, plus optional **Accurate RAW analysis** |

## Using it

- **Open Folder** (⌘O) or drop a folder on the window. Analysis is cached, so reopening only analyzes new or changed files.
- Three views (toolbar, ⌘1/⌘2/⌘3):
  - **Photo**: sidebar of groups (⌘/⇧-click for several; search people, places, file names), big preview, filmstrip.
  - **Looks**: every Creative Look applied to the current photo. Click one to enlarge and customise it with Sony's
    controls (base look, Contrast, Highlights, Shadows, Fade, Saturation, Sharpness, Clarity, WB Kelvin, A–B / G–M
    shift, DRO), then **Apply to Photo**, **Save JPEG…** or **Save as My Look**.
  - **Map**: a heatmap of where shots were taken; click a cluster to show those shots.
- Preview: pinch, ⌘-scroll or double-click to zoom (`Z` = 100%/fit, ⌘+ / ⌘−); drag to pan. Zoom is shared across shots, so
  you can arrow through a burst at 100%. `Y` before/after (side by side or split), `J` clipping overlay, `G` background
  (auto/black/gray/white), `F` full screen.
- Inspector: **Rate** (scores, a breakdown of how the rating was worked out, the same scores for the edited version,
  keep/reject, your stars) · **Adjust** (scopes, Auto, crop & straighten, light, curves, colour, detail, applied look) ·
  **Info** (camera, location map, people). Double-click any slider to reset it. Adjust sections fold.
- **Auto** (Adjust tab) runs Apple's auto-enhance and sets the ordinary sliders. It is a toggle: turning it off restores
  what you had, and changing a slider by hand turns it off.
- Scopes: histogram with clipping indicators, RGB waveform with a 0–100 scale, vectorscope with colour targets and a
  skin-tone line.
- Keys: `P` keep · `X` reject · `U` clear · `1–5` rate · `0` auto rating · `B` keep best in stack · `R` JPEG/RAW · `C` crop ·
  `⌘L` location · `⌘S` save copy · `⌘Z`/`⇧⌘Z` undo/redo (covers marks, ratings, edits, locations, names, Trash and
  metadata written into files).

### What Apixa writes

- **Its own library** (`~/Library/Application Support/Apixa/`): marks, ratings, edits, locations, face names, your looks.
- **Into your files, metadata only** (Settings ▸ Original Files; location and rating on by default):
  - JPEG: patched in place. Image data, maker notes and embedded previews are kept byte-for-byte; only GPS / XMP change.
  - RAW (and HEIC/TIFF/PNG): a standard `NAME.xmp` sidecar, merged with any existing one (a backup is kept).
    darktable's `NAME.ARW.xmp` files are never touched.
  - ⌘Z restores what the file had before.
- **New files** only via Save Copy / Save JPEG. Neither will overwrite an original.
- **Trash**: rejects, after confirmation; ⌘Z puts them back.

### Creative Looks

Sony's Creative Look processing is proprietary, so Apixa approximates it and can learn it:

- **Built in:** each look is a set of parameters fitted to real Sony output.
- **Learned from Sony's renders:** export a RAW from Sony Imaging Edge in each look as `NAME-ST.tif`, `NAME-FL.tif`, …
  beside `NAME.ARW`, then use Settings ▸ Looks ▸ **Learn Looks from Folders…**. Apixa learns each look as a colour table
  from Sony's Standard to Sony's look and scores it on a scene left out of the fit.
- **Learned from your camera:** the same button also uses RAW+JPEG pairs, reading which look the camera used from the JPEG.
- **Limit:** Apixa develops RAW with Apple's decoder, which differs from Sony's Standard by a few ΔE, and that gap varies
  by scene. Looks land about as close to Sony as Standard does. Applying a look to a Sony Standard JPEG avoids the gap.

Recipes (look + Contrast, Highlights, Shadows, Fade, Saturation, Sharpness, Clarity, WB, DRO) can be pasted in from text
with **Import Recipes…**. The Looks page also has Apple's photo filters (Chrome, Fade, Instant, Process, Transfer, Mono,
Tonal, Noir). White balance and DRO are applied in the RAW 9 decoder; the rest on the GPU.

### People

Click a face in **Info** to name it. Apixa suggests names for look-alike faces (threshold calibrated on real shots)
and can name all similar faces at once; it's always confirmed and undoable. Names are searchable and can be written to files
as keywords (File ▸ Write Metadata to Files…).

## Verification hooks

`Apixa.app/Contents/MacOS/Apixa --selftest <folder> [--accurate]` runs scan → analyze → stack headlessly and prints a summary.
`--developtest <folder> <outdir>` renders, computes scopes and saves a copy of the first shot. `--perftest <raw> <outdir>`
times slider renders. `--looktest <raw> <jpeg> <outdir>` renders all looks and checks white-balance direction.
`--metatest <folder>` writes location/rating into COPIES and verifies pixels are untouched and undo restores them. `--statetest <folder>` checks that
marks/ratings/locations/edits survive a reload. `--trashtest <folder>` runs trash→undo→redo; use it on copies only.
`--auditdump <folder> <outdir>` writes contact sheets of every shot with its stack, stars and score parts.
`--sonyfit <folder> [--save]` learns look tables from Sony renders and prints left-out-scene accuracy.
`--lookcompare <outdir> <folders…> [--dry]` learns looks from camera RAW+JPEG pairs. `--scopetest <image> <outdir>`
draws the three scopes to PNGs.
