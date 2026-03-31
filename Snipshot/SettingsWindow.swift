import Cocoa
import Carbon.HIToolbox
import ServiceManagement

let kSnipshotVersion = "0.5.0"

// MARK: - Hotkey Configuration

struct HotkeyConfig: Equatable {
    var keyCode: UInt16
    var modifiers: NSEvent.ModifierFlags

    var displayString: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        parts.append(keyCodeToString(keyCode))
        return parts.joined()
    }

    static let defaultCapture = HotkeyConfig(keyCode: 122, modifiers: []) // F1

    private func keyCodeToString(_ code: UInt16) -> String {
        let fnKeys: [UInt16: String] = [
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"
        ]
        if let fn = fnKeys[code] { return fn }

        let charKeys: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L",
            38: "J", 40: "K", 45: "N", 46: "M",
            18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6",
            26: "7", 28: "8", 25: "9", 29: "0",
            49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 53: "Esc"
        ]
        return charKeys[code] ?? "Key(\(code))"
    }
}

// MARK: - Settings Window (Tabbed)

class SettingsWindow: NSWindow {
    private var tabView: NSTabView!
    private var hotkeyField: HotkeyRecorderField!
    private var currentConfig: HotkeyConfig
    var onHotkeyChanged: ((HotkeyConfig) -> Void)?
    var onShowOnboarding: (() -> Void)?

    // Debug section views (for collapse/expand) — in General tab
    private var debugDisclosureButton: NSButton!
    private var debugContentViews: [NSView] = []
    private var debugIsExpanded = false

    // AI section fields
    private var aiStatusLabel: NSTextField!
    private var aiApiKeyField: RevealableSecureTextField!
    private var aiEndpointField: NSTextField!
    private var aiModelField: NSTextField!
    private var aiTestButton: NSButton!
    private var aiTestStatusLabel: NSTextField!

    // Translation section
    private var translateLanguagePopup: NSPopUpButton!

    // Translation prompt (always visible)
    private var translatePromptView: NSScrollView!
    private var translatePromptTextView: NSTextView!

    // OCR Refine prompt
    private var ocrRefinePromptView: NSScrollView!
    private var ocrRefinePromptTextView: NSTextView!

    init() {
        // Load saved hotkey or use default
        let savedKeyCode = UserDefaults.standard.object(forKey: "captureHotkeyKeyCode") as? UInt16
            ?? HotkeyConfig.defaultCapture.keyCode
        let savedModifiers = UserDefaults.standard.object(forKey: "captureHotkeyModifiers") as? UInt
            ?? HotkeyConfig.defaultCapture.modifiers.rawValue
        currentConfig = HotkeyConfig(keyCode: savedKeyCode, modifiers: NSEvent.ModifierFlags(rawValue: savedModifiers))

        // Migrate old keys
        AISettings.migrateIfNeeded()

        let width: CGFloat = 540
        let height: CGFloat = 560
        let screenFrame = NSScreen.main?.frame ?? .zero
        let rect = NSRect(
            x: (screenFrame.width - width) / 2,
            y: (screenFrame.height - height) / 2,
            width: width,
            height: height
        )
        super.init(
            contentRect: rect,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        self.title = "Snipshot Settings"
        self.level = .normal
        self.animationBehavior = .default
        self.isReleasedWhenClosed = false
        setupUI()
    }

    private func setupUI() {
        guard let contentView = self.contentView else { return }
        contentView.wantsLayer = true

        tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.tabViewType = .topTabsBezelBorder
        contentView.addSubview(tabView)

        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            tabView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            tabView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            tabView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])

        // Create tabs
        let generalTab = NSTabViewItem(identifier: "general")
        generalTab.label = "General"
        generalTab.view = buildGeneralTab()

        let aiTab = NSTabViewItem(identifier: "ai")
        aiTab.label = "AI"
        aiTab.view = buildAITab()

        let aboutTab = NSTabViewItem(identifier: "about")
        aboutTab.label = "About"
        aboutTab.view = buildAboutTab()

        tabView.addTabViewItem(generalTab)
        tabView.addTabViewItem(aiTab)
        tabView.addTabViewItem(aboutTab)
    }

    // MARK: - General Tab

    private func buildGeneralTab() -> NSView {
        let container = NSView()
        container.autoresizingMask = [.width, .height]

        let margin: CGFloat = 20
        let sectionGap: CGFloat = 16
        let itemGap: CGFloat = 8
        let descGap: CGFloat = 2

        // Capture Hotkey
        let hotkeyTitle = NSTextField(labelWithString: "Capture Hotkey")
        hotkeyTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        hotkeyTitle.textColor = .labelColor
        hotkeyTitle.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hotkeyTitle)

        hotkeyField = HotkeyRecorderField(config: currentConfig)
        hotkeyField.translatesAutoresizingMaskIntoConstraints = false
        hotkeyField.onConfigChanged = { [weak self] newConfig in
            self?.currentConfig = newConfig
            UserDefaults.standard.set(newConfig.keyCode, forKey: "captureHotkeyKeyCode")
            UserDefaults.standard.set(newConfig.modifiers.rawValue, forKey: "captureHotkeyModifiers")
            self?.onHotkeyChanged?(newConfig)
        }
        container.addSubview(hotkeyField)

        let resetButton = NSButton(title: "Reset to Default (F1)", target: self, action: #selector(resetHotkey))
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .regular
        resetButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(resetButton)

        // Separator 1
        let separator1 = NSBox()
        separator1.boxType = .separator
        separator1.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(separator1)

        // Auto-copy
        let autoCopyCheckbox = NSButton(checkboxWithTitle: "Auto-copy after selection",
                                         target: self, action: #selector(toggleAutoCopy(_:)))
        autoCopyCheckbox.state = UserDefaults.standard.bool(forKey: "autoCopyAfterSelection") ? .on : .off
        autoCopyCheckbox.controlSize = .regular
        autoCopyCheckbox.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(autoCopyCheckbox)

        let autoCopyDesc = NSTextField(labelWithString: "Automatically copy selection to clipboard when area is selected")
        autoCopyDesc.font = .systemFont(ofSize: 11, weight: .regular)
        autoCopyDesc.textColor = .secondaryLabelColor
        autoCopyDesc.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(autoCopyDesc)

        // Launch at login
        let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Launch at login",
                                              target: self, action: #selector(toggleLaunchAtLogin(_:)))
        launchAtLoginCheckbox.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        launchAtLoginCheckbox.controlSize = .regular
        launchAtLoginCheckbox.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(launchAtLoginCheckbox)

        let launchDesc = NSTextField(labelWithString: "Start Snipshot automatically when you log in")
        launchDesc.font = .systemFont(ofSize: 11, weight: .regular)
        launchDesc.textColor = .secondaryLabelColor
        launchDesc.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(launchDesc)

        // Double-click to close pin
        let dblClickCheckbox = NSButton(checkboxWithTitle: "Double-click to close pinned image",
                                         target: self, action: #selector(toggleDoubleClickClosePin(_:)))
        let dblClickDefault = UserDefaults.standard.object(forKey: "doubleClickToClosePin") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "doubleClickToClosePin")
        dblClickCheckbox.state = dblClickDefault ? .on : .off
        dblClickCheckbox.controlSize = .regular
        dblClickCheckbox.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(dblClickCheckbox)

        let dblClickDesc = NSTextField(labelWithString: "Double-click a pinned screenshot to dismiss it")
        dblClickDesc.font = .systemFont(ofSize: 11, weight: .regular)
        dblClickDesc.textColor = .secondaryLabelColor
        dblClickDesc.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(dblClickDesc)

        // Trackpad scroll as zoom
        let trackpadScrollCheckbox = NSButton(checkboxWithTitle: "Trackpad: use two-finger scroll for zoom",
                                               target: self, action: #selector(toggleTrackpadScrollZoom(_:)))
        trackpadScrollCheckbox.state = UserDefaults.standard.bool(forKey: "trackpadScrollAsZoom") ? .on : .off
        trackpadScrollCheckbox.controlSize = .regular
        trackpadScrollCheckbox.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(trackpadScrollCheckbox)

        let trackpadScrollDesc = NSTextField(labelWithString: "Enable this for Magic Mouse or if pinch-to-zoom is unavailable")
        trackpadScrollDesc.font = .systemFont(ofSize: 11, weight: .regular)
        trackpadScrollDesc.textColor = .secondaryLabelColor
        trackpadScrollDesc.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(trackpadScrollDesc)

        // Auto-switch to select after annotation
        let autoSwitchCheckbox = NSButton(checkboxWithTitle: "Switch to Select tool after adding annotation",
                                           target: self, action: #selector(toggleAutoSwitchToSelect(_:)))
        autoSwitchCheckbox.state = UserDefaults.standard.bool(forKey: "autoSwitchToSelectAfterAnnotation") ? .on : .off
        autoSwitchCheckbox.controlSize = .regular
        autoSwitchCheckbox.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(autoSwitchCheckbox)

        let autoSwitchDesc = NSTextField(labelWithString: "Automatically return to Select tool after drawing each annotation")
        autoSwitchDesc.font = .systemFont(ofSize: 11, weight: .regular)
        autoSwitchDesc.textColor = .secondaryLabelColor
        autoSwitchDesc.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(autoSwitchDesc)

        // Separator 2 (before debug)
        let separator2 = NSBox()
        separator2.boxType = .separator
        separator2.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(separator2)

        // Debug section (collapsible)
        debugDisclosureButton = NSButton(title: "Debug ▶", target: self, action: #selector(toggleDebugSection))
        debugDisclosureButton.bezelStyle = .inline
        debugDisclosureButton.isBordered = false
        debugDisclosureButton.font = .systemFont(ofSize: 11, weight: .regular)
        debugDisclosureButton.contentTintColor = .tertiaryLabelColor
        debugDisclosureButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(debugDisclosureButton)

        let onboardingCheckbox = NSButton(checkboxWithTitle: "Always show onboarding on launch",
                                          target: self, action: #selector(toggleAlwaysOnboarding(_:)))
        onboardingCheckbox.state = UserDefaults.standard.bool(forKey: "debugAlwaysShowOnboarding") ? .on : .off
        onboardingCheckbox.controlSize = .regular
        onboardingCheckbox.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(onboardingCheckbox)

        let showNowButton = NSButton(title: "Show Onboarding Now", target: self, action: #selector(showOnboardingNow))
        showNowButton.bezelStyle = .rounded
        showNowButton.controlSize = .regular
        showNowButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(showNowButton)

        let resetAllButton = NSButton(title: "Reset Everything & Quit", target: self, action: #selector(resetEverythingAndQuit))
        resetAllButton.bezelStyle = .rounded
        resetAllButton.controlSize = .regular
        resetAllButton.contentTintColor = .systemRed
        resetAllButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(resetAllButton)

        debugContentViews = [onboardingCheckbox, showNowButton, resetAllButton]

        NSLayoutConstraint.activate([
            // Hotkey
            hotkeyTitle.topAnchor.constraint(equalTo: container.topAnchor, constant: margin),
            hotkeyTitle.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),

            hotkeyField.centerYAnchor.constraint(equalTo: hotkeyTitle.centerYAnchor),
            hotkeyField.leadingAnchor.constraint(equalTo: hotkeyTitle.trailingAnchor, constant: 16),
            hotkeyField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),
            hotkeyField.heightAnchor.constraint(equalToConstant: 28),

            resetButton.topAnchor.constraint(equalTo: hotkeyTitle.bottomAnchor, constant: sectionGap),
            resetButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),

            // Separator 1
            separator1.topAnchor.constraint(equalTo: resetButton.bottomAnchor, constant: sectionGap),
            separator1.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),
            separator1.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),

            // Auto-copy
            autoCopyCheckbox.topAnchor.constraint(equalTo: separator1.bottomAnchor, constant: sectionGap),
            autoCopyCheckbox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),

            autoCopyDesc.topAnchor.constraint(equalTo: autoCopyCheckbox.bottomAnchor, constant: descGap),
            autoCopyDesc.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin + 18),

            // Launch at login
            launchAtLoginCheckbox.topAnchor.constraint(equalTo: autoCopyDesc.bottomAnchor, constant: itemGap + 4),
            launchAtLoginCheckbox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),

            launchDesc.topAnchor.constraint(equalTo: launchAtLoginCheckbox.bottomAnchor, constant: descGap),
            launchDesc.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin + 18),

            // Double-click
            dblClickCheckbox.topAnchor.constraint(equalTo: launchDesc.bottomAnchor, constant: itemGap + 4),
            dblClickCheckbox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),

            dblClickDesc.topAnchor.constraint(equalTo: dblClickCheckbox.bottomAnchor, constant: descGap),
            dblClickDesc.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin + 18),

            // Trackpad scroll as zoom
            trackpadScrollCheckbox.topAnchor.constraint(equalTo: dblClickDesc.bottomAnchor, constant: itemGap + 4),
            trackpadScrollCheckbox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),

            trackpadScrollDesc.topAnchor.constraint(equalTo: trackpadScrollCheckbox.bottomAnchor, constant: descGap),
            trackpadScrollDesc.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin + 18),

            // Auto-switch to select
            autoSwitchCheckbox.topAnchor.constraint(equalTo: trackpadScrollDesc.bottomAnchor, constant: itemGap + 4),
            autoSwitchCheckbox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),

            autoSwitchDesc.topAnchor.constraint(equalTo: autoSwitchCheckbox.bottomAnchor, constant: descGap),
            autoSwitchDesc.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin + 18),

            // Separator 2
            separator2.topAnchor.constraint(equalTo: autoSwitchDesc.bottomAnchor, constant: sectionGap),
            separator2.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),
            separator2.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),

            // Debug
            debugDisclosureButton.topAnchor.constraint(equalTo: separator2.bottomAnchor, constant: 10),
            debugDisclosureButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),

            onboardingCheckbox.topAnchor.constraint(equalTo: debugDisclosureButton.bottomAnchor, constant: itemGap),
            onboardingCheckbox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),

            showNowButton.topAnchor.constraint(equalTo: onboardingCheckbox.bottomAnchor, constant: itemGap),
            showNowButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),

            resetAllButton.topAnchor.constraint(equalTo: showNowButton.bottomAnchor, constant: itemGap),
            resetAllButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),
        ])

        // Start with debug collapsed
        setDebugExpanded(false, animate: false)

        return container
    }

    // MARK: - AI Tab

    private func buildAITab() -> NSView {
        // Outer scroll view that fills the tab area
        let scrollView = NSScrollView()
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true

        // Flipped container so Auto Layout anchors from top work correctly
        let container = FlippedView()
        container.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = container

        // Pin container width to scroll view's clip view (no horizontal scroll)
        let clipView = scrollView.contentView
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
        ])

        let margin: CGFloat = 20
        let sectionGap: CGFloat = 16
        let itemGap: CGFloat = 8
        let fieldGap: CGFloat = 6
        let configLabelWidth: CGFloat = 70

        // AI Configuration section
        let aiTitle = NSTextField(labelWithString: "AI Configuration")
        aiTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        aiTitle.textColor = .labelColor
        aiTitle.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(aiTitle)

        let aiStatusText = AISettings.isConfigured ? "Configured" : "Not Configured"
        let aiStatusColor: NSColor = AISettings.isConfigured ? .systemGreen : .systemOrange
        aiStatusLabel = NSTextField(labelWithString: aiStatusText)
        aiStatusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        aiStatusLabel.textColor = aiStatusColor
        aiStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(aiStatusLabel)

        let aiDesc = NSTextField(wrappingLabelWithString: "Powers all AI features (translation, etc). Get a free API key from Google AI Studio:")
        aiDesc.font = .systemFont(ofSize: 11, weight: .regular)
        aiDesc.textColor = .secondaryLabelColor
        aiDesc.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(aiDesc)

        let getKeyButton = NSButton(title: "Get Free API Key →", target: self, action: #selector(openGoogleAIStudio))
        getKeyButton.bezelStyle = .inline
        getKeyButton.isBordered = false
        getKeyButton.font = .systemFont(ofSize: 11, weight: .medium)
        getKeyButton.contentTintColor = .systemBlue
        getKeyButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(getKeyButton)

        // API Key
        let apiKeyLabel = NSTextField(labelWithString: "API Key")
        apiKeyLabel.font = .systemFont(ofSize: 12, weight: .medium)
        apiKeyLabel.textColor = .labelColor
        apiKeyLabel.alignment = .right
        apiKeyLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(apiKeyLabel)

        aiApiKeyField = RevealableSecureTextField()
        aiApiKeyField.placeholderString = "Paste your API key here"
        aiApiKeyField.font = .systemFont(ofSize: 12)
        aiApiKeyField.translatesAutoresizingMaskIntoConstraints = false
        aiApiKeyField.stringValue = AISettings.apiKey
        container.addSubview(aiApiKeyField)

        // Endpoint
        let endpointLabel = NSTextField(labelWithString: "Endpoint")
        endpointLabel.font = .systemFont(ofSize: 12, weight: .medium)
        endpointLabel.textColor = .labelColor
        endpointLabel.alignment = .right
        endpointLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(endpointLabel)

        aiEndpointField = NSTextField()
        aiEndpointField.placeholderString = "OpenAI-compatible API endpoint"
        aiEndpointField.font = .systemFont(ofSize: 11)
        aiEndpointField.translatesAutoresizingMaskIntoConstraints = false
        aiEndpointField.stringValue = AISettings.apiEndpoint
        container.addSubview(aiEndpointField)

        // Model
        let modelLabel = NSTextField(labelWithString: "Model")
        modelLabel.font = .systemFont(ofSize: 12, weight: .medium)
        modelLabel.textColor = .labelColor
        modelLabel.alignment = .right
        modelLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(modelLabel)

        aiModelField = NSTextField()
        aiModelField.placeholderString = "e.g. gemini-3-flash-preview"
        aiModelField.font = .systemFont(ofSize: 12)
        aiModelField.translatesAutoresizingMaskIntoConstraints = false
        aiModelField.stringValue = AISettings.model
        container.addSubview(aiModelField)

        // Test button + status
        aiTestButton = NSButton(title: "Test Connection", target: self, action: #selector(testAIConnection))
        aiTestButton.bezelStyle = .rounded
        aiTestButton.controlSize = .small
        aiTestButton.font = .systemFont(ofSize: 11)
        aiTestButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(aiTestButton)

        aiTestStatusLabel = NSTextField(labelWithString: "")
        aiTestStatusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        aiTestStatusLabel.textColor = .secondaryLabelColor
        aiTestStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        aiTestStatusLabel.lineBreakMode = .byTruncatingTail
        container.addSubview(aiTestStatusLabel)

        // Register for text field editing notifications (auto-save)
        // For aiApiKeyField (RevealableSecureTextField), use its callback
        aiApiKeyField.onTextChange = { [weak self] in
            self?.saveAIFields()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(aiFieldDidEndEditing(_:)),
                                               name: NSControl.textDidEndEditingNotification, object: aiEndpointField)
        NotificationCenter.default.addObserver(self, selector: #selector(aiFieldDidEndEditing(_:)),
                                               name: NSControl.textDidEndEditingNotification, object: aiModelField)
        NotificationCenter.default.addObserver(self, selector: #selector(aiFieldDidChange(_:)),
                                               name: NSControl.textDidChangeNotification, object: aiEndpointField)
        NotificationCenter.default.addObserver(self, selector: #selector(aiFieldDidChange(_:)),
                                               name: NSControl.textDidChangeNotification, object: aiModelField)

        // Separator
        let separator1 = NSBox()
        separator1.boxType = .separator
        separator1.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(separator1)

        // Translation section
        let translateTitle = NSTextField(labelWithString: "Translation")
        translateTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        translateTitle.textColor = .labelColor
        translateTitle.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(translateTitle)

        let langLabel = NSTextField(labelWithString: "Target Language")
        langLabel.font = .systemFont(ofSize: 12, weight: .regular)
        langLabel.textColor = .labelColor
        langLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(langLabel)

        translateLanguagePopup = NSPopUpButton()
        translateLanguagePopup.font = .systemFont(ofSize: 12)
        translateLanguagePopup.translatesAutoresizingMaskIntoConstraints = false
        translateLanguagePopup.target = self
        translateLanguagePopup.action = #selector(translateLanguageChanged)
        rebuildSettingsLanguageMenu()
        container.addSubview(translateLanguagePopup)

        // Translation prompt (always visible, no fold)
        let promptLabel = NSTextField(labelWithString: "Prompt")
        promptLabel.font = .systemFont(ofSize: 12, weight: .medium)
        promptLabel.textColor = .labelColor
        promptLabel.alignment = .right
        promptLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(promptLabel)

        translatePromptView = NSScrollView()
        translatePromptView.hasVerticalScroller = true
        translatePromptView.borderType = .bezelBorder
        translatePromptView.translatesAutoresizingMaskIntoConstraints = false

        translatePromptTextView = NSTextView()
        translatePromptTextView.font = .systemFont(ofSize: 11)
        translatePromptTextView.isRichText = false
        translatePromptTextView.isAutomaticQuoteSubstitutionEnabled = false
        translatePromptTextView.isAutomaticDashSubstitutionEnabled = false
        translatePromptTextView.textContainerInset = NSSize(width: 4, height: 4)
        let savedPrompt = UserDefaults.standard.string(forKey: TranslateSettings.systemPromptKey)
            ?? TranslateSettings.defaultSystemPrompt
        translatePromptTextView.string = savedPrompt
        translatePromptTextView.delegate = self
        translatePromptView.documentView = translatePromptTextView
        container.addSubview(translatePromptView)

        let resetTranslatePromptButton = NSButton(title: "Reset", target: self, action: #selector(resetTranslatePrompt))
        resetTranslatePromptButton.bezelStyle = .rounded
        resetTranslatePromptButton.controlSize = .small
        resetTranslatePromptButton.font = .systemFont(ofSize: 11)
        resetTranslatePromptButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(resetTranslatePromptButton)

        // Separator 2
        let separator2 = NSBox()
        separator2.boxType = .separator
        separator2.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(separator2)

        // OCR Refine section
        let ocrTitle = NSTextField(labelWithString: "OCR Refine")
        ocrTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        ocrTitle.textColor = .labelColor
        ocrTitle.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(ocrTitle)

        let ocrPromptLabel = NSTextField(labelWithString: "Prompt")
        ocrPromptLabel.font = .systemFont(ofSize: 12, weight: .medium)
        ocrPromptLabel.textColor = .labelColor
        ocrPromptLabel.alignment = .right
        ocrPromptLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(ocrPromptLabel)

        ocrRefinePromptView = NSScrollView()
        ocrRefinePromptView.hasVerticalScroller = true
        ocrRefinePromptView.borderType = .bezelBorder
        ocrRefinePromptView.translatesAutoresizingMaskIntoConstraints = false

        ocrRefinePromptTextView = NSTextView()
        ocrRefinePromptTextView.font = .systemFont(ofSize: 11)
        ocrRefinePromptTextView.isRichText = false
        ocrRefinePromptTextView.isAutomaticQuoteSubstitutionEnabled = false
        ocrRefinePromptTextView.isAutomaticDashSubstitutionEnabled = false
        ocrRefinePromptTextView.textContainerInset = NSSize(width: 4, height: 4)
        let savedOCRPrompt = UserDefaults.standard.string(forKey: OCRRefineSettings.systemPromptKey)
            ?? OCRRefineSettings.defaultSystemPrompt
        ocrRefinePromptTextView.string = savedOCRPrompt
        ocrRefinePromptTextView.delegate = self
        ocrRefinePromptView.documentView = ocrRefinePromptTextView
        container.addSubview(ocrRefinePromptView)

        let resetOCRPromptButton = NSButton(title: "Reset", target: self, action: #selector(resetOCRRefinePrompt))
        resetOCRPromptButton.bezelStyle = .rounded
        resetOCRPromptButton.controlSize = .small
        resetOCRPromptButton.font = .systemFont(ofSize: 11)
        resetOCRPromptButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(resetOCRPromptButton)

        NSLayoutConstraint.activate([
            // AI Configuration
            aiTitle.topAnchor.constraint(equalTo: container.topAnchor, constant: margin),
            aiTitle.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),

            aiStatusLabel.centerYAnchor.constraint(equalTo: aiTitle.centerYAnchor),
            aiStatusLabel.leadingAnchor.constraint(equalTo: aiTitle.trailingAnchor, constant: 10),

            aiDesc.topAnchor.constraint(equalTo: aiTitle.bottomAnchor, constant: 4),
            aiDesc.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),
            aiDesc.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),

            getKeyButton.topAnchor.constraint(equalTo: aiDesc.bottomAnchor, constant: 2),
            getKeyButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),

            // API Key row
            apiKeyLabel.topAnchor.constraint(equalTo: getKeyButton.bottomAnchor, constant: itemGap),
            apiKeyLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),
            apiKeyLabel.widthAnchor.constraint(equalToConstant: configLabelWidth),

            aiApiKeyField.centerYAnchor.constraint(equalTo: apiKeyLabel.centerYAnchor),
            aiApiKeyField.leadingAnchor.constraint(equalTo: apiKeyLabel.trailingAnchor, constant: 8),
            aiApiKeyField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),
            aiApiKeyField.heightAnchor.constraint(equalToConstant: 24),

            // Endpoint row
            endpointLabel.topAnchor.constraint(equalTo: apiKeyLabel.bottomAnchor, constant: fieldGap + 4),
            endpointLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),
            endpointLabel.widthAnchor.constraint(equalToConstant: configLabelWidth),

            aiEndpointField.centerYAnchor.constraint(equalTo: endpointLabel.centerYAnchor),
            aiEndpointField.leadingAnchor.constraint(equalTo: endpointLabel.trailingAnchor, constant: 8),
            aiEndpointField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),
            aiEndpointField.heightAnchor.constraint(equalToConstant: 24),

            // Model row
            modelLabel.topAnchor.constraint(equalTo: endpointLabel.bottomAnchor, constant: fieldGap + 4),
            modelLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),
            modelLabel.widthAnchor.constraint(equalToConstant: configLabelWidth),

            aiModelField.centerYAnchor.constraint(equalTo: modelLabel.centerYAnchor),
            aiModelField.leadingAnchor.constraint(equalTo: modelLabel.trailingAnchor, constant: 8),
            aiModelField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),
            aiModelField.heightAnchor.constraint(equalToConstant: 24),

            // Test button + status
            aiTestButton.topAnchor.constraint(equalTo: modelLabel.bottomAnchor, constant: itemGap + 2),
            aiTestButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),

            aiTestStatusLabel.centerYAnchor.constraint(equalTo: aiTestButton.centerYAnchor),
            aiTestStatusLabel.leadingAnchor.constraint(equalTo: aiTestButton.trailingAnchor, constant: 8),
            aiTestStatusLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -margin),

            // Separator
            separator1.topAnchor.constraint(equalTo: aiTestButton.bottomAnchor, constant: sectionGap),
            separator1.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),
            separator1.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),

            // Translation section
            translateTitle.topAnchor.constraint(equalTo: separator1.bottomAnchor, constant: sectionGap),
            translateTitle.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),

            langLabel.topAnchor.constraint(equalTo: translateTitle.bottomAnchor, constant: itemGap),
            langLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),

            translateLanguagePopup.centerYAnchor.constraint(equalTo: langLabel.centerYAnchor),
            translateLanguagePopup.leadingAnchor.constraint(equalTo: langLabel.trailingAnchor, constant: 8),
            translateLanguagePopup.widthAnchor.constraint(equalToConstant: 180),

            // Prompt row (always visible)
            promptLabel.topAnchor.constraint(equalTo: langLabel.bottomAnchor, constant: itemGap),
            promptLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),
            promptLabel.widthAnchor.constraint(equalToConstant: configLabelWidth),

            translatePromptView.topAnchor.constraint(equalTo: promptLabel.topAnchor),
            translatePromptView.leadingAnchor.constraint(equalTo: promptLabel.trailingAnchor, constant: 8),
            translatePromptView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),
            translatePromptView.heightAnchor.constraint(equalToConstant: 80),

            resetTranslatePromptButton.topAnchor.constraint(equalTo: translatePromptView.bottomAnchor, constant: fieldGap),
            resetTranslatePromptButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),

            // Separator 2
            separator2.topAnchor.constraint(equalTo: resetTranslatePromptButton.bottomAnchor, constant: sectionGap),
            separator2.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),
            separator2.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),

            // OCR Refine section
            ocrTitle.topAnchor.constraint(equalTo: separator2.bottomAnchor, constant: sectionGap),
            ocrTitle.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),

            ocrPromptLabel.topAnchor.constraint(equalTo: ocrTitle.bottomAnchor, constant: itemGap),
            ocrPromptLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),
            ocrPromptLabel.widthAnchor.constraint(equalToConstant: configLabelWidth),

            ocrRefinePromptView.topAnchor.constraint(equalTo: ocrPromptLabel.topAnchor),
            ocrRefinePromptView.leadingAnchor.constraint(equalTo: ocrPromptLabel.trailingAnchor, constant: 8),
            ocrRefinePromptView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),
            ocrRefinePromptView.heightAnchor.constraint(equalToConstant: 80),

            resetOCRPromptButton.topAnchor.constraint(equalTo: ocrRefinePromptView.bottomAnchor, constant: fieldGap),
            resetOCRPromptButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),
        ])

        // Bottom anchor to size the container to fit its content
        NSLayoutConstraint.activate([
            resetOCRPromptButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -margin)
        ])

        return scrollView
    }

    // MARK: - About Tab

    private func buildAboutTab() -> NSView {
        let container = NSView()
        container.autoresizingMask = [.width, .height]

        let margin: CGFloat = 20

        // App icon (use system symbol as placeholder)
        let iconView = NSImageView()
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(iconView)

        let nameLabel = NSTextField(labelWithString: "Snipshot")
        nameLabel.font = .systemFont(ofSize: 20, weight: .bold)
        nameLabel.textColor = .labelColor
        nameLabel.alignment = .center
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(nameLabel)

        let versionLabel = NSTextField(labelWithString: "Version \(kSnipshotVersion)")
        versionLabel.font = .systemFont(ofSize: 13, weight: .regular)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.alignment = .center
        versionLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(versionLabel)

        let descLabel = NSTextField(wrappingLabelWithString: "A lightweight macOS screenshot tool with annotation, OCR, translation, and pin-to-desktop.")
        descLabel.font = .systemFont(ofSize: 12, weight: .regular)
        descLabel.textColor = .secondaryLabelColor
        descLabel.alignment = .center
        descLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(descLabel)

        let authorLabel = NSTextField(labelWithString: "by giyyapan")
        authorLabel.font = .systemFont(ofSize: 11, weight: .regular)
        authorLabel.textColor = .tertiaryLabelColor
        authorLabel.alignment = .center
        authorLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(authorLabel)

        let githubButton = NSButton(title: "GitHub", target: self, action: #selector(openGitHub))
        githubButton.bezelStyle = .inline
        githubButton.isBordered = false
        githubButton.font = .systemFont(ofSize: 12, weight: .medium)
        githubButton.contentTintColor = .systemBlue
        githubButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(githubButton)

        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: container.topAnchor, constant: margin + 20),
            iconView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 64),
            iconView.heightAnchor.constraint(equalToConstant: 64),

            nameLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 12),
            nameLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            versionLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4),
            versionLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            descLabel.topAnchor.constraint(equalTo: versionLabel.bottomAnchor, constant: 16),
            descLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin + 20),
            descLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -(margin + 20)),

            authorLabel.topAnchor.constraint(equalTo: descLabel.bottomAnchor, constant: 16),
            authorLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            githubButton.topAnchor.constraint(equalTo: authorLabel.bottomAnchor, constant: 8),
            githubButton.centerXAnchor.constraint(equalTo: container.centerXAnchor),
        ])

        return container
    }



    // MARK: - Debug Section Collapse/Expand

    private func setDebugExpanded(_ expanded: Bool, animate: Bool) {
        debugIsExpanded = expanded
        debugDisclosureButton.title = expanded ? "Debug ▼" : "Debug ▶"

        let alpha: CGFloat = expanded ? 1.0 : 0.0

        if animate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.allowsImplicitAnimation = true
                for view in self.debugContentViews {
                    view.animator().alphaValue = alpha
                    view.isHidden = !expanded
                }
            }
        } else {
            for view in debugContentViews {
                view.alphaValue = alpha
                view.isHidden = !expanded
            }
        }
    }

    @objc private func toggleDebugSection() {
        setDebugExpanded(!debugIsExpanded, animate: true)
    }

    /// Expand the AI tab (called when user clicks translate without API key)
    func expandTranslationSection() {
        tabView.selectTabViewItem(withIdentifier: "ai")
    }

    private func updateAIStatus() {
        if AISettings.isConfigured {
            aiStatusLabel.stringValue = "Configured"
            aiStatusLabel.textColor = .systemGreen
        } else {
            aiStatusLabel.stringValue = "Not Configured"
            aiStatusLabel.textColor = .systemOrange
        }
    }

    // MARK: - AI Auto-save

    @objc private func aiFieldDidEndEditing(_ notification: Notification) {
        saveAIFields()
    }

    @objc private func aiFieldDidChange(_ notification: Notification) {
        saveAIFields()
    }

    private func saveAIFields() {
        AISettings.apiKey = aiApiKeyField.stringValue
        AISettings.apiEndpoint = aiEndpointField.stringValue
        AISettings.model = aiModelField.stringValue
        updateAIStatus()
    }

    // MARK: - AI Test Connection

    @objc private func testAIConnection() {
        saveAIFields()

        guard AISettings.isConfigured else {
            aiTestStatusLabel.stringValue = "Please enter an API key first"
            aiTestStatusLabel.textColor = .systemOrange
            return
        }

        aiTestButton.isEnabled = false
        aiTestStatusLabel.stringValue = "Testing..."
        aiTestStatusLabel.textColor = .secondaryLabelColor

        AIService.shared.testConnection { [weak self] errorMessage in
            guard let self = self else { return }
            self.aiTestButton.isEnabled = true

            if let error = errorMessage {
                self.aiTestStatusLabel.stringValue = error
                self.aiTestStatusLabel.textColor = .systemRed
            } else {
                self.aiTestStatusLabel.stringValue = "Connection successful"
                self.aiTestStatusLabel.textColor = .systemGreen
            }
        }
    }

    // MARK: - Actions

    @objc private func resetHotkey() {
        let defaultConfig = HotkeyConfig.defaultCapture
        currentConfig = defaultConfig
        hotkeyField.setConfig(defaultConfig)
        UserDefaults.standard.set(defaultConfig.keyCode, forKey: "captureHotkeyKeyCode")
        UserDefaults.standard.set(defaultConfig.modifiers.rawValue, forKey: "captureHotkeyModifiers")
        onHotkeyChanged?(defaultConfig)
    }

    @objc private func toggleAutoCopy(_ sender: NSButton) {
        let enabled = sender.state == .on
        UserDefaults.standard.set(enabled, forKey: "autoCopyAfterSelection")
        logMessage("Auto-copy after selection = \(enabled)")
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSButton) {
        let enabled = sender.state == .on
        do {
            if enabled {
                try SMAppService.mainApp.register()
                logMessage("Launch at login: registered")
            } else {
                try SMAppService.mainApp.unregister()
                logMessage("Launch at login: unregistered")
            }
        } catch {
            logMessage("Launch at login error: \(error.localizedDescription)")
            sender.state = enabled ? .off : .on
        }
    }

    @objc private func toggleDoubleClickClosePin(_ sender: NSButton) {
        let enabled = sender.state == .on
        UserDefaults.standard.set(enabled, forKey: "doubleClickToClosePin")
        logMessage("Double-click to close pin = \(enabled)")
    }

    @objc private func toggleTrackpadScrollZoom(_ sender: NSButton) {
        let enabled = sender.state == .on
        UserDefaults.standard.set(enabled, forKey: "trackpadScrollAsZoom")
        logMessage("Trackpad scroll as zoom = \(enabled)")
    }

    @objc private func toggleAutoSwitchToSelect(_ sender: NSButton) {
        let enabled = sender.state == .on
        UserDefaults.standard.set(enabled, forKey: "autoSwitchToSelectAfterAnnotation")
        logMessage("Auto-switch to select after annotation = \(enabled)")
    }

    @objc private func toggleAlwaysOnboarding(_ sender: NSButton) {
        let enabled = sender.state == .on
        UserDefaults.standard.set(enabled, forKey: "debugAlwaysShowOnboarding")
        logMessage("Debug: Always show onboarding = \(enabled)")
    }

    @objc private func showOnboardingNow() {
        onShowOnboarding?()
    }

    @objc private func resetEverythingAndQuit() {
        let alert = NSAlert()
        alert.messageText = "Reset Everything?"
        alert.informativeText = "This will clear all settings and quit the app. Next launch will behave like a fresh install (permissions are not revoked)."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset & Quit")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            try? SMAppService.mainApp.unregister()
            if let bundleId = Bundle.main.bundleIdentifier {
                UserDefaults.standard.removePersistentDomain(forName: bundleId)
                UserDefaults.standard.synchronize()
            }
            logMessage("Debug: Reset everything and quitting.")
            NSApp.terminate(nil)
        }
    }

    // MARK: - Translation Actions

    @objc private func openGoogleAIStudio() {
        if let url = URL(string: "https://aistudio.google.com/apikey") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openGitHub() {
        if let url = URL(string: "https://github.com/giyyapan/Snipshot") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func translateLanguageChanged() {
        if let selected = translateLanguagePopup.selectedItem?.title {
            TranslateSettings.targetLanguage = selected
            TranslateSettings.markLanguageUsed(selected)
            rebuildSettingsLanguageMenu()
            logMessage("Translation target language: \(selected)")
        }
    }

    private func rebuildSettingsLanguageMenu() {
        translateLanguagePopup.removeAllItems()
        let recent = TranslateSettings.recentLanguages
        let current = TranslateSettings.targetLanguage

        for lang in recent {
            translateLanguagePopup.addItem(withTitle: lang)
        }

        translateLanguagePopup.menu?.addItem(NSMenuItem.separator())

        for lang in TranslateSettings.availableLanguages where !recent.contains(lang) {
            translateLanguagePopup.addItem(withTitle: lang)
        }

        translateLanguagePopup.selectItem(withTitle: current)
    }

    @objc private func resetTranslatePrompt() {
        translatePromptTextView.string = TranslateSettings.defaultSystemPrompt
        TranslateSettings.rawSystemPrompt = TranslateSettings.defaultSystemPrompt
        logMessage("Translation prompt reset to default")
    }

    @objc private func resetOCRRefinePrompt() {
        ocrRefinePromptTextView.string = OCRRefineSettings.defaultSystemPrompt
        OCRRefineSettings.rawSystemPrompt = OCRRefineSettings.defaultSystemPrompt
        logMessage("OCR Refine prompt reset to default")
    }
}

// MARK: - NSTextViewDelegate (for prompt text view)
extension SettingsWindow: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        if let textView = notification.object as? NSTextView {
            if textView === translatePromptTextView {
                TranslateSettings.rawSystemPrompt = textView.string
            } else if textView === ocrRefinePromptTextView {
                OCRRefineSettings.rawSystemPrompt = textView.string
            }
        }
    }
}

// MARK: - Hotkey Recorder Field

class HotkeyRecorderField: NSView {
    private var config: HotkeyConfig
    private var label: NSTextField!
    private var isRecording = false
    var onConfigChanged: ((HotkeyConfig) -> Void)?

    init(config: HotkeyConfig) {
        self.config = config
        super.init(frame: .zero)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    func setConfig(_ config: HotkeyConfig) {
        self.config = config
        label.stringValue = config.displayString
        label.textColor = .labelColor
    }

    private func setupUI() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        label = NSTextField(labelWithString: config.displayString)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(startRecording))
        addGestureRecognizer(click)
    }

    @objc private func startRecording() {
        isRecording = true
        label.stringValue = "Press a key…"
        label.textColor = .systemOrange
        layer?.borderColor = NSColor.systemBlue.cgColor
        layer?.borderWidth = 2
        window?.makeFirstResponder(self)
    }

    private func stopRecording() {
        isRecording = false
        label.stringValue = config.displayString
        label.textColor = .labelColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }

        if event.keyCode == 53 {
            stopRecording()
            return
        }

        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let newConfig = HotkeyConfig(keyCode: event.keyCode, modifiers: modifiers)
        config = newConfig
        stopRecording()
        onConfigChanged?(newConfig)
    }

    override func resignFirstResponder() -> Bool {
        if isRecording { stopRecording() }
        return super.resignFirstResponder()
    }
}


// MARK: - Revealable Secure Text Field
/// A text field that shows content as plain text when focused and masks it when not.
/// Internally swaps between NSTextField (plain) and NSSecureTextField (masked).
class RevealableSecureTextField: NSView {
    private var secureField: NSSecureTextField!
    private var plainField: NSTextField!
    private var isRevealed = false

    /// Called whenever the text content changes (from either field) or editing ends.
    var onTextChange: (() -> Void)?

    var stringValue: String {
        get {
            isRevealed ? plainField.stringValue : secureField.stringValue
        }
        set {
            secureField.stringValue = newValue
            plainField.stringValue = newValue
        }
    }

    var placeholderString: String? {
        get { secureField.placeholderString }
        set {
            secureField.placeholderString = newValue
            plainField.placeholderString = newValue
        }
    }

    var font: NSFont? {
        get { secureField.font }
        set {
            secureField.font = newValue
            plainField.font = newValue
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    convenience init() {
        self.init(frame: .zero)
    }

    private func setup() {
        secureField = NSSecureTextField()
        secureField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(secureField)

        plainField = NSTextField()
        plainField.translatesAutoresizingMaskIntoConstraints = false
        plainField.isHidden = true
        addSubview(plainField)

        NSLayoutConstraint.activate([
            secureField.topAnchor.constraint(equalTo: topAnchor),
            secureField.bottomAnchor.constraint(equalTo: bottomAnchor),
            secureField.leadingAnchor.constraint(equalTo: leadingAnchor),
            secureField.trailingAnchor.constraint(equalTo: trailingAnchor),

            plainField.topAnchor.constraint(equalTo: topAnchor),
            plainField.bottomAnchor.constraint(equalTo: bottomAnchor),
            plainField.leadingAnchor.constraint(equalTo: leadingAnchor),
            plainField.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        // Focus / blur notifications to swap fields
        NotificationCenter.default.addObserver(self, selector: #selector(fieldDidBeginEditing(_:)),
                                               name: NSControl.textDidBeginEditingNotification, object: secureField)
        NotificationCenter.default.addObserver(self, selector: #selector(fieldDidBeginEditing(_:)),
                                               name: NSControl.textDidBeginEditingNotification, object: plainField)
        NotificationCenter.default.addObserver(self, selector: #selector(fieldDidEndEditing(_:)),
                                               name: NSControl.textDidEndEditingNotification, object: secureField)
        NotificationCenter.default.addObserver(self, selector: #selector(fieldDidEndEditing(_:)),
                                               name: NSControl.textDidEndEditingNotification, object: plainField)

        // Text change notifications to forward to owner
        NotificationCenter.default.addObserver(self, selector: #selector(innerTextDidChange(_:)),
                                               name: NSControl.textDidChangeNotification, object: secureField)
        NotificationCenter.default.addObserver(self, selector: #selector(innerTextDidChange(_:)),
                                               name: NSControl.textDidChangeNotification, object: plainField)
    }

    @objc private func innerTextDidChange(_ notification: Notification) {
        onTextChange?()
    }

    @objc private func fieldDidBeginEditing(_ notification: Notification) {
        guard !isRevealed else { return }
        isRevealed = true
        plainField.stringValue = secureField.stringValue
        secureField.isHidden = true
        plainField.isHidden = false
        window?.makeFirstResponder(plainField)
    }

    @objc private func fieldDidEndEditing(_ notification: Notification) {
        guard isRevealed else { return }
        isRevealed = false
        secureField.stringValue = plainField.stringValue
        plainField.isHidden = true
        secureField.isHidden = false
        onTextChange?()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - Flipped View (for scroll view document view)
/// An NSView subclass that flips the coordinate system so Auto Layout constraints
/// anchor from the top, which is needed for NSScrollView document views.
class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
