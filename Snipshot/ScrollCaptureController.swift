import Cocoa

/// Manages the entire scrolling capture session:
///
/// 1. Shows a dashed border around the capture region (mouse-transparent).
/// 2. Periodically captures the region and feeds frames to `StitchingManager`.
/// 3. Displays a live preview thumbnail that "grows upward" as new content is stitched.
/// 4. Provides Copy / Save buttons to finish the capture.
///
/// The controller creates its own floating windows so the user can freely interact
/// with the application underneath.
class ScrollCaptureController {

    // MARK: - Callbacks

    /// Called when the user finishes (copy or save) or cancels.
    var onFinish: (() -> Void)?

    // MARK: - Configuration

    /// Interval between frame captures (seconds).
    private let captureInterval: TimeInterval = 0.25

    // MARK: - State

    private let captureRect: NSRect          // Screen coordinates of the capture region
    private let screen: NSScreen             // The screen the capture is on
    private let stitcher = StitchingManager()
    private var captureTimer: Timer?
    private var isCapturing = false

    // MARK: - Windows

    private var borderWindow: NSWindow?      // Dashed border around capture region
    private var previewWindow: NSWindow?     // Thumbnail preview of stitched image
    private var actionPanel: NSPanel?        // Copy / Save / Cancel buttons
    private var hintWindow: NSWindow?        // Hint label above capture region
    private var previewImageView: NSImageView?
    private var hintLabel: NSTextField?

    // Preview layout constants
    private let previewWidth: CGFloat = 140
    private let previewMaxHeight: CGFloat = 500
    private let previewGap: CGFloat = 12     // Gap between capture rect and preview
    private let actionPanelHeight: CGFloat = 34

    // MARK: - Init

    /// The clean first frame cropped from the overlay's original screenshot.
    private let firstFrame: NSImage?

    /// - Parameters:
    ///   - captureRect: The region to capture, in screen coordinates.
    ///   - screen: The screen the capture region is on.
    ///   - firstFrame: A clean first frame cropped from the overlay's original screenshot (no UI controls).
    init(captureRect: NSRect, screen: NSScreen, firstFrame: NSImage? = nil) {
        self.captureRect = captureRect
        self.screen = screen
        self.firstFrame = firstFrame
    }

    // MARK: - Public API

    /// Start the scrolling capture session.
    func start() {
        guard !isCapturing else { return }
        isCapturing = true

        logMessage("[ScrollCapture] Starting. Region: \(captureRect)")

        setupBorderWindow()
        setupPreviewWindow()
        setupActionPanel()
        setupHintWindow()

        stitcher.onUpdate = { [weak self] image in
            self?.updatePreview(with: image)
        }

        stitcher.onDirectionLocked = { [weak self] direction in
            self?.updateHintForDirection(direction)
        }

        // Feed the clean first frame from the overlay's original screenshot
        if let firstFrame = firstFrame {
            stitcher.addFrame(firstFrame)
        }

        // Delay the start of periodic capture to ensure the overlay is fully dismissed
        // and the screen shows the actual app content.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self = self, self.isCapturing else { return }
            self.captureTimer = Timer.scheduledTimer(withTimeInterval: self.captureInterval, repeats: true) { [weak self] _ in
                self?.captureFrame()
            }
        }
    }

    /// Stop the capture session and clean up all windows.
    func stop() {
        captureTimer?.invalidate()
        captureTimer = nil
        isCapturing = false

        borderWindow?.orderOut(nil)
        borderWindow = nil
        previewWindow?.orderOut(nil)
        previewWindow = nil
        actionPanel?.orderOut(nil)
        actionPanel = nil
        hintWindow?.orderOut(nil)
        hintWindow = nil
        previewImageView = nil
        hintLabel = nil

        logMessage("[ScrollCapture] Stopped.")
    }

    // MARK: - Frame Capture

    /// Capture the screen region defined by `captureRect`.
    private func captureFrame() {
        // Convert from NS screen coordinates to CG coordinates (top-left origin)
        let mainHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let cgRect = CGRect(
            x: captureRect.origin.x,
            y: mainHeight - captureRect.origin.y - captureRect.height,
            width: captureRect.width,
            height: captureRect.height
        )

        // Capture the screen region (our overlay windows have level > .statusBar
        // so they appear above normal content, but CGWindowListCreateImage captures
        // all on-screen windows including ours — the border window is transparent
        // and the preview/action panel are positioned outside the capture rect)
        guard let cgImage = CGWindowListCreateImage(
            cgRect,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution]
        ) else {
            logMessage("[ScrollCapture] CGWindowListCreateImage failed.")
            return
        }

        let nsImage = NSImage(
            cgImage: cgImage,
            size: NSSize(width: captureRect.width, height: captureRect.height)
        )

        stitcher.addFrame(nsImage)
    }

    // MARK: - Border Window

    /// A transparent, mouse-transparent window that draws a dashed border
    /// around the capture region so the user knows what area is being captured.
    private func setupBorderWindow() {
        // The border is drawn OUTSIDE the capture rect so it won't be
        // included in the captured frames. We expand the window by `margin`
        // on each side and draw the dashed stroke in that outer margin.
        let strokeWidth: CGFloat = 2.0
        let margin: CGFloat = strokeWidth + 1  // enough room for the stroke outside
        let borderRect = captureRect.insetBy(dx: -margin, dy: -margin)

        let window = NSWindow(
            contentRect: borderRect,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.level = .statusBar + 1
        window.isOpaque = false
        window.hasShadow = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.animationBehavior = .none

        let borderView = DashedBorderView(
            frame: NSRect(origin: .zero, size: borderRect.size),
            margin: margin,
            strokeWidth: strokeWidth
        )
        window.contentView = borderView

        window.orderFront(nil)
        self.borderWindow = window
    }

    // MARK: - Preview Window

    /// A floating window on the right side of the capture region that shows
    /// a live thumbnail of the stitched image, growing upward.
    private func setupPreviewWindow() {
        // Position preview to the right of the capture rect
        let previewX = captureRect.maxX + previewGap

        // Initial height matches the aspect ratio of the first frame
        let aspectRatio = captureRect.height / captureRect.width
        let initialHeight = min(previewWidth * aspectRatio, previewMaxHeight)

        // Vertically center the preview with the capture rect's midline
        let captureMidY = captureRect.midY
        let previewY = captureMidY - initialHeight / 2

        let previewRect = NSRect(
            x: previewX,
            y: previewY,
            width: previewWidth,
            height: initialHeight
        )

        // Check if preview fits on screen; if not, put it on the left
        let screenFrame = screen.frame
        var finalRect = previewRect
        if previewRect.maxX > screenFrame.maxX - 10 {
            finalRect.origin.x = captureRect.origin.x - previewWidth - previewGap
        }

        let window = NSWindow(
            contentRect: finalRect,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.level = .statusBar + 1
        window.isOpaque = false
        window.hasShadow = true
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.animationBehavior = .none

        // Container with rounded corners and subtle border
        let container = NSView(frame: NSRect(origin: .zero, size: finalRect.size))
        container.wantsLayer = true
        container.layer?.cornerRadius = 6
        container.layer?.masksToBounds = true
        container.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.85).cgColor
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor

        let imageView = NSImageView(frame: container.bounds)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignBottom  // New content appears at bottom, old pushed up
        imageView.autoresizingMask = [.width, .height]
        container.addSubview(imageView)

        window.contentView = container
        window.orderFront(nil)

        self.previewWindow = window
        self.previewImageView = imageView
    }

    // MARK: - Action Panel

    /// A floating panel with Copy, Save, and Cancel buttons, positioned below the preview.
    private func setupActionPanel() {
        guard let previewFrame = previewWindow?.frame else { return }

        let buttonSize: CGFloat = 26
        let buttonSpacing: CGFloat = 2
        let panelPadding: CGFloat = 6
        let buttonCount: CGFloat = 3
        let panelWidth = buttonCount * buttonSize + (buttonCount - 1) * buttonSpacing + panelPadding * 2
        let panelHeight: CGFloat = 34

        // Position below the preview window, right-aligned
        let panelX = previewFrame.origin.x + previewFrame.width - panelWidth
        let panelY = previewFrame.origin.y - panelHeight - 6

        let panel = NSPanel(
            contentRect: NSRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar + 1
        panel.isOpaque = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 6
        bg.layer?.masksToBounds = true

        let buttonY = (panelHeight - buttonSize) / 2
        var x = panelPadding

        // Save button
        let saveBtn = HoverIconButton(
            frame: NSRect(x: x, y: buttonY, width: buttonSize, height: buttonSize),
            symbolName: "square.and.arrow.down",
            tooltip: "Save Image"
        )
        saveBtn.onPress = { [weak self] in self?.saveResult() }
        bg.addSubview(saveBtn)
        x += buttonSize + buttonSpacing

        // Cancel button
        let cancelBtn = HoverIconButton(
            frame: NSRect(x: x, y: buttonY, width: buttonSize, height: buttonSize),
            symbolName: "xmark",
            tooltip: "Cancel"
        )
        cancelBtn.onPress = { [weak self] in self?.cancel() }
        bg.addSubview(cancelBtn)
        x += buttonSize + buttonSpacing

        // Copy button (rightmost)
        let copyBtn = HoverIconButton(
            frame: NSRect(x: x, y: buttonY, width: buttonSize, height: buttonSize),
            symbolName: "doc.on.doc",
            tooltip: "Copy & Done"
        )
        copyBtn.onPress = { [weak self] in self?.copyResult() }
        bg.addSubview(copyBtn)

        panel.contentView = bg
        panel.orderFront(nil)
        self.actionPanel = panel


    }

    // MARK: - Hint Window

    /// A floating label above the capture border showing scroll direction guidance.
    private func setupHintWindow() {
        let hintText = "Scroll up or down to start capturing"
        let hintHeight: CGFloat = 28
        let hintPadding: CGFloat = 16

        // Measure text width
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let textSize = (hintText as NSString).size(withAttributes: [.font: font])
        let hintWidth = textSize.width + hintPadding * 2

        // Position: horizontally centered above the capture rect
        let hintX = captureRect.midX - hintWidth / 2
        let hintY = captureRect.maxY + 30  // 30pt gap above the border to avoid being captured

        let window = NSWindow(
            contentRect: NSRect(x: hintX, y: hintY, width: hintWidth, height: hintHeight),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.level = .statusBar + 1
        window.isOpaque = false
        window.hasShadow = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.animationBehavior = .none

        let container = NSView(frame: NSRect(x: 0, y: 0, width: hintWidth, height: hintHeight))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.0, alpha: 0.85).cgColor
        container.layer?.cornerRadius = 6
        container.layer?.masksToBounds = true

        let label = NSTextField(labelWithString: hintText)
        label.font = font
        label.textColor = .white
        label.alignment = .center
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        // Vertically center the label by calculating the y offset
        let textHeight = font.ascender - font.descender + font.leading
        let labelY = (hintHeight - textHeight) / 2
        label.frame = NSRect(x: 0, y: labelY, width: hintWidth, height: textHeight)
        label.lineBreakMode = .byTruncatingTail
        container.addSubview(label)

        window.contentView = container
        window.orderFront(nil)

        self.hintWindow = window
        self.hintLabel = label
    }

    /// Update the hint text when the scroll direction is locked.
    private func updateHintForDirection(_ direction: StitchingManager.ScrollDirection) {
        guard let hintLabel = hintLabel, let hintWindow = hintWindow else { return }

        let newText: String
        switch direction {
        case .down:
            newText = "Continue scrolling down to capture more"
        case .up:
            newText = "Continue scrolling up to capture more"
        case .unknown:
            newText = "Scroll up or down to start capturing"
        }

        // Update text
        hintLabel.stringValue = newText

        // Resize window to fit new text
        let font = hintLabel.font ?? NSFont.systemFont(ofSize: 13, weight: .medium)
        let hintPadding: CGFloat = 16
        let textSize = (newText as NSString).size(withAttributes: [.font: font])
        let newWidth = textSize.width + hintPadding * 2
        let hintHeight = hintWindow.frame.height

        var frame = hintWindow.frame
        frame.origin.x = captureRect.midX - newWidth / 2
        frame.size.width = newWidth
        hintWindow.setFrame(frame, display: false)

        // Also resize the container and label
        if let container = hintWindow.contentView {
            container.frame = NSRect(x: 0, y: 0, width: newWidth, height: hintHeight)
            let textHeight = font.ascender - font.descender + font.leading
            let labelY = (hintHeight - textHeight) / 2
            hintLabel.frame = NSRect(x: 0, y: labelY, width: newWidth, height: textHeight)
        }

        hintWindow.display()
    }

    // MARK: - Preview Update

    private func updatePreview(with image: NSImage) {
        guard let previewWindow = previewWindow,
              let imageView = previewImageView else { return }

        imageView.image = image

        // Resize preview window to reflect the growing image
        // Maintain the preview width, adjust height based on aspect ratio
        let aspectRatio = image.size.height / image.size.width
        let desiredHeight = min(previewWidth * aspectRatio, previewMaxHeight)

        // Keep the preview vertically centered on the capture rect's midline
        let captureMidY = captureRect.midY
        var frame = previewWindow.frame
        frame.size.height = desiredHeight
        frame.origin.y = captureMidY - desiredHeight / 2

        // Clamp to screen bounds
        let screenFrame = screen.frame
        if frame.origin.y < screenFrame.origin.y + 10 {
            frame.origin.y = screenFrame.origin.y + 10
        }
        if frame.maxY > screenFrame.maxY - 10 {
            frame.origin.y = screenFrame.maxY - 10 - desiredHeight
        }

        previewWindow.setFrame(frame, display: true, animate: false)

        // Reposition action panel below the preview
        repositionActionPanel()
    }

    private func repositionActionPanel() {
        guard let previewFrame = previewWindow?.frame,
              let panel = actionPanel else { return }

        var panelFrame = panel.frame
        panelFrame.origin.x = previewFrame.origin.x + previewFrame.width - panelFrame.width
        panelFrame.origin.y = previewFrame.origin.y - panelFrame.height - 6
        panel.setFrame(panelFrame, display: true, animate: false)
    }

    // MARK: - Actions

    private func copyResult() {
        guard let image = stitcher.stitchedImage else {
            logMessage("[ScrollCapture] No stitched image to copy.")
            cancel()
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        logMessage("[ScrollCapture] Stitched image copied to clipboard. Height: \(Int(stitcher.stitchedPixelHeight))px")

        stop()
        onFinish?()
    }

    private func saveResult() {
        guard let image = stitcher.stitchedImage else {
            logMessage("[ScrollCapture] No stitched image to save.")
            cancel()
            return
        }

        // Pause capture while save panel is open
        captureTimer?.invalidate()
        captureTimer = nil

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.png]
        savePanel.nameFieldStringValue = "Snipshot_Scroll_\(Int(Date().timeIntervalSince1970)).png"
        savePanel.canCreateDirectories = true
        savePanel.level = .statusBar + 2

        savePanel.begin { [weak self] response in
            guard let self = self else { return }
            if response == .OK, let url = savePanel.url {
                if let tiffData = image.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiffData),
                   let pngData = bitmap.representation(using: .png, properties: [:]) {
                    try? pngData.write(to: url)
                    logMessage("[ScrollCapture] Stitched image saved to \(url.path)")
                }
                self.stop()
                self.onFinish?()
            } else {
                // User cancelled save — resume capture
                self.captureTimer = Timer.scheduledTimer(withTimeInterval: self.captureInterval, repeats: true) { [weak self] _ in
                    self?.captureFrame()
                }
            }
        }
    }

    private func cancel() {
        logMessage("[ScrollCapture] Cancelled by user.")
        stop()
        onFinish?()
    }


}

// MARK: - Dashed Border View

/// Draws an animated dashed border to indicate the capture region.
/// The border is drawn in the outer margin area so it stays outside the capture rect.
private class DashedBorderView: NSView {

    private let margin: CGFloat
    private let strokeWidth: CGFloat
    private var dashPhase: CGFloat = 0
    private var animationTimer: Timer?

    init(frame: NSRect, margin: CGFloat, strokeWidth: CGFloat) {
        self.margin = margin
        self.strokeWidth = strokeWidth
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        // Animate the marching ants
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.dashPhase += 1
            self.needsDisplay = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        animationTimer?.invalidate()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // The stroke is centered on the rect edge. We want the stroke to be
        // entirely in the margin area (outside the capture rect).
        // The capture rect starts at (margin, margin) in view coords.
        // We offset outward by half the stroke width so the inner edge of the
        // stroke exactly touches the capture rect boundary.
        let halfStroke = strokeWidth / 2
        let strokeRect = NSRect(
            x: margin - halfStroke,
            y: margin - halfStroke,
            width: bounds.width - 2 * (margin - halfStroke),
            height: bounds.height - 2 * (margin - halfStroke)
        )

        context.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.8).cgColor)
        context.setLineWidth(strokeWidth)
        context.setLineDash(phase: dashPhase, lengths: [6, 4])
        context.stroke(strokeRect)
    }
}
