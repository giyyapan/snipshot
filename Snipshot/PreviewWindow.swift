import Cocoa

enum PreviewAction {
    case copy
    case save
    case pin
    case cancel
}

// MARK: - HoverButton
// Custom NSButton subclass with a visible hover background highlight.
// Uses a backing NSView for the hover background to avoid CALayer issues
// inside NSVisualEffectView.
class HoverButton: NSView {

    var toolTip_: String = ""
    var onPress: (() -> Void)?

    private var iconView: NSImageView!
    private var isHovered = false
    private var isPressed = false

    init(frame: NSRect, symbolName: String, tooltip: String, tintColor: NSColor = .labelColor) {
        super.init(frame: frame)

        toolTip = tooltip
        toolTip_ = tooltip

        wantsLayer = true
        layer?.cornerRadius = 5

        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(config)

        iconView = NSImageView(frame: bounds.insetBy(dx: 3, dy: 3))
        iconView.image = img
        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = tintColor
        iconView.autoresizingMask = [.width, .height]
        addSubview(iconView)

        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        if isPressed {
            NSColor.white.withAlphaComponent(0.25).setFill()
            let path = NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5)
            path.fill()
        } else if isHovered {
            NSColor.white.withAlphaComponent(0.12).setFill()
            let path = NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5)
            path.fill()
        }
    }

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
        let loc = convert(event.locationInWindow, from: nil)
        if bounds.contains(loc) {
            onPress?()
        }
    }
}

// MARK: - PreviewWindow
class PreviewWindow: NSWindow {

    private let onAction: (PreviewAction) -> Void
    private let capturedImage: NSImage
    private var infoPanelWindow: NSWindow?
    private var actionPanelWindow: NSWindow?

    init(image: NSImage, selectionRect: NSRect, onAction: @escaping (PreviewAction) -> Void) {
        self.capturedImage = image
        self.onAction = onAction

        let windowRect = NSRect(
            x: selectionRect.origin.x,
            y: selectionRect.origin.y,
            width: selectionRect.width,
            height: selectionRect.height
        )

        super.init(
            contentRect: windowRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.isOpaque = false
        self.hasShadow = true
        self.backgroundColor = .clear
        self.isMovableByWindowBackground = false
        self.isReleasedWhenClosed = false

        let imageView = NSImageView(frame: NSRect(origin: .zero, size: windowRect.size))
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 3
        imageView.layer?.masksToBounds = true
        imageView.layer?.borderWidth = 1
        imageView.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor

        let container = NSView(frame: NSRect(origin: .zero, size: windowRect.size))
        container.addSubview(imageView)
        self.contentView = container

        setupInfoPanel(selectionRect: selectionRect, image: image)
        setupActionPanel(selectionRect: selectionRect)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    private func setupInfoPanel(selectionRect: NSRect, image: NSImage) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let pixelW = Int(image.size.width * scale)
        let pixelH = Int(image.size.height * scale)
        let text = "\(pixelW) × \(pixelH)"

        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let textSize = (text as NSString).size(withAttributes: attrs)

        let panelWidth = textSize.width + 16
        let panelHeight: CGFloat = 24

        let panelX = selectionRect.origin.x
        let panelY = selectionRect.origin.y - panelHeight - 6

        let panel = NSPanel(
            contentRect: NSRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.hasShadow = true
        panel.backgroundColor = .clear

        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 6
        bg.layer?.masksToBounds = true

        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 8, y: (panelHeight - textSize.height) / 2, width: textSize.width, height: textSize.height)
        bg.addSubview(label)

        panel.contentView = bg
        panel.orderFront(nil)
        self.addChildWindow(panel, ordered: .above)
        self.infoPanelWindow = panel
    }

    private func setupActionPanel(selectionRect: NSRect) {
        let buttonSize: CGFloat = 26
        let buttonSpacing: CGFloat = 2
        let buttonCount: CGFloat = 4
        let panelPadding: CGFloat = 6
        let panelWidth = buttonCount * buttonSize + (buttonCount - 1) * buttonSpacing + panelPadding * 2
        let panelHeight: CGFloat = 34

        let panelX = selectionRect.origin.x + selectionRect.width - panelWidth
        let panelY = selectionRect.origin.y - panelHeight - 6

        let panel = NSPanel(
            contentRect: NSRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.hasShadow = true
        panel.backgroundColor = .clear

        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 6
        bg.layer?.masksToBounds = true

        let buttonY = (panelHeight - buttonSize) / 2

        // Layout left to right: Pin, Save, Cancel, Copy
        var x = panelPadding

        // Pin
        let pinBtn = HoverButton(
            frame: NSRect(x: x, y: buttonY, width: buttonSize, height: buttonSize),
            symbolName: "pin",
            tooltip: "Pin to Screen  F3"
        )
        pinBtn.onPress = { [weak self] in self?.handleAction(.pin) }
        bg.addSubview(pinBtn)
        x += buttonSize + buttonSpacing

        // Save
        let saveBtn = HoverButton(
            frame: NSRect(x: x, y: buttonY, width: buttonSize, height: buttonSize),
            symbolName: "square.and.arrow.down",
            tooltip: "Save Image  \u{2318}S"
        )
        saveBtn.onPress = { [weak self] in self?.handleAction(.save) }
        bg.addSubview(saveBtn)
        x += buttonSize + buttonSpacing

        // Cancel
        let cancelBtn = HoverButton(
            frame: NSRect(x: x, y: buttonY, width: buttonSize, height: buttonSize),
            symbolName: "xmark",
            tooltip: "Close  Esc"
        )
        cancelBtn.onPress = { [weak self] in self?.handleAction(.cancel) }
        bg.addSubview(cancelBtn)
        x += buttonSize + buttonSpacing

        // Copy (rightmost)
        let copyBtn = HoverButton(
            frame: NSRect(x: x, y: buttonY, width: buttonSize, height: buttonSize),
            symbolName: "doc.on.doc",
            tooltip: "Copy & Done  \u{21A9}"
        )
        copyBtn.onPress = { [weak self] in self?.handleAction(.copy) }
        bg.addSubview(copyBtn)

        panel.contentView = bg
        panel.orderFront(nil)
        self.addChildWindow(panel, ordered: .above)
        self.actionPanelWindow = panel
    }

    private func handleAction(_ action: PreviewAction) {
        onAction(action)
    }

    // MARK: - Keyboard shortcuts
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if event.keyCode == 53 { // Escape
            handleAction(.cancel)
        } else if event.keyCode == 36 { // Return/Enter
            handleAction(.copy)
        } else if event.keyCode == 99 { // F3
            handleAction(.pin)
        } else if event.keyCode == 1 && flags.contains(.command) { // Cmd+S
            handleAction(.save)
        } else {
            super.keyDown(with: event)
        }
    }

    override func close() {
        infoPanelWindow?.orderOut(nil)
        actionPanelWindow?.orderOut(nil)
        super.close()
    }

    func dismiss() {
        infoPanelWindow?.orderOut(nil)
        actionPanelWindow?.orderOut(nil)
        orderOut(nil)
    }
}
