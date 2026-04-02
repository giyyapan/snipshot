import Cocoa
import UniformTypeIdentifiers
import VisionKit

// MARK: - Overlay Actions
enum OverlayAction {
    case copy(NSImage, NSRect)
    case save(NSImage, NSRect)
    case pin(NSImage, NSRect)
    case scrollCapture(NSRect, NSImage)  // Start scrolling capture with the selection rect (screen coords) and clean first frame
    case askAI(NSImage, NSRect)  // Ask AI about the selected region
    case runPlugin(Plugin, NSImage, String)  // Run a plugin with image and input text
    case cancel
}

// MARK: - OverlayWindow
// Uses NSPanel + .nonactivatingPanel so the overlay can become key window
// (receive keyboard events via responder chain) WITHOUT activating the app.
// This preserves other windows' focus state and shadows — same technique as Raycast.
class OverlayWindow: NSPanel {
    init(contentRect: NSRect, screenshot: NSImage, onAction: @escaping (OverlayAction) -> Void) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.level = .statusBar + 1
        self.isOpaque = false
        self.hasShadow = false
        self.backgroundColor = .clear
        self.ignoresMouseEvents = false
        self.acceptsMouseMovedEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.hidesOnDeactivate = false
        self.animationBehavior = .none

        // contentView frame must be zero-origin (relative to window, not screen)
        let viewFrame = NSRect(origin: .zero, size: contentRect.size)
        let overlayView = OverlayView(frame: viewFrame, screenshot: screenshot, onAction: onAction)
        self.contentView = overlayView
    }

    // Allow the panel to become key so it receives keyboard events via normal responder chain.
    // With .nonactivatingPanel, becoming key does NOT activate the owning app.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // Auto-dismiss when the overlay loses key window status (e.g. another window steals focus).
    // This prevents the overlay from getting stuck with no way to close it.
    // Only exception: NSSavePanel taking key is expected during save flow.
    override func resignKey() {
        super.resignKey()
        // Defer to next runloop tick to let window state settle.
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isVisible else { return }
            // Check if any visible NSSavePanel exists, not just keyWindow.
            // On first app activation, NSSavePanel may be visible but not yet key.
            let hasSavePanel = NSApp.windows.contains { $0 is NSSavePanel && $0.isVisible }
            if hasSavePanel { return }
            if let overlayView = self.contentView as? OverlayView {
                overlayView.onAction(.cancel)
            }
        }
    }
}

// MARK: - Resize Handle (selection)
enum ResizeHandle: Equatable {
    case topLeft, topRight, bottomLeft, bottomRight
    case top, bottom, left, right
}

// MARK: - Interaction Mode
enum InteractionMode: Equatable {
    case idle
    case drawing
    case selected
    case moving
    case resizing(ResizeHandle)
    case annotating
    case drawingAnnotation
    case movingAnnotation
    case resizingAnnotation(AnnoResizeHandle)
    case editingText
    case ocrMode
    case pluginInput
}

// MARK: - OverlayView
class OverlayView: NSView {

    let screenshot: NSImage
    let onAction: (OverlayAction) -> Void
    var onScreenChange: (() -> Void)?

    var selectionRect: NSRect = .zero
    var currentMousePosition: NSPoint?
    var mode: InteractionMode = .idle

    // Selection drawing/moving/resizing
    var drawStart: NSPoint = .zero
    var moveOffset: NSPoint = .zero
    var resizeAnchor: NSPoint = .zero
    var hoveredHandle: ResizeHandle? = nil

    // Panels
    var infoPanelView: NSView?
    var bottomBarView: NSView?
    var secondaryPanelView: NSView?
    var textField: NSTextField?  // kept for type compat; actual editing uses textEditView
    var textEditView: NSTextView?
    var textEditScrollView: NSScrollView?

    // Annotation state
    var annoState = AnnotationState()
    var annotationDrawStart: NSPoint = .zero
    var currentAnnotationElement: AnnotationElement? = nil
    var toolButtons: [AnnotationTool: HoverIconButton] = [:]
    var colorDots: [NSColor: ColorDot] = [:]
    var undoButton: HoverIconButton?
    var redoButton: HoverIconButton?

    // Annotation dragging
    var annoDragStart: NSPoint = .zero
    var annoDragElementStart: NSPoint = .zero
    var annoDragElementEnd: NSPoint = .zero

    // Annotation resizing
    var annoResizeElement: AnnotationElement? = nil
    var annoResizeHandle: AnnoResizeHandle? = nil

    // Marquee selection (select tool)
    var marqueeStart: NSPoint? = nil
    var marqueeRect: NSRect? = nil

    // Auto-switch back to select tool after drawing
    var autoSwitchToSelect: Bool = UserDefaults.standard.bool(forKey: "autoSwitchToSelectAfterAnnotation")

    let handleSize: CGFloat = 8
    let handleHitSize: CGFloat = 14

    // OCR state
    var ocrOverlayView: ImageAnalysisOverlayView?
    var ocrImageView: NSImageView?
    var ocrPanelView: NSView?
    let imageAnalyzer = ImageAnalyzer()

    // Translate state
    var translateResultWindow: TranslateResultWindow?

    // Plugin state
    var activePlugin: Plugin?
    var pluginPanelView: NSView?
    var pluginInputField: NSTextField?

    // Auto-copy: when enabled, selection completion auto-copies to clipboard
    var autoCopyEnabled: Bool = UserDefaults.standard.bool(forKey: "autoCopyAfterSelection")
    private var hasAutoCopied: Bool = false

    // Color picker (idle mode)
    enum ColorFormat: Int, CaseIterable {
        case hex = 0, rgb, hsl
        var next: ColorFormat { ColorFormat(rawValue: (rawValue + 1) % ColorFormat.allCases.count)! }
    }
    var colorFormat: ColorFormat = .hex
    var cachedBitmapRep: NSBitmapImageRep?

    // Window snapping
    var windowFrames: [NSRect] = []
    var hoveredWindowFrame: NSRect? = nil

    init(frame: NSRect, screenshot: NSImage, onAction: @escaping (OverlayAction) -> Void) {
        self.screenshot = screenshot
        self.onAction = onAction
        super.init(frame: frame)

        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)

        // Cache window frames for snapping
        cacheWindowFrames()

        // Cache bitmap rep for color picker pixel reading
        if let tiff = screenshot.tiffRepresentation {
            cachedBitmapRep = NSBitmapImageRep(data: tiff)
        }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() {}

    // MARK: - Selection Helpers
    var hasSelection: Bool { selectionRect.width > 3 && selectionRect.height > 3 }

    func normalizedRect(from p1: NSPoint, to p2: NSPoint) -> NSRect {
        NSRect(x: min(p1.x, p2.x), y: min(p1.y, p2.y), width: abs(p1.x - p2.x), height: abs(p1.y - p2.y))
    }

    func screenToLocal(_ point: NSPoint) -> NSPoint {
        NSPoint(x: point.x - selectionRect.origin.x, y: point.y - selectionRect.origin.y)
    }

    // MARK: - Selection Handle Hit Testing
    func handleRects() -> [(ResizeHandle, NSRect)] {
        let r = selectionRect; let s = handleHitSize; let hs = s / 2
        return [
            (.topLeft,     NSRect(x: r.minX - hs, y: r.maxY - hs, width: s, height: s)),
            (.topRight,    NSRect(x: r.maxX - hs, y: r.maxY - hs, width: s, height: s)),
            (.bottomLeft,  NSRect(x: r.minX - hs, y: r.minY - hs, width: s, height: s)),
            (.bottomRight, NSRect(x: r.maxX - hs, y: r.minY - hs, width: s, height: s)),
            (.top,         NSRect(x: r.midX - hs, y: r.maxY - hs, width: s, height: s)),
            (.bottom,      NSRect(x: r.midX - hs, y: r.minY - hs, width: s, height: s)),
            (.left,        NSRect(x: r.minX - hs, y: r.midY - hs, width: s, height: s)),
            (.right,       NSRect(x: r.maxX - hs, y: r.midY - hs, width: s, height: s)),
        ]
    }

    func hitTestHandle(at point: NSPoint) -> ResizeHandle? {
        for (handle, rect) in handleRects() { if rect.contains(point) { return handle } }
        return nil
    }

    func anchorForHandle(_ handle: ResizeHandle) -> NSPoint {
        let r = selectionRect
        switch handle {
        case .topLeft:     return NSPoint(x: r.maxX, y: r.minY)
        case .topRight:    return NSPoint(x: r.minX, y: r.minY)
        case .bottomLeft:  return NSPoint(x: r.maxX, y: r.maxY)
        case .bottomRight: return NSPoint(x: r.minX, y: r.maxY)
        case .top:         return NSPoint(x: r.minX, y: r.minY)
        case .bottom:      return NSPoint(x: r.minX, y: r.maxY)
        case .left:        return NSPoint(x: r.maxX, y: r.minY)
        case .right:       return NSPoint(x: r.minX, y: r.minY)
        }
    }

    func cursorForHandle(_ handle: ResizeHandle) -> NSCursor {
        switch handle {
        case .top, .bottom: return .resizeUpDown
        case .left, .right: return .resizeLeftRight
        case .topLeft, .bottomRight: return makeDiagonalCursor(nwse: true)
        case .topRight, .bottomLeft: return makeDiagonalCursor(nwse: false)
        }
    }

    func makeDiagonalCursor(nwse: Bool) -> NSCursor {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            let ctx = NSGraphicsContext.current!.cgContext
            ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(2.5)
            if nwse {
                ctx.move(to: CGPoint(x: 2, y: 14)); ctx.addLine(to: CGPoint(x: 14, y: 2))
                ctx.move(to: CGPoint(x: 2, y: 14)); ctx.addLine(to: CGPoint(x: 6, y: 14))
                ctx.move(to: CGPoint(x: 2, y: 14)); ctx.addLine(to: CGPoint(x: 2, y: 10))
                ctx.move(to: CGPoint(x: 14, y: 2)); ctx.addLine(to: CGPoint(x: 10, y: 2))
                ctx.move(to: CGPoint(x: 14, y: 2)); ctx.addLine(to: CGPoint(x: 14, y: 6))
            } else {
                ctx.move(to: CGPoint(x: 14, y: 14)); ctx.addLine(to: CGPoint(x: 2, y: 2))
                ctx.move(to: CGPoint(x: 14, y: 14)); ctx.addLine(to: CGPoint(x: 10, y: 14))
                ctx.move(to: CGPoint(x: 14, y: 14)); ctx.addLine(to: CGPoint(x: 14, y: 10))
                ctx.move(to: CGPoint(x: 2, y: 2)); ctx.addLine(to: CGPoint(x: 6, y: 2))
                ctx.move(to: CGPoint(x: 2, y: 2)); ctx.addLine(to: CGPoint(x: 2, y: 6))
            }
            ctx.strokePath()
            ctx.setStrokeColor(NSColor.black.cgColor); ctx.setLineWidth(1.0)
            if nwse {
                ctx.move(to: CGPoint(x: 2, y: 14)); ctx.addLine(to: CGPoint(x: 14, y: 2))
                ctx.move(to: CGPoint(x: 2, y: 14)); ctx.addLine(to: CGPoint(x: 6, y: 14))
                ctx.move(to: CGPoint(x: 2, y: 14)); ctx.addLine(to: CGPoint(x: 2, y: 10))
                ctx.move(to: CGPoint(x: 14, y: 2)); ctx.addLine(to: CGPoint(x: 10, y: 2))
                ctx.move(to: CGPoint(x: 14, y: 2)); ctx.addLine(to: CGPoint(x: 14, y: 6))
            } else {
                ctx.move(to: CGPoint(x: 14, y: 14)); ctx.addLine(to: CGPoint(x: 2, y: 2))
                ctx.move(to: CGPoint(x: 14, y: 14)); ctx.addLine(to: CGPoint(x: 10, y: 14))
                ctx.move(to: CGPoint(x: 14, y: 14)); ctx.addLine(to: CGPoint(x: 14, y: 10))
                ctx.move(to: CGPoint(x: 2, y: 2)); ctx.addLine(to: CGPoint(x: 6, y: 2))
                ctx.move(to: CGPoint(x: 2, y: 2)); ctx.addLine(to: CGPoint(x: 2, y: 6))
            }
            ctx.strokePath()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 8, y: 8))
    }

    // MARK: - Annotation Handle Cursor
    func cursorForAnnoHandle(_ handle: AnnoResizeHandle) -> NSCursor {
        switch handle {
        case .startPoint, .endPoint:
            return .crosshair
        case .topLeft, .bottomRight:
            return makeDiagonalCursor(nwse: true)
        case .topRight, .bottomLeft:
            return makeDiagonalCursor(nwse: false)
        }
    }

    // MARK: - Annotation Hit Testing
    func hitTestAnnotation(at screenPoint: NSPoint) -> AnnotationElement? {
        let localPoint = screenToLocal(screenPoint)
        for element in annoState.elements.reversed() {
            if element.hitTest(point: localPoint) {
                return element
            }
        }
        return nil
    }

    // Hit test annotation resize handles (only for selected element)
    func hitTestAnnoResizeHandle(at screenPoint: NSPoint) -> (AnnotationElement, AnnoResizeHandle)? {
        guard let sel = annoState.selectedElement else { return nil }
        let localPoint = screenToLocal(screenPoint)
        if let handle = sel.hitTestResizeHandle(point: localPoint) {
            return (sel, handle)
        }
        return nil
    }

    // MARK: - Crop (with annotations)
    func cropImage() -> NSImage? {
        guard hasSelection else { return nil }

        guard let cgImage = screenshot.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        // Use actual CGImage pixel dimensions for scale, not NSBitmapImageRep.pixelsWide
        // which can differ from cgImage dimensions on non-standard DPI configurations (e.g. 4K at 1x)
        let viewWidth = bounds.width
        let viewHeight = bounds.height
        let scaleX = CGFloat(cgImage.width) / viewWidth
        let scaleY = CGFloat(cgImage.height) / viewHeight

        let imageRect = CGRect(
            x: selectionRect.origin.x * scaleX,
            y: (viewHeight - selectionRect.origin.y - selectionRect.height) * scaleY,
            width: selectionRect.width * scaleX,
            height: selectionRect.height * scaleY
        )

        guard let croppedCG = cgImage.cropping(to: imageRect) else { return nil }

        let baseImage = NSImage(cgImage: croppedCG, size: NSSize(width: selectionRect.width, height: selectionRect.height))

        if !annoState.elements.isEmpty {
            return AnnotationRenderer.renderAnnotationsOntoImage(
                baseImage: baseImage,
                annotations: annoState.elements,
                selectionRect: selectionRect,
                screenshot: screenshot
            )
        }

        return baseImage
    }

    // MARK: - Tool Selection
    func selectTool(_ tool: AnnotationTool) {
        // If currently editing text, commit it first
        if mode == .editingText {
            commitTextEditing()
        }
        annoState.currentTool = tool
        // Switching tools always clears selection
        annoState.clearSelection()
        marqueeStart = nil
        marqueeRect = nil
        // Only transition to .annotating if annotations exist;
        // otherwise preserve .selected so the selection frame stays interactive
        if !annoState.elements.isEmpty {
            mode = .annotating
        }
        removeAllPanels()
        showAllPanels()
        needsDisplay = true
    }

    /// Switch to select tool and select the given element (shows element properties)
    func selectElement(_ element: AnnotationElement) {
        annoState.currentTool = .select
        annoState.selectedElementId = element.id
        annoState.selectedElementIds.removeAll()
        annoState.currentColor = element.color
        if element.tool != .select {
            annoState.strokeWidths[element.tool] = element.strokeWidth
        }
        // Element exists, so we're in annotation mode
        mode = .annotating
        removeAllPanels()
        showAllPanels()
        needsDisplay = true
    }

    /// Enter select tool mode (used after selection completion).
    /// Does NOT change mode — caller is responsible for setting the correct mode.
    func enterSelectMode() {
        annoState.currentTool = .select
        annoState.clearSelection()
        removeAllPanels()
        showAllPanels()
        needsDisplay = true
    }

    func selectColor(_ color: NSColor) {
        annoState.currentColor = color
        if let sel = annoState.selectedElement {
            annoState.pushUndoForPropertyChange(kind: .color)
            sel.color = color
        }
        updateColorDots()
        needsDisplay = true
    }

    func updateToolbarState() {
        for (tool, btn) in toolButtons {
            btn.isActive = (annoState.currentTool == tool)
        }
    }

    func updateColorDots() {
        for (color, dot) in colorDots {
            dot.isSelected = annoState.currentColor.isEqual(to: color)
        }
    }

    // MARK: - Auto-Copy
    /// Automatically copy the current selection to clipboard if auto-copy is enabled.
    func autoCopyIfEnabled() {
        // Auto-commit any uncommitted text editing before auto-copy
        if case .editingText = mode {
            commitTextEditing()
            mode = .annotating
        }
        guard autoCopyEnabled, hasSelection else { return }
        if let image = cropImage() {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([image])
            hasAutoCopied = true
            logMessage("Auto-copy: selection copied to clipboard.")
        }
    }

    // MARK: - Actions
    enum ActionType { case copy, save, pin, scrollCapture, askAI, cancel }

    func performAction(_ type: ActionType) {
        // Auto-commit any uncommitted text editing before exporting
        if case .editingText = mode {
            commitTextEditing()
            mode = .annotating
        }
        if type == .cancel {
            // When auto-copy is enabled and we have a selection, copy before cancelling
            if autoCopyEnabled && hasSelection && !hasAutoCopied {
                autoCopyIfEnabled()
            }
            onAction(.cancel)
            return
        }

        // Convert view-local selectionRect to screen coordinates
        let windowOrigin = window?.frame.origin ?? .zero
        let screenRect = NSRect(
            x: selectionRect.origin.x + windowOrigin.x,
            y: selectionRect.origin.y + windowOrigin.y,
            width: selectionRect.width,
            height: selectionRect.height
        )

        if type == .scrollCapture {
            // Crop a clean first frame from the original screenshot (no UI controls)
            guard let cgImage = screenshot.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            let viewWidth = bounds.width
            let viewHeight = bounds.height
            let scaleX = CGFloat(cgImage.width) / viewWidth
            let scaleY = CGFloat(cgImage.height) / viewHeight
            let imageRect = CGRect(
                x: selectionRect.origin.x * scaleX,
                y: (viewHeight - selectionRect.origin.y - selectionRect.height) * scaleY,
                width: selectionRect.width * scaleX,
                height: selectionRect.height * scaleY
            )
            guard let croppedCG = cgImage.cropping(to: imageRect) else { return }
            let firstFrame = NSImage(cgImage: croppedCG, size: NSSize(width: selectionRect.width, height: selectionRect.height))
            onAction(.scrollCapture(screenRect, firstFrame))
            return
        }

        guard let image = cropImage() else { return }
        switch type {
        case .copy:  onAction(.copy(image, screenRect))
        case .save:  onAction(.save(image, screenRect))
        case .pin:   onAction(.pin(image, screenRect))
        case .askAI: onAction(.askAI(image, screenRect))
        case .scrollCapture, .cancel: break
        }
    }

    // MARK: - Window Snapping
    func cacheWindowFrames() {
        // Determine which screen this overlay covers.
        // At init time window may not be set yet, so we fall back to mouse location.
        let overlayScreen: NSScreen
        if let ws = window?.screen {
            overlayScreen = ws
        } else {
            let mouseLocation = NSEvent.mouseLocation
            overlayScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main ?? NSScreen.screens[0]
        }
        let screenFrame = overlayScreen.frame
        // CG coordinates use top-left origin of the primary display
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screenFrame.height
        let viewBounds = bounds

        // Get the overlay window's own window number so we can skip exactly that window.
        // Other Snipshot windows (e.g. Settings) at layer 0 should remain snappable.
        let overlayWindowNumber = window?.windowNumber ?? -1

        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }

        // First pass: collect all valid window rects in Z-order (front to back)
        var allFrames: [NSRect] = []
        for info in windowList {
            // Skip our own overlay window (by window number, not PID, so other
            // Snipshot windows like Settings remain snappable)
            if let wid = info[kCGWindowNumber as String] as? Int,
               wid == overlayWindowNumber { continue }

            guard let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = boundsDict["X"], let y = boundsDict["Y"],
                  let w = boundsDict["Width"], let h = boundsDict["Height"],
                  w > 50 && h > 50 else { continue }

            // Only include normal windows (layer 0). Skip floating overlays,
            // status bars, and system UI elements.
            let layer = info[kCGWindowLayer as String] as? Int ?? -1
            guard layer == 0 else { continue }

            // Convert CG rect (top-left origin) to NS rect (bottom-left origin)
            let nsY = primaryHeight - y - h
            let localRect = NSRect(
                x: x - screenFrame.origin.x,
                y: nsY - screenFrame.origin.y,
                width: w,
                height: h
            )

            // Skip windows that don't intersect with the current screen
            guard viewBounds.intersects(localRect) else { continue }

            // Clip to view bounds so off-screen portions don't affect hit-testing
            let clipped = viewBounds.intersection(localRect)
            guard clipped.width > 50 && clipped.height > 50 else { continue }

            allFrames.append(clipped)
        }

        // Second pass: keep windows that have at least one corner visible
        // (not fully occluded by higher Z-order windows).
        // Previous logic required ALL 4 corners visible, which incorrectly
        // excluded fullscreen/maximized apps when any overlapping window
        // covered even a single corner.
        var snappableFrames: [NSRect] = []
        for (i, frame) in allFrames.enumerated() {
            let corners = [
                NSPoint(x: frame.minX + 1, y: frame.minY + 1),
                NSPoint(x: frame.maxX - 1, y: frame.minY + 1),
                NSPoint(x: frame.minX + 1, y: frame.maxY - 1),
                NSPoint(x: frame.maxX - 1, y: frame.maxY - 1),
            ]
            var anyCornersVisible = false
            for corner in corners {
                var cornerVisible = true
                for j in 0..<i {
                    if allFrames[j].contains(corner) {
                        cornerVisible = false
                        break
                    }
                }
                if cornerVisible {
                    anyCornersVisible = true
                    break
                }
            }
            if anyCornersVisible {
                snappableFrames.append(frame)
            }
        }
        windowFrames = snappableFrames
    }

    func snapToWindows(point: NSPoint) -> NSPoint {
        let threshold: CGFloat = 8
        var snapped = point

        for frame in windowFrames {
            // Snap to left edge
            if abs(point.x - frame.minX) < threshold { snapped.x = frame.minX }
            // Snap to right edge
            if abs(point.x - frame.maxX) < threshold { snapped.x = frame.maxX }
            // Snap to top edge
            if abs(point.y - frame.maxY) < threshold { snapped.y = frame.maxY }
            // Snap to bottom edge
            if abs(point.y - frame.minY) < threshold { snapped.y = frame.minY }
        }

        return snapped
    }

    /// Find the window frame that contains the given point (Z-order: first match = topmost)
    func windowFrameAt(point: NSPoint) -> NSRect? {
        // CGWindowListCopyWindowInfo returns windows in Z-order (front to back),
        // so the first frame containing the point is the topmost window.
        for frame in windowFrames {
            if frame.contains(point) {
                return frame
            }
        }
        return nil
    }

    // MARK: - Color Picker Helpers

    /// Read pixel color from the screenshot bitmap at a view-coordinate point.
    /// Returns nil if the point is out of bounds.
    func pixelColor(atViewPoint point: NSPoint) -> NSColor? {
        guard let bitmap = cachedBitmapRep else { return nil }
        let bitmapW = bitmap.pixelsWide
        let bitmapH = bitmap.pixelsHigh
        let viewW = bounds.width
        let viewH = bounds.height
        // Convert view coords (bottom-left origin) to bitmap coords (top-left origin)
        let bx = Int(point.x * CGFloat(bitmapW) / viewW)
        let by = Int((viewH - point.y) * CGFloat(bitmapH) / viewH)
        guard bx >= 0 && bx < bitmapW && by >= 0 && by < bitmapH else { return nil }
        return bitmap.colorAt(x: bx, y: by)
    }

    /// Get NxN pixel colors around a view-coordinate point (N = 2*radius+1).
    /// Returns array of N*N colors in row-major order (top-left to bottom-right visually).
    func pixelColorsNxN(atViewPoint point: NSPoint, radius: Int) -> [NSColor?] {
        let n = radius * 2 + 1
        guard let bitmap = cachedBitmapRep else { return Array(repeating: nil, count: n * n) }
        let bitmapW = bitmap.pixelsWide
        let bitmapH = bitmap.pixelsHigh
        let viewW = bounds.width
        let viewH = bounds.height
        let bx = Int(point.x * CGFloat(bitmapW) / viewW)
        let by = Int((viewH - point.y) * CGFloat(bitmapH) / viewH)
        var colors: [NSColor?] = []
        for dy in -radius...radius {
            for dx in -radius...radius {
                let px = bx + dx
                let py = by + dy
                if px >= 0 && px < bitmapW && py >= 0 && py < bitmapH {
                    colors.append(bitmap.colorAt(x: px, y: py))
                } else {
                    colors.append(nil)
                }
            }
        }
        return colors
    }

    /// Format an NSColor to string based on current colorFormat.
    func formatColor(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        let r = c.redComponent
        let g = c.greenComponent
        let b = c.blueComponent
        switch colorFormat {
        case .hex:
            return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
        case .rgb:
            return String(format: "rgb(%d, %d, %d)", Int(r * 255), Int(g * 255), Int(b * 255))
        case .hsl:
            let maxC = max(r, g, b)
            let minC = min(r, g, b)
            let l = (maxC + minC) / 2
            if maxC == minC {
                return String(format: "hsl(0, 0%%, %d%%)", Int(l * 100))
            }
            let d = maxC - minC
            let s = l > 0.5 ? d / (2 - maxC - minC) : d / (maxC + minC)
            var h: CGFloat
            if maxC == r {
                h = (g - b) / d + (g < b ? 6 : 0)
            } else if maxC == g {
                h = (b - r) / d + 2
            } else {
                h = (r - g) / d + 4
            }
            h /= 6
            return String(format: "hsl(%d, %d%%, %d%%)", Int(h * 360), Int(s * 100), Int(l * 100))
        }
    }

    /// Draw the 9x9 pixel preview box and color value label near the cursor.
    /// The grid box and the color label are laid out independently so the label
    /// never stretches the grid.
    private func drawColorPicker(at point: NSPoint) {
        let gridN = 9
        let radius = gridN / 2  // 4
        let colors = pixelColorsNxN(atViewPoint: point, radius: radius)
        let centerIndex = radius * gridN + radius
        let centerColor = colors[centerIndex]

        let cellSize: CGFloat = 10
        let gridSize = cellSize * CGFloat(gridN)
        let gridPadding: CGFloat = 3
        let labelFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)

        // --- Grid box dimensions (fixed) ---
        let gridBoxWidth = gridSize + gridPadding * 2
        let gridBoxHeight = gridSize + gridPadding * 2

        // --- Label dimensions ---
        let colorText: String
        if let cc = centerColor {
            colorText = formatColor(cc)
        } else {
            colorText = "---"
        }
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: NSColor.white
        ]
        let textSize = (colorText as NSString).size(withAttributes: textAttrs)
        let labelPaddingH: CGFloat = 6
        let labelPaddingV: CGFloat = 3
        let labelBoxWidth = textSize.width + labelPaddingH * 2
        let labelBoxHeight = textSize.height + labelPaddingV * 2
        let labelGap: CGFloat = 3  // gap between grid box and label box

        // --- Combined bounding height for positioning ---
        let totalHeight = gridBoxHeight + labelGap + labelBoxHeight

        // Position: offset from cursor (right-bottom, with fallback)
        let offsetX: CGFloat = 20
        let offsetY: CGFloat = -20
        var anchorOrigin = NSPoint(x: point.x + offsetX, y: point.y + offsetY - totalHeight)
        // Keep within bounds (use the wider of the two for x check)
        let maxWidth = max(gridBoxWidth, labelBoxWidth)
        if anchorOrigin.x + maxWidth > bounds.maxX - 4 {
            anchorOrigin.x = point.x - offsetX - maxWidth
        }
        if anchorOrigin.y < bounds.minY + 4 {
            anchorOrigin.y = point.y - offsetY
        }
        if anchorOrigin.x < bounds.minX + 4 {
            anchorOrigin.x = bounds.minX + 4
        }

        // --- Draw grid box ---
        let gridBoxOrigin = NSPoint(x: anchorOrigin.x, y: anchorOrigin.y + labelBoxHeight + labelGap)
        let gridBoxRect = NSRect(x: gridBoxOrigin.x, y: gridBoxOrigin.y, width: gridBoxWidth, height: gridBoxHeight)
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: gridBoxRect, xRadius: 6, yRadius: 6).fill()

        let gridOriginX = gridBoxOrigin.x + gridPadding
        let gridOriginY = gridBoxOrigin.y + gridPadding

        for row in 0..<gridN {
            for col in 0..<gridN {
                let idx = row * gridN + col
                let cellRect = NSRect(
                    x: gridOriginX + CGFloat(col) * cellSize,
                    y: gridOriginY + CGFloat(gridN - 1 - row) * cellSize,
                    width: cellSize,
                    height: cellSize
                )
                if let c = colors[idx] {
                    c.setFill()
                } else {
                    NSColor.darkGray.setFill()
                }
                cellRect.fill()

                // Draw thin grid lines
                NSColor.black.withAlphaComponent(0.15).setStroke()
                let cellPath = NSBezierPath(rect: cellRect)
                cellPath.lineWidth = 0.5
                cellPath.stroke()
            }
        }

        // Highlight center cell
        let centerRect = NSRect(
            x: gridOriginX + CGFloat(radius) * cellSize,
            y: gridOriginY + CGFloat(radius) * cellSize,
            width: cellSize,
            height: cellSize
        )
        NSColor.white.setStroke()
        let centerPath = NSBezierPath(rect: centerRect.insetBy(dx: 0.5, dy: 0.5))
        centerPath.lineWidth = 1.5
        centerPath.stroke()

        // --- Draw color label box (independent, below grid, left-aligned) ---
        let labelBoxOrigin = NSPoint(x: anchorOrigin.x, y: anchorOrigin.y)
        let labelBoxRect = NSRect(x: labelBoxOrigin.x, y: labelBoxOrigin.y, width: labelBoxWidth, height: labelBoxHeight)
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: labelBoxRect, xRadius: 4, yRadius: 4).fill()

        let textOrigin = NSPoint(
            x: labelBoxOrigin.x + labelPaddingH,
            y: labelBoxOrigin.y + labelPaddingV
        )
        (colorText as NSString).draw(at: textOrigin, withAttributes: textAttrs)
    }

    /// Draw post-selection help tips in the bottom-left corner with grouped sections.
    private func drawPostSelectionTips() {
        // Each section: (header, [(key, description)])
        let sections: [(String, [(String, String)])] = [
            ("Annotation", [
                ("Click", "Select element"),
                ("Backspace", "Delete selected"),
                ("Double-click", "Edit text"),
                ("Shift+Enter", "New line in text"),
            ]),
            ("Pin (F3)", [
                ("Drag", "Move pinned image"),
                ("Scroll", "Resize"),
                ("\u{2318}+Scroll", "Adjust opacity"),
                ("[ ]", "Adjust opacity"),
            ]),
        ]

        let headerFont = NSFont.systemFont(ofSize: 11, weight: .bold)
        let keyFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        let descFont = NSFont.systemFont(ofSize: 11, weight: .regular)
        let headerAttrs: [NSAttributedString.Key: Any] = [.font: headerFont, .foregroundColor: NSColor(white: 0.95, alpha: 1.0)]
        let keyAttrs: [NSAttributedString.Key: Any] = [.font: keyFont, .foregroundColor: NSColor.white]
        let descAttrs: [NSAttributedString.Key: Any] = [.font: descFont, .foregroundColor: NSColor(white: 0.7, alpha: 1.0)]

        let padding: CGFloat = 10
        let lineSpacing: CGFloat = 3
        let sectionSpacing: CGFloat = 8
        let keyDescGap: CGFloat = 8

        // Measure all content
        let sampleSize = ("Xg" as NSString).size(withAttributes: keyAttrs)
        let lineHeight = sampleSize.height
        let headerHeight = ("Xg" as NSString).size(withAttributes: headerAttrs).height

        var maxKeyWidth: CGFloat = 0
        var maxDescWidth: CGFloat = 0
        for (_, items) in sections {
            for (key, desc) in items {
                let ks = (key as NSString).size(withAttributes: keyAttrs)
                let ds = (desc as NSString).size(withAttributes: descAttrs)
                maxKeyWidth = max(maxKeyWidth, ks.width)
                maxDescWidth = max(maxDescWidth, ds.width)
            }
        }
        // Header widths are considered via maxHeaderWidth below

        let contentWidth = maxKeyWidth + keyDescGap + maxDescWidth
        var maxHeaderWidth: CGFloat = 0
        for (header, _) in sections {
            maxHeaderWidth = max(maxHeaderWidth, (header as NSString).size(withAttributes: headerAttrs).width)
        }
        let boxWidth = padding + max(contentWidth, maxHeaderWidth) + padding

        // Calculate total height
        var totalHeight: CGFloat = padding
        for (i, (_, items)) in sections.enumerated() {
            totalHeight += headerHeight + lineSpacing  // header + gap
            totalHeight += CGFloat(items.count) * lineHeight + CGFloat(items.count - 1) * lineSpacing
            if i < sections.count - 1 {
                totalHeight += sectionSpacing
            }
        }
        totalHeight += padding

        let margin: CGFloat = 12
        let boxOrigin = NSPoint(x: bounds.minX + margin, y: bounds.minY + margin)
        let boxRect = NSRect(x: boxOrigin.x, y: boxOrigin.y, width: boxWidth, height: totalHeight)

        // Hide if mouse is near
        if let mousePos = currentMousePosition {
            let expandedRect = boxRect.insetBy(dx: -30, dy: -30)
            if expandedRect.contains(mousePos) { return }
        }

        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: boxRect, xRadius: 6, yRadius: 6).fill()

        // Draw from top
        var y = boxOrigin.y + totalHeight - padding
        for (i, (header, items)) in sections.enumerated() {
            // Draw header
            y -= headerHeight
            (header as NSString).draw(at: NSPoint(x: boxOrigin.x + padding, y: y), withAttributes: headerAttrs)
            y -= lineSpacing

            // Draw items
            for (j, (key, desc)) in items.enumerated() {
                y -= lineHeight
                (key as NSString).draw(at: NSPoint(x: boxOrigin.x + padding, y: y), withAttributes: keyAttrs)
                let descX = boxOrigin.x + padding + maxKeyWidth + keyDescGap
                (desc as NSString).draw(at: NSPoint(x: descX, y: y), withAttributes: descAttrs)
                if j < items.count - 1 {
                    y -= lineSpacing
                }
            }

            if i < sections.count - 1 {
                y -= sectionSpacing
            }
        }
    }

    /// Draw the keyboard shortcuts tips box in the bottom-left corner.
    /// Hidden when mouse is near it or when selection exists.
    private func drawTipsBox(mousePos: NSPoint) {
        let tips: [(String, String)] = [
            ("Esc", "Exit"),
            ("Shift", "Switch color format"),
            ("C", "Copy color value"),
        ]

        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        let descFont = NSFont.systemFont(ofSize: 12, weight: .regular)
        let keyAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let descAttrs: [NSAttributedString.Key: Any] = [.font: descFont, .foregroundColor: NSColor(white: 0.75, alpha: 1.0)]

        let padding: CGFloat = 10
        let lineSpacing: CGFloat = 4
        let keyDescGap: CGFloat = 8

        // Calculate dimensions
        var maxKeyWidth: CGFloat = 0
        var maxDescWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        for (key, desc) in tips {
            let ks = (key as NSString).size(withAttributes: keyAttrs)
            let ds = (desc as NSString).size(withAttributes: descAttrs)
            maxKeyWidth = max(maxKeyWidth, ks.width)
            maxDescWidth = max(maxDescWidth, ds.width)
            lineHeight = max(lineHeight, max(ks.height, ds.height))
        }

        let boxWidth = padding + maxKeyWidth + keyDescGap + maxDescWidth + padding
        let boxHeight = padding + CGFloat(tips.count) * lineHeight + CGFloat(tips.count - 1) * lineSpacing + padding

        let margin: CGFloat = 12
        let boxOrigin = NSPoint(x: bounds.minX + margin, y: bounds.minY + margin)
        let boxRect = NSRect(x: boxOrigin.x, y: boxOrigin.y, width: boxWidth, height: boxHeight)

        // Hide if mouse is near the tips box
        let hoverMargin: CGFloat = 40
        let expandedRect = boxRect.insetBy(dx: -hoverMargin, dy: -hoverMargin)
        if expandedRect.contains(mousePos) {
            return
        }

        // Draw background
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: boxRect, xRadius: 6, yRadius: 6).fill()

        // Draw tips
        var y = boxOrigin.y + boxHeight - padding - lineHeight
        for (key, desc) in tips {
            let keyStr = key as NSString
            let descStr = desc as NSString
            keyStr.draw(at: NSPoint(x: boxOrigin.x + padding, y: y), withAttributes: keyAttrs)
            descStr.draw(at: NSPoint(x: boxOrigin.x + padding + maxKeyWidth + keyDescGap, y: y), withAttributes: descAttrs)
            y -= lineHeight + lineSpacing
        }
    }

    // MARK: - Drawing
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        screenshot.draw(in: bounds)
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()

        if hasSelection {
            screenshot.draw(in: selectionRect, from: selectionRect, operation: .copy, fraction: 1.0)

            // Draw annotations
            if let context = NSGraphicsContext.current {
                context.cgContext.saveGState()
                context.cgContext.clip(to: selectionRect)

                // Draw mosaic elements first (bottom layer) so they only pixelate the original image
                for element in annoState.elements where element.tool == .mosaic {
                    let isSelected = annoState.isElementSelected(element)
                    AnnotationRenderer.draw(
                        element: element,
                        in: context,
                        selectionOrigin: selectionRect.origin,
                        isSelected: isSelected,
                        screenshot: screenshot,
                        selectionRect: selectionRect
                    )
                }
                if let current = currentAnnotationElement, current.tool == .mosaic {
                    AnnotationRenderer.draw(
                        element: current,
                        in: context,
                        selectionOrigin: selectionRect.origin,
                        isSelected: false,
                        screenshot: screenshot,
                        selectionRect: selectionRect
                    )
                }

                // Draw all other annotations on top
                for element in annoState.elements where element.tool != .mosaic {
                    // Skip drawing text element while it's being edited (textEditView is visible)
                    if element.tool == .text && element.id == annoState.selectedElementId && textEditView != nil {
                        continue
                    }
                    let isSelected = annoState.isElementSelected(element)
                    AnnotationRenderer.draw(
                        element: element,
                        in: context,
                        selectionOrigin: selectionRect.origin,
                        isSelected: isSelected,
                        screenshot: screenshot,
                        selectionRect: selectionRect
                    )
                }
                if let current = currentAnnotationElement, current.tool != .mosaic {
                    AnnotationRenderer.draw(
                        element: current,
                        in: context,
                        selectionOrigin: selectionRect.origin,
                        isSelected: false,
                        screenshot: screenshot,
                        selectionRect: selectionRect
                    )
                }

                // Draw marquee selection rect
                if let mRect = marqueeRect {
                    let screenMRect = NSRect(
                        x: mRect.origin.x + selectionRect.origin.x,
                        y: mRect.origin.y + selectionRect.origin.y,
                        width: mRect.width,
                        height: mRect.height
                    )
                    NSColor.systemBlue.withAlphaComponent(0.15).setFill()
                    NSBezierPath(rect: screenMRect).fill()
                    NSColor.systemBlue.withAlphaComponent(0.6).setStroke()
                    let mPath = NSBezierPath(rect: screenMRect)
                    mPath.lineWidth = 1.0
                    mPath.setLineDash([4, 3], count: 2, phase: 0)
                    mPath.stroke()
                }

                context.cgContext.restoreGState()
            }

            // Selection border
            NSColor.white.setStroke()
            let borderPath = NSBezierPath(rect: selectionRect)
            borderPath.lineWidth = 1.5; borderPath.stroke()

            NSColor(white: 1.0, alpha: 0.6).setStroke()
            let dashedPath = NSBezierPath(rect: selectionRect.insetBy(dx: 1, dy: 1))
            dashedPath.lineWidth = 0.5; dashedPath.setLineDash([4, 4], count: 2, phase: 0); dashedPath.stroke()

            // Resize handles only in selected mode (no annotation tool active)
            if mode == .selected {
                drawResizeHandles()
            }

            if case .drawing = mode { drawDimensionLabel(for: selectionRect) }

            // Show help tips in selected/annotating modes
            if mode == .selected || mode == .annotating {
                drawPostSelectionTips()
            }
        }

        if case .idle = mode, let mousePos = currentMousePosition {
            // Draw window highlight under cursor
            if let winFrame = hoveredWindowFrame {
                drawWindowHighlight(winFrame)
            }
            drawCrosshair(at: mousePos)
            drawColorPicker(at: mousePos)
            drawTipsBox(mousePos: mousePos)
        }
    }

    private func drawResizeHandles() {
        let r = selectionRect; let s = handleSize
        let positions: [(ResizeHandle, NSPoint)] = [
            (.topLeft, NSPoint(x: r.minX, y: r.maxY)), (.topRight, NSPoint(x: r.maxX, y: r.maxY)),
            (.bottomLeft, NSPoint(x: r.minX, y: r.minY)), (.bottomRight, NSPoint(x: r.maxX, y: r.minY)),
            (.top, NSPoint(x: r.midX, y: r.maxY)), (.bottom, NSPoint(x: r.midX, y: r.minY)),
            (.left, NSPoint(x: r.minX, y: r.midY)), (.right, NSPoint(x: r.maxX, y: r.midY)),
        ]
        for (handle, pt) in positions {
            let rect = NSRect(x: pt.x - s/2, y: pt.y - s/2, width: s, height: s)
            let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            (hoveredHandle == handle ? NSColor.systemBlue : NSColor.white).setFill()
            path.fill()
            NSColor(white: 0.3, alpha: 1.0).setStroke(); path.lineWidth = 0.5; path.stroke()
        }
    }

    private func drawCrosshair(at point: NSPoint) {
        NSColor.black.withAlphaComponent(0.35).setStroke()
        let vS = NSBezierPath(); vS.move(to: NSPoint(x: point.x, y: bounds.minY)); vS.line(to: NSPoint(x: point.x, y: bounds.maxY)); vS.lineWidth = 1.5; vS.stroke()
        let hS = NSBezierPath(); hS.move(to: NSPoint(x: bounds.minX, y: point.y)); hS.line(to: NSPoint(x: bounds.maxX, y: point.y)); hS.lineWidth = 1.5; hS.stroke()

        let dp: [CGFloat] = [6, 4]
        NSColor.white.withAlphaComponent(0.7).setStroke()
        let vL = NSBezierPath(); vL.move(to: NSPoint(x: point.x, y: bounds.minY)); vL.line(to: NSPoint(x: point.x, y: bounds.maxY)); vL.lineWidth = 0.75; vL.setLineDash(dp, count: 2, phase: 0); vL.stroke()
        let hL = NSBezierPath(); hL.move(to: NSPoint(x: bounds.minX, y: point.y)); hL.line(to: NSPoint(x: bounds.maxX, y: point.y)); hL.lineWidth = 0.75; hL.setLineDash(dp, count: 2, phase: 0); hL.stroke()

        let ms: CGFloat = 8
        NSColor.white.withAlphaComponent(0.85).setStroke()
        let cV = NSBezierPath(); cV.move(to: NSPoint(x: point.x, y: point.y - ms)); cV.line(to: NSPoint(x: point.x, y: point.y + ms)); cV.lineWidth = 1.5; cV.stroke()
        let cH = NSBezierPath(); cH.move(to: NSPoint(x: point.x - ms, y: point.y)); cH.line(to: NSPoint(x: point.x + ms, y: point.y)); cH.lineWidth = 1.5; cH.stroke()
    }

    private func drawDimensionLabel(for rect: NSRect) {
        let scale: CGFloat = window?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let text = "\(Int(rect.width * scale)) \u{00D7} \(Int(rect.height * scale))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
        let ts = text.size(withAttributes: attrs)
        var origin = NSPoint(x: rect.origin.x, y: rect.origin.y - ts.height - 8)
        if origin.y < bounds.minY + 4 { origin.y = rect.maxY + 4 }
        let bg = NSRect(x: origin.x, y: origin.y, width: ts.width + 12, height: ts.height + 6)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 4, yRadius: 4).fill()
        text.draw(at: NSPoint(x: bg.origin.x + 6, y: bg.origin.y + 3), withAttributes: attrs)
    }

    private func drawWindowHighlight(_ frame: NSRect) {
        // Reveal the screenshot content inside the window frame (lift the dim overlay)
        screenshot.draw(in: frame, from: frame, operation: .copy, fraction: 1.0)

        // Draw a highlight border around the window
        let highlightColor = NSColor.systemBlue.withAlphaComponent(0.6)
        highlightColor.setStroke()
        let borderPath = NSBezierPath(rect: frame)
        borderPath.lineWidth = 2.5
        borderPath.stroke()

        // Draw dimension label for the highlighted window
        drawDimensionLabel(for: frame)
    }

    // MARK: - Mouse Events
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Check panels first
        if isPointInPanel(point) { super.mouseDown(with: event); return }

        switch mode {
        case .ocrMode:
            if isPointInPanel(point) { super.mouseDown(with: event); return }
            super.mouseDown(with: event)
            return

        case .annotating:
            guard selectionRect.contains(point) || hitTestAnnoResizeHandle(at: point) != nil else { return }
            let localPt = screenToLocal(point)

            // Resize handles on selected element (works for both select and drawing tools)
            if let (element, handle) = hitTestAnnoResizeHandle(at: point) {
                annoState.pushUndo()
                annoResizeElement = element
                annoResizeHandle = handle
                mode = .resizingAnnotation(handle)
                return
            }

            let isSelectTool = annoState.currentTool == .select

            // Hit an existing element?
            if let element = hitTestAnnotation(at: point) {
                // Double-click on text element: re-enter editing mode
                if event.clickCount == 2 && element.tool == .text {
                    annoState.selectedElementId = element.id
                    annoState.selectedElementIds.removeAll()
                    mode = .editingText
                    showTextEditor(for: element)
                    needsDisplay = true
                    return
                }
                // Click on element: always switch to select tool and select it
                selectElement(element)
                annoState.pushUndo()  // snapshot before move
                annoDragStart = localPt
                annoDragElementStart = element.startPoint
                annoDragElementEnd = element.endPoint
                mode = .movingAnnotation
                return
            }

            // Clicked empty area
            annoState.clearSelection()
            refreshSecondaryPanel()

            if isSelectTool {
                // Start marquee selection
                marqueeStart = localPt
                marqueeRect = nil
                needsDisplay = true
                return
            }

            // Drawing tools: create new element
            if let tool = annoState.currentTool, tool.isDrawingTool {
                annoState.pushUndo()
                if tool == .text {
                    let element = AnnotationElement(tool: .text, color: annoState.currentColor, strokeWidth: annoState.strokeWidths[.text] ?? 4, startPoint: localPt, endPoint: localPt)
                    element.text = ""
                    annoState.elements.append(element)
                    annoState.selectedElementId = element.id
                    mode = .editingText
                    showTextEditor(for: element)
                    needsDisplay = true
                    return
                } else if tool == .marker {
                    let element = AnnotationElement(tool: .marker, color: annoState.currentColor, strokeWidth: annoState.strokeWidths[.marker] ?? 12, startPoint: localPt, endPoint: localPt)
                    element.markerNumber = annoState.nextMarkerNumber
                    annoState.nextMarkerNumber += 1
                    annoState.elements.append(element)
                    if autoSwitchToSelect {
                        selectElement(element)
                    }
                    needsDisplay = true
                    return
                } else {
                    annotationDrawStart = localPt
                    let sw = annoState.strokeWidths[tool] ?? 3
                    currentAnnotationElement = AnnotationElement(tool: tool, color: annoState.currentColor, strokeWidth: sw, startPoint: localPt, endPoint: localPt)
                    mode = .drawingAnnotation
                    needsDisplay = true
                    return
                }
            }
            refreshSecondaryPanel()
            needsDisplay = true

        case .drawingAnnotation:
            break

        case .movingAnnotation:
            break

        case .resizingAnnotation:
            break

        case .editingText:
            commitTextEditing()
            mode = .annotating
            needsDisplay = true

        case .selected:
            if let element = hitTestAnnotation(at: point) {
                // Double-click on text element: re-enter editing mode
                if event.clickCount == 2 && element.tool == .text {
                    annoState.selectedElementId = element.id
                    annoState.selectedElementIds.removeAll()
                    mode = .editingText
                    showTextEditor(for: element)
                    needsDisplay = true
                    return
                }
                selectElement(element)
                let localPt = screenToLocal(point)
                annoDragStart = localPt
                annoDragElementStart = element.startPoint
                annoDragElementEnd = element.endPoint
                mode = .movingAnnotation
                return
            }

            if let handle = hitTestHandle(at: point) {
                mode = .resizing(handle)
                resizeAnchor = anchorForHandle(handle)
                return
            }

            if selectionRect.contains(point) {
                // If a drawing tool is active, start drawing annotation instead of moving selection
                if let tool = annoState.currentTool, tool.isDrawingTool {
                    let localPt = screenToLocal(point)
                    annoState.pushUndo()
                    if tool == .text {
                        let element = AnnotationElement(tool: .text, color: annoState.currentColor, strokeWidth: annoState.strokeWidths[.text] ?? 4, startPoint: localPt, endPoint: localPt)
                        element.text = ""
                        annoState.elements.append(element)
                        annoState.selectedElementId = element.id
                        mode = .editingText
                        showTextEditor(for: element)
                        needsDisplay = true
                        return
                    } else if tool == .marker {
                        let element = AnnotationElement(tool: .marker, color: annoState.currentColor, strokeWidth: annoState.strokeWidths[.marker] ?? 12, startPoint: localPt, endPoint: localPt)
                        element.markerNumber = annoState.nextMarkerNumber
                        annoState.nextMarkerNumber += 1
                        annoState.elements.append(element)
                        if autoSwitchToSelect {
                            selectElement(element)
                        }
                        needsDisplay = true
                        return
                    } else {
                        annotationDrawStart = localPt
                        let sw = annoState.strokeWidths[tool] ?? 3
                        currentAnnotationElement = AnnotationElement(tool: tool, color: annoState.currentColor, strokeWidth: sw, startPoint: localPt, endPoint: localPt)
                        mode = .drawingAnnotation
                        needsDisplay = true
                        return
                    }
                }
                mode = .moving
                moveOffset = NSPoint(x: point.x - selectionRect.origin.x, y: point.y - selectionRect.origin.y)
                NSCursor.closedHand.set()
                return
            }

            // Outside = restart
            removeAllPanels()
            annoState.elements.removeAll()
            annoState.undoStack.removeAll()
            annoState.selectedElementId = nil
            annoState.nextMarkerNumber = 1
            selectionRect = .zero
            hoveredWindowFrame = nil
            mode = .drawing; drawStart = point
            needsDisplay = true

        case .idle:
            hoveredWindowFrame = nil
            mode = .drawing; drawStart = point; selectionRect = .zero; needsDisplay = true

        default: break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        switch mode {
        case .drawing:
            let snappedPoint = snapToWindows(point: point)
            let snappedStart = snapToWindows(point: drawStart)
            selectionRect = normalizedRect(from: snappedStart, to: snappedPoint); needsDisplay = true

        case .moving:
            selectionRect.origin = NSPoint(x: point.x - moveOffset.x, y: point.y - moveOffset.y)
            removeAllPanels(); needsDisplay = true

        case .resizing(let handle):
            let anchor = resizeAnchor
            switch handle {
            case .topLeft, .topRight, .bottomLeft, .bottomRight:
                selectionRect = normalizedRect(from: anchor, to: point)
            case .top, .bottom:
                let nr = normalizedRect(from: anchor, to: NSPoint(x: anchor.x + selectionRect.width, y: point.y))
                selectionRect = NSRect(x: selectionRect.origin.x, y: nr.origin.y, width: selectionRect.width, height: nr.height)
            case .left, .right:
                let nr = normalizedRect(from: anchor, to: NSPoint(x: point.x, y: anchor.y + selectionRect.height))
                selectionRect = NSRect(x: nr.origin.x, y: selectionRect.origin.y, width: nr.width, height: selectionRect.height)
            }
            removeAllPanels(); needsDisplay = true

        case .drawingAnnotation:
            let localPt = screenToLocal(point)
            currentAnnotationElement?.endPoint = localPt
            needsDisplay = true

        case .annotating:
            // Marquee drag for select tool
            if annoState.currentTool == .select, let start = marqueeStart {
                let localPt = screenToLocal(point)
                let x = min(start.x, localPt.x)
                let y = min(start.y, localPt.y)
                let w = abs(localPt.x - start.x)
                let h = abs(localPt.y - start.y)
                if w > 3 || h > 3 {
                    marqueeRect = NSRect(x: x, y: y, width: w, height: h)
                    needsDisplay = true
                }
            }

        case .movingAnnotation:
            if let sel = annoState.selectedElement {
                let localPt = screenToLocal(point)
                let dx = localPt.x - annoDragStart.x
                let dy = localPt.y - annoDragStart.y
                sel.startPoint = NSPoint(x: annoDragElementStart.x + dx, y: annoDragElementStart.y + dy)
                sel.endPoint = NSPoint(x: annoDragElementEnd.x + dx, y: annoDragElementEnd.y + dy)
                needsDisplay = true
            }

        case .resizingAnnotation(let handle):
            if let element = annoResizeElement {
                let localPt = screenToLocal(point)
                element.applyResize(handle: handle, to: localPt)
                needsDisplay = true
            }

        default: break
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch mode {
        case .drawing:
            if hasSelection {
                mode = .selected
                // Auto-enter select tool mode after selection
                enterSelectMode()
                autoCopyIfEnabled()
            } else if let winFrame = windowFrameAt(point: drawStart) {
                // Click without drag: snap selection to the window under cursor
                selectionRect = winFrame
                mode = .selected
                enterSelectMode()
                autoCopyIfEnabled()
            } else {
                mode = .idle; selectionRect = .zero
            }
            hoveredWindowFrame = nil
            needsDisplay = true

        case .moving:
            mode = .selected; showAllPanels(); needsDisplay = true

        case .resizing:
            if hasSelection { mode = .selected; showAllPanels() }
            else { mode = .idle; selectionRect = .zero }
            needsDisplay = true

        case .drawingAnnotation:
            if let element = currentAnnotationElement {
                let dx = abs(element.endPoint.x - element.startPoint.x)
                let dy = abs(element.endPoint.y - element.startPoint.y)
                if dx > 3 || dy > 3 {
                    annoState.elements.append(element)
                    if autoSwitchToSelect {
                        currentAnnotationElement = nil
                        selectElement(element)
                        return
                    }
                }
            }
            currentAnnotationElement = nil
            mode = .annotating
            needsDisplay = true

        case .annotating:
            // Marquee selection finished
            if annoState.currentTool == .select, let rect = marqueeRect, rect.width > 3 || rect.height > 3 {
                // Find all elements whose bounding rect intersects the marquee
                var selectedIds = Set<UUID>()
                for element in annoState.elements {
                    if element.boundingRect.intersects(rect) {
                        selectedIds.insert(element.id)
                    }
                }
                annoState.selectedElementIds = selectedIds
                if selectedIds.count == 1, let onlyId = selectedIds.first,
                   let element = annoState.elements.first(where: { $0.id == onlyId }) {
                    // Single element selected via marquee: treat as single select
                    selectElement(element)
                } else {
                    annoState.selectedElementId = nil
                    refreshSecondaryPanel()
                }
            }
            marqueeStart = nil
            marqueeRect = nil
            needsDisplay = true

        case .movingAnnotation:
            // Pop undo if element wasn't actually moved
            annoState.popUndoIfUnchanged()
            mode = .annotating
            needsDisplay = true

        case .resizingAnnotation:
            // Pop undo if element wasn't actually resized
            annoState.popUndoIfUnchanged()
            annoResizeElement = nil
            annoResizeHandle = nil
            mode = .annotating
            needsDisplay = true

        default: break
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        currentMousePosition = point

        if isPointInPanel(point) {
            if hoveredHandle != nil { hoveredHandle = nil; needsDisplay = true }
            NSCursor.arrow.set(); return
        }

        switch mode {
        case .ocrMode:
            return

        case .selected:
            if let handle = hitTestHandle(at: point) {
                if hoveredHandle != handle { hoveredHandle = handle; needsDisplay = true }
                cursorForHandle(handle).set(); return
            }
            if hitTestAnnotation(at: point) != nil {
                if hoveredHandle != nil { hoveredHandle = nil; needsDisplay = true }
                NSCursor.openHand.set(); return
            }
            if selectionRect.contains(point) {
                if hoveredHandle != nil { hoveredHandle = nil; needsDisplay = true }
                // Show crosshair if a drawing tool is active, openHand for select/move
                if let tool = annoState.currentTool, tool.isDrawingTool {
                    NSCursor.crosshair.set()
                } else {
                    NSCursor.openHand.set()
                }
                return
            }
            if hoveredHandle != nil { hoveredHandle = nil; needsDisplay = true }
            NSCursor.crosshair.set()

        case .annotating:
            if let (_, handle) = hitTestAnnoResizeHandle(at: point) {
                cursorForAnnoHandle(handle).set(); return
            }
            if hitTestAnnotation(at: point) != nil {
                NSCursor.openHand.set(); return
            }
            if selectionRect.contains(point) {
                let isSelectTool = annoState.currentTool == .select
                if isSelectTool {
                    NSCursor.arrow.set()
                } else {
                    NSCursor.crosshair.set()
                }
            } else {
                NSCursor.arrow.set()
            }

        default:
            if hoveredHandle != nil { hoveredHandle = nil; needsDisplay = true }
            NSCursor.crosshair.set()
        }

        if case .idle = mode {
            // Update hovered window frame for highlight
            let newHoveredFrame = windowFrameAt(point: point)
            if hoveredWindowFrame != newHoveredFrame {
                hoveredWindowFrame = newHoveredFrame
            }
            needsDisplay = true
            // Multi-screen follow: if mouse moves to a different screen while idle, notify to re-capture
            let globalMouse = NSEvent.mouseLocation
            if let currentScreen = window?.screen,
               let mouseScreen = NSScreen.screens.first(where: { $0.frame.contains(globalMouse) }),
               mouseScreen != currentScreen {
                onScreenChange?()
            }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        // Right-click is intentionally disabled for cancellation.
        // Use ESC key to cancel instead.
    }

    // MARK: - Scroll Wheel / Pinch (adjust stroke width)
    override func scrollWheel(with event: NSEvent) {
        // Only handle discrete mouse wheel events; ignore trackpad scroll
        guard !event.hasPreciseScrollingDeltas else { return }
        guard mode == .annotating || mode == .selected else { return }
        if mode == .ocrMode { return }
        let delta: CGFloat = event.scrollingDeltaY > 0 ? 0.5 : -0.5
        annoState.adjustStrokeWidth(delta: delta)
        refreshSecondaryPanel()
        needsDisplay = true
    }

    // MARK: - Trackpad pinch → adjust stroke width
    override func magnify(with event: NSEvent) {
        guard mode == .annotating || mode == .selected else { return }
        if mode == .ocrMode { return }
        let delta: CGFloat = event.magnification > 0 ? 0.5 : -0.5
        annoState.adjustStrokeWidth(delta: delta)
        refreshSecondaryPanel()
        needsDisplay = true
    }

    // MARK: - Keyboard Events
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if case .editingText = mode {
            if event.keyCode == 53 {
                cancelTextEditing()
                mode = .annotating; needsDisplay = true
                return
            }
            if event.keyCode == 36 {
                if flags.contains(.shift) {
                    // Shift+Enter: insert newline (NSTextView handles this natively)
                    textEditView?.insertNewline(nil)
                    resizeTextEditor()
                    return
                }
                commitTextEditing()
                mode = .annotating; needsDisplay = true
                return
            }
            return
        }

        // OCR mode
        if mode == .ocrMode {
            if event.keyCode == 53 { // Escape
                exitOCRMode()
                onAction(.cancel)
                return
            }
            if event.keyCode == 8 && flags.contains(.command) { // Cmd+C
                ocrCopySelectedOrAll()
                return
            }
            if event.keyCode == 0 && flags.contains(.command) { // Cmd+A
                ocrOverlayView?.selectAll(nil)
                return
            }
            return
        }

        // Idle mode: 'c' copies color value
        if mode == .idle && flags.isEmpty && event.characters?.lowercased() == "c" {
            if let mousePos = currentMousePosition, let color = pixelColor(atViewPoint: mousePos) {
                let colorString = formatColor(color)
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(colorString, forType: .string)
            }
            onAction(.cancel)
            return
        }

        if event.keyCode == 53 { // Escape
            // Layered ESC behavior:
            // 1. If an element is selected -> deselect and switch to select tool
            // 2. If a drawing tool is active -> switch to select tool
            // 3. Otherwise -> exit/cancel
            if (mode == .annotating || mode == .selected) &&
               (annoState.selectedElementId != nil || !annoState.selectedElementIds.isEmpty) {
                annoState.clearSelection()
                annoState.currentTool = .select
                mode = .annotating
                removeAllPanels(); showAllPanels()
                needsDisplay = true
                return
            }
            if (mode == .annotating || mode == .selected),
               let tool = annoState.currentTool, tool != .select {
                annoState.currentTool = .select
                mode = .annotating
                removeAllPanels(); showAllPanels()
                needsDisplay = true
                return
            }
            if autoCopyEnabled && hasSelection && !hasAutoCopied {
                autoCopyIfEnabled()
            }
            onAction(.cancel)
        } else if event.keyCode == 36 { // Enter
            if mode == .selected || mode == .annotating { performAction(.copy) }
        } else if event.keyCode == 8 && flags.contains(.command) { // Cmd+C
            if mode == .selected || mode == .annotating { performAction(.copy) }
        } else if event.keyCode == 99 { // F3
            if mode == .selected || mode == .annotating { performAction(.pin) }
        } else if event.keyCode == 1 && flags.contains(.command) { // Cmd+S
            if mode == .selected || mode == .annotating { performAction(.save) }
        } else if event.keyCode == 51 { // Delete/Backspace
            if annoState.selectedElementId != nil || !annoState.selectedElementIds.isEmpty {
                annoState.deleteSelected()
                removeAllPanels(); showAllPanels()
                needsDisplay = true
            }
        } else if event.keyCode == 6 && flags.contains(.command) && flags.contains(.shift) { // Cmd+Shift+Z redo
            annoState.redo()
            removeAllPanels(); showAllPanels()
            needsDisplay = true
        } else if event.keyCode == 6 && flags.contains(.command) { // Cmd+Z undo
            annoState.undo()
            removeAllPanels(); showAllPanels()
            needsDisplay = true
        } else if (mode == .selected || mode == .annotating) && flags == .shift {
            // Shift+O: OCR Copy All Text & Done
            if event.characters?.lowercased() == "o" {
                ocrCopyAllAndDone()
                return
            }
            // Shift+Arrow: nudge selection by 10px
            if mode == .selected {
                let nudge: CGFloat = 10
                switch event.keyCode {
                case 123: selectionRect.origin.x -= nudge; refreshPanels()
                case 124: selectionRect.origin.x += nudge; refreshPanels()
                case 125: selectionRect.origin.y -= nudge; refreshPanels()
                case 126: selectionRect.origin.y += nudge; refreshPanels()
                default: break
                }
            }
        } else if (mode == .selected || mode == .annotating) && flags.isEmpty {
            // Tool shortcuts (only when no modifier keys are pressed)
            switch event.characters?.lowercased() {
            case "s": selectTool(.select)
            case "a": selectTool(.arrow)
            case "r": selectTool(.rectangle)
            case "t": selectTool(.text)
            case "c": selectTool(.marker)
            case "m": selectTool(.mosaic)
            case "o": enterOCRMode()
            case "y": enterTranslateMode()
            case "l": performAction(.scrollCapture)
            case "q": performAction(.askAI)
            default:
                if mode == .selected {
                    let nudge: CGFloat = 1
                    switch event.keyCode {
                    case 123: selectionRect.origin.x -= nudge; refreshPanels()
                    case 124: selectionRect.origin.x += nudge; refreshPanels()
                    case 125: selectionRect.origin.y -= nudge; refreshPanels()
                    case 126: selectionRect.origin.y += nudge; refreshPanels()
                    default: break
                    }
                }
            }
        }
    }

    // MARK: - Modifier Key Events (Shift to toggle color format)
    override func flagsChanged(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mode == .idle && flags.contains(.shift) {
            colorFormat = colorFormat.next
            needsDisplay = true
        }
        super.flagsChanged(with: event)
    }

    // MARK: - Text Editing (NSTextView-based for multi-line support)
    //
    // Coordinate convention: element.startPoint stores the TOP-LEFT corner of the text
    // in selection-relative coordinates (non-flipped: higher Y = higher on screen).
    //
    // For NSString.draw(at:): point is bottom-left, so drawY = startPoint.y - textHeight
    // For NSScrollView frame: origin.y is bottom edge, top = origin.y + height
    //   So sv.origin.y = screenTopY - fieldHeight, where screenTopY = startPoint.y + selectionRect.origin.y
    // On commit: startPoint.y = (sv.origin.y + sv.height) - selectionRect.origin.y

    func showTextEditor(for element: AnnotationElement) {
        let fontSize = element.strokeWidth * 4
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)

        let sampleAttrs: [NSAttributedString.Key: Any] = [.font: font]
        let textSize = ("Xg" as NSString).size(withAttributes: sampleAttrs)
        let singleLineHeight = textSize.height

        // For NEW elements, startPoint is the click position = top-left. No adjustment needed.
        // For existing elements (re-edit), startPoint is already the stored top-left.

        // Calculate width from content
        let minWidth: CGFloat = 60
        let contentWidth: CGFloat
        if !element.text.isEmpty {
            let lines = element.text.components(separatedBy: "\n")
            let maxLineWidth = lines.map { ($0 as NSString).size(withAttributes: sampleAttrs).width }.max() ?? 0
            contentWidth = maxLineWidth + 16
        } else {
            contentWidth = minWidth
        }
        let fieldWidth = max(minWidth, contentWidth)

        // Calculate height based on number of lines
        let lineCount = max(1, element.text.components(separatedBy: "\n").count)
        let fieldHeight = singleLineHeight * CGFloat(lineCount) + 4

        // Convert startPoint (top-left, selection-relative) to screen coordinates.
        // In non-flipped view: scrollView.frame.origin.y is bottom edge.
        // Top of scrollView = origin.y + height = startPoint.y + selectionRect.origin.y
        // So origin.y = startPoint.y + selectionRect.origin.y - fieldHeight
        let screenTopY = element.startPoint.y + selectionRect.origin.y
        let svOriginY = screenTopY - fieldHeight
        let svOriginX = element.startPoint.x + selectionRect.origin.x

        // Create NSTextView wrapped in NSScrollView
        let scrollView = NSScrollView(frame: NSRect(x: svOriginX, y: svOriginY, width: fieldWidth, height: fieldHeight))
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: fieldWidth, height: fieldHeight))
        tv.font = font
        tv.textColor = element.color
        tv.backgroundColor = .clear
        tv.drawsBackground = false
        tv.isEditable = true
        tv.isSelectable = true
        tv.isRichText = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isFieldEditor = false
        tv.textContainerInset = NSSize(width: 0, height: 0)
        tv.textContainer?.lineFragmentPadding = 2
        tv.string = element.text
        tv.delegate = self

        scrollView.documentView = tv
        addSubview(scrollView)
        window?.makeFirstResponder(tv)

        textEditView = tv
        textEditScrollView = scrollView
    }

    /// Auto-resize the text editor based on content.
    /// Grows downward from the fixed top edge (non-flipped: top = origin.y + height stays constant).
    func resizeTextEditor() {
        guard let tv = textEditView, let sv = textEditScrollView else { return }
        let font = tv.font ?? NSFont.systemFont(ofSize: 14)
        let sampleAttrs: [NSAttributedString.Key: Any] = [.font: font]
        let singleLineHeight = ("Xg" as NSString).size(withAttributes: sampleAttrs).height

        let text = tv.string.isEmpty ? "W" : tv.string
        let lines = text.components(separatedBy: "\n")
        let maxLineWidth = lines.map { ($0 as NSString).size(withAttributes: sampleAttrs).width }.max() ?? 0
        let lineCount = max(1, lines.count)

        let minWidth: CGFloat = 60
        let newWidth = max(minWidth, maxLineWidth + 16)
        let newHeight = singleLineHeight * CGFloat(lineCount) + 4

        // Keep top edge fixed: top = origin.y + height
        let currentTop = sv.frame.origin.y + sv.frame.height
        var frame = sv.frame
        frame.size.width = newWidth
        frame.size.height = newHeight
        frame.origin.y = currentTop - newHeight  // grow downward from fixed top
        sv.frame = frame

        tv.frame = NSRect(x: 0, y: 0, width: newWidth, height: newHeight)
    }

    func commitTextEditing() {
        if let tv = textEditView, let sv = textEditScrollView, let sel = annoState.selectedElement, sel.tool == .text {
            let oldText = sel.text
            let newText = tv.string
            if oldText != newText {
                annoState.pushUndoForPropertyChange(kind: .text)
            }
            sel.text = newText
            if sel.text.isEmpty {
                annoState.elements.removeAll { $0.id == sel.id }
                annoState.selectedElementId = nil
            } else {
                // Recover top-left from scrollView frame.
                // Top of scrollView in screen coords = sv.frame.origin.y + sv.frame.height
                // startPoint (selection-relative) = screen - selectionRect.origin
                sel.startPoint.x = sv.frame.origin.x - selectionRect.origin.x
                sel.startPoint.y = (sv.frame.origin.y + sv.frame.height) - selectionRect.origin.y
            }
        }
        textEditScrollView?.removeFromSuperview()
        textEditScrollView = nil
        textEditView = nil
        textField = nil
        window?.makeFirstResponder(self)
    }

    func cancelTextEditing() {
        if let sel = annoState.selectedElement, sel.tool == .text, sel.text.isEmpty {
            annoState.elements.removeAll { $0.id == sel.id }
            annoState.selectedElementId = nil
        }
        textEditScrollView?.removeFromSuperview()
        textEditScrollView = nil
        textEditView = nil
        textField = nil
        window?.makeFirstResponder(self)
    }
}

// MARK: - NSTextViewDelegate for text annotation editing
extension OverlayView: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        resizeTextEditor()
    }
}
