import Cocoa

// MARK: - OverlayView Plugin Mode (Input Only)
// After the user submits input, the overlay closes and execution is handed off
// to PluginManager which runs the script in the background.
extension OverlayView {

    // MARK: - Enter Plugin Mode
    func enterPluginMode(_ plugin: Plugin) {
        guard hasSelection else { return }

        // Quick-action plugins: execute immediately with preset prompt, no input UI
        if plugin.manifest.isQuickAction {
            executeQuickAction(plugin)
            return
        }

        activePlugin = plugin
        annoState.currentTool = nil
        annoState.selectedElementId = nil

        // Remove existing panels
        removeAllPanels()

        mode = .pluginInput

        // Show plugin input panel
        showPluginInputPanel(plugin)
        needsDisplay = true
    }

    // MARK: - Quick Action (no input UI)
    private func executeQuickAction(_ plugin: Plugin) {
        guard let croppedImage = cropImage() else {
            logMessage("Quick action: cropImage() returned nil")
            return
        }

        let prompt = plugin.manifest.quickPrompt ?? ""
        logMessage("Quick action '\(plugin.manifest.name)' executing with preset prompt")

        // Hand off to PluginManager for background execution
        PluginManager.shared.executePlugin(
            plugin: plugin,
            image: croppedImage,
            inputText: prompt
        )

        // Close the overlay
        onAction(.cancel)
    }

    // MARK: - Plugin Input Panel
    func showPluginInputPanel(_ plugin: Plugin) {
        let padding: CGFloat = 8
        let fieldHeight: CGFloat = 24
        let btnSize: CGFloat = 26
        let spacing: CGFloat = 6
        let panelWidth: CGFloat = 340
        let h: CGFloat = 36

        let x = selectionRect.midX - panelWidth / 2
        let y = panelYPosition()

        let panel = NSView(frame: NSRect(x: x, y: y, width: panelWidth, height: h))
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor(white: 0.95, alpha: 0.92).cgColor
        panel.layer?.cornerRadius = 6
        panel.layer?.masksToBounds = true

        // Text input field
        let fieldY = (h - fieldHeight) / 2
        let fieldWidth = panelWidth - padding * 2 - btnSize - spacing
        let tf = NSTextField(frame: NSRect(x: padding, y: fieldY, width: fieldWidth, height: fieldHeight))
        tf.font = NSFont.systemFont(ofSize: 12)
        tf.placeholderString = plugin.manifest.inputs?.first?.placeholder ?? "Enter input..."
        tf.isBordered = true
        tf.bezelStyle = .roundedBezel
        tf.focusRingType = .none
        tf.isEditable = true
        tf.isSelectable = true
        tf.target = self
        tf.action = #selector(pluginInputSubmit(_:))
        tf.tag = 9999  // marker tag
        panel.addSubview(tf)

        // Submit button
        let btnX = padding + fieldWidth + spacing
        let btnY = (h - btnSize) / 2
        let submitBtn = HoverIconButton(
            frame: NSRect(x: btnX, y: btnY, width: btnSize, height: btnSize),
            symbolName: "paperplane.fill",
            tooltip: "Run  \u{21A9}"
        )
        submitBtn.onPress = { [weak self] in
            self?.submitPlugin(inputText: tf.stringValue)
        }
        panel.addSubview(submitBtn)

        addSubview(panel)
        pluginPanelView = panel
        pluginInputField = tf

        // Focus the text field
        window?.makeFirstResponder(tf)
    }

    @objc func pluginInputSubmit(_ sender: NSTextField) {
        submitPlugin(inputText: sender.stringValue)
    }

    // MARK: - Submit: crop image, close overlay, hand off to PluginManager
    func submitPlugin(inputText: String) {
        guard let plugin = activePlugin else { return }
        guard let croppedImage = cropImage() else {
            logMessage("Plugin submit: cropImage() returned nil")
            return
        }

        logMessage("Plugin '\(plugin.manifest.name)' submitted with input: \(inputText.prefix(100))")

        // Clean up plugin UI state
        exitPluginMode()

        // Hand off to PluginManager for background execution
        PluginManager.shared.executePlugin(
            plugin: plugin,
            image: croppedImage,
            inputText: inputText
        )

        // Close the overlay — user can continue working
        onAction(.cancel)
    }

    // MARK: - Exit Plugin Mode (cleanup only)
    func exitPluginMode() {
        pluginInputField = nil
        pluginPanelView?.removeFromSuperview()
        pluginPanelView = nil
        activePlugin = nil
    }
}
