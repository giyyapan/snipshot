import Cocoa

class PinWindow: NSWindow {

    let pinnedImage: NSImage
    var currentScale: CGFloat = 1.0
    let baseSize: NSSize

    /// Stable center point in screen coordinates, updated only on drag or explicit reposition.
    /// Zoom always preserves this center to avoid floating-point drift.
    private var stableCenter: NSPoint = .zero

    private var imageView: NSImageView!
    private var pinView: PinContentView!

    let minScale: CGFloat = 0.1
    let maxScale: CGFloat = 5.0

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

        // Initialize stable center from the window frame
        self.stableCenter = NSPoint(
            x: windowRect.origin.x + baseSize.width / 2,
            y: windowRect.origin.y + baseSize.height / 2
        )
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

        if event.keyCode == 53 || event.keyCode == 51 { // Escape or Backspace - unpin
            close()
        } else if event.keyCode == 8 && flags.contains(.command) { // Cmd+C - copy image
            copyImageToClipboard()
        } else if event.keyCode == 33 { // [ — decrease opacity
            adjustOpacity(by: -0.1)
        } else if event.keyCode == 30 { // ] — increase opacity
            adjustOpacity(by: 0.1)
        } else {
            super.keyDown(with: event)
        }
    }

    private func adjustOpacity(by delta: CGFloat) {
        let newOpacity = (alphaValue + delta).clamped(to: 0.2...1.0)
        alphaValue = newOpacity
    }

    // MARK: - Copy image
    func copyImageToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([pinnedImage])
        logMessage("Pin: Image copied to clipboard.")
        pinView?.showCopyFeedback()
    }

    // MARK: - Scroll wheel → zoom or opacity
    override func scrollWheel(with event: NSEvent) {
        // When trackpadScrollAsZoom is enabled, treat precise (trackpad/Magic Mouse) scrolling as zoom too
        let trackpadAsZoom = UserDefaults.standard.bool(forKey: "trackpadScrollAsZoom")
        if event.hasPreciseScrollingDeltas && !trackpadAsZoom { return }

        let delta = event.scrollingDeltaY
        // For precise deltas, use a smaller factor since they produce larger values
        let isPrecise = event.hasPreciseScrollingDeltas
        guard abs(delta) > (isPrecise ? 0.5 : 0.1) else { return }

        // Cmd+Scroll: adjust opacity
        if event.modifierFlags.contains(.command) {
            let opacityDelta: CGFloat = delta > 0 ? 0.05 : -0.05
            adjustOpacity(by: opacityDelta)
            return
        }

        let effectiveDelta = isPrecise ? -delta : delta
        let factor: CGFloat = isPrecise ? 0.005 : 0.03
        let zoomFactor: CGFloat = 1.0 + (effectiveDelta * factor)
        // For trackpad scroll, anchor at center for stability; for mouse wheel, anchor at cursor
        applyZoom(to: currentScale * zoomFactor, anchorCenter: isPrecise)
    }

    // MARK: - Trackpad pinch → zoom
    override func magnify(with event: NSEvent) {
        let zoomFactor: CGFloat = 1.0 + event.magnification
        // Pinch gesture: anchor at center for stability
        applyZoom(to: currentScale * zoomFactor, anchorCenter: true)
    }

    /// Update stable center from the current window frame (call after drag).
    func updateStableCenter() {
        stableCenter = NSPoint(
            x: frame.origin.x + frame.width / 2,
            y: frame.origin.y + frame.height / 2
        )
    }

    // MARK: - Zoom
    /// Zoom to target scale.
    /// `anchorCenter: true` uses the stable center (for trackpad/pinch).
    /// `anchorCenter: false` uses the current mouse location (for discrete scroll wheel).
    func applyZoom(to targetScale: CGFloat, anchorCenter: Bool = true) {
        let newScale = targetScale.clamped(to: minScale...maxScale)
        guard abs(newScale - currentScale) > 0.001 else { return }

        let newWidth = baseSize.width * newScale
        let newHeight = baseSize.height * newScale

        let newX: CGFloat
        let newY: CGFloat

        if anchorCenter {
            // Anchor at stable center: deterministic, no drift
            newX = stableCenter.x - newWidth / 2
            newY = stableCenter.y - newHeight / 2
        } else {
            // Anchor at mouse location
            let mouseScreen = NSEvent.mouseLocation
            let anchorInWindow = NSPoint(
                x: mouseScreen.x - frame.origin.x,
                y: mouseScreen.y - frame.origin.y
            )
            let proportionX = frame.width > 0 ? anchorInWindow.x / frame.width : 0.5
            let proportionY = frame.height > 0 ? anchorInWindow.y / frame.height : 0.5
            newX = mouseScreen.x - proportionX * newWidth
            newY = mouseScreen.y - proportionY * newHeight
            // Update stable center to the new window center
            stableCenter = NSPoint(x: newX + newWidth / 2, y: newY + newHeight / 2)
        }

        currentScale = newScale

        let newFrame = NSRect(x: newX, y: newY, width: newWidth, height: newHeight)
        setFrame(newFrame, display: true, animate: false)

        let contentSize = NSSize(width: newWidth, height: newHeight)
        contentView?.frame = NSRect(origin: .zero, size: contentSize)
        imageView.frame = NSRect(origin: .zero, size: contentSize)
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
    private weak var parentWindow: PinWindow?
    private var dragOrigin: NSPoint?
    private var windowOriginAtDragStart: NSPoint?
    private var feedbackOverlay: NSView?

    // Border colors
    private let normalBorderColor = NSColor.white.withAlphaComponent(0.3).cgColor
    private let selectedBorderColor = NSColor.systemBlue.withAlphaComponent(0.8).cgColor

    init(frame: NSRect, image: NSImage, parentWindow: PinWindow) {
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

    // KEY CHANGE: Accept the first mouse click without requiring the window to
    // be focused first. This lets the user drag the pin window immediately.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    // MARK: - Border state
    func updateBorder(isKey: Bool) {
        guard let layer = layer else { return }
        if isKey {
            layer.borderWidth = 2
            layer.borderColor = selectedBorderColor
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
        let overlay = NSView(frame: bounds)
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.3).cgColor
        overlay.layer?.cornerRadius = 2
        addSubview(overlay)
        feedbackOverlay = overlay

        layer?.borderColor = NSColor.systemGreen.cgColor
        layer?.borderWidth = 3

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                overlay.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                overlay.removeFromSuperview()
                self?.feedbackOverlay = nil
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

    // MARK: - Manual drag (works without prior focus thanks to acceptsFirstMouse)
    override func mouseDown(with event: NSEvent) {
        // Double-click to close pin (default: on; can be toggled in Settings)
        if event.clickCount == 2 {
            let key = "doubleClickToClosePin"
            let enabled = UserDefaults.standard.object(forKey: key) == nil
                ? true
                : UserDefaults.standard.bool(forKey: key)
            if enabled {
                parentWindow?.close()
                return
            }
        }

        // Record drag start — do NOT makeKey here so drag works without focus
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
        // If it was a click (not a drag), make key so ESC/Cmd+C and pinch zoom work
        if let origin = dragOrigin {
            let current = NSEvent.mouseLocation
            let distance = hypot(current.x - origin.x, current.y - origin.y)
            if distance < 3 {
                parentWindow?.makeKey()
            }
        }
        dragOrigin = nil
        windowOriginAtDragStart = nil
        // Update stable center after drag so zoom anchors at the new position
        if let window = parentWindow {
            window.updateStableCenter()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.1, alpha: 1.0).setFill()
        bounds.fill()
        super.draw(dirtyRect)
    }
}
