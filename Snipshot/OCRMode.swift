import Cocoa
import VisionKit

// MARK: - OverlayView OCR Mode
extension OverlayView {

    func enterOCRMode() {
        guard hasSelection else { return }
        guard ImageAnalyzer.isSupported else {
            logMessage("ImageAnalyzer is not supported on this device.")
            return
        }

        // Crop the selected region
        guard let croppedImage = cropImage() else { return }

        mode = .ocrMode
        annoState.currentTool = nil
        annoState.selectedElementId = nil

        // Remove existing panels
        removeAllPanels()

        // Create an NSImageView to host the cropped image at the selection rect
        let imgView = NSImageView(frame: selectionRect)
        imgView.image = croppedImage
        imgView.imageScaling = .scaleAxesIndependently
        imgView.wantsLayer = true
        addSubview(imgView)
        ocrImageView = imgView

        // Create the VisionKit overlay
        let overlay = ImageAnalysisOverlayView(frame: imgView.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.trackingImageView = imgView
        overlay.preferredInteractionTypes = .textSelection
        overlay.isSupplementaryInterfaceHidden = true
        imgView.addSubview(overlay)
        ocrOverlayView = overlay

        // Show OCR panel
        showOCRPanel()

        // Analyze the image
        Task { @MainActor in
            do {
                let configuration = ImageAnalyzer.Configuration([.text])
                let analysis = try await imageAnalyzer.analyze(croppedImage, orientation: .up, configuration: configuration)
                overlay.analysis = analysis
                logMessage("OCR analysis complete. Found text: \(analysis.transcript.prefix(100))")
                // Highlight all text to indicate recognition is done
                overlay.selectableItemsHighlighted = true
            } catch {
                logMessage("OCR analysis failed: \(error.localizedDescription)")
            }
        }

        needsDisplay = true
    }

    func exitOCRMode() {
        ocrOverlayView?.removeFromSuperview()
        ocrOverlayView = nil
        ocrImageView?.removeFromSuperview()
        ocrImageView = nil
        ocrPanelView?.removeFromSuperview()
        ocrPanelView = nil
    }

    func showOCRPanel() {
        let btnSize: CGFloat = 26
        let padding: CGFloat = 6
        let spacing: CGFloat = 2

        let totalWidth = padding + btnSize + spacing + btnSize + padding
        let h: CGFloat = 30

        let x = selectionRect.origin.x + selectionRect.width - totalWidth
        let y = panelYPosition()

        let panel = NSView(frame: NSRect(x: x, y: y, width: totalWidth, height: h))
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor(white: 0.95, alpha: 0.92).cgColor
        panel.layer?.cornerRadius = 6; panel.layer?.masksToBounds = true

        let by = (h - btnSize) / 2
        var bx = padding

        // Copy All button (doc.on.doc icon)
        let copyAllBtn = HoverIconButton(frame: NSRect(x: bx, y: by, width: btnSize, height: btnSize), symbolName: "doc.on.doc", tooltip: "Copy All  \u{2318}C")
        copyAllBtn.onPress = { [weak self] in self?.ocrCopyAll() }
        panel.addSubview(copyAllBtn)
        bx += btnSize + spacing

        // Done button (checkmark icon)
        let doneBtn = HoverIconButton(frame: NSRect(x: bx, y: by, width: btnSize, height: btnSize), symbolName: "checkmark", tooltip: "Done  Esc")
        doneBtn.onPress = { [weak self] in self?.ocrDone() }
        panel.addSubview(doneBtn)

        addSubview(panel)
        ocrPanelView = panel
    }

    func ocrCopyAll() {
        guard let overlay = ocrOverlayView else { return }
        let allText = overlay.text
        if !allText.isEmpty {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(allText, forType: .string)
            logMessage("OCR: Copied all text to clipboard (\(allText.count) chars).")
        }
        // Exit after copying all
        exitOCRMode()
        onAction(.cancel)
    }

    func ocrDone() {
        exitOCRMode()
        onAction(.cancel)
    }

    func ocrCopySelectedOrAll() {
        guard let overlay = ocrOverlayView else { return }
        let selectedText = overlay.selectedText
        let textToCopy = selectedText.isEmpty ? overlay.text : selectedText
        if !textToCopy.isEmpty {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(textToCopy, forType: .string)
            logMessage("OCR: Copied text to clipboard (\(textToCopy.count) chars).")
        }
    }
}
