import Cocoa

// MARK: - Annotation Tool Type
enum AnnotationTool: String, CaseIterable {
    case arrow
    case rectangle
    case text
    case marker
    case mosaic

    var symbolName: String {
        switch self {
        case .arrow:     return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .text:      return "textformat"
        case .marker:    return "1.circle"
        case .mosaic:    return "mosaic"
        }
    }

    var displayName: String {
        switch self {
        case .arrow:     return "Arrow  A"
        case .rectangle: return "Rectangle  R"
        case .text:      return "Text  T"
        case .marker:    return "Marker  C"
        case .mosaic:    return "Mosaic  M"
        }
    }
}

// MARK: - Annotation Resize Handle
enum AnnoResizeHandle: Equatable {
    case topLeft, topRight, bottomLeft, bottomRight
    // For arrow: start/end point
    case startPoint, endPoint
}

// MARK: - Annotation Element
class AnnotationElement {
    var id: UUID = UUID()
    var tool: AnnotationTool
    var color: NSColor
    var strokeWidth: CGFloat
    var startPoint: NSPoint
    var endPoint: NSPoint
    var text: String = ""
    var markerNumber: Int = 0

    init(tool: AnnotationTool, color: NSColor, strokeWidth: CGFloat, startPoint: NSPoint, endPoint: NSPoint) {
        self.tool = tool
        self.color = color
        self.strokeWidth = strokeWidth
        self.startPoint = startPoint
        self.endPoint = endPoint
    }

    func copy() -> AnnotationElement {
        let c = AnnotationElement(tool: tool, color: color, strokeWidth: strokeWidth, startPoint: startPoint, endPoint: endPoint)
        c.id = id
        c.text = text
        c.markerNumber = markerNumber
        return c
    }

    // Bounding rect in selection-local coordinates
    var boundingRect: NSRect {
        switch tool {
        case .arrow:
            let padding = max(strokeWidth * 2, 10)
            let minX = min(startPoint.x, endPoint.x) - padding
            let minY = min(startPoint.y, endPoint.y) - padding
            let maxX = max(startPoint.x, endPoint.x) + padding
            let maxY = max(startPoint.y, endPoint.y) + padding
            return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        case .rectangle, .mosaic:
            let r = normalizedRect
            return r.insetBy(dx: -max(strokeWidth, 4), dy: -max(strokeWidth, 4))
        case .text:
            return textBoundingRect
        case .marker:
            let radius = max(strokeWidth * 1.5, 6)
            return NSRect(x: startPoint.x - radius, y: startPoint.y - radius, width: radius * 2, height: radius * 2)
        }
    }

    var normalizedRect: NSRect {
        let x = min(startPoint.x, endPoint.x)
        let y = min(startPoint.y, endPoint.y)
        let w = abs(endPoint.x - startPoint.x)
        let h = abs(endPoint.y - startPoint.y)
        return NSRect(x: x, y: y, width: w, height: h)
    }

    private var textBoundingRect: NSRect {
        guard !text.isEmpty else { return .zero }
        let font = NSFont.systemFont(ofSize: strokeWidth * 4, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attrs)
        return NSRect(x: startPoint.x - 4, y: startPoint.y - 2, width: size.width + 8, height: size.height + 4)
    }

    func hitTest(point: NSPoint) -> Bool {
        switch tool {
        case .arrow:
            return distanceToLine(point: point, from: startPoint, to: endPoint) < max(strokeWidth * 2, 8)
        case .rectangle:
            let r = normalizedRect
            let outer = r.insetBy(dx: -max(strokeWidth, 4), dy: -max(strokeWidth, 4))
            let inner = r.insetBy(dx: max(strokeWidth, 4), dy: max(strokeWidth, 4))
            return outer.contains(point) && (inner.width <= 0 || inner.height <= 0 || !inner.contains(point))
        case .text:
            return textBoundingRect.contains(point)
        case .marker:
            let radius = max(strokeWidth * 1.5, 6)
            let dx = point.x - startPoint.x
            let dy = point.y - startPoint.y
            return (dx * dx + dy * dy) <= (radius * radius)
        case .mosaic:
            return normalizedRect.contains(point)
        }
    }

    // Resize handle hit test - returns which handle was hit
    func hitTestResizeHandle(point: NSPoint) -> AnnoResizeHandle? {
        let hs: CGFloat = 8  // handle hit radius

        switch tool {
        case .arrow:
            // Arrow has start and end point handles
            if distance(point, startPoint) < hs { return .startPoint }
            if distance(point, endPoint) < hs { return .endPoint }
            return nil

        case .rectangle, .mosaic:
            let r = normalizedRect
            let corners: [(AnnoResizeHandle, NSPoint)] = [
                (.topLeft,     NSPoint(x: r.minX, y: r.maxY)),
                (.topRight,    NSPoint(x: r.maxX, y: r.maxY)),
                (.bottomLeft,  NSPoint(x: r.minX, y: r.minY)),
                (.bottomRight, NSPoint(x: r.maxX, y: r.minY)),
            ]
            for (handle, pt) in corners {
                if distance(point, pt) < hs { return handle }
            }
            return nil

        case .text, .marker:
            // Text and marker don't have resize handles
            return nil
        }
    }

    // Apply resize from a handle drag
    func applyResize(handle: AnnoResizeHandle, to point: NSPoint) {
        switch handle {
        case .startPoint:
            startPoint = point
        case .endPoint:
            endPoint = point
        case .topLeft:
            let r = normalizedRect
            // Determine which of start/end is which corner
            startPoint = NSPoint(x: point.x, y: point.y)
            endPoint = NSPoint(x: r.maxX, y: r.minY)
        case .topRight:
            let r = normalizedRect
            startPoint = NSPoint(x: r.minX, y: r.minY)
            endPoint = NSPoint(x: point.x, y: point.y)
        case .bottomLeft:
            let r = normalizedRect
            startPoint = NSPoint(x: point.x, y: point.y)
            endPoint = NSPoint(x: r.maxX, y: r.maxY)
        case .bottomRight:
            let r = normalizedRect
            startPoint = NSPoint(x: r.minX, y: r.maxY)
            endPoint = NSPoint(x: point.x, y: point.y)
        }
    }

    func move(dx: CGFloat, dy: CGFloat) {
        startPoint.x += dx
        startPoint.y += dy
        endPoint.x += dx
        endPoint.y += dy
    }

    private func distance(_ a: NSPoint, _ b: NSPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return sqrt(dx * dx + dy * dy)
    }

    private func distanceToLine(point: NSPoint, from: NSPoint, to: NSPoint) -> CGFloat {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let lenSq = dx * dx + dy * dy
        if lenSq < 0.001 {
            let px = point.x - from.x
            let py = point.y - from.y
            return sqrt(px * px + py * py)
        }
        var t = ((point.x - from.x) * dx + (point.y - from.y) * dy) / lenSq
        t = max(0, min(1, t))
        let projX = from.x + t * dx
        let projY = from.y + t * dy
        let px = point.x - projX
        let py = point.y - projY
        return sqrt(px * px + py * py)
    }
}

// MARK: - Annotation State
class AnnotationState {
    private static let colorKey = "annoColor"
    private static let strokeKey = "annoStrokeWidths"

    private static let colorNameMap: [String: NSColor] = [
        "systemRed": .systemRed, "systemOrange": .systemOrange,
        "systemYellow": .systemYellow, "systemGreen": .systemGreen,
        "systemBlue": .systemBlue, "systemPurple": .systemPurple,
        "white": .white, "black": .black
    ]
    private static let nameColorMap: [NSColor: String] = [
        .systemRed: "systemRed", .systemOrange: "systemOrange",
        .systemYellow: "systemYellow", .systemGreen: "systemGreen",
        .systemBlue: "systemBlue", .systemPurple: "systemPurple",
        .white: "white", .black: "black"
    ]

    var currentTool: AnnotationTool? = nil

    var currentColor: NSColor = .systemRed {
        didSet {
            let ud = UserDefaults.standard
            ud.set(Self.nameColorMap[currentColor] ?? "systemRed", forKey: Self.colorKey)
        }
    }

    var strokeWidths: [AnnotationTool: CGFloat] = [
        .arrow: 3,
        .rectangle: 2,
        .text: 4,
        .marker: 8,
        .mosaic: 20
    ] {
        didSet {
            var dict: [String: Double] = [:]
            for (tool, width) in strokeWidths {
                dict[tool.rawValue] = Double(width)
            }
            UserDefaults.standard.set(dict, forKey: Self.strokeKey)
        }
    }

    var elements: [AnnotationElement] = []
    var selectedElementId: UUID? = nil
    var nextMarkerNumber: Int = 1

    init() {
        // Load stroke widths FIRST (before color, since color didSet won't touch strokes)
        let ud = UserDefaults.standard
        if let dict = ud.dictionary(forKey: Self.strokeKey) as? [String: Double] {
            for (key, val) in dict {
                if let tool = AnnotationTool(rawValue: key) {
                    strokeWidths[tool] = CGFloat(val)
                }
            }
        }
        // Load color (didSet will fire but only saves color key, won't overwrite strokes)
        if let colorName = ud.string(forKey: Self.colorKey),
           let color = Self.colorNameMap[colorName] {
            currentColor = color
        }
    }

    var undoStack: [[AnnotationElement]] = []

    func pushUndo() {
        undoStack.append(elements.map { $0.copy() })
        if undoStack.count > 50 { undoStack.removeFirst() }
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        elements = previous
        selectedElementId = nil
        let maxMarker = elements.filter { $0.tool == .marker }.map { $0.markerNumber }.max() ?? 0
        nextMarkerNumber = maxMarker + 1
    }

    var currentStrokeWidth: CGFloat {
        get { strokeWidths[currentTool ?? .arrow] ?? 3 }
        set {
            if let tool = currentTool {
                strokeWidths[tool] = newValue
            }
        }
    }

    func adjustStrokeWidth(delta: CGFloat) {
        guard let tool = currentTool ?? selectedElement?.tool else { return }
        let current = strokeWidths[tool] ?? 3
        let newVal = max(1, min(20, current + delta))
        strokeWidths[tool] = newVal
        if let sel = selectedElement, sel.tool == tool {
            sel.strokeWidth = newVal
        }
    }

    func incrementStrokeWidth() {
        adjustStrokeWidth(delta: 1)
    }

    func decrementStrokeWidth() {
        adjustStrokeWidth(delta: -1)
    }

    var selectedElement: AnnotationElement? {
        guard let id = selectedElementId else { return nil }
        return elements.first { $0.id == id }
    }

    func deleteSelected() {
        guard let id = selectedElementId else { return }
        pushUndo()
        elements.removeAll { $0.id == id }
        selectedElementId = nil
    }

    static let availableColors: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen,
        .systemBlue, .systemPurple, .white, .black
    ]
}

// MARK: - Annotation Renderer
class AnnotationRenderer {

    static func draw(element: AnnotationElement, in context: NSGraphicsContext, selectionOrigin: NSPoint, isSelected: Bool, screenshot: NSImage? = nil, selectionRect: NSRect? = nil) {
        let ox = selectionOrigin.x
        let oy = selectionOrigin.y

        switch element.tool {
        case .arrow:
            drawArrow(element: element, ctx: context.cgContext, ox: ox, oy: oy)
        case .rectangle:
            drawRectangle(element: element, ctx: context.cgContext, ox: ox, oy: oy)
        case .text:
            drawText(element: element, ox: ox, oy: oy)
        case .marker:
            drawMarker(element: element, ctx: context.cgContext, ox: ox, oy: oy)
        case .mosaic:
            if let screenshot = screenshot, let selRect = selectionRect {
                drawMosaic(element: element, ctx: context.cgContext, ox: ox, oy: oy, screenshot: screenshot, selectionRect: selRect)
            }
        }

        if isSelected {
            drawSelectionIndicator(for: element, ctx: context.cgContext, ox: ox, oy: oy)
        }
    }

    private static func drawArrow(element: AnnotationElement, ctx: CGContext, ox: CGFloat, oy: CGFloat) {
        let from = NSPoint(x: element.startPoint.x + ox, y: element.startPoint.y + oy)
        let to = NSPoint(x: element.endPoint.x + ox, y: element.endPoint.y + oy)

        let angle = atan2(to.y - from.y, to.x - from.x)
        let sw = element.strokeWidth

        // Arrow dimensions
        let headLength = max(sw * 3.5, 12)
        let headWidth = max(sw * 2.5, 8)
        let shaftWidth = sw

        // Calculate the point where the shaft meets the head
        let shaftEnd = NSPoint(
            x: to.x - headLength * cos(angle),
            y: to.y - headLength * sin(angle)
        )

        // Perpendicular direction
        let perpX = -sin(angle)
        let perpY = cos(angle)

        // Shaft corners
        let s1 = NSPoint(x: from.x + perpX * shaftWidth / 2, y: from.y + perpY * shaftWidth / 2)
        let s2 = NSPoint(x: from.x - perpX * shaftWidth / 2, y: from.y - perpY * shaftWidth / 2)
        let s3 = NSPoint(x: shaftEnd.x - perpX * shaftWidth / 2, y: shaftEnd.y - perpY * shaftWidth / 2)
        let s4 = NSPoint(x: shaftEnd.x + perpX * shaftWidth / 2, y: shaftEnd.y + perpY * shaftWidth / 2)

        // Arrowhead wings
        let h1 = NSPoint(x: shaftEnd.x + perpX * headWidth / 2, y: shaftEnd.y + perpY * headWidth / 2)
        let h2 = NSPoint(x: shaftEnd.x - perpX * headWidth / 2, y: shaftEnd.y - perpY * headWidth / 2)

        // Build the full arrow shape as a single path
        let path = NSBezierPath()
        // Start at shaft top-left, go along shaft
        path.move(to: s1)
        path.line(to: s4)
        // Wing out to arrowhead
        path.line(to: h1)
        // Tip
        path.line(to: to)
        // Other wing
        path.line(to: h2)
        // Back along shaft
        path.line(to: s3)
        path.line(to: s2)
        path.close()

        element.color.setFill()
        path.fill()
    }

    private static func drawRectangle(element: AnnotationElement, ctx: CGContext, ox: CGFloat, oy: CGFloat) {
        let r = element.normalizedRect
        let rect = NSRect(x: r.origin.x + ox, y: r.origin.y + oy, width: r.width, height: r.height)

        let path = NSBezierPath(rect: rect)
        path.lineWidth = element.strokeWidth
        element.color.setStroke()
        path.stroke()
    }

    private static func drawText(element: AnnotationElement, ox: CGFloat, oy: CGFloat) {
        let font = NSFont.systemFont(ofSize: element.strokeWidth * 4, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: element.color
        ]
        // Don't render empty text elements
        guard !element.text.isEmpty else { return }
        let point = NSPoint(x: element.startPoint.x + ox, y: element.startPoint.y + oy)
        (element.text as NSString).draw(at: point, withAttributes: attrs)
    }

    private static func drawMarker(element: AnnotationElement, ctx: CGContext, ox: CGFloat, oy: CGFloat) {
        let center = NSPoint(x: element.startPoint.x + ox, y: element.startPoint.y + oy)
        let radius = max(element.strokeWidth * 1.5, 6)

        let circleRect = NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        let circlePath = NSBezierPath(ovalIn: circleRect)
        element.color.setFill()
        circlePath.fill()

        let numStr = "\(element.markerNumber)" as NSString
        let fontSize = radius * 1.2
        let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)

        let textColor: NSColor = .white

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]
        let textSize = numStr.size(withAttributes: attrs)
        let textPoint = NSPoint(
            x: center.x - textSize.width / 2,
            y: center.y - textSize.height / 2
        )
        numStr.draw(at: textPoint, withAttributes: attrs)
    }

    private static func drawMosaic(element: AnnotationElement, ctx: CGContext, ox: CGFloat, oy: CGFloat, screenshot: NSImage, selectionRect: NSRect) {
        let r = element.normalizedRect
        let screenRect = NSRect(x: r.origin.x + ox, y: r.origin.y + oy, width: r.width, height: r.height)

        guard screenRect.width > 1 && screenRect.height > 1 else { return }

        guard let cgImage = screenshot.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        // Use actual CGImage pixel dimensions for scale, not NSBitmapImageRep.pixelsWide
        let scaleX = CGFloat(cgImage.width) / screenshot.size.width
        let scaleY = CGFloat(cgImage.height) / screenshot.size.height

        let imgRect = CGRect(
            x: screenRect.origin.x * scaleX,
            y: (screenshot.size.height - screenRect.origin.y - screenRect.height) * scaleY,
            width: screenRect.width * scaleX,
            height: screenRect.height * scaleY
        )

        guard let regionCG = cgImage.cropping(to: imgRect) else { return }

        let blockSize = max(Int(element.strokeWidth), 5)
        let regionImage = NSImage(cgImage: regionCG, size: NSSize(width: screenRect.width, height: screenRect.height))

        guard let tiffData = regionImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return }

        let smallW = max(1, Int(bitmap.pixelsWide) / blockSize)
        let smallH = max(1, Int(bitmap.pixelsHigh) / blockSize)

        let smallImage = NSImage(size: NSSize(width: smallW, height: smallH))
        smallImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none
        regionImage.draw(in: NSRect(x: 0, y: 0, width: smallW, height: smallH))
        smallImage.unlockFocus()

        ctx.saveGState()
        ctx.interpolationQuality = .none
        smallImage.draw(in: screenRect, from: NSRect(origin: .zero, size: smallImage.size), operation: .sourceOver, fraction: 1.0)
        ctx.restoreGState()
    }

    private static func drawSelectionIndicator(for element: AnnotationElement, ctx: CGContext, ox: CGFloat, oy: CGFloat) {
        let r = element.boundingRect
        let screenRect = NSRect(x: r.origin.x + ox, y: r.origin.y + oy, width: r.width, height: r.height)

        let path = NSBezierPath(rect: screenRect)
        path.lineWidth = 1
        NSColor.systemBlue.withAlphaComponent(0.6).setStroke()
        path.setLineDash([3, 3], count: 2, phase: 0)
        path.stroke()

        // Draw resize handles based on tool type
        let hs: CGFloat = 5

        switch element.tool {
        case .arrow:
            // Show handles at start and end points
            let pts = [
                NSPoint(x: element.startPoint.x + ox, y: element.startPoint.y + oy),
                NSPoint(x: element.endPoint.x + ox, y: element.endPoint.y + oy),
            ]
            for pt in pts {
                let handleRect = NSRect(x: pt.x - hs/2, y: pt.y - hs/2, width: hs, height: hs)
                NSColor.systemBlue.setFill()
                NSBezierPath(ovalIn: handleRect).fill()
                NSColor.white.setStroke()
                let ring = NSBezierPath(ovalIn: handleRect)
                ring.lineWidth = 0.5
                ring.stroke()
            }

        case .rectangle, .mosaic:
            // Show handles at four corners of the normalized rect
            let nr = element.normalizedRect
            let corners = [
                NSPoint(x: nr.minX + ox, y: nr.minY + oy),
                NSPoint(x: nr.maxX + ox, y: nr.minY + oy),
                NSPoint(x: nr.minX + ox, y: nr.maxY + oy),
                NSPoint(x: nr.maxX + ox, y: nr.maxY + oy),
            ]
            for pt in corners {
                let handleRect = NSRect(x: pt.x - hs/2, y: pt.y - hs/2, width: hs, height: hs)
                NSColor.systemBlue.setFill()
                NSBezierPath(roundedRect: handleRect, xRadius: 1, yRadius: 1).fill()
                NSColor.white.setStroke()
                let ring = NSBezierPath(roundedRect: handleRect, xRadius: 1, yRadius: 1)
                ring.lineWidth = 0.5
                ring.stroke()
            }

        case .text, .marker:
            // No resize handles for text and marker
            break
        }
    }

    // MARK: - Render annotations onto an image for export
    static func renderAnnotationsOntoImage(baseImage: NSImage, annotations: [AnnotationElement], selectionRect: NSRect, screenshot: NSImage) -> NSImage {
        let size = baseImage.size
        let result = NSImage(size: size)
        result.lockFocus()

        baseImage.draw(in: NSRect(origin: .zero, size: size))

        if let context = NSGraphicsContext.current {
            for element in annotations {
                draw(element: element, in: context, selectionOrigin: .zero, isSelected: false, screenshot: screenshot, selectionRect: selectionRect)
            }
        }

        result.unlockFocus()
        return result
    }
}
