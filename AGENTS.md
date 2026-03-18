# Snipshot: Agent Guidelines

## 1. Operational Rules

- **Restart After Build**: After every successful build, kill and relaunch: `pkill -f Snipshot; sleep 1; open build/Snipshot.app`.
- **Sync Disk Loss**: If `/mnt/desktop/` becomes unresponsive, stop immediately and inform the user. Do NOT attempt workarounds.
- **No Doc Versioning**: Always update docs in place. Never create `_v2`, `_v3` copies.
- **Edit Files Directly**: Edit source files directly under `/mnt/desktop/Snipshot/` rather than copying to sandbox first.

## 2. Project Structure

| File | Role |
| :--- | :--- |
| `Snipshot/OverlayWindow.swift` | Core: window/view setup, mouse/keyboard events, selection, drawing, window snapping |
| `Snipshot/OverlayPanels.swift` | Panel management: info panel, bottom toolbar, secondary annotation panel |
| `Snipshot/UIComponents.swift` | Reusable UI: `HoverIconButton`, `SmallButton`, `ColorDot` |
| `Snipshot/OCRMode.swift` | OCR (Live Text) mode using VisionKit |
| `Snipshot/AppDelegate.swift` | App lifecycle, hotkeys (`CGEvent.tapCreate`), screen capture (`CGWindowListCreateImage`), pin windows |
| `build.sh` | Compile (`swiftc`) + sign (`codesign -s "Snipshot Dev"`) |

## 3. Architecture Notes

- **Overlay**: `OverlayWindow` is an `NSPanel` with `.nonactivatingPanel` + `canBecomeKey=true`. Presented via `makeKeyAndOrderFront(nil)`. This makes the panel key window (receives keyboard) without activating the app, preserving other windows' focus and shadows.
- **Screen Capture**: Uses `CGWindowListCreateImage` (not ScreenCaptureKit). `SCScreenshotManager.captureImage` activates the app and changes window shadows; `CGWindowListCreateImage` does not.
- **Coordinate System**: CG uses top-left origin; NS uses bottom-left. `cacheWindowFrames` converts global CG coords to view-local NS coords using the overlay screen's frame. At init time (when `window` is nil), screen is determined via `NSEvent.mouseLocation`.
- **Window Snapping**: Two-pass algorithm in `cacheWindowFrames`. Pass 1: collect layer-0 windows, clip to screen bounds. Pass 2: four-corner visibility check filters out occluded windows. `windowFrameAt` returns first Z-order match. Idle mode shows highlight + click-to-select.
- **Multi-Monitor**: Overlay follows mouse between screens in idle mode (re-captures via `onScreenChange` callback to `AppDelegate`).
- **Toolbar Positioning**: `panelYPosition()` tries below selection, then above, then inside (fullscreen fallback).
- **TCC Permissions**: Self-signed cert "Snipshot Dev" keeps permissions stable across rebuilds.

## 4. Keyboard Shortcuts

| Key | Context | Action |
| :--- | :--- | :--- |
| F1 | Global | Start screenshot |
| F3 (global) | Global | Pin clipboard image |
| F3 | Selected/Annotating | Pin selection |
| Enter / Cmd+C | Selected/Annotating | Copy & done |
| Cmd+S | Selected/Annotating | Save image |
| Esc | Any | Cancel / dismiss |
| Cmd+Z | Annotating | Undo |
| A, R, T, C, M | Selected/Annotating (no modifier) | Arrow, Rectangle, Text, Marker, Mosaic tools |
| Arrow keys | Selected | Nudge selection (1px; +Shift = 10px) |
