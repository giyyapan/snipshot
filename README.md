# Snipshot

A lightweight macOS screenshot tool with window snapping, annotation, OCR, and pin-to-desktop.

## Requirements

- macOS 14.0+ (Apple Silicon)
- Xcode Command Line Tools (`xcode-select --install`)

## Quick Start

```bash
# First time only: create a self-signed certificate for stable TCC permissions
bash setup_cert.sh

# Build and run
bash build.sh
open build/Snipshot.app
```

After launching, Snipshot runs as a menu bar agent. Press **F1** to start a screenshot.

## Usage

| Shortcut | Action |
|---|---|
| F1 | Start screenshot |
| Click | Select window under cursor |
| Drag | Draw custom selection |
| Enter / Cmd+C | Copy selection |
| Cmd+S | Save selection |
| F3 | Pin selection to desktop |
| Esc | Cancel |

In the annotation toolbar: **A**rrow, **R**ectangle, **T**ext, **M**arker, **C**olor picker, Mosaic (**M** with shift).

## Project Structure

```
Snipshot/
├── Snipshot/          # Source code
│   ├── AppDelegate.swift      # App lifecycle, hotkeys, screen capture
│   ├── OverlayWindow.swift    # Core overlay, selection, window snapping
│   ├── OverlayPanels.swift    # Toolbar and info panel
│   ├── Annotation.swift       # Annotation rendering
│   ├── UIComponents.swift     # Reusable UI components
│   ├── OCRMode.swift          # Live Text / OCR
│   ├── PinWindow.swift        # Pin-to-desktop windows
│   └── main.swift             # Entry point
├── docs/              # Design docs and research
├── build.sh           # Build script (swiftc + codesign)
├── release.sh         # Publish script (Sparkle + GitHub Releases)
├── setup_cert.sh      # Self-signed certificate setup
└── AGENTS.md          # AI agent guidelines
```

## Development

No Xcode project needed. The app compiles directly with `swiftc` via `build.sh`. To iterate:

```bash
# Edit source files, then:
bash build.sh
pkill -f Snipshot; sleep 1; open build/Snipshot.app
```

The self-signed certificate ("Snipshot Dev") keeps Screen Recording and Accessibility permissions stable across rebuilds. If permissions break, re-run `setup_cert.sh` and re-grant in System Settings > Privacy & Security.

## Publishing Updates

Snipshot uses **Sparkle** for automatic updates via GitHub Releases. To publish a new version:

1. Update the version number in `Snipshot/Info.plist` and `Snipshot/SettingsWindow.swift`.
2. Build the production DMG:
   ```bash
   bash build.sh prod
   ```
3. Publish to GitHub Releases (requires `gh` CLI and Sparkle EdDSA private key):
   ```bash
   bash release.sh
   ```
   This will sign the DMG, create a GitHub Release, and update the `appcast.xml` feed automatically.

See `docs/` for architecture details and `AGENTS.md` for AI-assisted development guidelines.
