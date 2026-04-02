import Cocoa
import Carbon.HIToolbox
import os.log
import UniformTypeIdentifiers
import Sparkle

private let logger = Logger(subsystem: "com.giyyapan.snipshot", category: "main")

func logMessage(_ message: String) {
    logger.notice("\(message, privacy: .public)")
    let logFile = NSHomeDirectory() + "/snipshot_debug.log"
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(message)\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logFile) {
            if let handle = FileHandle(forWritingAtPath: logFile) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            FileManager.default.createFile(atPath: logFile, contents: data)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    // MARK: - Properties
    private var statusItem: NSStatusItem!
    private var eventTap: CFMachPort?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var overlayWindow: OverlayWindow?
    private var pinWindows: [PinWindow] = []
    private var settingsWindow: SettingsWindow?
    private var onboardingWindow: OnboardingWindow?
    private var chatWindow: ChatWindow?
    var isCapturing = false
    private var captureHotkey: HotkeyConfig = HotkeyConfig.defaultCapture

    // MARK: - Sparkle Auto-Update
    private let updaterController: SPUStandardUpdaterController

    override init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
    }

    // MARK: - App Lifecycle
    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.removeItem(atPath: NSHomeDirectory() + "/snipshot_debug.log")

        NSApp.setActivationPolicy(.accessory)

        // Load saved hotkey config
        if let savedKeyCode = UserDefaults.standard.object(forKey: "captureHotkeyKeyCode") as? UInt16 {
            let savedModifiers = UserDefaults.standard.object(forKey: "captureHotkeyModifiers") as? UInt ?? 0
            captureHotkey = HotkeyConfig(keyCode: savedKeyCode, modifiers: NSEvent.ModifierFlags(rawValue: savedModifiers))
        }

        setupStatusItem()

        // Reset onboarding state if permissions were revoked since last run
        OnboardingWindow.resetIfPermissionsRevoked()

        // Check permissions and show onboarding if needed
        let forceOnboarding = UserDefaults.standard.bool(forKey: "debugAlwaysShowOnboarding")
        if OnboardingWindow.shouldShowOnboarding() || forceOnboarding {
            logMessage("Showing onboarding (should show: \(OnboardingWindow.shouldShowOnboarding()), debug force: \(forceOnboarding))")
            showOnboarding()
            // If accessibility is already granted, register hotkey immediately
            if AXIsProcessTrusted() {
                setupGlobalHotkey()
            }
            // Otherwise, onboarding's polling will call onAccessibilityGranted when ready
        } else {
            // No onboarding needed, register hotkey directly
            setupGlobalHotkey()
        }

        // Listen for "open settings for translation" notification
        NotificationCenter.default.addObserver(self, selector: #selector(openSettingsForTranslation), name: NSNotification.Name("OpenSettingsForTranslation"), object: nil)

        logMessage("Snipshot v\(kSnipshotVersion) ready. Capture hotkey: \(captureHotkey.displayString), F3 to pin from clipboard.")
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeGlobalHotkey()
    }

    // MARK: - Status Bar
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "scissors", accessibilityDescription: "Snipshot")
        }
        updateStatusMenu()
    }

    private func updateStatusMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Capture (\(captureHotkey.displayString))", action: #selector(startCapture), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        // Check for Updates menu item
        let checkForUpdatesItem = NSMenuItem(title: "Check for Updates...", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        checkForUpdatesItem.target = updaterController
        menu.addItem(checkForUpdatesItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Quit Snipshot", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    // MARK: - Global Hotkey
    private func setupGlobalHotkey() {
        let trusted = AXIsProcessTrusted()
        logMessage("AXIsProcessTrusted = \(trusted)")

        if trusted {
            setupEventTap()
        } else {
            logMessage("Accessibility not granted. Hotkey will be registered when granted.")
        }

        setupNSEventMonitor()
    }

    private func setupEventTap() {
        guard eventTap == nil else { return }

        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

        let callback: CGEventTapCallBack = { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let refcon = refcon {
                    let appDelegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
                    if let machPort = appDelegate.eventTap {
                        CGEvent.tapEnable(tap: machPort, enable: true)
                    }
                }
                return Unmanaged.passRetained(event)
            }

            guard type == .keyDown else {
                return Unmanaged.passRetained(event)
            }

            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags

            let appDelegate = Unmanaged<AppDelegate>.fromOpaque(refcon!).takeUnretainedValue()
            let hotkey = appDelegate.captureHotkey

            // Check capture hotkey
            let relevantFlags = flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
            var expectedCGFlags: CGEventFlags = []
            if hotkey.modifiers.contains(.command) { expectedCGFlags.insert(.maskCommand) }
            if hotkey.modifiers.contains(.option) { expectedCGFlags.insert(.maskAlternate) }
            if hotkey.modifiers.contains(.control) { expectedCGFlags.insert(.maskControl) }
            if hotkey.modifiers.contains(.shift) { expectedCGFlags.insert(.maskShift) }

            if keyCode == Int64(hotkey.keyCode) && relevantFlags == expectedCGFlags {
                DispatchQueue.main.async {
                    logMessage("Capture hotkey pressed (CGEvent tap)")
                    appDelegate.startCapture()
                }
                return nil
            }

            if keyCode == 99 { // F3
                let appDelegate = Unmanaged<AppDelegate>.fromOpaque(refcon!).takeUnretainedValue()
                if appDelegate.isCapturing {
                    // During capture, let F3 pass through to overlay for pin-selection
                    return Unmanaged.passRetained(event)
                }
                DispatchQueue.main.async {
                    logMessage("F3 pressed (CGEvent tap)")
                    appDelegate.pinFromClipboard()
                }
                return nil
            }

            return Unmanaged.passRetained(event)
        }

        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: refcon
        ) else {
            logMessage("Failed to create CGEvent tap.")
            return
        }

        self.eventTap = tap
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        logMessage("CGEvent tap registered.")
    }

    private func setupNSEventMonitor() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return }
            if self.matchesCaptureHotkey(event) {
                logMessage("Capture hotkey pressed (global NSEvent monitor)")
                self.startCapture()
            } else if event.keyCode == 99 {
                guard !self.isCapturing else { return }
                logMessage("F3 pressed (global NSEvent monitor)")
                self.pinFromClipboard()
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            if self.matchesCaptureHotkey(event) {
                logMessage("Capture hotkey pressed (local NSEvent monitor)")
                self.startCapture()
                return nil
            } else if event.keyCode == 99 {
                guard !self.isCapturing else { return event }
                logMessage("F3 pressed (local NSEvent monitor)")
                self.pinFromClipboard()
                return nil
            }
            return event
        }

        logMessage("NSEvent monitors registered.")
    }

    private func matchesCaptureHotkey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        return event.keyCode == captureHotkey.keyCode && modifiers == captureHotkey.modifiers
    }

    private func removeGlobalHotkey() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    // MARK: - Capture Flow
    @objc func startCapture() {
        guard !isCapturing else {
            logMessage("Already capturing, ignoring.")
            return
        }
        isCapturing = true
        logMessage("Starting capture...")
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main else {
            isCapturing = false
            return
        }
        // Use CGWindowListCreateImage instead of ScreenCaptureKit to avoid stealing focus.
        // SCScreenshotManager.captureImage activates the app, causing other windows to lose
        // their focused shadow. CGWindowListCreateImage does not have this side effect.
        let mainHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let cgRect = CGRect(
            x: screen.frame.origin.x,
            y: mainHeight - screen.frame.origin.y - screen.frame.height,
            width: screen.frame.width,
            height: screen.frame.height
        )
        guard let cgImage = CGWindowListCreateImage(
            cgRect,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution]
        ) else {
            logMessage("CGWindowListCreateImage failed.")
            isCapturing = false
            return
        }
        let nsImage = NSImage(cgImage: cgImage, size: screen.frame.size)
        logMessage("Screenshot captured: \(Int(nsImage.size.width))x\(Int(nsImage.size.height))")
        DispatchQueue.main.async {
            self.showOverlay(with: nsImage)
        }
    }


    private func showOverlay(with screenshot: NSImage) {
        // Use the screen where the mouse cursor is, not the main/focused screen
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main else { return }

        overlayWindow = OverlayWindow(
            contentRect: screen.frame,
            screenshot: screenshot
        ) { [weak self] action in
            self?.handleOverlayAction(action)
        }

        // Multi-screen follow: when mouse moves to another screen in idle mode, re-capture
        if let overlayView = overlayWindow?.contentView as? OverlayView {
            overlayView.onScreenChange = { [weak self] in
                guard let self = self else { return }
                self.dismissOverlay()
                // Small delay to let the dismiss complete, then re-capture on the new screen
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self.startCapture()
                }
            }
        }

        overlayWindow?.makeKeyAndOrderFront(nil)
    }

    private func handleOverlayAction(_ action: OverlayAction) {
        switch action {
        case .copy(let image, _):
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([image])
            logMessage("Image copied to clipboard.")
            dismissOverlay()

        case .save(let image, _):
            // Keep overlay visible while save panel is open
            saveImage(image)

        case .pin(let image, let rect):
            dismissOverlay()
            pinImage(image, at: NSPoint(x: rect.origin.x, y: rect.origin.y))
            logMessage("Image pinned to screen.")

        case .askAI(let image, let rect):
            logMessage("Ask AI for rect: \(rect)")
            dismissOverlay()
            showChatWindow(image: image)

        case .scrollCapture(let rect, let firstFrame):
            logMessage("Starting scroll capture for rect: \(rect)")
            dismissOverlay()
            startScrollCapture(rect: rect, firstFrame: firstFrame)

        case .cancel:
            logMessage("Capture cancelled.")
            dismissOverlay()
        }
    }

    private func dismissOverlay() {
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
        isCapturing = false
    }

    // MARK: - Scroll Capture
    private var scrollCaptureController: ScrollCaptureController?

    private func startScrollCapture(rect: NSRect, firstFrame: NSImage) {
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main else { return }

        let controller = ScrollCaptureController(captureRect: rect, screen: screen, firstFrame: firstFrame)
        controller.onFinish = { [weak self] in
            self?.scrollCaptureController = nil
            self?.isCapturing = false
            logMessage("Scroll capture finished.")
        }
        self.scrollCaptureController = controller
        controller.start()
    }

    // MARK: - Ask AI Chat
    private func showChatWindow(image: NSImage) {
        // Close existing chat window if any
        chatWindow?.close()
        chatWindow = nil

        let window = ChatWindow(image: image)
        window.onClose = { [weak self] in
            self?.chatWindow = nil
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.chatWindow = window
    }

    // MARK: - Save
    private func saveImage(_ image: NSImage) {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.png]
        savePanel.nameFieldStringValue = "Snipshot_\(Int(Date().timeIntervalSince1970)).png"
        savePanel.canCreateDirectories = true
        savePanel.level = .statusBar + 2

        savePanel.begin { [weak self] response in
            if response == .OK, let url = savePanel.url {
                if let tiffData = image.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiffData),
                   let pngData = bitmap.representation(using: .png, properties: [:]) {
                    try? pngData.write(to: url)
                    logMessage("Image saved to \(url.path)")
                }
                self?.dismissOverlay()
            } else {
                // User cancelled save — restore overlay as key window
                self?.overlayWindow?.makeKeyAndOrderFront(nil)
            }
        }
    }

    // MARK: - Pin
    private func pinImage(_ image: NSImage, at origin: NSPoint) {
        let pinWindow = PinWindow(image: image, origin: origin)
        pinWindow.makeKeyAndOrderFront(nil)
        pinWindows.append(pinWindow)
        pinWindows.removeAll { !$0.isVisible }
        // Activate the app so the pin window becomes truly key and can receive Esc
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func pinFromClipboard() {
        let pasteboard = NSPasteboard.general

        guard let image = NSImage(pasteboard: pasteboard) else {
            logMessage("No image in clipboard to pin.")
            return
        }

        logMessage("Pinning image from clipboard: \(Int(image.size.width))x\(Int(image.size.height))")

        guard let screen = NSScreen.main else { return }
        let origin = NSPoint(
            x: (screen.frame.width - image.size.width) / 2 + screen.frame.origin.x,
            y: (screen.frame.height - image.size.height) / 2 + screen.frame.origin.y
        )

        pinImage(image, at: origin)
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindow()
            settingsWindow?.onHotkeyChanged = { [weak self] newConfig in
                self?.captureHotkey = newConfig
                // Update menu item title (don't recreate status item)
                self?.updateStatusMenu()
                // Re-register hotkey listeners
                self?.removeGlobalHotkey()
                self?.setupGlobalHotkey()
                logMessage("Capture hotkey changed to \(newConfig.displayString)")
            }
            settingsWindow?.onShowOnboarding = { [weak self] in
                self?.showOnboarding()
            }
            settingsWindow?.delegate = self
        }
        showDockIcon()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openSettingsForTranslation() {
        openSettings()
        settingsWindow?.expandTranslationSection()
    }

    // MARK: - Onboarding
    private func showOnboarding() {
        if onboardingWindow == nil {
            onboardingWindow = OnboardingWindow()
            onboardingWindow?.onComplete = { [weak self] in
                logMessage("Onboarding complete.")
                self?.onboardingWindow = nil
                self?.hideDockIconIfNoWindows()
            }
            onboardingWindow?.onAccessibilityGranted = { [weak self] in
                logMessage("Accessibility granted via onboarding, registering hotkey.")
                self?.setupGlobalHotkey()
            }
            onboardingWindow?.onOpenSettings = { [weak self] in
                self?.openSettings()
            }
            onboardingWindow?.delegate = self
        }
        showDockIcon()
        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Activation Policy (Dock Icon)

    private func showDockIcon() {
        NSApp.setActivationPolicy(.regular)
    }

    private func hideDockIconIfNoWindows() {
        // Only hide dock icon if no managed windows are visible
        let hasVisibleWindows = (onboardingWindow?.isVisible == true) || (settingsWindow?.isVisible == true)
        if !hasVisibleWindows {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === onboardingWindow {
            onboardingWindow = nil
        } else if window === settingsWindow {
            settingsWindow = nil
        }
        // Delay slightly so the window finishes closing before we check
        DispatchQueue.main.async { [weak self] in
            self?.hideDockIconIfNoWindows()
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
