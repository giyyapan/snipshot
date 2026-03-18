# Focus Preservation Research

## Problem

When Snipshot's overlay appears, the previously focused window's shadow changes because macOS adjusts window shadows based on whether the owning app is active. If Snipshot becomes the active app, the previous app deactivates and its windows get lighter shadows.

## Root Cause

Diagnostic testing revealed the root cause was **not** the overlay window, but the **screen capture method**. `ScreenCaptureKit`'s `SCScreenshotManager.captureImage` internally activates the calling app, which causes other windows to lose their focused shadows. This was confirmed by showing a transparent overlay (no capture) — shadows were preserved.

## Solution

Two changes were required:

1. **Replace ScreenCaptureKit with `CGWindowListCreateImage`** — this captures the screen without activating the app. Although deprecated in macOS 14, it remains functional and is the only public API without focus side effects.
2. **Use `NSPanel` with `.nonactivatingPanel` style mask** — same technique used by Raycast, Alfred, and similar launcher apps, ensuring the overlay window itself doesn't activate the app either.

### Key Configuration

| Property | Value | Reason |
|---|---|---|
| Window class | `NSPanel` | Required for `.nonactivatingPanel` |
| Style mask | `.borderless`, `.nonactivatingPanel` | Prevents app activation on interaction |
| `canBecomeKey` | `true` | Allows keyboard input via responder chain |
| `canBecomeMain` | `false` | Not the main window |
| `hidesOnDeactivate` | `false` | Stay visible when app is inactive |
| `animationBehavior` | `.none` | No panel animation on show |
| Presentation | `makeKeyAndOrderFront(nil)` | Panel becomes key without activating app |

### What NOT to do

- Do not call `NSApp.activate(ignoringOtherApps:)` — this activates the app and changes shadows.
- Do not use `SCScreenshotManager.captureImage` — it internally activates the app.
- Do not set `canBecomeKey = false` — this breaks the responder chain, requiring global event monitors as a workaround.
- Do not use `_setPreventsActivation:` — private API, unnecessary with correct configuration.

### How it works

With `LSUIElement = true` (agent app) and `.nonactivatingPanel`, calling `makeKeyAndOrderFront` makes the panel the key window so it receives keyboard events, but does not activate the owning app. The previously focused app remains active, and its windows keep their normal shadows. `CGWindowListCreateImage` captures the screen content without any activation side effects.

## References

- [Multi.app blog: Nailing the Activation Behavior of a Spotlight/Raycast-like Command Palette](https://multi.app/blog/nailing-the-activation-behavior-of-a-spotlight-raycast-like-command-palette)
- [Multi.app demo repo](https://github.com/multi-software-co/multi-app-activation-demo)
- [Sol (open-source Raycast alternative)](https://github.com/ospfranco/sol) — uses `NSPanel` + `.nonactivatingPanel`
- Apple docs: [nonactivatingPanel](https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/nonactivatingpanel)
