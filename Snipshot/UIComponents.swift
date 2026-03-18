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
    var isActive: Bool = false {
        didSet {
            iconView.contentTintColor = isActive ? activeColor : normalColor
            needsDisplay = true
        }
    }
    private var iconView: NSImageView!
    private var isHovered = false
    private var isPressed = false
    private let normalColor: NSColor = NSColor(white: 0.3, alpha: 1.0)
    private let hoverColor: NSColor = NSColor.systemBlue
    private let activeColor: NSColor = NSColor.systemBlue
    private var tooltipText: String
    private var tooltipWindow: TooltipWindow?

    init(frame: NSRect, symbolName: String, tooltip: String, pointSize: CGFloat = 12) {
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
        if isActive {
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
        isHovered = true
        if !isActive { iconView.contentTintColor = hoverColor }
        NSCursor.arrow.set()
        needsDisplay = true
        showTooltip()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
        if !isActive { iconView.contentTintColor = normalColor }
        needsDisplay = true
        hideTooltip()
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        needsDisplay = true
        hideTooltip()
    }

    override func mouseUp(with event: NSEvent) {
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
