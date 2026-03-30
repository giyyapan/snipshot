import Cocoa

// MARK: - Translate Result Window
/// A thin wrapper that creates an AIResultWindow configured for translation,
/// with a language picker widget in the title bar.
class TranslateResultWindow {

    let aiWindow: AIResultWindow
    private var languageButton: NSPopUpButton!

    /// Called when user changes the target language.
    var onLanguageChanged: ((String) -> Void)?

    init(near selectionRect: NSRect, screenFrame: NSRect) {
        let config = AIResultWindowConfig(
            title: "Translate to",
            savedWidthKey: "translateResultWindowWidth",
            savedHeightKey: "translateResultWindowHeight",
            onDismiss: {
                TranslateService.shared.cancelCurrentRequest()
                TranslateResultWindowHolder.shared.clear()
            }
        )

        aiWindow = AIResultWindow(near: selectionRect, screenFrame: screenFrame, config: config)
        setupLanguagePicker()
    }

    // MARK: - Language Picker

    private func setupLanguagePicker() {
        let container = aiWindow.widgetContainer!
        let popupH: CGFloat = 24
        languageButton = NSPopUpButton(frame: NSRect(x: 0, y: (32 - popupH) / 2, width: 160, height: popupH), pullsDown: false)
        languageButton.bezelStyle = .inline
        languageButton.isBordered = false
        languageButton.font = .systemFont(ofSize: 12, weight: .semibold)
        (languageButton.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
        languageButton.autoresizingMask = []
        rebuildLanguageMenu()
        container.addSubview(languageButton)
    }

    private func rebuildLanguageMenu() {
        languageButton.removeAllItems()
        let recent = TranslateSettings.recentLanguages
        let current = TranslateSettings.targetLanguage

        for lang in recent {
            languageButton.addItem(withTitle: lang)
        }

        languageButton.menu?.addItem(NSMenuItem.separator())

        for lang in TranslateSettings.availableLanguages where !recent.contains(lang) {
            languageButton.addItem(withTitle: lang)
        }

        languageButton.selectItem(withTitle: current)

        languageButton.target = self
        languageButton.action = #selector(languageSelected(_:))
    }

    @objc private func languageSelected(_ sender: NSPopUpButton) {
        guard let selected = sender.titleOfSelectedItem else { return }
        let previous = TranslateSettings.targetLanguage
        guard selected != previous else { return }

        TranslateSettings.targetLanguage = selected
        TranslateSettings.markLanguageUsed(selected)

        rebuildLanguageMenu()

        logMessage("Translate: language changed to \(selected)")
        onLanguageChanged?(selected)
    }

    // MARK: - Forwarding to AIResultWindow

    func orderFront(_ sender: Any?) { aiWindow.orderFront(sender) }
    func showPhase(_ text: String) { aiWindow.showPhase(text) }
    func showError(_ message: String) { aiWindow.showError(message) }
    func updateContent(_ markdown: String) { aiWindow.updateContent(markdown) }
    func showResult(_ markdown: String) { aiWindow.showResult(markdown) }
}

// MARK: - Translate Result Window Holder
class TranslateResultWindowHolder {
    static let shared = TranslateResultWindowHolder()
    var window: TranslateResultWindow?
    var cachedOCRText: String?
    var cachedImageDataURL: String?
    private init() {}

    func clear() {
        window = nil
        cachedOCRText = nil
        cachedImageDataURL = nil
    }
}
