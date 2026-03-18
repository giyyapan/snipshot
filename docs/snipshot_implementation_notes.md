# Snipshot: Implementation Notes v3

This document details the significant architectural changes, new features, and bug fixes implemented in Snipshot, building upon the initial MVP. It covers the refactoring of the core overlay logic, the introduction of OCR functionality, and numerous UX refinements.

## 1. Core Architecture Refactoring

The `OverlayWindow.swift` file, which had grown to over 1,400 lines, was identified as a major maintainability bottleneck. A significant refactoring effort was undertaken to modularize the codebase, resulting in a clearer separation of concerns.

### 1.1. Code Splitting

The original `OverlayWindow.swift` was split into four distinct files, each with a specific responsibility. This was achieved using Swift's `extension` feature to keep the core `OverlayView` class intact while logically grouping its functionality.

| New File | Line Count | Responsibilities |
| :--- | :--- | :--- |
| **`OverlayWindow.swift`** | ~1027 | Core window/view setup, mouse/keyboard event handling, selection logic, and drawing. |
| **`UIComponents.swift`** | ~259 | Reusable UI elements like `HoverIconButton`, `SmallButton`, and `ColorDot`. |
| **`OverlayPanels.swift`** | ~247 | All panel management code, including the info panel, main bottom bar, and secondary annotation panels. |
| **`OCRMode.swift`** | ~134 | All logic related to the new OCR (Live Text) mode. |

This refactoring has significantly improved code readability and made it easier to locate and modify specific features without navigating a monolithic file.

## 2. New Feature Implementation

Several major features were added to enhance the utility and user experience of Snipshot.

### 2.1. OCR (Live Text) Integration

A powerful OCR feature was implemented, allowing users to select text directly from their screenshots. The implementation leverages Apple's latest VisionKit framework for a native, high-quality experience.

- **Technology**: `VisionKit`'s `ImageAnalysisOverlayView` is used to provide the native "Live Text" interaction. This was chosen over the lower-level `Vision` framework (`VNRecognizeTextRequest`) to minimize custom implementation of text selection and highlighting logic [1].
- **User Flow**:
    1. After selecting a region, the user clicks a new OCR button in the toolbar.
    2. The selected image region is passed to an `ImageAnalyzer`.
    3. An `ImageAnalysisOverlayView` is placed over the selection, allowing direct text interaction (selection, copy).
    4. A dedicated OCR panel provides "Copy All" and "Done" actions.
    5. Standard keyboard shortcuts like `Cmd+C` (copy selected) and `Cmd+A` (select all) are supported within this mode.

### 2.2. Window Snapping

The selection tool features intelligent window snapping, allowing users to quickly select entire windows or snap selection edges to window boundaries.

- **Window Detection**: The `CGWindowListCopyWindowInfo` API is used to get a Z-ordered list of all on-screen windows. The list is cached when the overlay first appears. Only normal windows (layer 0) are included; floating overlays, status bars, and system UI elements are filtered out.
- **Occlusion Filtering**: A two-pass algorithm determines which windows are "snappable". In the first pass, all valid window rects are collected in Z-order and clipped to the current screen bounds. In the second pass, a four-corner visibility check is performed: a window is only snappable if none of its four corners are covered by a higher Z-order window. This effectively filters out fully or mostly occluded windows.
- **Edge Snapping**: During selection drawing (`mouseDragged`), the cursor's position is checked against the cached window frames. If it is within a small threshold (8px), the selection edge snaps to the window edge.
- **Window Highlight**: In idle mode (before drawing a selection), the window under the mouse cursor is highlighted with a blue border and its original screenshot content is revealed through the dark overlay. The window's dimensions are displayed as a label.
- **Click-to-Select**: Clicking without dragging in idle mode automatically selects the entire window under the cursor, entering the selected state immediately.
- **Multi-Monitor Coordinate Handling**: Window coordinates from `CGWindowListCopyWindowInfo` are global (CG top-left origin). They are converted to NS coordinates and then to view-local coordinates using the overlay screen's frame. At init time, when `window` is not yet available, the correct screen is determined via `NSEvent.mouseLocation` (matching the logic in `AppDelegate.showOverlay`).

### 2.3. Multi-Monitor Enhancements

Significant improvements were made to ensure a seamless experience across multiple displays.

- **Capture on Mouse Screen**: The screenshot process now correctly identifies the screen where the mouse cursor is located and captures that specific screen, rather than defaulting to the `NSScreen.main` (which is tied to the focused window).
- **Idle-Mode Screen Following**: If the user has triggered the screenshot overlay but has not yet started drawing a selection, moving the mouse to a different screen will now cause the overlay to automatically dismiss and re-appear on the new screen. This is achieved via a callback from `OverlayView`'s `mouseMoved` to `AppDelegate`.
- **Coordinate Space Correction**: A major bug causing selection offsets on external displays was fixed. The root cause was that the `OverlayView`'s frame was incorrectly initialized with the screen's global frame origin. The fix involved setting the view's frame to be zero-origin and ensuring all coordinate calculations (cropping, snapping) are relative to the view's bounds and the specific screen's origin.

## 3. Window Management and Focus Preservation

A critical issue with the initial overlay implementation was that it "stole focus" from the currently active application when the screenshot shortcut was pressed. This caused the frontmost window's shadow to disappear or change, resulting in a screenshot that didn't accurately reflect the user's visual state.

Extensive research and diagnostic testing revealed that the root cause was **not** the overlay window itself, but the **screen capture method**. `ScreenCaptureKit`'s `SCScreenshotManager.captureImage` internally activates the calling app, which causes other windows to lose their focused appearance (shadow changes). This was confirmed by testing with a transparent overlay (no capture) — shadows were preserved.

- **Capture Method**: Replaced `ScreenCaptureKit` (`SCScreenshotManager.captureImage`) with `CGWindowListCreateImage`, which captures the screen without activating the app. Although `CGWindowListCreateImage` was deprecated in macOS 14, it remains functional and is the only public API that captures without side effects on window focus state.
- **Non-Activating Panel**: The `OverlayWindow` is an `NSPanel` with the `.nonactivatingPanel` style mask. Combined with `LSUIElement = true` (agent app), this allows the panel to become the key window (receiving keyboard events via the normal responder chain) without activating the Snipshot app itself. Other windows retain their focused state and shadows.
- **Panel Configuration**: `canBecomeKey = true` (for keyboard events), `canBecomeMain = false`, `hidesOnDeactivate = false`, `animationBehavior = .none`. Presented via `makeKeyAndOrderFront(nil)`.

## 4. User Experience and UI Refinements

Based on user feedback, numerous small but impactful changes were made to the UI and interaction logic.

| Feature | Refinement |
| :--- | :--- |
| **PinWindow** | - **Selection State**: The selected PinWindow now has a much stronger visual indicator (a blue border with a glowing shadow).
- **Copy Action**: Users can now copy the pinned image directly to the clipboard by selecting the window and pressing `Cmd+C`.
- **Visual Feedback**: A brief flash animation provides clear feedback when the copy action is successful. |
| **Text Tool** | - **Positioning**: The text input box now appears with its top-left corner at the mouse click position, mimicking the behavior of design tools like Figma.
- **Styling**: The input box is now transparent with no placeholder text, providing a cleaner editing experience.
- **Auto-Sizing**: The width of the text box now grows automatically as the user types.
- **Bug Fixes**: Fixed issues where text would render underneath the input box and where empty text elements could be created. |
| **Toolbars** | - **Background**: The semi-transparent Gaussian blur background was replaced with a solid, slightly off-white color (`white: 0.95, alpha: 0.92`) for consistent appearance.
- **Tooltips**: System tooltips were replaced with a custom, instant-appearing tooltip implementation for better responsiveness.
- **Info Panel**: The resolution display panel now uses `sizeToFit()` to ensure its width always accommodates the text, preventing clipping.
- **Fullscreen Fallback**: When the selection fills the entire screen and there is no room for the toolbar outside the selection (neither below nor above), the toolbar is now placed inside the selection area near the bottom edge, ensuring it remains accessible. |
| **Tool Selection** | The logic for deselecting a tool by clicking it again was removed. The currently selected tool now remains active until a different tool is chosen. |
| **Shortcuts** | Keyboard shortcuts were added for all annotation tools (e.g., `T` for Text, `R` for Rectangle) to speed up workflow. These are only active when not in text editing mode. `Cmd+C` now works as a copy shortcut in the selected/annotating state (equivalent to pressing Enter), in addition to the existing `Cmd+S` (save) and `F3` (pin) shortcuts. |

## 5. References

[1] Apple Developer Documentation. "ImageAnalysisOverlayView". https://developer.apple.com/documentation/visionkit/imageanalysisoverlayview
[2] Apple Developer Documentation. "CGWindowListCreateImage". https://developer.apple.com/documentation/coregraphics/1454852-cgwindowlistcreateimage
[3] Multi.app Blog. "Nailing the activation behavior of a Spotlight/Raycast-like command palette". https://multi.app/blog/nailing-the-activation-behavior-of-a-spotlight-raycast-like-command-palette

