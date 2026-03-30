import Cocoa
import WebKit

// MARK: - AI Result Window Holder
/// Keeps a strong reference to AI result windows after overlay is dismissed.
class AIResultWindowHolder {
    static let shared = AIResultWindowHolder()
    var windows: [AIResultWindow] = []
    private init() {}

    func track(_ window: AIResultWindow) {
        windows.append(window)
    }

    func remove(_ window: AIResultWindow) {
        windows.removeAll { $0 === window }
    }

    func clear() {
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
    }
}

// MARK: - AI Result Window Configuration
/// Configuration for creating an AIResultWindow with feature-specific options.
struct AIResultWindowConfig {
    var title: String = "AI Result"
    var savedWidthKey: String = "aiResultWindowWidth"
    var savedHeightKey: String = "aiResultWindowHeight"
    var onDismiss: (() -> Void)? = nil
}

// MARK: - AI Result Window
/// A unified floating window for displaying AI-generated results with Markdown rendering.
/// Supports streaming updates, resizing with size memory, and split copy (plain text / markdown).
/// Used by both Translate and OCR Refine features.
class AIResultWindow: NSPanel, NSWindowDelegate {

    private var webView: WKWebView!
    private var loadingContainer: NSView!
    private var loadingLabel: NSTextField!
    private var closeButton: NSButton!
    private var copyButton: NSButton!
    private var copyMenuButton: NSButton!
    private var titleBar: NSView!
    private var titleLabel: NSTextField!
    private var currentContent: String = ""
    private var webViewReady = false
    private var pendingContent: String? = nil
    private var dotsTimer: Timer?
    private var dotCount: Int = 0
    private var currentPhaseText: String = "Preparing"
    private var isShowingLoading = true
    private var config: AIResultWindowConfig

    /// Area in the title bar for feature-specific widgets (e.g., language picker).
    private(set) var widgetContainer: NSView!

    init(near anchorRect: NSRect, screenFrame: NSRect, config: AIResultWindowConfig = AIResultWindowConfig()) {
        self.config = config

        let savedW = CGFloat(UserDefaults.standard.float(forKey: config.savedWidthKey))
        let savedH = CGFloat(UserDefaults.standard.float(forKey: config.savedHeightKey))
        let windowWidth: CGFloat = savedW > 200 ? savedW : 400
        let windowHeight: CGFloat = savedH > 150 ? savedH : 320

        var windowX = anchorRect.maxX + 12
        if windowX + windowWidth > screenFrame.maxX - 20 {
            windowX = anchorRect.minX - windowWidth - 12
        }
        if windowX < screenFrame.minX + 20 {
            windowX = anchorRect.midX - windowWidth / 2
        }

        var windowY = anchorRect.midY - windowHeight / 2
        windowY = max(screenFrame.minY + 20, min(windowY, screenFrame.maxY - windowHeight - 20))

        let rect = NSRect(x: windowX, y: windowY, width: windowWidth, height: windowHeight)

        super.init(
            contentRect: rect,
            styleMask: [.resizable, .nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.isOpaque = false
        self.hasShadow = true
        self.backgroundColor = .clear
        self.isMovableByWindowBackground = true
        self.isReleasedWhenClosed = false
        self.hidesOnDeactivate = false
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.minSize = NSSize(width: 250, height: 180)
        self.delegate = self

        self.standardWindowButton(.closeButton)?.isHidden = true
        self.standardWindowButton(.miniaturizeButton)?.isHidden = true
        self.standardWindowButton(.zoomButton)?.isHidden = true

        setupUI()
        showPhase("Preparing")
    }

    override var canBecomeKey: Bool { true }

    // MARK: - NSWindowDelegate

    func windowDidResize(_ notification: Notification) {
        let size = frame.size
        UserDefaults.standard.set(Float(size.width), forKey: config.savedWidthKey)
        UserDefaults.standard.set(Float(size.height), forKey: config.savedHeightKey)
        relayoutContent()
    }

    private func relayoutContent() {
        guard let container = contentView else { return }
        let w = container.bounds.width
        let h = container.bounds.height

        titleBar.frame = NSRect(x: 0, y: h - 32, width: w, height: 32)
        closeButton.frame = NSRect(x: w - 28, y: 4, width: 24, height: 24)
        copyMenuButton.frame = NSRect(x: w - 48, y: 4, width: 16, height: 24)
        copyButton.frame = NSRect(x: w - 72, y: 4, width: 24, height: 24)

        // Widget container fills between title label and copy button
        let widgetX = titleLabel.frame.maxX + 4
        let widgetW = max(0, (w - 72) - widgetX - 4)
        widgetContainer.frame = NSRect(x: widgetX, y: 0, width: widgetW, height: 32)

        loadingContainer.frame = NSRect(x: 0, y: 0, width: w, height: h - 32)
        repositionLoadingLabel()

        webView.frame = NSRect(x: 1, y: 1, width: w - 2, height: h - 33)
    }

    private func repositionLoadingLabel() {
        let areaH = loadingContainer.bounds.height
        let areaW = loadingContainer.bounds.width
        loadingLabel.sizeToFit()
        let sz = loadingLabel.frame.size
        loadingLabel.frame = NSRect(x: (areaW - sz.width) / 2, y: (areaH - sz.height) / 2, width: sz.width, height: sz.height)
    }

    private func setupUI() {
        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.98, alpha: 0.96).cgColor
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 0.5
        container.layer?.borderColor = NSColor(white: 0.8, alpha: 1.0).cgColor
        container.autoresizingMask = [.width, .height]

        let w = frame.width
        let h = frame.height

        // Title bar
        titleBar = NSView(frame: NSRect(x: 0, y: h - 32, width: w, height: 32))
        titleBar.wantsLayer = true
        titleBar.layer?.backgroundColor = NSColor(white: 0.94, alpha: 1.0).cgColor
        titleBar.autoresizingMask = [.width, .minYMargin]

        titleLabel = NSTextField(labelWithString: config.title)
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.sizeToFit()
        let titleLabelH = ceil(titleLabel.frame.height)
        titleLabel.frame = NSRect(x: 10, y: (32 - titleLabelH) / 2, width: titleLabel.frame.width, height: titleLabelH)
        titleBar.addSubview(titleLabel)

        // Widget container for feature-specific controls
        let widgetX = titleLabel.frame.maxX + 4
        let widgetW = max(0, (w - 72) - widgetX - 4)
        widgetContainer = NSView(frame: NSRect(x: widgetX, y: 0, width: widgetW, height: 32))
        widgetContainer.autoresizingMask = [.width]
        titleBar.addSubview(widgetContainer)

        // Close button
        closeButton = NSButton(frame: NSRect(x: w - 28, y: 4, width: 24, height: 24))
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(dismissWindow)
        closeButton.autoresizingMask = [.minXMargin]
        titleBar.addSubview(closeButton)

        // Copy dropdown arrow
        copyMenuButton = NSButton(frame: NSRect(x: w - 48, y: 4, width: 16, height: 24))
        copyMenuButton.bezelStyle = .inline
        copyMenuButton.isBordered = false
        copyMenuButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Copy options")?
            .withSymbolConfiguration(.init(pointSize: 7, weight: .bold))
        copyMenuButton.contentTintColor = .secondaryLabelColor
        copyMenuButton.target = self
        copyMenuButton.action = #selector(showCopyMenu(_:))
        copyMenuButton.toolTip = "Copy options"
        copyMenuButton.autoresizingMask = [.minXMargin]
        titleBar.addSubview(copyMenuButton)

        // Copy button (default: plain text)
        copyButton = NSButton(frame: NSRect(x: w - 72, y: 4, width: 24, height: 24))
        copyButton.bezelStyle = .inline
        copyButton.isBordered = false
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        copyButton.contentTintColor = .secondaryLabelColor
        copyButton.target = self
        copyButton.action = #selector(copyPlainText)
        copyButton.toolTip = "Copy as plain text  \u{2318}C"
        copyButton.autoresizingMask = [.minXMargin]
        titleBar.addSubview(copyButton)

        container.addSubview(titleBar)

        // Loading container
        let contentAreaHeight = h - 32
        loadingContainer = NSView(frame: NSRect(x: 0, y: 0, width: w, height: contentAreaHeight))
        loadingContainer.autoresizingMask = [.width, .height]

        loadingLabel = NSTextField(labelWithString: "Preparing")
        loadingLabel.font = .systemFont(ofSize: 13, weight: .medium)
        loadingLabel.textColor = .secondaryLabelColor
        loadingLabel.alignment = .center
        loadingLabel.sizeToFit()
        repositionLoadingLabel()
        loadingContainer.addSubview(loadingLabel)

        container.addSubview(loadingContainer)

        // WebView for Markdown rendering
        let webConfig = WKWebViewConfiguration()
        webConfig.preferences.setValue(true, forKey: "developerExtrasEnabled")
        webView = WKWebView(frame: NSRect(x: 1, y: 1, width: w - 2, height: h - 33), configuration: webConfig)
        webView.isHidden = true
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)

        let shellHTML = buildShellHTML()
        webView.loadHTMLString(shellHTML, baseURL: nil)

        self.contentView = container
    }

    // MARK: - Dots Timer

    private func startDotsTimer() {
        dotCount = 0
        updateLoadingText()
        dotsTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self = self, self.isShowingLoading else { return }
            self.dotCount = (self.dotCount + 1) % 4
            self.updateLoadingText()
        }
    }

    private func stopDotsTimer() {
        dotsTimer?.invalidate()
        dotsTimer = nil
    }

    private func updateLoadingText() {
        let dots = String(repeating: ".", count: dotCount)
        loadingLabel.stringValue = "\(currentPhaseText)\(dots)"
        loadingLabel.sizeToFit()
        repositionLoadingLabel()
    }

    // MARK: - Public API

    func showPhase(_ text: String) {
        isShowingLoading = true
        loadingContainer.isHidden = false
        webView.isHidden = true

        currentPhaseText = text
        loadingLabel.textColor = .secondaryLabelColor

        stopDotsTimer()
        startDotsTimer()
    }

    func showError(_ message: String) {
        isShowingLoading = false
        stopDotsTimer()
        loadingContainer.isHidden = false
        webView.isHidden = true

        loadingLabel.stringValue = message
        loadingLabel.textColor = .systemRed
        loadingLabel.lineBreakMode = .byWordWrapping
        loadingLabel.maximumNumberOfLines = 0
        loadingLabel.preferredMaxLayoutWidth = loadingContainer.bounds.width - 40

        let fittingSize = loadingLabel.sizeThatFits(NSSize(width: loadingContainer.bounds.width - 40, height: CGFloat.greatestFiniteMagnitude))
        let contentAreaHeight = loadingContainer.bounds.height
        let startX = (loadingContainer.bounds.width - fittingSize.width) / 2
        let centerY = (contentAreaHeight - fittingSize.height) / 2
        loadingLabel.frame = NSRect(x: startX, y: centerY, width: fittingSize.width, height: fittingSize.height)
    }

    func updateContent(_ markdown: String) {
        if isShowingLoading {
            isShowingLoading = false
            stopDotsTimer()
            loadingContainer.isHidden = true
            webView.isHidden = false
        }
        currentContent = markdown

        if webViewReady {
            pushContentToWebView(markdown)
        } else {
            pendingContent = markdown
        }
    }

    func showResult(_ markdown: String) {
        updateContent(markdown)
    }

    func updateTitle(_ title: String) {
        titleLabel.stringValue = title
        titleLabel.sizeToFit()
    }

    // MARK: - WebView Content

    private func pushContentToWebView(_ markdown: String) {
        let escaped = markdown
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")

        let js = "updateContent('\(escaped)');"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func buildShellHTML() -> String {
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"></script>
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body {
                font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
                font-size: 13px;
                line-height: 1.6;
                color: #1d1d1f;
                padding: 14px 16px;
                background: transparent;
                -webkit-font-smoothing: antialiased;
            }
            h1 { font-size: 18px; margin: 12px 0 8px; font-weight: 600; }
            h2 { font-size: 16px; margin: 10px 0 6px; font-weight: 600; }
            h3 { font-size: 14px; margin: 8px 0 4px; font-weight: 600; }
            p { margin: 6px 0; }
            ul, ol { margin: 6px 0; padding-left: 20px; }
            li { margin: 2px 0; }
            code {
                background: rgba(0,0,0,0.06);
                padding: 1px 4px;
                border-radius: 3px;
                font-size: 12px;
                font-family: "SF Mono", Menlo, monospace;
            }
            pre {
                background: rgba(0,0,0,0.04);
                padding: 10px 12px;
                border-radius: 6px;
                overflow-x: auto;
                margin: 8px 0;
            }
            pre code { background: none; padding: 0; }
            blockquote {
                border-left: 3px solid #d1d1d6;
                padding-left: 12px;
                margin: 8px 0;
                color: #636366;
            }
            table { border-collapse: collapse; margin: 8px 0; width: 100%; }
            th, td {
                border: 1px solid #d1d1d6;
                padding: 4px 8px;
                text-align: left;
                font-size: 12px;
            }
            th { background: rgba(0,0,0,0.04); font-weight: 600; }
            hr { border: none; border-top: 1px solid #d1d1d6; margin: 12px 0; }
            a { color: #007aff; text-decoration: none; }
            ::selection { background: rgba(0, 122, 255, 0.2); }
        </style>
        </head>
        <body>
        <div id="content"></div>
        <script>
            marked.setOptions({ breaks: true });
            function updateContent(md) {
                document.getElementById('content').innerHTML = marked.parse(md);
            }
        </script>
        </body>
        </html>
        """
    }

    // MARK: - Actions

    @objc func dismissWindow() {
        stopDotsTimer()
        config.onDismiss?()
        orderOut(nil)
        AIResultWindowHolder.shared.remove(self)
    }

    @objc private func copyPlainText() {
        guard !currentContent.isEmpty else { return }
        let plain = stripMarkdown(currentContent)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(plain, forType: .string)
        logMessage("AIResult: copied plain text (\(plain.count) chars)")
        showCopyFeedback()
    }

    @objc private func copyMarkdown() {
        guard !currentContent.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(currentContent, forType: .string)
        logMessage("AIResult: copied markdown (\(currentContent.count) chars)")
        showCopyFeedback()
    }

    @objc private func showCopyMenu(_ sender: NSButton) {
        let menu = NSMenu()

        let plainItem = NSMenuItem(title: "Copy as Plain Text", action: #selector(copyPlainText), keyEquivalent: "")
        plainItem.target = self
        menu.addItem(plainItem)

        let mdItem = NSMenuItem(title: "Copy as Markdown", action: #selector(copyMarkdown), keyEquivalent: "")
        mdItem.target = self
        menu.addItem(mdItem)

        let location = NSPoint(x: sender.bounds.midX, y: sender.bounds.minY)
        menu.popUp(positioning: nil, at: location, in: sender)
    }

    private func showCopyFeedback() {
        copyButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        copyButton.contentTintColor = .systemGreen
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
            self?.copyButton.contentTintColor = .secondaryLabelColor
        }
    }

    /// Simple markdown stripping for plain text copy.
    private func stripMarkdown(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: "**", with: "")
        result = result.replacingOccurrences(of: "__", with: "")
        result = result.replacingOccurrences(of: "*", with: "")
        result = result.replacingOccurrences(of: "_", with: "")
        result = result.replacingOccurrences(of: "```", with: "")
        result = result.replacingOccurrences(of: "`", with: "")
        let lines = result.split(separator: "\n", omittingEmptySubsequences: false)
        result = lines.map { line in
            var l = String(line)
            while l.hasPrefix("# ") || l.hasPrefix("## ") || l.hasPrefix("### ") {
                if let spaceIdx = l.firstIndex(of: " ") {
                    l = String(l[l.index(after: spaceIdx)...])
                } else { break }
            }
            return l
        }.joined(separator: "\n")
        return result
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            dismissWindow()
        } else if event.keyCode == 8 && event.modifierFlags.contains(.command) {
            copyPlainText()
        } else {
            super.keyDown(with: event)
        }
    }
}

// MARK: - WKNavigationDelegate
extension AIResultWindow: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webViewReady = true
        if let pending = pendingContent {
            pendingContent = nil
            pushContentToWebView(pending)
            loadingContainer.isHidden = true
            self.webView.isHidden = false
        }
    }
}
