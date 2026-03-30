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

// MARK: - Settings Window

class SettingsWindow: NSWindow {
    private var hotkeyField: HotkeyRecorderField!
    private var currentConfig: HotkeyConfig
    var onHotkeyChanged: ((HotkeyConfig) -> Void)?
    var onShowOnboarding: (() -> Void)?

    // Debug section views (for collapse/expand)
    private var debugDisclosureButton: NSButton!
    private var debugContentViews: [NSView] = []
    private var debugContentConstraints: [NSLayoutConstraint] = []
    private var debugIsExpanded = false

    // Dynamic height constraints
    private var windowHeightConstraint: NSLayoutConstraint?

    init() {
        // Load saved hotkey or use default
        let savedKeyCode = UserDefaults.standard.object(forKey: "captureHotkeyKeyCode") as? UInt16
            ?? HotkeyConfig.defaultCapture.keyCode
        let savedModifiers = UserDefaults.standard.object(forKey: "captureHotkeyModifiers") as? UInt
            ?? HotkeyConfig.defaultCapture.modifiers.rawValue
        currentConfig = HotkeyConfig(keyCode: savedKeyCode, modifiers: NSEvent.ModifierFlags(rawValue: savedModifiers))

        let width: CGFloat = 400
        let height: CGFloat = 460
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

        // =====================================================================
        // Version label (bottom-right)
        // =====================================================================
        let versionLabel = NSTextField(labelWithString: "Snipshot v\(kSnipshotVersion)")
        versionLabel.font = .systemFont(ofSize: 11, weight: .regular)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(versionLabel)

        let authorLabel = NSTextField(labelWithString: "by giyyapan")
        authorLabel.font = .systemFont(ofSize: 11, weight: .regular)
        authorLabel.textColor = .tertiaryLabelColor
        authorLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(authorLabel)

        // =====================================================================
        // Section 1: Capture Hotkey
        // =====================================================================
        let hotkeyTitle = NSTextField(labelWithString: "Capture Hotkey")
        hotkeyTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        hotkeyTitle.textColor = .labelColor
        hotkeyTitle.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(hotkeyTitle)

        hotkeyField = HotkeyRecorderField(config: currentConfig)
        hotkeyField.translatesAutoresizingMaskIntoConstraints = false
        hotkeyField.onConfigChanged = { [weak self] newConfig in
            self?.currentConfig = newConfig
            UserDefaults.standard.set(newConfig.keyCode, forKey: "captureHotkeyKeyCode")
            UserDefaults.standard.set(newConfig.modifiers.rawValue, forKey: "captureHotkeyModifiers")
            self?.onHotkeyChanged?(newConfig)
        }
        contentView.addSubview(hotkeyField)

        let resetButton = NSButton(title: "Reset to Default (F1)", target: self, action: #selector(resetHotkey))
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .regular
        resetButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(resetButton)

        // =====================================================================
        // Separator 1
        // =====================================================================
        let separator1 = NSBox()
        separator1.boxType = .separator
        separator1.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(separator1)

        // =====================================================================
        // Section 2: General Settings
        // =====================================================================
        let generalTitle = NSTextField(labelWithString: "General")
        generalTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        generalTitle.textColor = .labelColor
        generalTitle.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(generalTitle)

        // Auto-copy toggle
        let autoCopyCheckbox = NSButton(checkboxWithTitle: "Auto-copy after selection",
                                         target: self, action: #selector(toggleAutoCopy(_:)))
        autoCopyCheckbox.state = UserDefaults.standard.bool(forKey: "autoCopyAfterSelection") ? .on : .off
        autoCopyCheckbox.controlSize = .regular
        autoCopyCheckbox.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(autoCopyCheckbox)

        let autoCopyDesc = NSTextField(labelWithString: "Automatically copy selection to clipboard when area is selected")
        autoCopyDesc.font = .systemFont(ofSize: 11, weight: .regular)
        autoCopyDesc.textColor = .secondaryLabelColor
        autoCopyDesc.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(autoCopyDesc)

        // Launch at login toggle
        let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Launch at login",
                                              target: self, action: #selector(toggleLaunchAtLogin(_:)))
        launchAtLoginCheckbox.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        launchAtLoginCheckbox.controlSize = .regular
        launchAtLoginCheckbox.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(launchAtLoginCheckbox)

        let launchDesc = NSTextField(labelWithString: "Start Snipshot automatically when you log in")
        launchDesc.font = .systemFont(ofSize: 11, weight: .regular)
        launchDesc.textColor = .secondaryLabelColor
        launchDesc.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(launchDesc)

        // Double-click to close pin toggle
        let dblClickCheckbox = NSButton(checkboxWithTitle: "Double-click to close pinned image",
                                         target: self, action: #selector(toggleDoubleClickClosePin(_:)))
        // Default to ON if the key has never been set
        let dblClickDefault = UserDefaults.standard.object(forKey: "doubleClickToClosePin") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "doubleClickToClosePin")
        dblClickCheckbox.state = dblClickDefault ? .on : .off
        dblClickCheckbox.controlSize = .regular
        dblClickCheckbox.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(dblClickCheckbox)

        let dblClickDesc = NSTextField(labelWithString: "Double-click a pinned screenshot to dismiss it")
        dblClickDesc.font = .systemFont(ofSize: 11, weight: .regular)
        dblClickDesc.textColor = .secondaryLabelColor
        dblClickDesc.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(dblClickDesc)

        // =====================================================================
        // Separator 2 (before plugins)
        // =====================================================================
        let separator2 = NSBox()
        separator2.boxType = .separator
        separator2.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(separator2)

        // =====================================================================
        // Section 3: Plugins
        // =====================================================================
        let pluginsTitle = NSTextField(labelWithString: "Plugins")
        pluginsTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        pluginsTitle.textColor = .labelColor
        pluginsTitle.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(pluginsTitle)

        let pluginCount = PluginManager.shared.plugins.count
        let pluginsDesc = NSTextField(labelWithString: "\(pluginCount) plugin(s) loaded from ~/.snipshot/plugins/")
        pluginsDesc.font = .systemFont(ofSize: 11, weight: .regular)
        pluginsDesc.textColor = .secondaryLabelColor
        pluginsDesc.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(pluginsDesc)

        let openPluginsFolderBtn = NSButton(title: "Open Plugins Folder", target: self, action: #selector(openPluginsFolder))
        openPluginsFolderBtn.bezelStyle = .rounded
        openPluginsFolderBtn.controlSize = .regular
        openPluginsFolderBtn.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(openPluginsFolderBtn)

        // =====================================================================
        // Separator 3 (before debug)
        // =====================================================================
        let separator3 = NSBox()
        separator3.boxType = .separator
        separator3.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(separator3)

        // =====================================================================
        // Section 4: Debug (collapsible, subtle entry)
        // =====================================================================
        // Use a small clickable text button as the disclosure trigger
        debugDisclosureButton = NSButton(title: "Debug ▶", target: self, action: #selector(toggleDebugSection))
        debugDisclosureButton.bezelStyle = .inline
        debugDisclosureButton.isBordered = false
        debugDisclosureButton.font = .systemFont(ofSize: 11, weight: .regular)
        debugDisclosureButton.contentTintColor = .tertiaryLabelColor
        debugDisclosureButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(debugDisclosureButton)

        // Debug content views (initially hidden)
        let onboardingCheckbox = NSButton(checkboxWithTitle: "Always show onboarding on launch",
                                          target: self, action: #selector(toggleAlwaysOnboarding(_:)))
        onboardingCheckbox.state = UserDefaults.standard.bool(forKey: "debugAlwaysShowOnboarding") ? .on : .off
        onboardingCheckbox.controlSize = .regular
        onboardingCheckbox.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(onboardingCheckbox)

        let showNowButton = NSButton(title: "Show Onboarding Now", target: self, action: #selector(showOnboardingNow))
        showNowButton.bezelStyle = .rounded
        showNowButton.controlSize = .regular
        showNowButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(showNowButton)

        let resetAllButton = NSButton(title: "Reset Everything & Quit", target: self, action: #selector(resetEverythingAndQuit))
        resetAllButton.bezelStyle = .rounded
        resetAllButton.controlSize = .regular
        resetAllButton.contentTintColor = .systemRed
        resetAllButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(resetAllButton)

        debugContentViews = [onboardingCheckbox, showNowButton, resetAllButton]

        // =====================================================================
        // Layout
        // =====================================================================
        let margin: CGFloat = 24
        let sectionGap: CGFloat = 16
        let itemGap: CGFloat = 8
        let descGap: CGFloat = 2

        NSLayoutConstraint.activate([
            // Hotkey section
            hotkeyTitle.topAnchor.constraint(equalTo: contentView.topAnchor, constant: margin),
            hotkeyTitle.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margin),

            hotkeyField.centerYAnchor.constraint(equalTo: hotkeyTitle.centerYAnchor),
            hotkeyField.leadingAnchor.constraint(equalTo: hotkeyTitle.trailingAnchor, constant: 16),
            hotkeyField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -margin),
            hotkeyField.heightAnchor.constraint(equalToConstant: 28),

            resetButton.topAnchor.constraint(equalTo: hotkeyTitle.bottomAnchor, constant: sectionGap),
            resetButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margin),

            // Separator 1
            separator1.topAnchor.constraint(equalTo: resetButton.bottomAnchor, constant: sectionGap),
            separator1.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margin),
            separator1.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -margin),

            // General section title
            generalTitle.topAnchor.constraint(equalTo: separator1.bottomAnchor, constant: sectionGap),
            generalTitle.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margin),

            // Auto-copy checkbox
            autoCopyCheckbox.topAnchor.constraint(equalTo: generalTitle.bottomAnchor, constant: itemGap),
            autoCopyCheckbox.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margin),

            autoCopyDesc.topAnchor.constraint(equalTo: autoCopyCheckbox.bottomAnchor, constant: descGap),
            autoCopyDesc.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margin + 18),

            // Launch at login checkbox
            launchAtLoginCheckbox.topAnchor.constraint(equalTo: autoCopyDesc.bottomAnchor, constant: itemGap + 4),
            launchAtLoginCheckbox.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margin),

            launchDesc.topAnchor.constraint(equalTo: launchAtLoginCheckbox.bottomAnchor, constant: descGap),
            launchDesc.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margin + 18),

            // Double-click to close pin checkbox
            dblClickCheckbox.topAnchor.constraint(equalTo: launchDesc.bottomAnchor, constant: itemGap + 4),
            dblClickCheckbox.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margin),

            dblClickDesc.topAnchor.constraint(equalTo: dblClickCheckbox.bottomAnchor, constant: descGap),
            dblClickDesc.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margin + 18),

            // Separator 2
            separator2.topAnchor.constraint(equalTo: dblClickDesc.bottomAnchor, constant: sectionGap),
            separator2.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margin),
            separator2.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -margin),

            // Plugins section
            pluginsTitle.topAnchor.constraint(equalTo: separator2.bottomAnchor, constant: sectionGap),
            pluginsTitle.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margin),

            pluginsDesc.topAnchor.constraint(equalTo: pluginsTitle.bottomAnchor, constant: descGap + 2),
            pluginsDesc.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margin),

            openPluginsFolderBtn.topAnchor.constraint(equalTo: pluginsDesc.bottomAnchor, constant: itemGap),
            openPluginsFolderBtn.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margin),

            // Separator 3
            separator3.topAnchor.constraint(equalTo: openPluginsFolderBtn.bottomAnchor, constant: sectionGap),
            separator3.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margin),
            separator3.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -margin),

            // Debug disclosure button (subtle, small)
            debugDisclosureButton.topAnchor.constraint(equalTo: separator3.bottomAnchor, constant: 10),
            debugDisclosureButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margin),

            // Debug content (initially hidden via constraints)
            onboardingCheckbox.topAnchor.constraint(equalTo: debugDisclosureButton.bottomAnchor, constant: itemGap),
            onboardingCheckbox.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margin),

            showNowButton.topAnchor.constraint(equalTo: onboardingCheckbox.bottomAnchor, constant: itemGap),
            showNowButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margin),

            resetAllButton.topAnchor.constraint(equalTo: showNowButton.bottomAnchor, constant: itemGap),
            resetAllButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margin),

            // Version + author labels
            versionLabel.bottomAnchor.constraint(equalTo: authorLabel.topAnchor, constant: -2),
            versionLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -margin),

            authorLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            authorLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -margin),
        ])

        // Start with debug section collapsed
        setDebugExpanded(false, animate: false)
    }

    // MARK: - Debug Section Collapse/Expand

    private func setDebugExpanded(_ expanded: Bool, animate: Bool) {
        debugIsExpanded = expanded

        if expanded {
            debugDisclosureButton.title = "Debug ▼"
        } else {
            debugDisclosureButton.title = "Debug ▶"
        }

        let alpha: CGFloat = expanded ? 1.0 : 0.0

        if animate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.allowsImplicitAnimation = true
                for view in debugContentViews {
                    view.animator().alphaValue = alpha
                    view.isHidden = !expanded
                }
                // Resize window
                self.adjustWindowHeight(expanded: expanded)
            }
        } else {
            for view in debugContentViews {
                view.alphaValue = alpha
                view.isHidden = !expanded
            }
            adjustWindowHeight(expanded: expanded)
        }
    }

    private func adjustWindowHeight(expanded: Bool) {
        let collapsedHeight: CGFloat = 460
        let expandedHeight: CGFloat = 570
        let targetHeight = expanded ? expandedHeight : collapsedHeight

        var frame = self.frame
        let delta = targetHeight - frame.height
        frame.origin.y -= delta
        frame.size.height = targetHeight
        self.setFrame(frame, display: true, animate: true)
    }

    @objc private func toggleDebugSection() {
        setDebugExpanded(!debugIsExpanded, animate: true)
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

    @objc private func openPluginsFolder() {
        PluginManager.shared.openPluginsFolder()
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
            // Revert checkbox state on failure
            sender.state = enabled ? .off : .on
        }
    }

    @objc private func toggleDoubleClickClosePin(_ sender: NSButton) {
        let enabled = sender.state == .on
        UserDefaults.standard.set(enabled, forKey: "doubleClickToClosePin")
        logMessage("Double-click to close pin = \(enabled)")
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
            // Unregister login item before reset
            try? SMAppService.mainApp.unregister()
            // Remove all UserDefaults for this app
            if let bundleId = Bundle.main.bundleIdentifier {
                UserDefaults.standard.removePersistentDomain(forName: bundleId)
                UserDefaults.standard.synchronize()
            }
            logMessage("Debug: Reset everything and quitting.")
            NSApp.terminate(nil)
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

        // Esc cancels recording
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
