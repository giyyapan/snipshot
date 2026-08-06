import Cocoa

// MARK: - Annotation Tool Type
enum AnnotationTool: String, CaseIterable {
    case select
    case arrow
    case line
    case rectangle
    case circle
    case text
    case marker
    case mosaic
    case highlight

    /// Top-level toolbar slots. Related tools share one slot and are selected
    /// from its separate menu trigger or by repeatedly pressing its shortcut.
    static let toolbarGroups: [[AnnotationTool]] = [
        [.select],
        [.arrow, .line],
        [.rectangle, .circle],
        [.text],
        [.marker],
        [.mosaic],
        [.highlight]
    ]

    static func cycledTool(in group: [AnnotationTool], current: AnnotationTool?) -> AnnotationTool {
        guard !group.isEmpty else { return .select }
        guard let current, let index = group.firstIndex(of: current) else { return group[0] }
        return group[(index + 1) % group.count]
    }

    var symbolName: String {
        switch self {
        case .select:    return "cursorarrow"
        case .arrow:     return "arrow.up.right"
        case .line:      return "line.diagonal"
        case .rectangle: return "rectangle"
        case .circle:    return "circle"
        case .text:      return "textformat"
        case .marker:    return "1.circle"
        case .mosaic:    return "mosaic"
        case .highlight: return "viewfinder"
        }
    }

    var displayName: String {
        switch self {
        case .select:    return "Select  S"
        case .arrow:     return "Arrow  A"
        case .line:      return "Line  A"
        case .rectangle: return "Rectangle  R"
        case .circle:    return "Circle  R"
        case .text:      return "Text  T"
        case .marker:    return "Marker  C"
        case .mosaic:    return "Mosaic  M"
        case .highlight: return "Highlight  H"
        }
    }

    /// Whether this tool is a drawing tool (not select)
    var isDrawingTool: Bool {
        return self != .select
    }

    var showsColorControls: Bool {
        return self != .select && self != .mosaic && self != .highlight
    }

    var usesStrokeWidth: Bool {
        return self != .select && self != .highlight
    }

    var supportsShapeFill: Bool {
        return self == .rectangle || self == .circle
    }
}

// MARK: - Annotation Glow
struct AnnotationGlowStyle: Equatable {
    let opacity: CGFloat
    let blurRadius: CGFloat

    /// Quartz shadows taper beyond their nominal blur radius. Reserving twice
    /// the radius keeps redraw and selection bounds from clipping that falloff.
    var drawingOutset: CGFloat { ceil(blurRadius * 2) }

    static func style(for tool: AnnotationTool, strokeWidth: CGFloat) -> AnnotationGlowStyle? {
        guard [.arrow, .line, .rectangle, .circle, .marker].contains(tool) else { return nil }

        let width = min(20, max(1, strokeWidth))
        return AnnotationGlowStyle(
            opacity: min(0.52, 0.40 + width * 0.006),
            blurRadius: min(7, 3.0 + width * 0.22)
        )
    }
}

// MARK: - Annotation Resize Handle
enum AnnoResizeHandle: Equatable {
    case topLeft, topRight, bottomLeft, bottomRight
    // For arrow: start/end point
    case startPoint, endPoint
}

// MARK: - Text Annotation Typography & Layout
/// The single source of truth for text annotation typography and TextKit layout.
///
/// Text annotations intentionally do not soft-wrap. The editor grows horizontally,
/// and only explicit newline characters create additional lines. This keeps the
/// persisted model (`text` + top-left point) sufficient to reproduce the exact
/// layout when drawing, exporting, and re-entering edit mode.
enum AnnotationTextLayout {
    static let primaryFontName = "AvenirNext-Medium"
    static let fontSizeMultiplier: CGFloat = 4
    static let unconstrainedDimension: CGFloat = 1_000_000
    static let emptyEditorWidth: CGFloat = 24

    struct Layout {
        let textStorage: NSTextStorage
        let layoutManager: NSLayoutManager
        let textContainer: NSTextContainer
        let usedRect: NSRect
        let lineFragmentCount: Int

        var size: NSSize { usedRect.size }
    }

    static func fontSize(forStrokeWidth strokeWidth: CGFloat) -> CGFloat {
        strokeWidth * fontSizeMultiplier
    }

    static func font(ofSize fontSize: CGFloat) -> NSFont {
        let systemFallback = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let descriptor = NSFontDescriptor(fontAttributes: [
            .name: primaryFontName,
            .cascadeList: [systemFallback.fontDescriptor]
        ])
        return NSFont(descriptor: descriptor, size: fontSize) ?? systemFallback
    }

    static func paragraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byClipping
        style.lineSpacing = 0
        style.paragraphSpacing = 0
        style.paragraphSpacingBefore = 0
        return style
    }

    static func attributes(fontSize: CGFloat, color: NSColor) -> [NSAttributedString.Key: Any] {
        [
            .font: font(ofSize: fontSize),
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle()
        ]
    }

    static func attributedString(text: String, fontSize: CGFloat, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: attributes(fontSize: fontSize, color: color))
    }

    static func layout(text: String, fontSize: CGFloat, color: NSColor) -> Layout {
        let storage = NSTextStorage(attributedString: attributedString(text: text, fontSize: fontSize, color: color))
        let manager = NSLayoutManager()
        manager.usesFontLeading = true

        let container = NSTextContainer(
            containerSize: NSSize(width: unconstrainedDimension, height: unconstrainedDimension)
        )
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.heightTracksTextView = false

        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)

        var lineFragmentCount = 0
        let glyphRange = manager.glyphRange(for: container)
        if !text.isEmpty {
            manager.enumerateLineFragments(forGlyphRange: glyphRange) { _, _, _, _, _ in
                lineFragmentCount += 1
            }
        }
        let usedRect = text.isEmpty ? NSRect.zero : manager.usedRect(for: container)

        return Layout(
            textStorage: storage,
            layoutManager: manager,
            textContainer: container,
            usedRect: usedRect,
            lineFragmentCount: lineFragmentCount
        )
    }

    static func configure(
        textView: NSTextView,
        text: String,
        fontSize: CGFloat,
        color: NSColor
    ) {
        textView.isRichText = false
        textView.textContainerInset = .zero
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: unconstrainedDimension, height: unconstrainedDimension)
        textView.defaultParagraphStyle = paragraphStyle()
        textView.font = font(ofSize: fontSize)
        textView.textColor = color
        let textAttributes = attributes(fontSize: fontSize, color: color)

        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(
            width: unconstrainedDimension,
            height: unconstrainedDimension
        )
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.layoutManager?.usesFontLeading = true
        textView.textStorage?.setAttributedString(
            NSAttributedString(string: text, attributes: textAttributes)
        )
        textView.typingAttributes = textAttributes
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    }

    static func usedRect(in textView: NSTextView) -> NSRect {
        guard let manager = textView.layoutManager,
              let container = textView.textContainer else { return .zero }
        manager.ensureLayout(for: container)
        return manager.usedRect(for: container)
    }

    static func editorSize(for textView: NSTextView, fontSize: CGFloat, color: NSColor) -> NSSize {
        let usedRect = usedRect(in: textView)
        guard textView.string.isEmpty else { return usedRect.size }
        let lineHeight = layout(text: "M", fontSize: fontSize, color: color).size.height
        return NSSize(width: emptyEditorWidth, height: lineHeight)
    }

    static func boundingRect(text: String, fontSize: CGFloat, color: NSColor, topLeft: NSPoint) -> NSRect {
        guard !text.isEmpty else { return .zero }
        let size = layout(text: text, fontSize: fontSize, color: color).size
        return NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
    }

    static func frame(topLeft: NSPoint, size: NSSize) -> NSRect {
        NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
    }

    static func draw(text: String, fontSize: CGFloat, color: NSColor, topLeft: NSPoint) {
        guard !text.isEmpty else { return }
        let textLayout = layout(text: text, fontSize: fontSize, color: color)
        let glyphRange = textLayout.layoutManager.glyphRange(for: textLayout.textContainer)
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // TextKit lays out from a top-left origin, while annotation canvases use
        // AppKit's bottom-left coordinates. Flip once around the persisted top-left
        // anchor so layout, selection bounds, and exported glyphs share one geometry.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        context.saveGState()
        context.translateBy(x: topLeft.x, y: topLeft.y)
        context.scaleBy(x: 1, y: -1)
        let containerOrigin = NSPoint(x: -textLayout.usedRect.minX, y: -textLayout.usedRect.minY)
        textLayout.layoutManager.drawBackground(forGlyphRange: glyphRange, at: containerOrigin)
        textLayout.layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: containerOrigin)
        context.restoreGState()
        NSGraphicsContext.restoreGraphicsState()
    }
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
    /// Stored per element so later tool preference changes do not alter
    /// existing annotations. The default keeps legacy call sites unfilled.
    var isFilled: Bool

    init(
        tool: AnnotationTool,
        color: NSColor,
        strokeWidth: CGFloat,
        startPoint: NSPoint,
        endPoint: NSPoint,
        isFilled: Bool = false
    ) {
        self.tool = tool
        self.color = color
        self.strokeWidth = strokeWidth
        self.startPoint = startPoint
        self.endPoint = endPoint
        self.isFilled = tool.supportsShapeFill && isFilled
    }

    func copy() -> AnnotationElement {
        let c = AnnotationElement(
            tool: tool,
            color: color,
            strokeWidth: strokeWidth,
            startPoint: startPoint,
            endPoint: endPoint,
            isFilled: isFilled
        )
        c.id = id
        c.text = text
        c.markerNumber = markerNumber
        return c
    }

    // Bounding rect in selection-local coordinates
    var boundingRect: NSRect {
        switch tool {
        case .select:
            return .zero
        case .arrow, .line:
            let padding = max(strokeWidth * 2, 10)
            let minX = min(startPoint.x, endPoint.x) - padding
            let minY = min(startPoint.y, endPoint.y) - padding
            let maxX = max(startPoint.x, endPoint.x) + padding
            let maxY = max(startPoint.y, endPoint.y) + padding
            let interactionBounds = NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            guard let drawingBounds = AnnotationRenderer.vectorDrawingBounds(for: self) else { return interactionBounds }
            return interactionBounds.union(drawingBounds)
        case .rectangle, .circle:
            let interactionBounds = normalizedRect.insetBy(dx: -max(strokeWidth, 4), dy: -max(strokeWidth, 4))
            guard let drawingBounds = AnnotationRenderer.vectorDrawingBounds(for: self) else { return interactionBounds }
            return interactionBounds.union(drawingBounds)
        case .mosaic, .highlight:
            let r = normalizedRect
            return r.insetBy(dx: -max(strokeWidth, 4), dy: -max(strokeWidth, 4))
        case .text:
            return textBoundingRect
        case .marker:
            let radius = max(strokeWidth * 1.5, 6)
            let interactionBounds = NSRect(x: startPoint.x - radius, y: startPoint.y - radius, width: radius * 2, height: radius * 2)
            guard let drawingBounds = AnnotationRenderer.vectorDrawingBounds(for: self) else { return interactionBounds }
            return interactionBounds.union(drawingBounds)
        }
    }

    var normalizedRect: NSRect {
        let x = min(startPoint.x, endPoint.x)
        let y = min(startPoint.y, endPoint.y)
        let w = abs(endPoint.x - startPoint.x)
        let h = abs(endPoint.y - startPoint.y)
        return NSRect(x: x, y: y, width: w, height: h)
    }

    /// Bounds used only for the visible editing indicator. Interaction and
    /// redraw bounds may intentionally be larger, but Mosaic's selection UI
    /// must coincide with the pixels it replaces.
    var selectionIndicatorRect: NSRect {
        tool == .mosaic ? normalizedRect : boundingRect
    }

    private var textBoundingRect: NSRect {
        AnnotationTextLayout.boundingRect(
            text: text,
            fontSize: AnnotationTextLayout.fontSize(forStrokeWidth: strokeWidth),
            color: color,
            topLeft: startPoint
        )
    }

    func hitTest(point: NSPoint) -> Bool {
        switch tool {
        case .select:
            return false
        case .arrow, .line:
            return distanceToLine(point: point, from: startPoint, to: endPoint) < max(strokeWidth * 2, 8)
        case .rectangle:
            let r = normalizedRect
            let outer = r.insetBy(dx: -max(strokeWidth, 4), dy: -max(strokeWidth, 4))
            if isFilled { return outer.contains(point) }
            let inner = r.insetBy(dx: max(strokeWidth, 4), dy: max(strokeWidth, 4))
            return outer.contains(point) && (inner.width <= 0 || inner.height <= 0 || !inner.contains(point))
        case .circle:
            return hitTestEllipseBorder(point: point)
        case .text:
            return textBoundingRect.contains(point)
        case .marker:
            let radius = max(strokeWidth * 1.5, 6)
            let dx = point.x - startPoint.x
            let dy = point.y - startPoint.y
            return (dx * dx + dy * dy) <= (radius * radius)
        case .mosaic:
            return normalizedRect.contains(point)
        case .highlight:
            return normalizedRect.contains(point)
        }
    }

    // Resize handle hit test - returns which handle was hit
    func hitTestResizeHandle(point: NSPoint) -> AnnoResizeHandle? {
        let hs: CGFloat = 8  // handle hit radius

        switch tool {
        case .select:
            return nil
        case .arrow, .line:
            // Arrow and line have start and end point handles
            if distance(point, startPoint) < hs { return .startPoint }
            if distance(point, endPoint) < hs { return .endPoint }
            return nil

        case .rectangle, .circle, .mosaic, .highlight:
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

    var hasRenderableGeometry: Bool {
        let dx = abs(endPoint.x - startPoint.x)
        let dy = abs(endPoint.y - startPoint.y)
        switch tool {
        case .select:
            return false
        case .line:
            return hypot(dx, dy) > 3
        case .circle, .highlight:
            return dx > 3 && dy > 3
        case .arrow, .rectangle, .mosaic:
            return dx > 3 || dy > 3
        case .text, .marker:
            return true
        }
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

    private func hitTestEllipseBorder(point: NSPoint) -> Bool {
        let rect = normalizedRect
        let radiusX = rect.width / 2
        let radiusY = rect.height / 2
        guard radiusX > 0.001, radiusY > 0.001 else { return false }

        let centerX = rect.midX
        let centerY = rect.midY
        let tolerance = max(strokeWidth, 4)

        let outerX = radiusX + tolerance
        let outerY = radiusY + tolerance
        let normalizedOuter = pow((point.x - centerX) / outerX, 2) + pow((point.y - centerY) / outerY, 2)
        guard normalizedOuter <= 1 else { return false }
        if isFilled { return true }

        let innerX = radiusX - tolerance
        let innerY = radiusY - tolerance
        guard innerX > 0, innerY > 0 else { return true }
        let normalizedInner = pow((point.x - centerX) / innerX, 2) + pow((point.y - centerY) / innerY, 2)
        return normalizedInner >= 1
    }
}

// MARK: - Mosaic Source Geometry
/// A frozen image plus the location, in that image's AppKit coordinate space,
/// that corresponds to the selection-local annotation origin.
struct AnnotationMosaicSource {
    let image: NSImage
    let selectionOriginInImage: NSPoint

    func sourceRect(for selectionLocalRect: NSRect) -> NSRect {
        selectionLocalRect.offsetBy(
            dx: selectionOriginInImage.x,
            dy: selectionOriginInImage.y
        )
    }
}

// MARK: - Annotation State
class AnnotationState {
    private static let colorKey = "annoColor"
    private static let strokeKey = "annoStrokeWidths"
    private static let rememberedGroupToolsKey = "annoRememberedGroupTools"
    private static let shapeFillKey = "annoShapeFillEnabled"

    private let userDefaults: UserDefaults

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

    /// The last selected member of each grouped toolbar slot. This is kept
    /// independently from `currentTool` so switching to Select does not reset
    /// the visible group choice back to Arrow/Rectangle.
    private var rememberedGroupTools: [AnnotationTool: AnnotationTool] = [
        .arrow: .arrow,
        .rectangle: .rectangle
    ]

    var currentTool: AnnotationTool? = nil {
        didSet {
            guard let currentTool else { return }
            for group in AnnotationTool.toolbarGroups where group.count > 1 && group.contains(currentTool) {
                if let groupKey = group.first {
                    if rememberedGroupTools[groupKey] != currentTool {
                        rememberedGroupTools[groupKey] = currentTool
                        persistRememberedGroupTools()
                    }
                }
                break
            }
        }
    }

    func rememberedTool(in group: [AnnotationTool]) -> AnnotationTool {
        guard let fallback = group.first else { return .select }
        if let currentTool, group.contains(currentTool) { return currentTool }
        return rememberedGroupTools[fallback].flatMap { group.contains($0) ? $0 : nil } ?? fallback
    }

    /// If the shortcut is already active, advance to the next group member.
    /// From Select or another group, restore this group's remembered member.
    func toolForGroupShortcut(_ group: [AnnotationTool]) -> AnnotationTool {
        if let currentTool, group.contains(currentTool) {
            return AnnotationTool.cycledTool(in: group, current: currentTool)
        }
        return rememberedTool(in: group)
    }

    var currentColor: NSColor = .systemRed {
        didSet {
            userDefaults.set(Self.nameColorMap[currentColor] ?? "systemRed", forKey: Self.colorKey)
        }
    }

    var strokeWidths: [AnnotationTool: CGFloat] = [
        .arrow: 3,
        .line: 3,
        .rectangle: 2,
        .circle: 2,
        .text: 4,
        .marker: 8,
        .mosaic: 20
    ] {
        didSet {
            var dict: [String: Double] = [:]
            for (tool, width) in strokeWidths {
                dict[tool.rawValue] = Double(width)
            }
            userDefaults.set(dict, forKey: Self.strokeKey)
        }
    }

    /// Rectangle and Circle deliberately share one creation preference. It is
    /// independent from selection so inspecting an old element cannot change
    /// the Fill value used by the next shape.
    var shapeFillEnabled: Bool = false {
        didSet {
            userDefaults.set(shapeFillEnabled, forKey: Self.shapeFillKey)
        }
    }

    var elements: [AnnotationElement] = []
    var selectedElementId: UUID? = nil
    var selectedElementIds: Set<UUID> = []  // for multi-select
    var nextMarkerNumber: Int = 1

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        // Load stroke widths FIRST (before color, since color didSet won't touch strokes)
        if let dict = userDefaults.dictionary(forKey: Self.strokeKey) as? [String: Double] {
            for (key, val) in dict {
                if let tool = AnnotationTool(rawValue: key) {
                    strokeWidths[tool] = CGFloat(val)
                }
            }
        }
        // Load color (didSet will fire but only saves color key, won't overwrite strokes)
        if let colorName = userDefaults.string(forKey: Self.colorKey),
           let color = Self.colorNameMap[colorName] {
            currentColor = color
        }

        if let storedTools = userDefaults.dictionary(forKey: Self.rememberedGroupToolsKey) as? [String: String] {
            for group in AnnotationTool.toolbarGroups where group.count > 1 {
                guard let groupKey = group.first,
                      let rawValue = storedTools[groupKey.rawValue],
                      let tool = AnnotationTool(rawValue: rawValue),
                      group.contains(tool) else { continue }
                rememberedGroupTools[groupKey] = tool
            }
        }

        shapeFillEnabled = userDefaults.bool(forKey: Self.shapeFillKey)
    }

    private func persistRememberedGroupTools() {
        var storedTools: [String: String] = [:]
        for (groupKey, tool) in rememberedGroupTools {
            storedTools[groupKey.rawValue] = tool.rawValue
        }
        userDefaults.set(storedTools, forKey: Self.rememberedGroupToolsKey)
    }

    var undoStack: [[AnnotationElement]] = []
    var redoStack: [[AnnotationElement]] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Tracks the type of the last debounced property change so only same-type changes merge.
    enum PropertyChangeKind: Equatable {
        case color, strokeWidth, fill, text
    }

    private var propertyUndoTimer: Timer?
    private var lastPropertyChangeKind: PropertyChangeKind?

    func pushUndo() {
        // Cancel any pending debounced snapshot since we're doing a full push
        propertyUndoTimer?.invalidate()
        propertyUndoTimer = nil
        lastPropertyChangeKind = nil

        undoStack.append(elements.map { $0.copy() })
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()  // new action clears redo history
    }

    /// Push undo for property changes with 1s debounce.
    /// Only merges consecutive changes of the **same kind** within 1s.
    /// A different kind immediately starts a new undo entry.
    func pushUndoForPropertyChange(kind: PropertyChangeKind) {
        if lastPropertyChangeKind == kind, propertyUndoTimer != nil {
            // Same kind within debounce window: coalesce (no new snapshot)
        } else {
            // Different kind or no active debounce: save snapshot now
            undoStack.append(elements.map { $0.copy() })
            if undoStack.count > 50 { undoStack.removeFirst() }
            redoStack.removeAll()
            lastPropertyChangeKind = kind
        }
        // Reset the debounce timer
        propertyUndoTimer?.invalidate()
        propertyUndoTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            self?.lastPropertyChangeKind = nil
            self?.propertyUndoTimer = nil
        }
    }

    /// Pop the last undo entry if the current state matches it (i.e., no actual change happened).
    func popUndoIfUnchanged() {
        guard let lastSnapshot = undoStack.last else { return }
        // Quick check: same count?
        guard lastSnapshot.count == elements.count else { return }
        // Deep check: compare each element
        var same = true
        for (a, b) in zip(lastSnapshot, elements) {
            if a.id != b.id || a.startPoint != b.startPoint || a.endPoint != b.endPoint ||
               a.strokeWidth != b.strokeWidth || !a.color.isEqual(to: b.color) ||
               a.isFilled != b.isFilled || a.text != b.text {
                same = false
                break
            }
        }
        if same {
            undoStack.removeLast()
        }
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(elements.map { $0.copy() })
        elements = previous
        selectedElementId = nil
        selectedElementIds.removeAll()
        let maxMarker = elements.filter { $0.tool == .marker }.map { $0.markerNumber }.max() ?? 0
        nextMarkerNumber = maxMarker + 1
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(elements.map { $0.copy() })
        elements = next
        selectedElementId = nil
        selectedElementIds.removeAll()
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

    func makeElement(
        tool: AnnotationTool,
        color: NSColor,
        strokeWidth: CGFloat,
        startPoint: NSPoint,
        endPoint: NSPoint
    ) -> AnnotationElement {
        AnnotationElement(
            tool: tool,
            color: color,
            strokeWidth: strokeWidth,
            startPoint: startPoint,
            endPoint: endPoint,
            isFilled: tool.supportsShapeFill && shapeFillEnabled
        )
    }

    func setFillEnabled(_ enabled: Bool, for element: AnnotationElement? = nil) {
        guard let element else {
            shapeFillEnabled = enabled
            return
        }
        guard element.tool.supportsShapeFill, element.isFilled != enabled else { return }
        pushUndoForPropertyChange(kind: .fill)
        element.isFilled = enabled
    }

    func adjustStrokeWidth(delta: CGFloat) {
        guard let tool = selectedElement?.tool ?? currentTool, tool.usesStrokeWidth else { return }
        if selectedElement != nil {
            pushUndoForPropertyChange(kind: .strokeWidth)
        }
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
        if !selectedElementIds.isEmpty {
            pushUndo()
            elements.removeAll { selectedElementIds.contains($0.id) }
            selectedElementIds.removeAll()
            selectedElementId = nil
            return
        }
        guard let id = selectedElementId else { return }
        pushUndo()
        elements.removeAll { $0.id == id }
        selectedElementId = nil
    }

    func duplicateSelected() {
        guard let sel = selectedElement else { return }
        guard sel.tool != .highlight else { return }
        pushUndo()
        let dup = sel.copy()
        dup.id = UUID()  // new identity
        // Offset slightly so it's visible
        dup.startPoint.x += 15
        dup.startPoint.y -= 15
        dup.endPoint.x += 15
        dup.endPoint.y -= 15
        if dup.tool == .marker {
            dup.markerNumber = nextMarkerNumber
            nextMarkerNumber += 1
        }
        elements.append(dup)
        selectedElementId = dup.id
        selectedElementIds.removeAll()
    }

    func clearSelection() {
        selectedElementId = nil
        selectedElementIds.removeAll()
    }

    var hasMultiSelection: Bool {
        return selectedElementIds.count > 1
    }

    func isElementSelected(_ element: AnnotationElement) -> Bool {
        if selectedElementIds.contains(element.id) { return true }
        return element.id == selectedElementId
    }

    static let availableColors: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen,
        .systemBlue, .systemPurple, .white, .black
    ]
}

// MARK: - Annotation Renderer
class AnnotationRenderer {

    static let highlightOutsideOpacity: CGFloat = 0.42
    static let highlightInsideOpacity: CGFloat = 0.08

    static func draw(
        element: AnnotationElement,
        in context: NSGraphicsContext,
        selectionOrigin: NSPoint,
        isSelected: Bool,
        mosaicSource: AnnotationMosaicSource? = nil,
        selectionSize: NSSize? = nil
    ) {
        let ox = selectionOrigin.x
        let oy = selectionOrigin.y

        switch element.tool {
        case .select:
            break  // select is not a drawable element
        case .arrow, .line, .rectangle, .circle:
            drawVector(element: element, ctx: context.cgContext, ox: ox, oy: oy)
        case .text:
            drawText(element: element, ox: ox, oy: oy)
        case .marker:
            drawMarker(element: element, ctx: context.cgContext, ox: ox, oy: oy)
        case .mosaic:
            if let mosaicSource {
                drawMosaic(element: element, ctx: context.cgContext, ox: ox, oy: oy, source: mosaicSource)
            }
        case .highlight:
            if let selectionSize {
                drawHighlight(element: element, ox: ox, oy: oy, selectionSize: selectionSize)
            }
        }

        if isSelected {
            drawSelectionIndicator(for: element, ctx: context.cgContext, ox: ox, oy: oy)
        }
    }

    static func vectorDrawingBounds(for element: AnnotationElement) -> NSRect? {
        guard let style = AnnotationGlowStyle.style(for: element.tool, strokeWidth: element.strokeWidth),
              let silhouette = vectorSilhouette(for: element, ox: 0, oy: 0) else { return nil }
        return silhouette.boundingBoxOfPath.insetBy(dx: -style.drawingOutset, dy: -style.drawingOutset)
    }

    private static func drawVector(element: AnnotationElement, ctx: CGContext, ox: CGFloat, oy: CGFloat) {
        guard let silhouette = vectorSilhouette(for: element, ox: ox, oy: oy) else { return }
        drawGlowingVector(silhouette: silhouette, element: element, ctx: ctx)
    }

    private static func vectorSilhouette(for element: AnnotationElement, ox: CGFloat, oy: CGFloat) -> CGPath? {
        switch element.tool {
        case .arrow:
            return arrowSilhouette(for: element, ox: ox, oy: oy)
        case .line:
            let path = CGMutablePath()
            path.move(to: NSPoint(x: element.startPoint.x + ox, y: element.startPoint.y + oy))
            path.addLine(to: NSPoint(x: element.endPoint.x + ox, y: element.endPoint.y + oy))
            return path.copy(
                strokingWithWidth: element.strokeWidth,
                lineCap: .round,
                lineJoin: .round,
                miterLimit: 10
            )
        case .rectangle:
            let rect = element.normalizedRect.offsetBy(dx: ox, dy: oy)
            let shape = CGPath(rect: rect, transform: nil)
            let border = shape.copy(
                strokingWithWidth: element.strokeWidth,
                lineCap: .butt,
                lineJoin: .miter,
                miterLimit: 10
            )
            return shapeSilhouette(shape: shape, border: border, isFilled: element.isFilled)
        case .circle:
            let rect = element.normalizedRect.offsetBy(dx: ox, dy: oy)
            let shape = CGPath(ellipseIn: rect, transform: nil)
            let border = shape.copy(
                strokingWithWidth: element.strokeWidth,
                lineCap: .butt,
                lineJoin: .round,
                miterLimit: 10
            )
            return shapeSilhouette(shape: shape, border: border, isFilled: element.isFilled)
        case .marker:
            let center = NSPoint(x: element.startPoint.x + ox, y: element.startPoint.y + oy)
            let radius = max(element.strokeWidth * 1.5, 6)
            let rect = NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            return CGPath(ellipseIn: rect, transform: nil)
        default:
            return nil
        }
    }

    /// A filled shape and its border use one combined silhouette. Drawing the
    /// color once avoids increasing the alpha where a translucent fill and
    /// border overlap, while retaining the existing border extent and glow.
    private static func shapeSilhouette(shape: CGPath, border: CGPath, isFilled: Bool) -> CGPath {
        guard isFilled else { return border }
        let silhouette = CGMutablePath()
        silhouette.addPath(shape)
        silhouette.addPath(border)
        return silhouette
    }

    private static func arrowSilhouette(for element: AnnotationElement, ox: CGFloat, oy: CGFloat) -> CGPath {
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

        // Build the full arrow shape as a single path so shaft and head share
        // one continuous glow silhouette.
        let path = CGMutablePath()
        // Start at shaft top-left, go along shaft
        path.move(to: s1)
        path.addLine(to: s4)
        // Wing out to arrowhead
        path.addLine(to: h1)
        // Tip
        path.addLine(to: to)
        // Other wing
        path.addLine(to: h2)
        // Back along shaft
        path.addLine(to: s3)
        path.addLine(to: s2)
        path.closeSubpath()
        return path
    }

    /// Draw only the shadow outside the vector silhouette, then restore the
    /// original fill once. Excluding the silhouette from the glow pass keeps
    /// translucent annotation colors and their alpha unchanged while the
    /// second pass leaves the visible edge crisp.
    private static func drawGlowingVector(silhouette: CGPath, element: AnnotationElement, ctx: CGContext) {
        if let style = AnnotationGlowStyle.style(for: element.tool, strokeWidth: element.strokeWidth) {
            let glowColor = element.color.withAlphaComponent(style.opacity * element.color.alphaComponent)
            let clipBounds = ctx.boundingBoxOfClipPath

            if !clipBounds.isNull && !clipBounds.isEmpty {
                ctx.saveGState()
                ctx.addRect(clipBounds)
                ctx.addPath(silhouette)
                ctx.clip(using: .evenOdd)
                ctx.setShadow(offset: .zero, blur: style.blurRadius, color: glowColor.cgColor)
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.addPath(silhouette)
                ctx.fillPath()
                ctx.restoreGState()
            }
        }

        ctx.saveGState()
        ctx.setFillColor(element.color.cgColor)
        ctx.addPath(silhouette)
        ctx.fillPath()
        ctx.restoreGState()
    }

    private static func drawHighlight(element: AnnotationElement, ox: CGFloat, oy: CGFloat, selectionSize: NSSize) {
        let canvas = NSRect(x: ox, y: oy, width: selectionSize.width, height: selectionSize.height)
        let proposedFocus = element.normalizedRect.offsetBy(dx: ox, dy: oy)
        let focus = canvas.intersection(proposedFocus)
        guard !focus.isNull, focus.width > 0, focus.height > 0 else { return }

        let outsideRects = [
            NSRect(x: canvas.minX, y: canvas.minY, width: canvas.width, height: max(0, focus.minY - canvas.minY)),
            NSRect(x: canvas.minX, y: focus.maxY, width: canvas.width, height: max(0, canvas.maxY - focus.maxY)),
            NSRect(x: canvas.minX, y: focus.minY, width: max(0, focus.minX - canvas.minX), height: focus.height),
            NSRect(x: focus.maxX, y: focus.minY, width: max(0, canvas.maxX - focus.maxX), height: focus.height)
        ]

        NSColor.black.withAlphaComponent(highlightOutsideOpacity).setFill()
        for rect in outsideRects where rect.width > 0 && rect.height > 0 {
            NSBezierPath(rect: rect).fill()
        }

        NSColor.white.withAlphaComponent(highlightInsideOpacity).setFill()
        NSBezierPath(rect: focus).fill()
    }

    private static func drawText(element: AnnotationElement, ox: CGFloat, oy: CGFloat) {
        AnnotationTextLayout.draw(
            text: element.text,
            fontSize: AnnotationTextLayout.fontSize(forStrokeWidth: element.strokeWidth),
            color: element.color,
            topLeft: NSPoint(x: element.startPoint.x + ox, y: element.startPoint.y + oy)
        )
    }

    private static func drawMarker(element: AnnotationElement, ctx: CGContext, ox: CGFloat, oy: CGFloat) {
        let center = NSPoint(x: element.startPoint.x + ox, y: element.startPoint.y + oy)
        let radius = max(element.strokeWidth * 1.5, 6)

        let circleRect = NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        let circlePath = CGPath(ellipseIn: circleRect, transform: nil)
        drawGlowingVector(silhouette: circlePath, element: element, ctx: ctx)

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

    private static func drawMosaic(
        element: AnnotationElement,
        ctx: CGContext,
        ox: CGFloat,
        oy: CGFloat,
        source: AnnotationMosaicSource
    ) {
        let r = element.normalizedRect
        let destinationRect = r.offsetBy(dx: ox, dy: oy)

        guard destinationRect.width > 1 && destinationRect.height > 1 else { return }

        guard let cgImage = source.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        // Use actual CGImage pixel dimensions for scale, not NSBitmapImageRep.pixelsWide
        let scaleX = CGFloat(cgImage.width) / source.image.size.width
        let scaleY = CGFloat(cgImage.height) / source.image.size.height
        let sourceRect = source.sourceRect(for: r)

        let imgRect = CGRect(
            x: sourceRect.origin.x * scaleX,
            y: (source.image.size.height - sourceRect.origin.y - sourceRect.height) * scaleY,
            width: sourceRect.width * scaleX,
            height: sourceRect.height * scaleY
        )

        guard let regionCG = cgImage.cropping(to: imgRect) else { return }

        let blockSize = max(Int(element.strokeWidth), 5)
        let regionImage = NSImage(cgImage: regionCG, size: destinationRect.size)

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
        smallImage.draw(in: destinationRect, from: NSRect(origin: .zero, size: smallImage.size), operation: .sourceOver, fraction: 1.0)
        ctx.restoreGState()
    }

    private static func drawSelectionIndicator(for element: AnnotationElement, ctx: CGContext, ox: CGFloat, oy: CGFloat) {
        let r = element.selectionIndicatorRect
        let screenRect = NSRect(x: r.origin.x + ox, y: r.origin.y + oy, width: r.width, height: r.height)

        let path = NSBezierPath(rect: screenRect)
        path.lineWidth = 1
        NSColor.systemBlue.withAlphaComponent(0.6).setStroke()
        path.setLineDash([3, 3], count: 2, phase: 0)
        path.stroke()

        // Draw resize handles based on tool type
        let hs: CGFloat = 5

        switch element.tool {
        case .arrow, .line:
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

        case .rectangle, .circle, .mosaic, .highlight:
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

        case .text, .marker, .select:
            // No resize handles for text, marker, and select
            break
        }
    }

    // MARK: - Render annotations onto an image for export
    static func renderAnnotationsOntoImage(baseImage: NSImage, annotations: [AnnotationElement]) -> NSImage {
        let size = baseImage.size
        let result = NSImage(size: size)
        result.lockFocus()

        baseImage.draw(in: NSRect(origin: .zero, size: size))

        if let context = NSGraphicsContext.current {
            // Export from the already-cropped frozen selection. This keeps the
            // Mosaic source in the same local coordinate space as its target
            // and prevents screen-space offsets from selecting unrelated pixels.
            let mosaicSource = AnnotationMosaicSource(
                image: baseImage,
                selectionOriginInImage: .zero
            )
            // Draw mosaic elements first (bottom layer) so they only pixelate the original image
            for element in annotations where element.tool == .mosaic {
                draw(
                    element: element,
                    in: context,
                    selectionOrigin: .zero,
                    isSelected: false,
                    mosaicSource: mosaicSource,
                    selectionSize: size
                )
            }
            // Spotlight is a single background effect: render after mosaic but before ordinary annotations.
            for element in annotations where element.tool == .highlight {
                draw(element: element, in: context, selectionOrigin: .zero, isSelected: false, selectionSize: size)
            }
            // Draw all other annotations on top
            for element in annotations where element.tool != .mosaic && element.tool != .highlight {
                draw(element: element, in: context, selectionOrigin: .zero, isSelected: false, selectionSize: size)
            }
        }

        result.unlockFocus()
        return result
    }
}
