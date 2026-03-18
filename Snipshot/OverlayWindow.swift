import Cocoa
import UniformTypeIdentifiers
import VisionKit

// MARK: - Overlay Actions
enum OverlayAction {
    case copy(NSImage, NSRect)
    case save(NSImage, NSRect)
    case pin(NSImage, NSRect)
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
    var textField: NSTextField?

    // Annotation state
    var annoState = AnnotationState()
    var annotationDrawStart: NSPoint = .zero
    var currentAnnotationElement: AnnotationElement? = nil
    var toolButtons: [AnnotationTool: HoverIconButton] = [:]
    var colorDots: [NSColor: ColorDot] = [:]

    // Annotation dragging
    var annoDragStart: NSPoint = .zero
    var annoDragElementStart: NSPoint = .zero
    var annoDragElementEnd: NSPoint = .zero

    // Annotation resizing
    var annoResizeElement: AnnotationElement? = nil
    var annoResizeHandle: AnnoResizeHandle? = nil

    let handleSize: CGFloat = 8
    let handleHitSize: CGFloat = 14

    // OCR state
    var ocrOverlayView: ImageAnalysisOverlayView?
    var ocrImageView: NSImageView?
    var ocrPanelView: NSView?
    let imageAnalyzer = ImageAnalyzer()

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

        let viewHeight = bounds.height
        let scale = screenshot.representations.first.map {
            CGFloat($0.pixelsWide) / screenshot.size.width
        } ?? 2.0

        let imageRect = NSRect(
            x: selectionRect.origin.x * scale,
            y: (viewHeight - selectionRect.origin.y - selectionRect.height) * scale,
            width: selectionRect.width * scale,
            height: selectionRect.height * scale
        )

        guard let cgImage = screenshot.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let croppedCG = cgImage.cropping(to: imageRect) else { return nil }

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
        annoState.selectedElementId = nil
        mode = .annotating
        removeAllPanels()
        showAllPanels()
        needsDisplay = true
    }

    func switchToElementTool(_ element: AnnotationElement) {
        annoState.currentTool = element.tool
        annoState.currentColor = element.color
        annoState.strokeWidths[element.tool] = element.strokeWidth
        mode = .annotating
        removeAllPanels()
        showAllPanels()
        needsDisplay = true
    }

    func selectColor(_ color: NSColor) {
        annoState.currentColor = color
        if let sel = annoState.selectedElement {
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

    // MARK: - Actions
    enum ActionType { case copy, save, pin, cancel }

    func performAction(_ type: ActionType) {
        if type == .cancel {
            onAction(.cancel)
            return
        }
        guard let image = cropImage() else { return }
        let rect = selectionRect
        switch type {
        case .copy:  onAction(.copy(image, rect))
        case .save:  onAction(.save(image, rect))
        case .pin:   onAction(.pin(image, rect))
        case .cancel: break
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

        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }

        // First pass: collect all valid window rects in Z-order (front to back)
        var allFrames: [NSRect] = []
        for info in windowList {
            // Skip our own overlay window
            if let ownerPID = info[kCGWindowOwnerPID as String] as? Int32,
               ownerPID == ProcessInfo.processInfo.processIdentifier { continue }

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

        // Second pass: only keep windows whose 4 corners are all visible
        // (not occluded by any higher Z-order window)
        var snappableFrames: [NSRect] = []
        for (i, frame) in allFrames.enumerated() {
            let corners = [
                NSPoint(x: frame.minX + 1, y: frame.minY + 1),
                NSPoint(x: frame.maxX - 1, y: frame.minY + 1),
                NSPoint(x: frame.minX + 1, y: frame.maxY - 1),
                NSPoint(x: frame.maxX - 1, y: frame.maxY - 1),
            ]
            var allCornersVisible = true
            for corner in corners {
                for j in 0..<i {
                    if allFrames[j].contains(corner) {
                        allCornersVisible = false
                        break
                    }
                }
                if !allCornersVisible { break }
            }
            if allCornersVisible {
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

                for element in annoState.elements {
                    // Skip drawing text element while it's being edited (textField is visible)
                    if element.tool == .text && element.id == annoState.selectedElementId && textField != nil {
                        continue
                    }
                    let isSelected = element.id == annoState.selectedElementId
                    AnnotationRenderer.draw(
                        element: element,
                        in: context,
                        selectionOrigin: selectionRect.origin,
                        isSelected: isSelected,
                        screenshot: screenshot,
                        selectionRect: selectionRect
                    )
                }

                if let current = currentAnnotationElement {
                    AnnotationRenderer.draw(
                        element: current,
                        in: context,
                        selectionOrigin: selectionRect.origin,
                        isSelected: false,
                        screenshot: screenshot,
                        selectionRect: selectionRect
                    )
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
        }

        if case .idle = mode, let mousePos = currentMousePosition {
            // Draw window highlight under cursor
            if let winFrame = hoveredWindowFrame {
                drawWindowHighlight(winFrame)
            }
            drawCrosshair(at: mousePos)
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

            if let (element, handle) = hitTestAnnoResizeHandle(at: point) {
                annoState.pushUndo()
                annoResizeElement = element
                annoResizeHandle = handle
                mode = .resizingAnnotation(handle)
                return
            }

            if let element = hitTestAnnotation(at: point) {
                annoState.selectedElementId = element.id
                switchToElementTool(element)
                annoDragStart = localPt
                annoDragElementStart = element.startPoint
                annoDragElementEnd = element.endPoint
                mode = .movingAnnotation
                return
            }

            annoState.selectedElementId = nil

            if let tool = annoState.currentTool {
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
                annoState.selectedElementId = element.id
                switchToElementTool(element)
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
                mode = .selected; showAllPanels()
            } else if let winFrame = windowFrameAt(point: drawStart) {
                // Click without drag: snap selection to the window under cursor
                selectionRect = winFrame
                mode = .selected; showAllPanels()
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
                }
            }
            currentAnnotationElement = nil
            mode = .annotating
            needsDisplay = true

        case .movingAnnotation:
            mode = annoState.currentTool != nil ? .annotating : .selected
            needsDisplay = true

        case .resizingAnnotation:
            annoResizeElement = nil
            annoResizeHandle = nil
            mode = annoState.currentTool != nil ? .annotating : .selected
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
                NSCursor.openHand.set(); return
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
                NSCursor.crosshair.set()
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
        if mode == .ocrMode { exitOCRMode() }
        onAction(.cancel)
    }

    // MARK: - Scroll Wheel (adjust stroke width)
    override func scrollWheel(with event: NSEvent) {
        guard mode == .annotating || mode == .selected else { return }
        if mode == .ocrMode { return }
        let delta: CGFloat = event.scrollingDeltaY > 0 ? 0.5 : -0.5
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

        if event.keyCode == 53 { // Escape
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
            if annoState.selectedElementId != nil {
                annoState.deleteSelected()
                removeAllPanels(); showAllPanels()
                needsDisplay = true
            }
        } else if event.keyCode == 6 && flags.contains(.command) { // Cmd+Z undo
            annoState.undo()
            removeAllPanels(); showAllPanels()
            needsDisplay = true
        } else if (mode == .selected || mode == .annotating) && flags.isEmpty {
            // Tool shortcuts (only when no modifier keys are pressed)
            switch event.characters?.lowercased() {
            case "a": selectTool(.arrow)
            case "r": selectTool(.rectangle)
            case "t": selectTool(.text)
            case "c": selectTool(.marker)
            case "m": selectTool(.mosaic)
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
        } else if mode == .selected && flags.contains(.shift) {
            let nudge: CGFloat = 10
            switch event.keyCode {
            case 123: selectionRect.origin.x -= nudge; refreshPanels()
            case 124: selectionRect.origin.x += nudge; refreshPanels()
            case 125: selectionRect.origin.y -= nudge; refreshPanels()
            case 126: selectionRect.origin.y += nudge; refreshPanels()
            default: break
            }
        }
    }

    // MARK: - Text Editing
    func showTextEditor(for element: AnnotationElement) {
        let fontSize = element.strokeWidth * 4
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)

        // Calculate the actual text size to determine field height precisely
        let sampleAttrs: [NSAttributedString.Key: Any] = [.font: font]
        let textSize = ("Xg" as NSString).size(withAttributes: sampleAttrs)
        let fieldHeight = textSize.height + 4  // minimal padding

        // Click position = visual top-left corner of text (Figma style).
        // In macOS standard coordinates (y-up), visual top-left has the HIGHEST y value.
        // NSString.draw(at:) in non-flipped view: point is the left-bottom of text bounding box.
        // So element.startPoint (used by drawText) should be at clickY - textHeight.
        let textHeight = textSize.height
        let textInsetY: CGFloat = -font.descender + 1  // offset from NSTextField frame bottom to text draw point

        // Store the draw position for drawText (left-bottom of text)
        let clickY = element.startPoint.y  // visual top-left y in view coords
        element.startPoint.y = clickY - textHeight  // left-bottom for NSString.draw(at:)

        // NSTextField frame.origin.y is its bottom edge.
        // The text inside NSTextField renders at frame.origin.y + textInsetY.
        // We want that to equal element.startPoint.y, so:
        let fieldY = element.startPoint.y - textInsetY

        // Field position
        let screenPt = NSPoint(
            x: element.startPoint.x + selectionRect.origin.x,
            y: fieldY + selectionRect.origin.y
        )

        // Start with a minimal width; will grow as user types
        let minWidth: CGFloat = 40
        let tf = NSTextField(frame: NSRect(x: screenPt.x, y: screenPt.y, width: minWidth, height: fieldHeight))
        tf.font = font
        tf.textColor = element.color
        tf.backgroundColor = .clear
        tf.drawsBackground = false
        tf.isBordered = false
        tf.focusRingType = .none
        tf.isEditable = true
        tf.isSelectable = true
        tf.placeholderString = ""
        tf.stringValue = element.text
        tf.target = self
        tf.action = #selector(textFieldAction(_:))
        tf.cell?.wraps = false
        tf.cell?.isScrollable = true

        addSubview(tf)
        tf.becomeFirstResponder()
        textField = tf

        // Observe text changes to auto-resize width
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textFieldDidChange(_:)),
            name: NSControl.textDidChangeNotification,
            object: tf
        )
    }

    @objc func textFieldDidChange(_ notification: Notification) {
        guard let tf = textField else { return }
        let font = tf.font ?? NSFont.systemFont(ofSize: 14)
        let text = tf.stringValue.isEmpty ? "W" : tf.stringValue
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let textWidth = (text as NSString).size(withAttributes: attrs).width
        let minWidth: CGFloat = 40
        let newWidth = max(minWidth, textWidth + 20) // padding for cursor
        var frame = tf.frame
        frame.size.width = newWidth
        tf.frame = frame
    }

    @objc func textFieldAction(_ sender: NSTextField) {
        commitTextEditing()
        mode = .annotating
        needsDisplay = true
    }

    func commitTextEditing() {
        if let tf = textField {
            NotificationCenter.default.removeObserver(self, name: NSControl.textDidChangeNotification, object: tf)
        }
        if let tf = textField, let sel = annoState.selectedElement, sel.tool == .text {
            sel.text = tf.stringValue
            if sel.text.isEmpty {
                annoState.elements.removeAll { $0.id == sel.id }
                annoState.selectedElementId = nil
            }
        }
        textField?.removeFromSuperview()
        textField = nil
        window?.makeFirstResponder(self)
    }

    func cancelTextEditing() {
        if let tf = textField {
            NotificationCenter.default.removeObserver(self, name: NSControl.textDidChangeNotification, object: tf)
        }
        if let sel = annoState.selectedElement, sel.tool == .text {
            annoState.elements.removeAll { $0.id == sel.id }
            annoState.selectedElementId = nil
        }
        textField?.removeFromSuperview()
        textField = nil
        window?.makeFirstResponder(self)
    }
}
