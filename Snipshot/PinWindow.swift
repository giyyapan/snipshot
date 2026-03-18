import Cocoa

class PinWindow: NSWindow {

    private let pinnedImage: NSImage
    private var currentScale: CGFloat = 1.0
    private let baseSize: NSSize
    private var imageView: NSImageView!
    private var pinView: PinContentView!

    private let minScale: CGFloat = 0.1
    private let maxScale: CGFloat = 5.0

    init(image: NSImage, origin: NSPoint) {
        self.pinnedImage = image
        self.baseSize = image.size

        let windowRect = NSRect(
            x: origin.x,
            y: origin.y,
            width: baseSize.width,
            height: baseSize.height
        )

        super.init(
            contentRect: windowRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.isOpaque = false
        self.hasShadow = true
        self.backgroundColor = .clear
        self.isReleasedWhenClosed = false
        self.isMovable = false  // We handle drag manually
        self.acceptsMouseMovedEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let pv = PinContentView(frame: NSRect(origin: .zero, size: baseSize), image: image, parentWindow: self)
        self.contentView = pv
        self.imageView = pv.imageView
        self.pinView = pv
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - Focus change: update border
    override func becomeKey() {
        super.becomeKey()
        pinView?.updateBorder(isKey: true)
    }

    override func resignKey() {
        super.resignKey()
        pinView?.updateBorder(isKey: false)
    }

    // MARK: - Keyboard
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if event.keyCode == 53 { // Escape - unpin
            close()
        } else if event.keyCode == 8 && flags.contains(.command) { // Cmd+C - copy image
            copyImageToClipboard()
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: - Copy image
    private func copyImageToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([pinnedImage])
        logMessage("Pin: Image copied to clipboard.")

        // Visual feedback
        pinView?.showCopyFeedback()
    }

    // MARK: - Scroll to zoom
    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        guard abs(delta) > 0.1 else { return }

        let zoomFactor: CGFloat = 1.0 + (delta * 0.03)
        let newScale = (currentScale * zoomFactor).clamped(to: minScale...maxScale)

        guard abs(newScale - currentScale) > 0.001 else { return }

        let mouseScreen = NSEvent.mouseLocation

        let newWidth = baseSize.width * newScale
        let newHeight = baseSize.height * newScale

        let mouseInWindow = NSPoint(
            x: mouseScreen.x - frame.origin.x,
            y: mouseScreen.y - frame.origin.y
        )
        let proportionX = mouseInWindow.x / frame.width
        let proportionY = mouseInWindow.y / frame.height

        let newX = mouseScreen.x - proportionX * newWidth
        let newY = mouseScreen.y - proportionY * newHeight

        currentScale = newScale

        let newFrame = NSRect(x: newX, y: newY, width: newWidth, height: newHeight)
        setFrame(newFrame, display: true, animate: false)

        contentView?.frame = NSRect(origin: .zero, size: NSSize(width: newWidth, height: newHeight))
        imageView.frame = NSRect(origin: .zero, size: NSSize(width: newWidth, height: newHeight))
    }
}

// MARK: - Clamped extension
extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        return min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - PinContentView (handles drag manually, no focus required)
class PinContentView: NSView {

    let imageView: NSImageView
    private weak var parentWindow: NSWindow?
    private var dragOrigin: NSPoint?
    private var windowOriginAtDragStart: NSPoint?
    private var feedbackOverlay: NSView?

    // Border colors
    private let normalBorderColor = NSColor.white.withAlphaComponent(0.3).cgColor
    private let selectedBorderColor = NSColor.systemBlue.withAlphaComponent(0.8).cgColor

    init(frame: NSRect, image: NSImage, parentWindow: NSWindow) {
        self.parentWindow = parentWindow

        imageView = NSImageView(frame: NSRect(origin: .zero, size: frame.size))
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.isEditable = false

        super.init(frame: frame)

        wantsLayer = true
        layer?.cornerRadius = 2
        layer?.masksToBounds = false
        layer?.borderWidth = 1
        layer?.borderColor = normalBorderColor

        addSubview(imageView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Border state
    func updateBorder(isKey: Bool) {
        guard let layer = layer else { return }
        if isKey {
            layer.borderWidth = 2
            layer.borderColor = selectedBorderColor
            // Add a subtle glow via shadow
            layer.shadowColor = NSColor.systemBlue.cgColor
            layer.shadowRadius = 6
            layer.shadowOpacity = 0.5
            layer.shadowOffset = .zero
        } else {
            layer.borderWidth = 1
            layer.borderColor = normalBorderColor
            layer.shadowOpacity = 0
        }
    }

    // MARK: - Copy feedback animation
    func showCopyFeedback() {
        // Brief white flash overlay
        let overlay = NSView(frame: bounds)
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.3).cgColor
        overlay.layer?.cornerRadius = 2
        addSubview(overlay)
        feedbackOverlay = overlay

        // Also briefly flash the border green
        layer?.borderColor = NSColor.systemGreen.cgColor
        layer?.borderWidth = 3

        // Fade out after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                overlay.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                overlay.removeFromSuperview()
                self?.feedbackOverlay = nil
                // Restore border to selected state
                let isKey = self?.parentWindow?.isKeyWindow ?? false
                self?.updateBorder(isKey: isKey)
            })
        }
    }

    // Override hitTest to ensure this view always receives mouse events
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    // MARK: - Manual drag (works without prior focus)
    override func mouseDown(with event: NSEvent) {
        // Make this window key immediately so ESC works
        parentWindow?.makeKey()
        // Record the mouse position in screen coordinates for drag
        dragOrigin = NSEvent.mouseLocation
        windowOriginAtDragStart = parentWindow?.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window = parentWindow,
              let origin = dragOrigin,
              let windowStart = windowOriginAtDragStart else { return }

        let current = NSEvent.mouseLocation
        let dx = current.x - origin.x
        let dy = current.y - origin.y

        let newOrigin = NSPoint(
            x: windowStart.x + dx,
            y: windowStart.y + dy
        )
        window.setFrameOrigin(newOrigin)
    }

    override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
        windowOriginAtDragStart = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.1, alpha: 1.0).setFill()
        bounds.fill()
        super.draw(dirtyRect)
    }
}
