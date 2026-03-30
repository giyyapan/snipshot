import Cocoa
import VisionKit

// MARK: - OverlayView Translate Mode
extension OverlayView {

    func enterTranslateMode() {
        guard hasSelection else { return }

        // Check if API key is configured
        guard TranslateSettings.isConfigured else {
            showTranslateNotConfiguredAlert()
            return
        }

        guard let croppedImage = cropImage() else {
            logMessage("Translate: cropImage returned nil")
            return
        }

        logMessage("Translate: starting translation...")

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

        // Show the result window in "Preparing image" phase
        let resultWindow = TranslateResultWindow(near: screenSelectionRect, screenFrame: screenFrame)
        resultWindow.orderFront(nil)
        let holder = TranslateResultWindowHolder.shared
        holder.window = resultWindow

        // Wire up language change callback for re-translation
        resultWindow.onLanguageChanged = { [weak resultWindow] newLanguage in
            guard let resultWindow = resultWindow else { return }
            // Cancel current request and re-translate with cached data
            TranslateService.shared.cancelCurrentRequest()
            Self.retranslate(resultWindow: resultWindow, newLanguage: newLanguage)
        }

        // Run the pipeline in background
        Task { @MainActor in
            // Phase 1: Prepare image (compress for API)
            let imageDataURL = await Task.detached(priority: .userInitiated) {
                return AIService.shared.prepareImageDataURL(from: croppedImage)
            }.value

            // Cache the image data URL
            holder.cachedImageDataURL = imageDataURL

            // Phase 2: OCR
            resultWindow.showPhase("Recognizing text")
            let ocrText: String
            do {
                let configuration = ImageAnalyzer.Configuration([.text])
                let analysis = try await imageAnalyzer.analyze(croppedImage, orientation: .up, configuration: configuration)
                ocrText = analysis.transcript
                logMessage("Translate: OCR complete, \(ocrText.count) chars")
            } catch {
                logMessage("Translate: OCR failed: \(error.localizedDescription)")
                resultWindow.showError("OCR failed: \(error.localizedDescription)")
                return
            }

            if ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                resultWindow.showError("No text recognized in the selected area.")
                return
            }

            // Cache the OCR text
            holder.cachedOCRText = ocrText

            // Phase 3: Send to AI (streaming)
            resultWindow.showPhase("Thinking")

            TranslateService.shared.translateStreaming(
                text: ocrText,
                imageDataURL: imageDataURL,
                onPhase: { phase in
                    resultWindow.showPhase(phase)
                },
                onChunk: { accumulated in
                    resultWindow.updateContent(accumulated)
                },
                completion: { result in
                    switch result {
                    case .success(let translated):
                        resultWindow.showResult(translated)
                    case .failure(let error):
                        resultWindow.showError(error.localizedDescription)
                    }
                }
            )
        }
    }

    /// Re-translate using cached OCR text and image data URL with a new target language.
    static func retranslate(resultWindow: TranslateResultWindow, newLanguage: String) {
        let holder = TranslateResultWindowHolder.shared
        guard let ocrText = holder.cachedOCRText, !ocrText.isEmpty else {
            logMessage("Translate: no cached OCR text for re-translation")
            resultWindow.showError("No cached text. Please take a new screenshot.")
            return
        }

        logMessage("Translate: re-translating to \(newLanguage)")
        resultWindow.showPhase("Thinking")

        TranslateService.shared.translateStreaming(
            text: ocrText,
            imageDataURL: holder.cachedImageDataURL,
            onPhase: { phase in
                resultWindow.showPhase(phase)
            },
            onChunk: { accumulated in
                resultWindow.updateContent(accumulated)
            },
            completion: { result in
                switch result {
                case .success(let translated):
                    resultWindow.showResult(translated)
                case .failure(let error):
                    resultWindow.showError(error.localizedDescription)
                }
            }
        )
    }

    private func showTranslateNotConfiguredAlert() {
        let alert = NSAlert()
        alert.messageText = "Translation Not Configured"
        alert.informativeText = "Please configure an API key in Settings to use translation."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")

        onAction(.cancel)

        DispatchQueue.main.async {
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                NotificationCenter.default.post(name: NSNotification.Name("OpenSettingsForTranslation"), object: nil)
            }
        }
    }
}
