import Cocoa
import Carbon.HIToolbox

let kSnipshotVersion = "0.1.0"

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

class SettingsWindow: NSPanel {
    private var hotkeyField: HotkeyRecorderField!
    private var currentConfig: HotkeyConfig
    var onHotkeyChanged: ((HotkeyConfig) -> Void)?

    init() {
        // Load saved hotkey or use default
        let savedKeyCode = UserDefaults.standard.object(forKey: "captureHotkeyKeyCode") as? UInt16
            ?? HotkeyConfig.defaultCapture.keyCode
        let savedModifiers = UserDefaults.standard.object(forKey: "captureHotkeyModifiers") as? UInt
            ?? HotkeyConfig.defaultCapture.modifiers.rawValue
        currentConfig = HotkeyConfig(keyCode: savedKeyCode, modifiers: NSEvent.ModifierFlags(rawValue: savedModifiers))

        let width: CGFloat = 380
        let height: CGFloat = 200
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
        self.isFloatingPanel = true
        self.level = .floating
        self.animationBehavior = .default
        self.isReleasedWhenClosed = false
        setupUI()
    }

    private func setupUI() {
        guard let contentView = self.contentView else { return }
        contentView.wantsLayer = true

        // Version label
        let versionLabel = NSTextField(labelWithString: "Snipshot v\(kSnipshotVersion)")
        versionLabel.font = .systemFont(ofSize: 11, weight: .regular)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(versionLabel)

        // Hotkey section title
        let hotkeyTitle = NSTextField(labelWithString: "Capture Hotkey")
        hotkeyTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        hotkeyTitle.textColor = .labelColor
        hotkeyTitle.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(hotkeyTitle)

        // Hotkey recorder
        hotkeyField = HotkeyRecorderField(config: currentConfig)
        hotkeyField.translatesAutoresizingMaskIntoConstraints = false
        hotkeyField.onConfigChanged = { [weak self] newConfig in
            self?.currentConfig = newConfig
            // Save to UserDefaults
            UserDefaults.standard.set(newConfig.keyCode, forKey: "captureHotkeyKeyCode")
            UserDefaults.standard.set(newConfig.modifiers.rawValue, forKey: "captureHotkeyModifiers")
            self?.onHotkeyChanged?(newConfig)
        }
        contentView.addSubview(hotkeyField)

        // Reset button
        let resetButton = NSButton(title: "Reset to Default (F1)", target: self, action: #selector(resetHotkey))
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .regular
        resetButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(resetButton)

        NSLayoutConstraint.activate([
            hotkeyTitle.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            hotkeyTitle.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),

            hotkeyField.centerYAnchor.constraint(equalTo: hotkeyTitle.centerYAnchor),
            hotkeyField.leadingAnchor.constraint(equalTo: hotkeyTitle.trailingAnchor, constant: 16),
            hotkeyField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            hotkeyField.heightAnchor.constraint(equalToConstant: 28),

            resetButton.topAnchor.constraint(equalTo: hotkeyTitle.bottomAnchor, constant: 20),
            resetButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),

            versionLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            versionLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
        ])
    }

    @objc private func resetHotkey() {
        let defaultConfig = HotkeyConfig.defaultCapture
        currentConfig = defaultConfig
        hotkeyField.setConfig(defaultConfig)
        UserDefaults.standard.set(defaultConfig.keyCode, forKey: "captureHotkeyKeyCode")
        UserDefaults.standard.set(defaultConfig.modifiers.rawValue, forKey: "captureHotkeyModifiers")
        onHotkeyChanged?(defaultConfig)
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
