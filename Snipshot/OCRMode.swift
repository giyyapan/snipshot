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

        logMessage("OCR: starting recognition...")

        // Calculate screen position before dismissing overlay
        let screenFrame = window?.screen?.frame ?? NSScreen.main?.frame ?? .zero
        let windowOrigin = window?.frame.origin ?? .zero
        let screenSelectionRect = NSRect(
            x: selectionRect.origin.x + windowOrigin.x,
            y: selectionRect.origin.y + windowOrigin.y,
            width: selectionRect.width,
            height: selectionRect.height
        )

        // Dismiss overlay first
        onAction(.cancel)

        // Show the result window with the image immediately (OCR highlights appear when ready)
        let resultWindow = OCRResultWindow(near: screenSelectionRect, screenFrame: screenFrame, image: croppedImage)
        resultWindow.orderFront(nil)
        let holder = OCRResultWindowHolder.shared
        holder.window = resultWindow

        // Prepare image data URL for AI refine in background
        Task.detached(priority: .utility) {
            let dataURL = AIService.shared.prepareImageDataURL(from: croppedImage)
            await MainActor.run {
                holder.cachedImageDataURL = dataURL
            }
        }

        // Run OCR analysis
        Task { @MainActor in
            do {
                let configuration = ImageAnalyzer.Configuration([.text])
                let analysis = try await imageAnalyzer.analyze(croppedImage, orientation: .up, configuration: configuration)
                let ocrText = analysis.transcript
                logMessage("OCR: recognition complete, \(ocrText.count) chars")

                if ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    resultWindow.showError("No text recognized in the selected area.")
                    return
                }

                resultWindow.showAnalysis(analysis)
            } catch {
                logMessage("OCR: recognition failed: \(error.localizedDescription)")
                resultWindow.showError("OCR failed: \(error.localizedDescription)")
            }
        }
    }

    /// Quick OCR: recognize all text in the selection, copy to clipboard, and close overlay.
    func ocrCopyAllAndDone() {
        guard hasSelection else { return }
        guard ImageAnalyzer.isSupported else {
            logMessage("ImageAnalyzer is not supported on this device.")
            return
        }

        // Auto-commit any uncommitted text editing
        if case .editingText = mode {
            commitTextEditing()
            mode = .annotating
        }

        guard let croppedImage = cropImage() else { return }

        logMessage("OCR quick copy: starting recognition...")

        // Run OCR and copy result, then dismiss
        Task { @MainActor in
            do {
                let configuration = ImageAnalyzer.Configuration([.text])
                let analysis = try await imageAnalyzer.analyze(croppedImage, orientation: .up, configuration: configuration)
                let ocrText = analysis.transcript
                logMessage("OCR quick copy: \(ocrText.count) chars recognized")

                if ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    logMessage("OCR quick copy: no text found")
                } else {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(ocrText, forType: .string)
                    logMessage("OCR quick copy: text copied to clipboard")
                }
            } catch {
                logMessage("OCR quick copy failed: \(error.localizedDescription)")
            }
            // Dismiss overlay regardless of result
            onAction(.cancel)
        }
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
        // Legacy: kept for compatibility but no longer used in new flow
    }

    func ocrCopyAll() {
        // Legacy: kept for compatibility
    }

    func ocrDone() {
        // Legacy: kept for compatibility
    }

    func ocrCopySelectedOrAll() {
        // Legacy: kept for compatibility
    }
}
