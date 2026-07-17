import Cocoa

// MARK: - Instant Tooltip Window
private class TooltipWindow: NSWindow {
    init(text: String) {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        label.textColor = .white
        label.backgroundColor = .clear
        label.sizeToFit()

        let padding: CGFloat = 6
        let size = NSSize(width: label.frame.width + padding * 2, height: label.frame.height + padding)

        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: .borderless,
                   backing: .buffered,
                   defer: false)

        isOpaque = false
        backgroundColor = .clear
        level = .statusBar + 2
        ignoresMouseEvents = true
        hasShadow = true

        let bg = NSView(frame: NSRect(origin: .zero, size: size))
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor(white: 0.15, alpha: 0.95).cgColor
        bg.layer?.cornerRadius = 4

        label.frame.origin = NSPoint(x: padding, y: padding / 2)
        bg.addSubview(label)
        contentView = bg
    }
}

// MARK: - HoverIconButton
class HoverIconButton: NSView {

    var onPress: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var isActive: Bool = false {
        didSet {
            updateTintColor()
            needsDisplay = true
        }
    }
    var isDisabled: Bool = false {
        didSet {
            updateTintColor()
            needsDisplay = true
        }
    }
    private var iconView: NSImageView!
    private var isHovered = false
    private var isPressed = false
    private let normalColor: NSColor = NSColor(white: 0.3, alpha: 1.0)
    private let disabledColor: NSColor = NSColor(white: 0.3, alpha: 0.25)
    private let hoverColor: NSColor = NSColor.systemBlue
    private let activeColor: NSColor = NSColor.systemBlue

    private func updateTintColor() {
        if isDisabled {
            iconView.contentTintColor = disabledColor
        } else if isActive {
            iconView.contentTintColor = activeColor
        } else if isHovered {
            iconView.contentTintColor = hoverColor
        } else {
            iconView.contentTintColor = normalColor
        }
    }
    private var tooltipText: String
    private var tooltipWindow: TooltipWindow?

    init(frame: NSRect, symbolName: String, tooltip: String, pointSize: CGFloat = 12, showsMenuIndicator: Bool = false) {
        self.tooltipText = tooltip
        super.init(frame: frame)

        // Don't use system tooltip (it's slow)
        wantsLayer = true
        layer?.cornerRadius = 5

        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(config)

        iconView = NSImageView(frame: bounds.insetBy(dx: 3, dy: 3))
        iconView.image = img
        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = normalColor
        iconView.autoresizingMask = [.width, .height]
        addSubview(iconView)

        if showsMenuIndicator {
            let indicator = NSImageView(frame: NSRect(x: bounds.maxX - 8, y: 2, width: 6, height: 6))
            let indicatorConfig = NSImage.SymbolConfiguration(pointSize: 5, weight: .bold)
            indicator.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "More tools")?
                .withSymbolConfiguration(indicatorConfig)
            indicator.imageScaling = .scaleProportionallyDown
            indicator.contentTintColor = NSColor(white: 0.35, alpha: 0.8)
            indicator.autoresizingMask = [.minXMargin, .maxYMargin]
            addSubview(indicator)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        if isDisabled {
            // No background for disabled buttons
        } else if isActive {
            NSColor.systemBlue.withAlphaComponent(0.2).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        } else if isPressed {
            NSColor.black.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        } else if isHovered {
            NSColor.black.withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    private func showTooltip() {
        guard !tooltipText.isEmpty else { return }
        let tw = TooltipWindow(text: tooltipText)
        // Position tooltip above the button, centered
        if let screenOrigin = window?.convertPoint(toScreen: convert(NSPoint(x: bounds.midX, y: bounds.maxY), to: nil)) {
            let tooltipSize = tw.frame.size
            let x = screenOrigin.x - tooltipSize.width / 2
            let y = screenOrigin.y + 4
            tw.setFrameOrigin(NSPoint(x: x, y: y))
        }
        tw.orderFront(nil)
        tooltipWindow = tw
    }

    private func hideTooltip() {
        tooltipWindow?.orderOut(nil)
        tooltipWindow = nil
    }

    override func mouseEntered(with event: NSEvent) {
        guard !isDisabled else { return }
        isHovered = true
        if !isActive { iconView.contentTintColor = hoverColor }
        NSCursor.arrow.set()
        needsDisplay = true
        if let onHover {
            onHover(true)
        } else {
            showTooltip()
        }
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
        if !isDisabled && !isActive { iconView.contentTintColor = normalColor }
        needsDisplay = true
        hideTooltip()
        onHover?(false)
    }

    override func mouseDown(with event: NSEvent) {
        guard !isDisabled else { return }
        isPressed = true
        needsDisplay = true
        hideTooltip()
    }

    override func mouseUp(with event: NSEvent) {
        guard !isDisabled else { return }
        isPressed = false
        needsDisplay = true
        let loc = convert(event.locationInWindow, from: nil)
        if bounds.contains(loc) { onPress?() }
    }

    override func removeFromSuperview() {
        hideTooltip()
        super.removeFromSuperview()
    }
}

// MARK: - Grouped Tool Menu Item
class GroupedToolMenuItem: NSView {
    var onPress: (() -> Void)?
    private var isHovered = false
    private var isPressed = false

    init(frame: NSRect, tool: AnnotationTool, isSelected: Bool) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 4

        let icon = NSImageView(frame: NSRect(x: 8, y: (frame.height - 16) / 2, width: 16, height: 16))
        icon.image = NSImage(systemSymbolName: tool.symbolName, accessibilityDescription: tool.displayName)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
        icon.imageScaling = .scaleProportionallyDown
        icon.contentTintColor = NSColor(white: 0.3, alpha: 1)
        addSubview(icon)

        let label = NSTextField(labelWithString: tool.displayName)
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = NSColor(white: 0.25, alpha: 1)
        label.frame = NSRect(x: 31, y: (frame.height - 16) / 2, width: frame.width - 58, height: 16)
        addSubview(label)

        if isSelected {
            let checkmark = NSImageView(frame: NSRect(x: frame.width - 22, y: (frame.height - 14) / 2, width: 14, height: 14))
            checkmark.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Selected")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
            checkmark.imageScaling = .scaleProportionallyDown
            checkmark.contentTintColor = .systemBlue
            addSubview(checkmark)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        if isPressed {
            NSColor.systemBlue.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        } else if isHovered {
            NSColor.systemBlue.withAlphaComponent(0.1).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        needsDisplay = true
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) { onPress?() }
    }
}

// MARK: - SmallButton (for +/- controls)
class SmallButton: NSView {
    var onPress: (() -> Void)?
    private var label: NSTextField!
    private var isHovered = false
    private var isPressed = false

    init(frame: NSRect, text: String) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 3

        label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        label.textColor = NSColor(white: 0.4, alpha: 1.0)
        label.alignment = .center
        label.frame = bounds
        label.autoresizingMask = [.width, .height]
        addSubview(label)

        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        if isPressed {
            NSColor.black.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        } else if isHovered {
            NSColor.black.withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    override func mouseEntered(with event: NSEvent) {
        isHovered = true; label.textColor = .systemBlue; NSCursor.arrow.set(); needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) {
        isHovered = false; isPressed = false; label.textColor = NSColor(white: 0.4, alpha: 1.0); needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) { isPressed = true; needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        isPressed = false; needsDisplay = true
        let loc = convert(event.locationInWindow, from: nil)
        if bounds.contains(loc) { onPress?() }
    }
}

// MARK: - ColorDot
class ColorDot: NSView {
    var onPress: (() -> Void)?
    var dotColor: NSColor
    var isSelected: Bool = false { didSet { needsDisplay = true } }
    private var isHovered = false

    init(frame: NSRect, color: NSColor) {
        self.dotColor = color
        super.init(frame: frame)
        wantsLayer = true
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = isSelected ? 2 : (isHovered ? 3 : 4)
        let circleRect = bounds.insetBy(dx: inset, dy: inset)
        let path = NSBezierPath(ovalIn: circleRect)
        dotColor.setFill()
        path.fill()

        if isSelected {
            NSColor(white: 0.3, alpha: 1.0).setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 1.5
            ring.stroke()
        }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    override func mouseEntered(with event: NSEvent) { isHovered = true; NSCursor.arrow.set(); needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        if bounds.contains(loc) { onPress?() }
    }
}
