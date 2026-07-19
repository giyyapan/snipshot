import Cocoa
import Carbon.HIToolbox
import ServiceManagement

let kSnipshotVersion = "0.9.0"

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
    private var aiProviderPopup: NSPopUpButton!
    private var aiDescriptionLabel: NSTextField!
    private var aiKeyHelpButton: NSButton!
    private var aiApiKeyField: NSSecureTextField!
    private var aiEndpointField: NSTextField!
    private var aiModelPopup: NSPopUpButton!
    private var aiModelField: NSTextField!
    private var aiRefreshModelsButton: NSButton!
    private var aiModelStatusLabel: NSTextField!
    private var aiCustomAuthPopup: NSPopUpButton!
    private var aiCustomHeaderField: NSTextField!
    private var aiCustomTokenPopup: NSPopUpButton!
    private var aiAllowInsecureCheckbox: NSButton!
    private var aiTestButton: NSButton!
    private var aiTestStatusLabel: NSTextField!
    private var aiSaveButton: NSButton!
    private var aiAdvancedViews: [NSView] = []
    private var aiModelTopBuiltInConstraint: NSLayoutConstraint!
    private var aiModelTopCustomConstraint: NSLayoutConstraint!
    private var aiModelFieldHeightConstraint: NSLayoutConstraint!
    private var aiModelStatusBelowPopupConstraint: NSLayoutConstraint!
    private var aiModelStatusBelowFieldConstraint: NSLayoutConstraint!

    // Translation section
    private var translateLanguagePopup: NSPopUpButton!
    private var translateSaveButton: NSButton!
    private var translateSaveStatusLabel: NSTextField!

    // Translation prompt (always visible)
    private var translatePromptView: NSScrollView!
    private var translatePromptTextView: NSTextView!

    // OCR Refine prompt
    private var ocrRefinePromptView: NSScrollView!
    private var ocrRefinePromptTextView: NSTextView!
    private var ocrSaveButton: NSButton!
    private var ocrSaveStatusLabel: NSTextField!

    // Dirty tracking — Save buttons are disabled until user makes a change
    private var aiConfigDirty = false
    private var aiModels: [AIModelDescriptor] = []
    private var translatePromptDirty = false
    private var ocrPromptDirty = false

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

    private func makePromptEditor(text: String) -> (scrollView: NSScrollView, textView: NSTextView) {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        // scrollableTextView() supplies the correctly sized/resizable document view.
        // A bare NSTextView() starts at zero size and can leave the prompt invisible.
        let textView = scrollView.documentView as! NSTextView
        textView.font = .systemFont(ofSize: 11)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.insertionPointColor = .textColor
        textView.drawsBackground = true
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.string = text
        textView.delegate = self
        return (scrollView, textView)
    }

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

        aiDescriptionLabel = NSTextField(wrappingLabelWithString: "Choose a provider, paste a key, and save. Snipshot verifies the same request path used for translation.")
        aiDescriptionLabel.font = .systemFont(ofSize: 11, weight: .regular)
        aiDescriptionLabel.textColor = .secondaryLabelColor
        aiDescriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(aiDescriptionLabel)

        aiKeyHelpButton = NSButton(title: "Get API Key →", target: self, action: #selector(openProviderAPIKeyPage))
        aiKeyHelpButton.bezelStyle = .inline
        aiKeyHelpButton.isBordered = false
        aiKeyHelpButton.font = .systemFont(ofSize: 11, weight: .medium)
        aiKeyHelpButton.contentTintColor = .systemBlue
        aiKeyHelpButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(aiKeyHelpButton)

        let providerLabel = NSTextField(labelWithString: "Provider")
        providerLabel.font = .systemFont(ofSize: 12, weight: .medium)
        providerLabel.alignment = .right
        providerLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(providerLabel)

        aiProviderPopup = NSPopUpButton()
        aiProviderPopup.addItems(withTitles: AIProviderID.allCases.map(\.displayName))
        aiProviderPopup.selectItem(at: AIProviderID.allCases.firstIndex(of: AISettings.configuration.provider) ?? 0)
        aiProviderPopup.target = self
        aiProviderPopup.action = #selector(aiProviderChanged)
        aiProviderPopup.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(aiProviderPopup)

        // API Key
        let apiKeyLabel = NSTextField(labelWithString: "API Key")
        apiKeyLabel.font = .systemFont(ofSize: 12, weight: .medium)
        apiKeyLabel.textColor = .labelColor
        apiKeyLabel.alignment = .right
        apiKeyLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(apiKeyLabel)

        aiApiKeyField = NSSecureTextField()
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

        let customAuthLabel = NSTextField(labelWithString: "Auth")
        customAuthLabel.font = .systemFont(ofSize: 12, weight: .medium)
        customAuthLabel.alignment = .right
        customAuthLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(customAuthLabel)

        aiCustomAuthPopup = NSPopUpButton()
        aiCustomAuthPopup.addItems(withTitles: AICustomAuthMode.allCases.map(\.displayName))
        aiCustomAuthPopup.selectItem(at: AICustomAuthMode.allCases.firstIndex(of: AISettings.configuration.customAuthMode) ?? 0)
        aiCustomAuthPopup.target = self
        aiCustomAuthPopup.action = #selector(aiCustomOptionChanged)
        aiCustomAuthPopup.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(aiCustomAuthPopup)

        aiCustomHeaderField = NSTextField()
        aiCustomHeaderField.placeholderString = "Header name, e.g. X-API-Key"
        aiCustomHeaderField.stringValue = AISettings.configuration.customAPIKeyHeader
        aiCustomHeaderField.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(aiCustomHeaderField)

        let tokenLabel = NSTextField(labelWithString: "Token Limit")
        tokenLabel.font = .systemFont(ofSize: 12, weight: .medium)
        tokenLabel.alignment = .right
        tokenLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(tokenLabel)

        aiCustomTokenPopup = NSPopUpButton()
        aiCustomTokenPopup.addItems(withTitles: AICustomTokenParameter.allCases.map(\.displayName))
        aiCustomTokenPopup.selectItem(at: AICustomTokenParameter.allCases.firstIndex(of: AISettings.configuration.customTokenParameter) ?? 0)
        aiCustomTokenPopup.target = self
        aiCustomTokenPopup.action = #selector(aiCustomOptionChanged)
        aiCustomTokenPopup.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(aiCustomTokenPopup)

        aiAllowInsecureCheckbox = NSButton(checkboxWithTitle: "Allow HTTP for localhost only", target: self, action: #selector(aiCustomOptionChanged))
        aiAllowInsecureCheckbox.state = AISettings.configuration.customAllowsInsecureHTTP ? .on : .off
        aiAllowInsecureCheckbox.font = .systemFont(ofSize: 10)
        aiAllowInsecureCheckbox.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(aiAllowInsecureCheckbox)

        // Model
        let modelLabel = NSTextField(labelWithString: "Model")
        modelLabel.font = .systemFont(ofSize: 12, weight: .medium)
        modelLabel.textColor = .labelColor
        modelLabel.alignment = .right
        modelLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(modelLabel)

        aiModelPopup = NSPopUpButton()
        aiModelPopup.addItem(withTitle: AISettings.model)
        aiModelPopup.target = self
        aiModelPopup.action = #selector(aiModelSelected)
        aiModelPopup.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(aiModelPopup)

        aiRefreshModelsButton = NSButton(title: "Refresh", target: self, action: #selector(refreshAIModels))
        aiRefreshModelsButton.bezelStyle = .rounded
        aiRefreshModelsButton.controlSize = .small
        aiRefreshModelsButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(aiRefreshModelsButton)

        aiModelField = NSTextField()
        aiModelField.placeholderString = "Enter a model ID"
        aiModelField.font = .systemFont(ofSize: 12)
        aiModelField.translatesAutoresizingMaskIntoConstraints = false
        aiModelField.stringValue = AISettings.model
        container.addSubview(aiModelField)

        aiModelStatusLabel = NSTextField(labelWithString: "Models have not been loaded.")
        aiModelStatusLabel.font = .systemFont(ofSize: 10)
        aiModelStatusLabel.textColor = .secondaryLabelColor
        aiModelStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(aiModelStatusLabel)

        // Button row: optional test-only action + primary Save & Test action.
        aiTestButton = NSButton(title: "Test Only", target: self, action: #selector(testAIConnection))
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

        aiSaveButton = NSButton(title: "Save & Test", target: self, action: #selector(saveAIConfigTapped))
        aiSaveButton.bezelStyle = .rounded
        aiSaveButton.controlSize = .small
        aiSaveButton.font = .systemFont(ofSize: 11)
        aiSaveButton.translatesAutoresizingMaskIntoConstraints = false
        aiSaveButton.isEnabled = false
        container.addSubview(aiSaveButton)

        aiAdvancedViews = [
            endpointLabel, aiEndpointField,
            customAuthLabel, aiCustomAuthPopup, aiCustomHeaderField,
            tokenLabel, aiCustomTokenPopup, aiAllowInsecureCheckbox,
        ]

        aiModelTopBuiltInConstraint = modelLabel.topAnchor.constraint(equalTo: apiKeyLabel.bottomAnchor, constant: fieldGap + 4)
        aiModelTopCustomConstraint = modelLabel.topAnchor.constraint(equalTo: tokenLabel.bottomAnchor, constant: fieldGap + 4)
        aiModelFieldHeightConstraint = aiModelField.heightAnchor.constraint(equalToConstant: 0)
        aiModelStatusBelowPopupConstraint = aiModelStatusLabel.topAnchor.constraint(equalTo: modelLabel.bottomAnchor, constant: 4)
        aiModelStatusBelowFieldConstraint = aiModelStatusLabel.topAnchor.constraint(equalTo: aiModelField.bottomAnchor, constant: 2)

        // Register for text field editing notifications (dirty tracking)
        NotificationCenter.default.addObserver(self, selector: #selector(aiFieldDidChange(_:)),
                                               name: NSControl.textDidChangeNotification, object: aiApiKeyField)
        NotificationCenter.default.addObserver(self, selector: #selector(aiFieldDidChange(_:)),
                                               name: NSControl.textDidChangeNotification, object: aiEndpointField)
        NotificationCenter.default.addObserver(self, selector: #selector(aiFieldDidChange(_:)),
                                               name: NSControl.textDidChangeNotification, object: aiModelField)
        NotificationCenter.default.addObserver(self, selector: #selector(aiFieldDidChange(_:)),
                                               name: NSControl.textDidChangeNotification, object: aiCustomHeaderField)

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

        let savedPrompt = UserDefaults.standard.string(forKey: TranslateSettings.systemPromptKey)
            ?? TranslateSettings.defaultSystemPrompt
        let translatePromptEditor = makePromptEditor(text: savedPrompt)
        translatePromptView = translatePromptEditor.scrollView
        translatePromptTextView = translatePromptEditor.textView
        translatePromptView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(translatePromptView)

        let resetTranslatePromptButton = NSButton(title: "Reset", target: self, action: #selector(resetTranslatePrompt))
        resetTranslatePromptButton.bezelStyle = .rounded
        resetTranslatePromptButton.controlSize = .small
        resetTranslatePromptButton.font = .systemFont(ofSize: 11)
        resetTranslatePromptButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(resetTranslatePromptButton)

        translateSaveButton = NSButton(title: "Save", target: self, action: #selector(saveTranslatePromptTapped))
        translateSaveButton.bezelStyle = .rounded
        translateSaveButton.controlSize = .small
        translateSaveButton.font = .systemFont(ofSize: 11)
        translateSaveButton.translatesAutoresizingMaskIntoConstraints = false
        translateSaveButton.isEnabled = false
        container.addSubview(translateSaveButton)

        translateSaveStatusLabel = NSTextField(labelWithString: "")
        translateSaveStatusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        translateSaveStatusLabel.textColor = .systemGreen
        translateSaveStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(translateSaveStatusLabel)

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

        let savedOCRPrompt = UserDefaults.standard.string(forKey: OCRRefineSettings.systemPromptKey)
            ?? OCRRefineSettings.defaultSystemPrompt
        let ocrPromptEditor = makePromptEditor(text: savedOCRPrompt)
        ocrRefinePromptView = ocrPromptEditor.scrollView
        ocrRefinePromptTextView = ocrPromptEditor.textView
        ocrRefinePromptView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(ocrRefinePromptView)

        let resetOCRPromptButton = NSButton(title: "Reset", target: self, action: #selector(resetOCRRefinePrompt))
        resetOCRPromptButton.bezelStyle = .rounded
        resetOCRPromptButton.controlSize = .small
        resetOCRPromptButton.font = .systemFont(ofSize: 11)
        resetOCRPromptButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(resetOCRPromptButton)

        ocrSaveButton = NSButton(title: "Save", target: self, action: #selector(saveOCRPromptTapped))
        ocrSaveButton.bezelStyle = .rounded
        ocrSaveButton.controlSize = .small
        ocrSaveButton.font = .systemFont(ofSize: 11)
        ocrSaveButton.translatesAutoresizingMaskIntoConstraints = false
        ocrSaveButton.isEnabled = false
        container.addSubview(ocrSaveButton)

        ocrSaveStatusLabel = NSTextField(labelWithString: "")
        ocrSaveStatusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        ocrSaveStatusLabel.textColor = .systemGreen
        ocrSaveStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(ocrSaveStatusLabel)

        NSLayoutConstraint.activate([
            // AI Configuration
            aiTitle.topAnchor.constraint(equalTo: container.topAnchor, constant: margin),
            aiTitle.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),

            aiStatusLabel.centerYAnchor.constraint(equalTo: aiTitle.centerYAnchor),
            aiStatusLabel.leadingAnchor.constraint(equalTo: aiTitle.trailingAnchor, constant: 10),

            aiDescriptionLabel.topAnchor.constraint(equalTo: aiTitle.bottomAnchor, constant: 4),
            aiDescriptionLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),
            aiDescriptionLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),

            providerLabel.topAnchor.constraint(equalTo: aiDescriptionLabel.bottomAnchor, constant: itemGap),
            providerLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),
            providerLabel.widthAnchor.constraint(equalToConstant: configLabelWidth),

            aiProviderPopup.centerYAnchor.constraint(equalTo: providerLabel.centerYAnchor),
            aiProviderPopup.leadingAnchor.constraint(equalTo: providerLabel.trailingAnchor, constant: 8),
            aiProviderPopup.widthAnchor.constraint(equalToConstant: 170),

            aiKeyHelpButton.centerYAnchor.constraint(equalTo: providerLabel.centerYAnchor),
            aiKeyHelpButton.leadingAnchor.constraint(equalTo: aiProviderPopup.trailingAnchor, constant: 8),

            // API Key row
            apiKeyLabel.topAnchor.constraint(equalTo: providerLabel.bottomAnchor, constant: fieldGap + 4),
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

            // Custom protocol options (disabled for built-in providers)
            customAuthLabel.topAnchor.constraint(equalTo: endpointLabel.bottomAnchor, constant: fieldGap + 4),
            customAuthLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),
            customAuthLabel.widthAnchor.constraint(equalToConstant: configLabelWidth),

            aiCustomAuthPopup.centerYAnchor.constraint(equalTo: customAuthLabel.centerYAnchor),
            aiCustomAuthPopup.leadingAnchor.constraint(equalTo: customAuthLabel.trailingAnchor, constant: 8),
            aiCustomAuthPopup.widthAnchor.constraint(equalToConstant: 150),

            aiCustomHeaderField.centerYAnchor.constraint(equalTo: customAuthLabel.centerYAnchor),
            aiCustomHeaderField.leadingAnchor.constraint(equalTo: aiCustomAuthPopup.trailingAnchor, constant: 8),
            aiCustomHeaderField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),

            tokenLabel.topAnchor.constraint(equalTo: customAuthLabel.bottomAnchor, constant: fieldGap + 4),
            tokenLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),
            tokenLabel.widthAnchor.constraint(equalToConstant: configLabelWidth),

            aiCustomTokenPopup.centerYAnchor.constraint(equalTo: tokenLabel.centerYAnchor),
            aiCustomTokenPopup.leadingAnchor.constraint(equalTo: tokenLabel.trailingAnchor, constant: 8),
            aiCustomTokenPopup.widthAnchor.constraint(equalToConstant: 180),

            aiAllowInsecureCheckbox.centerYAnchor.constraint(equalTo: tokenLabel.centerYAnchor),
            aiAllowInsecureCheckbox.leadingAnchor.constraint(equalTo: aiCustomTokenPopup.trailingAnchor, constant: 8),

            // Model row. Its top anchor switches between the compact built-in
            // layout and expanded Custom-provider layout.
            modelLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),
            modelLabel.widthAnchor.constraint(equalToConstant: configLabelWidth),

            aiModelPopup.centerYAnchor.constraint(equalTo: modelLabel.centerYAnchor),
            aiModelPopup.leadingAnchor.constraint(equalTo: modelLabel.trailingAnchor, constant: 8),
            aiModelPopup.trailingAnchor.constraint(equalTo: aiRefreshModelsButton.leadingAnchor, constant: -8),

            aiRefreshModelsButton.centerYAnchor.constraint(equalTo: modelLabel.centerYAnchor),
            aiRefreshModelsButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),

            aiModelField.topAnchor.constraint(equalTo: modelLabel.bottomAnchor, constant: fieldGap),
            aiModelField.leadingAnchor.constraint(equalTo: modelLabel.trailingAnchor, constant: 8),
            aiModelField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),
            aiModelFieldHeightConstraint,

            aiModelStatusLabel.leadingAnchor.constraint(equalTo: aiModelField.leadingAnchor),
            aiModelStatusLabel.trailingAnchor.constraint(equalTo: aiModelField.trailingAnchor),

            // Button row: test-only action + one unified status + primary action.
            aiTestButton.topAnchor.constraint(equalTo: aiModelStatusLabel.bottomAnchor, constant: itemGap + 2),
            aiTestButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),

            aiTestStatusLabel.centerYAnchor.constraint(equalTo: aiTestButton.centerYAnchor),
            aiTestStatusLabel.leadingAnchor.constraint(equalTo: aiTestButton.trailingAnchor, constant: 8),
            aiTestStatusLabel.trailingAnchor.constraint(lessThanOrEqualTo: aiSaveButton.leadingAnchor, constant: -8),

            aiSaveButton.centerYAnchor.constraint(equalTo: aiTestButton.centerYAnchor),
            aiSaveButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),

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

            // Button row: Reset (left) | Save + status (right)
            resetTranslatePromptButton.topAnchor.constraint(equalTo: translatePromptView.bottomAnchor, constant: fieldGap),
            resetTranslatePromptButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),

            translateSaveButton.centerYAnchor.constraint(equalTo: resetTranslatePromptButton.centerYAnchor),
            translateSaveButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),

            translateSaveStatusLabel.centerYAnchor.constraint(equalTo: translateSaveButton.centerYAnchor),
            translateSaveStatusLabel.trailingAnchor.constraint(equalTo: translateSaveButton.leadingAnchor, constant: -6),

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

            // Button row: Reset (left) | Save + status (right)
            resetOCRPromptButton.topAnchor.constraint(equalTo: ocrRefinePromptView.bottomAnchor, constant: fieldGap),
            resetOCRPromptButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),

            ocrSaveButton.centerYAnchor.constraint(equalTo: resetOCRPromptButton.centerYAnchor),
            ocrSaveButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),

            ocrSaveStatusLabel.centerYAnchor.constraint(equalTo: ocrSaveButton.centerYAnchor),
            ocrSaveStatusLabel.trailingAnchor.constraint(equalTo: ocrSaveButton.leadingAnchor, constant: -6),
        ])

        // Bottom anchor to size the container to fit its content
        NSLayoutConstraint.activate([
            resetOCRPromptButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -margin)
        ])

        updateProviderUI(loadCachedModels: true)
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

    // MARK: - AI Dirty Tracking & Save

    @objc private func aiFieldDidChange(_ notification: Notification) {
        markAIConfigDirty()
    }

    private func markAIConfigDirty() {
        aiTestStatusLabel.stringValue = ""
        guard !aiConfigDirty else { return }
        aiConfigDirty = true
        aiSaveButton.isEnabled = true
        aiStatusLabel.stringValue = "Unsaved Changes"
        aiStatusLabel.textColor = .systemOrange
    }

    private var selectedProvider: AIProviderID {
        AIProviderID.allCases[max(0, aiProviderPopup.indexOfSelectedItem)]
    }

    private func draftAIConfiguration() -> AIProviderConfiguration {
        AIProviderConfiguration(
            provider: selectedProvider,
            baseURL: aiEndpointField.stringValue,
            model: aiModelField.stringValue,
            customAuthMode: AICustomAuthMode.allCases[max(0, aiCustomAuthPopup.indexOfSelectedItem)],
            customAPIKeyHeader: aiCustomHeaderField.stringValue,
            customTokenParameter: AICustomTokenParameter.allCases[max(0, aiCustomTokenPopup.indexOfSelectedItem)],
            customAllowsInsecureHTTP: aiAllowInsecureCheckbox.state == .on
        )
    }

    private func saveAIFields(configuration: AIProviderConfiguration, apiKey: String) throws {
        try AISettings.save(configuration: configuration, apiKey: apiKey)
        updateAIStatus()
        aiConfigDirty = false
        aiSaveButton.isEnabled = false
    }

    @objc private func aiProviderChanged() {
        let provider = selectedProvider
        aiEndpointField.stringValue = provider.defaultBaseURL
        aiModelField.stringValue = provider.defaultModel
        aiApiKeyField.stringValue = AISettings.apiKey(for: provider)
        aiModels = []
        aiRefreshModelsButton.isEnabled = true
        updateProviderUI(loadCachedModels: true)
        markAIConfigDirty()
    }

    @objc private func aiCustomOptionChanged() {
        updateProviderUI(loadCachedModels: false)
        markAIConfigDirty()
    }

    @objc private func aiModelSelected() {
        guard let modelID = aiModelPopup.selectedItem?.representedObject as? String else { return }
        if modelID == "__manual__" {
            setManualModelEntryVisible(true)
            makeFirstResponder(aiModelField)
            return
        }
        aiModelField.stringValue = modelID
        setManualModelEntryVisible(false)
        markAIConfigDirty()
    }

    private func updateProviderUI(loadCachedModels: Bool) {
        let provider = selectedProvider
        let isCustom = provider == .custom
        aiDescriptionLabel.stringValue = isCustom
            ? "Use any OpenAI-compatible endpoint and configure its protocol options below."
            : "\(provider.displayName) · API key stored in macOS Keychain · default: \(provider.defaultModel)"
        aiKeyHelpButton.isHidden = provider.helpURL == nil
        aiAdvancedViews.forEach { $0.isHidden = !isCustom }
        aiModelTopBuiltInConstraint.isActive = false
        aiModelTopCustomConstraint.isActive = false
        (isCustom ? aiModelTopCustomConstraint : aiModelTopBuiltInConstraint).isActive = true
        aiEndpointField.isEditable = true
        aiEndpointField.textColor = .labelColor
        aiCustomAuthPopup.isEnabled = true
        aiCustomHeaderField.isEnabled = isCustom && AICustomAuthMode.allCases[max(0, aiCustomAuthPopup.indexOfSelectedItem)] == .apiKeyHeader
        aiCustomTokenPopup.isEnabled = true
        aiAllowInsecureCheckbox.isEnabled = true
        aiApiKeyField.placeholderString = isCustom && AICustomAuthMode.allCases[max(0, aiCustomAuthPopup.indexOfSelectedItem)] == .none
            ? "Optional for unauthenticated localhost endpoints" : "Stored securely in macOS Keychain"
        if loadCachedModels { loadCachedModelsForSelectedProvider() }
        if let migrationError = UserDefaults.standard.string(forKey: AIConfigurationStore.migrationErrorKey) {
            aiModelStatusLabel.stringValue = "Legacy settings migration needs attention: \(migrationError)"
            aiModelStatusLabel.textColor = .systemRed
        }
    }

    private func modelCacheKey(for provider: AIProviderID) -> String { "aiModelCache.\(provider.rawValue)" }
    private func modelCacheDateKey(for provider: AIProviderID) -> String { "aiModelCacheDate.\(provider.rawValue)" }

    private func loadCachedModelsForSelectedProvider() {
        let provider = selectedProvider
        guard let data = UserDefaults.standard.data(forKey: modelCacheKey(for: provider)),
              let models = try? JSONDecoder().decode([AIModelDescriptor].self, from: data), !models.isEmpty else {
            rebuildModelPopup(models: [], status: "Using the recommended default. Refresh to browse all available models.")
            return
        }
        let date = UserDefaults.standard.object(forKey: modelCacheDateKey(for: provider)) as? Date
        let age = date.map { Date().timeIntervalSince($0) }
        let stale = age == nil || age! > 24 * 60 * 60
        rebuildModelPopup(models: models, status: stale ? "Cached model list may be stale · Refresh to update." : "Using cached model list · Refresh to update.")
    }

    private func rebuildModelPopup(models: [AIModelDescriptor], status: String) {
        aiModels = models
        aiModelPopup.removeAllItems()
        let currentModel = aiModelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var displayedModels = models
        if !currentModel.isEmpty && !displayedModels.contains(where: { $0.id == currentModel }) {
            displayedModels.insert(
                AIModelDescriptor(id: currentModel, displayName: models.isEmpty ? "\(currentModel) · recommended" : currentModel),
                at: 0
            )
        }
        for model in displayedModels {
            let vision = model.supportsImages == true ? " · vision" : ""
            aiModelPopup.addItem(withTitle: "\(model.displayName)\(vision)")
            aiModelPopup.lastItem?.representedObject = model.id
        }
        aiModelPopup.menu?.addItem(.separator())
        aiModelPopup.addItem(withTitle: "Enter model ID manually…")
        aiModelPopup.lastItem?.representedObject = "__manual__"
        aiModelPopup.isEnabled = true

        if let matchingItem = aiModelPopup.itemArray.first(where: { ($0.representedObject as? String) == currentModel }) {
            aiModelPopup.select(matchingItem)
            setManualModelEntryVisible(false)
        } else {
            aiModelPopup.select(aiModelPopup.lastItem)
            setManualModelEntryVisible(true)
        }
        aiModelStatusLabel.stringValue = status
        aiModelStatusLabel.textColor = .secondaryLabelColor
    }

    private func setManualModelEntryVisible(_ visible: Bool) {
        aiModelField.isHidden = !visible
        aiModelFieldHeightConstraint.constant = visible ? 24 : 0
        aiModelStatusBelowPopupConstraint.isActive = false
        aiModelStatusBelowFieldConstraint.isActive = false
        (visible ? aiModelStatusBelowFieldConstraint : aiModelStatusBelowPopupConstraint).isActive = true
    }

    @objc private func refreshAIModels() {
        let configuration = draftAIConfiguration()
        let requestedProvider = configuration.provider
        let key = aiApiKeyField.stringValue
        aiRefreshModelsButton.isEnabled = false
        aiModelPopup.isEnabled = false
        aiModelStatusLabel.stringValue = "Loading models…"
        aiModelStatusLabel.textColor = .secondaryLabelColor
        AIService.shared.listModels(configuration: configuration, apiKey: key) { [weak self] result in
            guard let self else { return }
            guard self.selectedProvider == requestedProvider else { return }
            self.aiRefreshModelsButton.isEnabled = true
            switch result {
            case .success(let models):
                let status = models.isEmpty ? "No models returned · manual entry is still available." : "\(models.count) models available."
                self.rebuildModelPopup(models: models, status: status)
                if let data = try? JSONEncoder().encode(models) {
                    UserDefaults.standard.set(data, forKey: self.modelCacheKey(for: requestedProvider))
                    UserDefaults.standard.set(Date(), forKey: self.modelCacheDateKey(for: requestedProvider))
                }
            case .failure(let error):
                self.aiModelPopup.isEnabled = true
                self.aiModelStatusLabel.stringValue = error.localizedDescription + " You can still enter a model ID manually."
                self.aiModelStatusLabel.textColor = .systemRed
            }
        }
    }

    // MARK: - AI Test Connection

    @objc private func testAIConnection() {
        runAIConnectionTest(saveOnSuccess: false)
    }

    private func runAIConnectionTest(saveOnSuccess: Bool) {
        let testedConfiguration = draftAIConfiguration()
        let testedAPIKey = aiApiKeyField.stringValue
        aiTestButton.isEnabled = false
        aiSaveButton.isEnabled = false
        aiTestStatusLabel.stringValue = "Testing..."
        aiTestStatusLabel.textColor = .secondaryLabelColor

        AIService.shared.testConnection(configuration: testedConfiguration, apiKey: testedAPIKey) { [weak self] errorMessage in
            guard let self = self else { return }
            self.aiTestButton.isEnabled = true
            self.aiSaveButton.isEnabled = self.aiConfigDirty

            guard self.draftAIConfiguration() == testedConfiguration,
                  self.aiApiKeyField.stringValue == testedAPIKey else {
                self.aiTestStatusLabel.stringValue = "Settings changed · test again"
                self.aiTestStatusLabel.textColor = .systemOrange
                return
            }

            if let error = errorMessage {
                self.aiTestStatusLabel.stringValue = error
                self.aiTestStatusLabel.textColor = .systemRed
            } else if saveOnSuccess {
                do {
                    try self.saveAIFields(configuration: testedConfiguration, apiKey: testedAPIKey)
                    self.aiTestStatusLabel.stringValue = "Saved and verified"
                    self.aiTestStatusLabel.textColor = .systemGreen
                    logMessage("AI configuration saved for \(self.selectedProvider.displayName)")
                } catch {
                    self.aiSaveButton.isEnabled = true
                    self.aiTestStatusLabel.stringValue = error.localizedDescription
                    self.aiTestStatusLabel.textColor = .systemRed
                }
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
            AIProviderID.allCases.forEach { KeychainAICredentialStore.shared.delete(provider: $0) }
            if let bundleId = Bundle.main.bundleIdentifier {
                UserDefaults.standard.removePersistentDomain(forName: bundleId)
                UserDefaults.standard.synchronize()
            }
            logMessage("Debug: Reset everything and quitting.")
            NSApp.terminate(nil)
        }
    }

    // MARK: - Translation Actions

    @objc private func openProviderAPIKeyPage() {
        if let url = selectedProvider.helpURL { NSWorkspace.shared.open(url) }
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
        translatePromptDirty = false
        translateSaveButton.isEnabled = false
        showTransientFeedback(label: translateSaveStatusLabel, message: "Reset to default")
        logMessage("Translation prompt reset to default")
    }

    @objc private func resetOCRRefinePrompt() {
        ocrRefinePromptTextView.string = OCRRefineSettings.defaultSystemPrompt
        OCRRefineSettings.rawSystemPrompt = OCRRefineSettings.defaultSystemPrompt
        ocrPromptDirty = false
        ocrSaveButton.isEnabled = false
        showTransientFeedback(label: ocrSaveStatusLabel, message: "Reset to default")
        logMessage("OCR Refine prompt reset to default")
    }

    // MARK: - Save Actions

    @objc private func saveAIConfigTapped() {
        runAIConnectionTest(saveOnSuccess: true)
    }

    @objc private func saveTranslatePromptTapped() {
        TranslateSettings.rawSystemPrompt = translatePromptTextView.string
        translatePromptDirty = false
        translateSaveButton.isEnabled = false
        showTransientFeedback(label: translateSaveStatusLabel, message: "Saved")
        logMessage("Translation prompt saved")
    }

    @objc private func saveOCRPromptTapped() {
        OCRRefineSettings.rawSystemPrompt = ocrRefinePromptTextView.string
        ocrPromptDirty = false
        ocrSaveButton.isEnabled = false
        showTransientFeedback(label: ocrSaveStatusLabel, message: "Saved")
        logMessage("OCR Refine prompt saved")
    }

    /// Show a transient success message on a label, then fade it out after 2 seconds.
    private func showTransientFeedback(label: NSTextField, message: String) {
        label.stringValue = message
        label.textColor = .systemGreen
        label.alphaValue = 1.0
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak label] in
            guard let label = label else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.5
                label.animator().alphaValue = 0.0
            } completionHandler: {
                label.stringValue = ""
                label.alphaValue = 1.0
            }
        }
    }
}

// MARK: - NSTextViewDelegate (for prompt text view)
extension SettingsWindow: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        if textView === translatePromptTextView && !translatePromptDirty {
            translatePromptDirty = true
            translateSaveButton.isEnabled = true
        } else if textView === ocrRefinePromptTextView && !ocrPromptDirty {
            ocrPromptDirty = true
            ocrSaveButton.isEnabled = true
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



// MARK: - Flipped View (for scroll view document view)
/// An NSView subclass that flips the coordinate system so Auto Layout constraints
/// anchor from the top, which is needed for NSScrollView document views.
class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
