import Cocoa
import VisionKit

// MARK: - OCR Result Window Holder
/// Keeps a strong reference to the OCR result window after overlay is dismissed.
class OCRResultWindowHolder {
    static let shared = OCRResultWindowHolder()
    var window: OCRResultWindow?
    var refineWindow: AIResultWindow?
    var cachedImageDataURL: String?
    private init() {}

    func clear() {
        window = nil
        refineWindow?.dismissWindow()
        refineWindow = nil
        cachedImageDataURL = nil
    }
}

// MARK: - OCR Result Window
/// A floating window that displays the cropped image at original size with VisionKit text selection.
/// AI Refine spawns a separate AIResultWindow to the right, showing results side-by-side.
class OCRResultWindow: NSPanel, NSWindowDelegate {

    // Title bar
    private var titleBar: NSView!
    private var titleLabel: NSTextField!
    private var closeButton: NSButton!
    private var copyButton: NSButton!
    private var refineButton: NSButton!
    private var refineSpinner: NSProgressIndicator?

    // Image + VisionKit overlay
    private var imageContainer: NSView!
    private var imageView: NSImageView!
    private var ocrOverlay: ImageAnalysisOverlayView!


    // State
    private var croppedImage: NSImage?
    private var ocrAnalysis: ImageAnalysis?
    private var currentText: String = ""
    private var isRefining = false

    init(near selectionRect: NSRect, screenFrame: NSRect, image: NSImage) {
        self.croppedImage = image

        let titleBarH: CGFloat = 32

        // Use the actual image pixel size for the window, clamped to screen bounds
        let imgW = image.size.width
        let imgH = image.size.height

        // Clamp to screen with some margin
        let maxW = screenFrame.width * 0.7
        let maxH = screenFrame.height * 0.8 - titleBarH
        let scale = min(1.0, min(maxW / imgW, maxH / imgH))
        let windowWidth = ceil(imgW * scale)
        let contentH = ceil(imgH * scale)
        let windowHeight = contentH + titleBarH

        // Position: align the image area's top edge with the selection's top edge.
        // In NS coords (bottom-left origin): selection top = selectionRect.origin.y + selectionRect.height
        // Image area occupies [windowY, windowY + contentH], title bar sits above.
        // So: windowY + contentH = selectionTop => windowY = selectionTop - contentH
        var windowX = selectionRect.origin.x
        var windowY = selectionRect.origin.y + selectionRect.height - contentH

        // Adjust if it goes off-screen
        if windowX + windowWidth > screenFrame.maxX - 10 {
            windowX = screenFrame.maxX - windowWidth - 10
        }
        if windowX < screenFrame.minX + 10 {
            windowX = screenFrame.minX + 10
        }
        if windowY < screenFrame.minY + 10 {
            windowY = screenFrame.minY + 10
        }
        if windowY + windowHeight > screenFrame.maxY - 10 {
            windowY = screenFrame.maxY - windowHeight - 10
        }

        let rect = NSRect(x: windowX, y: windowY, width: windowWidth, height: windowHeight)

        super.init(
            contentRect: rect,
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.isOpaque = false
        self.hasShadow = true
        self.backgroundColor = .clear
        self.isMovableByWindowBackground = true
        self.isReleasedWhenClosed = false
        self.hidesOnDeactivate = false
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.delegate = self

        self.standardWindowButton(.closeButton)?.isHidden = true
        self.standardWindowButton(.miniaturizeButton)?.isHidden = true
        self.standardWindowButton(.zoomButton)?.isHidden = true

        setupUI()
    }

    override var canBecomeKey: Bool { true }

    // MARK: - Setup

    private func setupUI() {
        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.98, alpha: 0.96).cgColor
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 0.5
        container.layer?.borderColor = NSColor(white: 0.8, alpha: 1.0).cgColor
        container.autoresizingMask = [.width, .height]

        let w = frame.width
        let h = frame.height
        let titleBarH: CGFloat = 32

        // --- Title bar ---
        titleBar = NSView(frame: NSRect(x: 0, y: h - titleBarH, width: w, height: titleBarH))
        titleBar.wantsLayer = true
        titleBar.layer?.backgroundColor = NSColor(white: 0.94, alpha: 1.0).cgColor
        titleBar.autoresizingMask = [.width, .minYMargin]

        titleLabel = NSTextField(labelWithString: "OCR Result")
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.sizeToFit()
        let titleLabelH = ceil(titleLabel.frame.height)
        titleLabel.frame = NSRect(x: 10, y: (titleBarH - titleLabelH) / 2, width: titleLabel.frame.width, height: titleLabelH)
        titleBar.addSubview(titleLabel)

        // Close button
        closeButton = NSButton(frame: NSRect(x: w - 28, y: 4, width: 24, height: 24))
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(dismissWindow)
        closeButton.autoresizingMask = [.minXMargin]
        titleBar.addSubview(closeButton)

        // Copy button
        copyButton = NSButton(frame: NSRect(x: w - 52, y: 4, width: 24, height: 24))
        copyButton.bezelStyle = .inline
        copyButton.isBordered = false
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy All")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        copyButton.contentTintColor = .secondaryLabelColor
        copyButton.target = self
        copyButton.action = #selector(copyText)
        copyButton.toolTip = "Copy All  \u{2318}C"
        copyButton.autoresizingMask = [.minXMargin]
        titleBar.addSubview(copyButton)

        // AI Refine button
        refineButton = NSButton(frame: NSRect(x: w - 76, y: 4, width: 24, height: 24))
        refineButton.bezelStyle = .inline
        refineButton.isBordered = false
        refineButton.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: "AI Refine")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        refineButton.contentTintColor = .tertiaryLabelColor
        refineButton.target = self
        refineButton.action = #selector(aiRefine)
        refineButton.toolTip = "AI Refine"
        refineButton.isEnabled = false  // enabled after OCR completes
        refineButton.autoresizingMask = [.minXMargin]
        titleBar.addSubview(refineButton)

        container.addSubview(titleBar)

        let contentFrame = NSRect(x: 0, y: 0, width: w, height: h - titleBarH)

        // --- Image container with VisionKit overlay ---
        imageContainer = NSView(frame: contentFrame)
        imageContainer.autoresizingMask = [.width, .height]
        imageContainer.wantsLayer = true

        imageView = NSImageView(frame: imageContainer.bounds)
        imageView.image = croppedImage
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        imageView.wantsLayer = true
        imageContainer.addSubview(imageView)

        ocrOverlay = ImageAnalysisOverlayView(frame: imageView.bounds)
        ocrOverlay.autoresizingMask = [.width, .height]
        ocrOverlay.trackingImageView = imageView
        ocrOverlay.preferredInteractionTypes = .textSelection
        ocrOverlay.isSupplementaryInterfaceHidden = true
        imageView.addSubview(ocrOverlay)

        container.addSubview(imageContainer)

        self.contentView = container
    }

    // MARK: - Public API

    /// Show error in the title bar.
    func showError(_ message: String) {
        hideRefineSpinner()
        titleLabel.stringValue = message
        titleLabel.textColor = .systemRed
        titleLabel.sizeToFit()
    }

    /// Show the VisionKit analysis overlay on top of the already-visible image.
    func showAnalysis(_ analysis: ImageAnalysis) {
        ocrAnalysis = analysis
        currentText = analysis.transcript

        ocrOverlay.analysis = analysis
        ocrOverlay.selectableItemsHighlighted = true

        // Enable AI Refine button
        let canRefine = AISettings.isConfigured
        refineButton.isEnabled = canRefine
        refineButton.contentTintColor = canRefine ? .secondaryLabelColor : .tertiaryLabelColor

        titleLabel.stringValue = "OCR Result"
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.sizeToFit()
    }

    // MARK: - Refine Spinner

    private func showRefineSpinner() {
        if refineSpinner == nil {
            let spinner = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isIndeterminate = true
            refineSpinner = spinner
        }
        guard let spinner = refineSpinner else { return }

        // Replace refine button icon with spinner
        refineButton.image = nil
        refineButton.isEnabled = false

        // Position spinner where refine button is
        let btnFrame = refineButton.frame
        spinner.frame = NSRect(
            x: btnFrame.midX - 8,
            y: btnFrame.midY - 8,
            width: 16,
            height: 16
        )
        titleBar.addSubview(spinner)
        spinner.startAnimation(nil)
    }

    private func hideRefineSpinner() {
        refineSpinner?.stopAnimation(nil)
        refineSpinner?.removeFromSuperview()

        // Restore refine button icon
        refineButton.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: "AI Refine")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        refineButton.isEnabled = true
        refineButton.contentTintColor = .secondaryLabelColor
    }

    // MARK: - Actions

    @objc private func dismissWindow() {
        AIService.shared.cancelCurrentRequest()
        orderOut(nil)
        OCRResultWindowHolder.shared.clear()
    }

    @objc private func copyText() {
        // Copy selected text from VisionKit overlay, or all text if nothing selected
        let selectedText = ocrOverlay?.selectedText ?? ""
        let textToCopy = selectedText.isEmpty ? currentText : selectedText
        guard !textToCopy.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(textToCopy, forType: .string)
        logMessage("OCR: copied text to clipboard (\(textToCopy.count) chars)")
        showCopyFeedback()
    }

    @objc func aiRefine() {
        guard !currentText.isEmpty else { return }
        guard AISettings.isConfigured else {
            showError("API key is not configured. Please set it in Settings.")
            return
        }

        isRefining = true

        // Show spinner on the refine button (image stays visible)
        showRefineSpinner()

        let ocrText = currentText
        let imageDataURL = OCRResultWindowHolder.shared.cachedImageDataURL

        let systemPrompt = OCRRefineSettings.systemPrompt

        let systemMessage = AIMessage.text(role: .system, content: systemPrompt)

        let userMessage: AIMessage
        if let dataURL = imageDataURL {
            userMessage = AIMessage.multimodal(
                role: .user,
                text: "OCR extracted text:\n\(ocrText)",
                imageDataURL: dataURL
            )
        } else {
            userMessage = AIMessage.text(role: .user, content: "OCR extracted text:\n\(ocrText)")
        }

        // Spawn AIResultWindow to the right of this OCR window
        let screenFrame = self.screen?.frame ?? NSScreen.main?.frame ?? .zero
        let myFrame = self.frame
        let anchorRect = NSRect(x: myFrame.maxX, y: myFrame.origin.y, width: 0, height: myFrame.height)

        let config = AIResultWindowConfig(
            title: "AI Refined",
            savedWidthKey: "ocrRefineWindowWidth",
            savedHeightKey: "ocrRefineWindowHeight",
            onDismiss: {
                AIService.shared.cancelCurrentRequest()
                OCRResultWindowHolder.shared.refineWindow = nil
            }
        )

        let refineWindow = AIResultWindow(near: anchorRect, screenFrame: screenFrame, config: config)
        refineWindow.showPhase("Refining")
        refineWindow.orderFront(nil)
        AIResultWindowHolder.shared.track(refineWindow)
        OCRResultWindowHolder.shared.refineWindow = refineWindow

        AIService.shared.streamChat(
            messages: [systemMessage, userMessage],
            temperature: 0.2,
            logPrefix: "OCR-Refine",
            onChunk: { [weak self, weak refineWindow] accumulated in
                self?.hideRefineSpinner()
                refineWindow?.updateContent(accumulated)
            },
            completion: { [weak self, weak refineWindow] result in
                self?.hideRefineSpinner()
                self?.isRefining = false
                switch result {
                case .success(let refined):
                    refineWindow?.showResult(refined)
                case .failure(let error):
                    refineWindow?.showError(error.localizedDescription)
                }
            }
        )
    }

    private func showCopyFeedback() {
        copyButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        copyButton.contentTintColor = .systemGreen
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
            self?.copyButton.contentTintColor = .secondaryLabelColor
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            dismissWindow()
        } else if event.keyCode == 8 && event.modifierFlags.contains(.command) {
            copyText()
        } else {
            super.keyDown(with: event)
        }
    }
}
