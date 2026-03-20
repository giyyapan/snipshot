import Cocoa

// MARK: - Onboarding Window

class OnboardingWindow: NSWindow {

    var onComplete: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onAccessibilityGranted: (() -> Void)?

    private var pollTimer: Timer?

    // Permission row views (for live status updates)
    private var accessibilityStatusLabel: NSTextField!
    private var accessibilityButton: NSButton!
    private var screenRecordingStatusLabel: NSTextField!
    private var screenRecordingButton: NSButton!

    // Bottom section (shown when both permissions granted)
    private var completionBox: NSView!
    private var waitingBox: NSView!
    private var hintLabel: NSTextField!
    private var doneButton: NSButton!
    private var changeHotkeyButton: NSButton!

    init() {
        let width: CGFloat = 500
        let height: CGFloat = 380
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
        self.title = "Welcome to Snipshot"
        self.level = .normal
        self.isReleasedWhenClosed = false
        self.animationBehavior = .default

        buildUI()
        refreshStatus()
        startPolling()
    }

    // MARK: - Permission & Onboarding State

    static func hasAccessibility() -> Bool {
        return AXIsProcessTrusted()
    }

    static func hasScreenRecording() -> Bool {
        return CGPreflightScreenCaptureAccess()
    }

    /// Onboarding should show if:
    ///  1. Any permission is missing (including previously granted then revoked), OR
    ///  2. User has never clicked "Done" (first-time user, or restarted after granting permissions)
    static func shouldShowOnboarding() -> Bool {
        let permissionsMissing = !hasAccessibility() || !hasScreenRecording()
        let onboardingCompleted = UserDefaults.standard.bool(forKey: "onboardingCompleted")
        return permissionsMissing || !onboardingCompleted
    }

    /// Reset onboardingCompleted if any permission was revoked, so onboarding re-appears.
    static func resetIfPermissionsRevoked() {
        if !hasAccessibility() || !hasScreenRecording() {
            UserDefaults.standard.set(false, forKey: "onboardingCompleted")
        }
    }

    // MARK: - Build UI

    private func buildUI() {
        guard let cv = self.contentView else { return }
        cv.wantsLayer = true

        // --- Title ---
        let titleLabel = NSTextField(labelWithString: "Snipshot needs your permission")
        titleLabel.font = .systemFont(ofSize: 18, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(titleLabel)

        let subtitleLabel = NSTextField(labelWithString: "Please grant the following permissions to enable all features.")
        subtitleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(subtitleLabel)

        // --- Permission Row 1: Accessibility ---
        let accessibilityRow = buildPermissionRow(
            icon: "hand.raised.fill",
            iconColor: .systemBlue,
            title: "Accessibility",
            description: "Required to register global hotkeys (e.g. F1 to capture). Without this, Snipshot can only be triggered from the menu bar.",
            buttonTitle: "Grant Accessibility",
            buttonAction: #selector(grantAccessibility),
            statusLabel: &accessibilityStatusLabel,
            actionButton: &accessibilityButton
        )
        cv.addSubview(accessibilityRow)

        // --- Permission Row 2: Screen Recording ---
        let screenRecordingRow = buildPermissionRow(
            icon: "rectangle.dashed.badge.record",
            iconColor: .systemOrange,
            title: "Screen Recording",
            description: "Required to capture screen content. Without this, screenshots will be blank or show only the wallpaper.",
            buttonTitle: "Grant Screen Recording",
            buttonAction: #selector(grantScreenRecording),
            statusLabel: &screenRecordingStatusLabel,
            actionButton: &screenRecordingButton
        )
        cv.addSubview(screenRecordingRow)

        // --- Separator ---
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(separator)

        // --- Completion box (hidden until both granted) ---
        completionBox = NSView()
        completionBox.translatesAutoresizingMaskIntoConstraints = false
        completionBox.isHidden = true
        cv.addSubview(completionBox)

        hintLabel = NSTextField(labelWithString: "All set! Press F1 to take your first screenshot.")
        hintLabel.font = .systemFont(ofSize: 13, weight: .medium)
        hintLabel.textColor = .systemGreen
        hintLabel.alignment = .center
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        completionBox.addSubview(hintLabel)

        doneButton = NSButton(title: "Done", target: self, action: #selector(doneClicked))
        doneButton.bezelStyle = .rounded
        doneButton.controlSize = .large
        doneButton.keyEquivalent = "\r"
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        completionBox.addSubview(doneButton)

        changeHotkeyButton = NSButton(title: "Change Shortcut…", target: self, action: #selector(changeHotkeyClicked))
        changeHotkeyButton.bezelStyle = .rounded
        changeHotkeyButton.controlSize = .large
        changeHotkeyButton.translatesAutoresizingMaskIntoConstraints = false
        completionBox.addSubview(changeHotkeyButton)

        // --- Waiting hint (shown when permissions not yet granted) ---
        waitingBox = NSView()
        waitingBox.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(waitingBox)

        let waitingLabel = NSTextField(labelWithString: "Grant both permissions above to continue.")
        waitingLabel.font = .systemFont(ofSize: 12, weight: .regular)
        waitingLabel.textColor = .tertiaryLabelColor
        waitingLabel.alignment = .center
        waitingLabel.translatesAutoresizingMaskIntoConstraints = false
        waitingBox.addSubview(waitingLabel)

        NSLayoutConstraint.activate([
            waitingLabel.centerXAnchor.constraint(equalTo: waitingBox.centerXAnchor),
            waitingLabel.centerYAnchor.constraint(equalTo: waitingBox.centerYAnchor),
        ])

        // --- Layout ---
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: cv.topAnchor, constant: 24),
            titleLabel.centerXAnchor.constraint(equalTo: cv.centerXAnchor),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.centerXAnchor.constraint(equalTo: cv.centerXAnchor),

            accessibilityRow.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 20),
            accessibilityRow.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 24),
            accessibilityRow.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -24),

            screenRecordingRow.topAnchor.constraint(equalTo: accessibilityRow.bottomAnchor, constant: 16),
            screenRecordingRow.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 24),
            screenRecordingRow.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -24),

            separator.topAnchor.constraint(equalTo: screenRecordingRow.bottomAnchor, constant: 20),
            separator.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 24),
            separator.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -24),

            completionBox.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 12),
            completionBox.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 24),
            completionBox.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -24),
            completionBox.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -16),

            hintLabel.topAnchor.constraint(equalTo: completionBox.topAnchor, constant: 4),
            hintLabel.centerXAnchor.constraint(equalTo: completionBox.centerXAnchor),

            doneButton.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 12),
            doneButton.trailingAnchor.constraint(equalTo: completionBox.centerXAnchor, constant: -8),
            doneButton.widthAnchor.constraint(equalToConstant: 120),

            changeHotkeyButton.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 12),
            changeHotkeyButton.leadingAnchor.constraint(equalTo: completionBox.centerXAnchor, constant: 8),
            changeHotkeyButton.widthAnchor.constraint(equalToConstant: 160),

            waitingBox.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 12),
            waitingBox.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 24),
            waitingBox.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -24),
            waitingBox.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -16),
        ])
    }

    // MARK: - Permission Row Builder

    private func buildPermissionRow(
        icon: String,
        iconColor: NSColor,
        title: String,
        description: String,
        buttonTitle: String,
        buttonAction: Selector,
        statusLabel: inout NSTextField!,
        actionButton: inout NSButton!
    ) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        // Icon
        let config = NSImage.SymbolConfiguration(pointSize: 24, weight: .regular)
        let image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        let iconView = NSImageView()
        iconView.image = image
        iconView.contentTintColor = iconColor
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(iconView)

        // Title + status badge
        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.textColor = .labelColor
        titleField.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(titleField)

        let badge = NSTextField(labelWithString: "")
        badge.font = .systemFont(ofSize: 11, weight: .medium)
        badge.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(badge)
        statusLabel = badge

        // Description
        let descField = NSTextField(wrappingLabelWithString: description)
        descField.font = .systemFont(ofSize: 11, weight: .regular)
        descField.textColor = .secondaryLabelColor
        descField.isSelectable = false
        descField.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(descField)

        // Action button
        let button = NSButton(title: buttonTitle, target: self, action: buttonAction)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(button)
        actionButton = button

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            iconView.topAnchor.constraint(equalTo: row.topAnchor, constant: 4),
            iconView.widthAnchor.constraint(equalToConstant: 32),
            iconView.heightAnchor.constraint(equalToConstant: 32),

            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            titleField.topAnchor.constraint(equalTo: row.topAnchor),

            badge.leadingAnchor.constraint(equalTo: titleField.trailingAnchor, constant: 8),
            badge.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),

            descField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            descField.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            descField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 2),

            button.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            button.topAnchor.constraint(equalTo: descField.bottomAnchor, constant: 6),
            button.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])

        return row
    }

    // MARK: - Actions

    @objc private func grantAccessibility() {
        // Trigger the system authorization prompt (system will guide user to Settings if needed)
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    @objc private func grantScreenRecording() {
        // Trigger the system authorization prompt (system will guide user to Settings if needed)
        CGRequestScreenCaptureAccess()
    }

    @objc private func doneClicked() {
        stopPolling()
        // Mark onboarding as completed
        UserDefaults.standard.set(true, forKey: "onboardingCompleted")
        onComplete?()
        self.close()
    }

    @objc private func changeHotkeyClicked() {
        stopPolling()
        // Mark onboarding as completed
        UserDefaults.standard.set(true, forKey: "onboardingCompleted")
        // Open settings first (keeps dock icon visible), then close onboarding
        onOpenSettings?()
        self.close()
        onComplete?()
    }

    // MARK: - Live Status Polling

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private var didNotifyAccessibility = false

    private func refreshStatus() {
        let hasAx = OnboardingWindow.hasAccessibility()
        let hasSR = OnboardingWindow.hasScreenRecording()

        // Notify when accessibility is granted (and re-notify if revoked then re-granted)
        if hasAx && !didNotifyAccessibility {
            didNotifyAccessibility = true
            onAccessibilityGranted?()
        } else if !hasAx && didNotifyAccessibility {
            // Permission was revoked, reset so we can notify again if re-granted
            didNotifyAccessibility = false
        }

        // Update accessibility status
        if hasAx {
            accessibilityStatusLabel.stringValue = "✓ Granted"
            accessibilityStatusLabel.textColor = .systemGreen
            accessibilityButton.isEnabled = false
            accessibilityButton.title = "Granted"
        } else {
            accessibilityStatusLabel.stringValue = "⚠ Not Granted"
            accessibilityStatusLabel.textColor = .systemYellow
            accessibilityButton.isEnabled = true
            accessibilityButton.title = "Grant Accessibility"
        }

        // Update screen recording status
        if hasSR {
            screenRecordingStatusLabel.stringValue = "✓ Granted"
            screenRecordingStatusLabel.textColor = .systemGreen
            screenRecordingButton.isEnabled = false
            screenRecordingButton.title = "Granted"
        } else {
            screenRecordingStatusLabel.stringValue = "⚠ Not Granted"
            screenRecordingStatusLabel.textColor = .systemYellow
            screenRecordingButton.isEnabled = true
            screenRecordingButton.title = "Grant Screen Recording"
        }

        // Update completion section
        let allGranted = hasAx && hasSR
        completionBox.isHidden = !allGranted

        // Update the hint with current hotkey
        if allGranted {
            let savedKeyCode = UserDefaults.standard.object(forKey: "captureHotkeyKeyCode") as? UInt16
                ?? HotkeyConfig.defaultCapture.keyCode
            let savedModifiers = UserDefaults.standard.object(forKey: "captureHotkeyModifiers") as? UInt
                ?? HotkeyConfig.defaultCapture.modifiers.rawValue
            let config = HotkeyConfig(keyCode: savedKeyCode, modifiers: NSEvent.ModifierFlags(rawValue: savedModifiers))
            hintLabel.stringValue = "All set! Press \(config.displayString) to take your first screenshot."
        }

        // Toggle waiting hint visibility
        waitingBox.isHidden = allGranted
    }

    // MARK: - Cleanup

    deinit {
        stopPolling()
    }
}
