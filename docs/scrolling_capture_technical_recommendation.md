# Technical Recommendation: Implementing Scrolling Capture in Snipshot

## 1. Overview of the Challenge

Implementing a reliable scrolling capture (long screenshot) feature on macOS is notoriously difficult due to the sandboxed nature of modern macOS and the diverse ways applications implement scrolling. Unlike iOS, where `UIScrollView` provides a unified scrolling API, macOS applications use a mix of native `NSScrollView`, custom web views (Electron/Chromium), and entirely custom rendering engines (like Visual Studio Code or Terminal).

Our research into existing solutions—ranging from commercial tools like Shottr [1] to open-source implementations like ScrollSnap [2] and Scrolly [3]—reveals that there is no single "silver bullet" API for scrolling capture. Instead, developers must choose between automated scrolling via synthetic events or manual scrolling driven by the user, coupled with sophisticated image stitching algorithms.

This document outlines the technical approaches available, analyzes their pros and cons, and provides a concrete recommendation for integrating this feature into Snipshot's existing architecture.

## 2. Technical Approaches to Scrolling Capture

There are three primary methodologies for implementing scrolling capture on macOS. Each approach balances user experience with technical reliability and implementation complexity.

### Approach A: Manual Scroll + Vision Stitching (Recommended)

In this approach, the application does not attempt to control the scrolling behavior. Instead, the user defines a capture region, initiates the capture process, and manually scrolls the target application. The screenshot utility captures frames at regular intervals and uses Apple's Vision framework to stitch them together.

The core of this method relies on `VNTranslationalImageRegistrationRequest` [4], which compares two consecutive frames and calculates the vertical translation offset (the distance the content has moved). If the offset indicates a downward scroll, the new unique content is composited onto the bottom of the running stitched image.

| Advantages | Disadvantages |
| :--- | :--- |
| **Universal Compatibility:** Works with any application, regardless of how it implements scrolling (native, Electron, custom). | **User Effort:** Requires the user to manually scroll the content at a reasonable pace. |
| **Robustness:** Immune to macOS updates that break accessibility or synthetic event APIs. | **Stitching Artifacts:** Fast scrolling or dynamic content (videos, animations) can confuse the stitching algorithm. |
| **Simplicity:** Does not require complex Accessibility API integration or event simulation. | **Floating Elements:** Sticky headers or footers can cause stitching errors if not explicitly handled. |

### Approach B: Automated Scroll via Synthetic Events

This method attempts to fully automate the process. The application sends synthetic scroll events (typically using `CGEventCreateScrollWheelEvent` [5]) to the target window, capturing a screenshot after each programmatic scroll step. This is the approach used by the "Auto" mode in tools like Shottr [1].

While this provides a "one-click" experience when it works, it is highly fragile. Many applications (like Visual Studio Code, Terminal, and non-native apps) do not respond predictably to synthetic scroll events. Furthermore, third-party mouse utilities (like MOS or Scroll Reverser) can intercept and alter these events, breaking the capture process.

| Advantages | Disadvantages |
| :--- | :--- |
| **Seamless UX:** Requires minimal user interaction; the tool handles the entire process. | **High Fragility:** Frequently breaks on non-native apps or specific macOS configurations. |
| **Consistent Pacing:** Programmatic scrolling ensures optimal overlap for the stitching algorithm. | **API Limitations:** `CGEventCreateScrollWheelEvent` behavior can vary wildly between applications. |

### Approach C: Accessibility API (AXUIElement)

The Accessibility API approach involves using `AXUIElement` [6] to locate the vertical scroll bar of the target window, read its current value (`kAXValueAttribute`), and programmatically increment it. This guarantees exact control over the scroll position.

However, this method is strictly limited to applications that expose a standard AppKit `AXScrollArea`. Modern applications built with Electron, Catalyst, or custom UI frameworks often fail to expose these accessibility elements correctly, making this approach unviable for a general-purpose screenshot tool.

## 3. Analysis of Snipshot's Current Architecture

Snipshot currently utilizes `CGWindowListCreateImage` for its primary capture mechanism, as noted in `AppDelegate.swift`, to avoid focus-stealing issues associated with `ScreenCaptureKit` [7]. The capture flow creates a full-screen image, which is then presented in an `OverlayWindow` where the user can select a region and apply annotations.

To implement scrolling capture, Snipshot needs to transition from a single-frame capture model to a continuous capture model while the overlay is active.

### Key Integration Points

1.  **Overlay Interaction:** The `OverlayWindow` currently intercepts all mouse events for region selection and annotation. For manual scrolling capture, the overlay must temporarily become transparent to mouse events (`ignoresMouseEvents = true`) so the user can scroll the underlying application.
2.  **Capture Mechanism:** While `CGWindowListCreateImage` is currently used, `ScreenCaptureKit` (`SCScreenshotManager.captureImage`) is significantly more performant for rapid, continuous frame capture [8]. Since the focus-stealing issue of `ScreenCaptureKit` primarily affects the initial full-screen grab, it may be suitable for the rapid frame-by-frame capture required during the scrolling phase, provided the overlay remains the key window.
3.  **State Management:** A new `OverlayAction` state (e.g., `.scrollingCapture`) must be introduced to manage the timer, frame collection, and stitching process.

## 4. Recommended Implementation Plan

Based on the analysis of existing tools and macOS limitations, we strongly recommend implementing **Approach A: Manual Scroll + Vision Stitching**. This approach, successfully utilized by open-source projects like ScrollSnap [2], offers the highest reliability across the diverse macOS application ecosystem.

### Step-by-Step Implementation Strategy

**Phase 1: The Stitching Engine**
Create a `StitchingManager` class responsible for combining `NSImage` frames.
1.  Utilize `VNTranslationalImageRegistrationRequest` from the Vision framework to compare the current frame with the previous frame.
2.  Extract the `ty` (y-axis translation) value from the resulting `VNImageTranslationAlignmentObservation`.
3.  If `ty > 0` (downward scroll), crop the new content based on the offset and append it to the bottom of the running stitched image using Core Graphics compositing.

**Phase 2: Capture Orchestration**
Modify the `OverlayWindow` to support a continuous capture mode.
1.  Add a UI trigger (e.g., a "Scroll Capture" button near the selection rect or a keyboard shortcut like `Enter`).
2.  Upon activation, set `self.ignoresMouseEvents = true` on the `OverlayWindow` to allow the user to scroll the app beneath it.
3.  Start a `Timer` (e.g., firing every 250ms) to capture the screen area defined by the user's selection rectangle.
4.  Pass each captured frame to the `StitchingManager`.

**Phase 3: Completion and Presentation**
Handle the termination of the scrolling capture.
1.  Provide a mechanism to stop the capture (e.g., listening for the `Esc` key via a global event monitor, or a floating "Stop" button that remains clickable).
2.  Once stopped, retrieve the final stitched image from the `StitchingManager`.
3.  Restore `ignoresMouseEvents = false` on the `OverlayWindow`.
4.  Present the final long screenshot in the existing `PreviewWindow` or `AIResultWindow` for saving, copying, or further annotation.

### Mitigating Known Issues

- **Sticky Headers/Footers:** The Vision framework may struggle if a large portion of the frame remains static (e.g., a fixed navigation bar). To mitigate this, the stitching algorithm should analyze the center portion of the image, or allow the user to define a "safe area" inset that excludes fixed elements from the translation calculation.
- **Performance:** Stitching large images in memory can be resource-intensive. Ensure the `StitchingManager` operates on a background `DispatchQueue` and aggressively releases intermediate `CGImage` references to prevent memory bloat.

By adopting the manual scroll and Vision-based stitching approach, Snipshot can deliver a robust long screenshot feature that avoids the fragility of automated scrolling while providing a highly requested capability to its users.

---

## References

[1] Shottr Official Website. (2026). *Shottr – Screenshot Annotation App For Mac*. Retrieved from https://shottr.cc/
[2] Brkgng. (2026). *ScrollSnap: A macOS app for capturing and stitching scrolling screenshots*. GitHub Repository. Retrieved from https://github.com/Brkgng/ScrollSnap
[3] bcardiff. (2026). *Scrolly: A minimal macOS menu-bar utility that synchronizes vertical scroll*. GitHub Repository. Retrieved from https://github.com/bcardiff/scrolly
[4] Apple Inc. (2026). *VNTranslationalImageRegistrationRequest*. Apple Developer Documentation. Retrieved from https://developer.apple.com/documentation/vision/vntranslationalimageregistrationrequest
[5] Apple Inc. (2026). *CGEventCreateScrollWheelEvent*. Apple Developer Documentation. Retrieved from https://developer.apple.com/documentation/coregraphics/cgeventcreatescrollwheelevent
[6] Apple Inc. (2026). *AXUIElement*. Apple Developer Documentation. Retrieved from https://developer.apple.com/documentation/applicationservices/axuielement
[7] Snipshot Source Code. (2026). *AppDelegate.swift*. Internal Project File.
[8] Apple Inc. (2026). *SCScreenshotManager*. Apple Developer Documentation. Retrieved from https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager
