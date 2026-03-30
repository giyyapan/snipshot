import Cocoa
import WebKit

// MARK: - Chat Message Model
struct ChatMessage {
    enum Role { case user, assistant, loading, image }
    let role: Role
    let text: String
    var image: NSImage? = nil
}

// MARK: - Plugin Chat Window
// A floating chat-style window anchored to screen top-right corner.
// Shows user prompts and LLM responses in a conversation view.
// Assistant messages are rendered as Markdown via WKWebView.
// In "chat" mode, an input field at the bottom allows follow-up messages.
class PluginChatWindow: NSPanel {

    private var messages: [ChatMessage] = []
    private var scrollView: NSScrollView!
    private var chatStackView: NSStackView!
    private var inputField: NSTextField?
    private var inputBar: NSView?
    private var loadingBubble: NSView?

    // Plugin context for follow-up messages
    var plugin: Plugin?
    var imagePath: URL?
    var onSendFollowUp: ((String) -> Void)?
    private(set) var isChatMode: Bool

    /// Chat history in OpenAI message format for multi-turn conversations.
    /// Managed by PluginManager.
    var chatHistory: [[String: Any]] = []

    init(title: String, chatMode: Bool) {
        self.isChatMode = chatMode

        // Fixed size, anchored to top-right corner of the screen
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let winWidth: CGFloat = 420
        let winHeight: CGFloat = 540
        let margin: CGFloat = 16
        let frame = NSRect(
            x: screen.visibleFrame.maxX - winWidth - margin,
            y: screen.visibleFrame.maxY - winHeight - margin,
            width: winWidth,
            height: winHeight
        )

        super.init(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )

        self.title = title
        self.level = .floating
        self.isFloatingPanel = true
        self.hidesOnDeactivate = false
        self.isMovableByWindowBackground = true
        self.animationBehavior = .utilityWindow
        self.minSize = NSSize(width: 320, height: 280)

        setupUI()
    }

    override var canBecomeKey: Bool { true }

    // MARK: - Setup UI

    private func setupUI() {
        guard let cv = contentView else { return }
        cv.wantsLayer = true

        // Chat scroll area
        scrollView = NSScrollView(frame: .zero)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        // Stack view for chat bubbles
        chatStackView = NSStackView()
        chatStackView.translatesAutoresizingMaskIntoConstraints = false
        chatStackView.orientation = .vertical
        chatStackView.alignment = .leading
        chatStackView.spacing = 10
        chatStackView.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        // Wrap stack in a flipped container so content grows downward
        let container = FlippedView(frame: .zero)
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(chatStackView)
        scrollView.documentView = container

        cv.addSubview(scrollView)

        // Pin stack view inside container
        NSLayoutConstraint.activate([
            chatStackView.topAnchor.constraint(equalTo: container.topAnchor),
            chatStackView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            chatStackView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            chatStackView.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
        ])

        // Container should match scroll view width
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])

        if isChatMode {
            setupInputBar(cv)
        } else {
            setupButtonBar(cv)
        }
    }

    // MARK: - Input Bar (chat mode)

    private func setupInputBar(_ cv: NSView) {
        let bar = NSView(frame: .zero)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(white: 0.96, alpha: 1.0).cgColor
        cv.addSubview(bar)
        inputBar = bar

        let tf = NSTextField(frame: .zero)
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.font = NSFont.systemFont(ofSize: 13)
        tf.placeholderString = "Follow up..."
        tf.isBordered = true
        tf.bezelStyle = .roundedBezel
        tf.focusRingType = .none
        tf.isEditable = true
        tf.isSelectable = true
        tf.target = self
        tf.action = #selector(inputSubmitted(_:))
        bar.addSubview(tf)
        inputField = tf

        let sendBtn = NSButton(title: "Send", target: self, action: #selector(sendButtonPressed))
        sendBtn.translatesAutoresizingMaskIntoConstraints = false
        sendBtn.bezelStyle = .rounded
        sendBtn.controlSize = .regular
        bar.addSubview(sendBtn)

        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 44),

            tf.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            tf.trailingAnchor.constraint(equalTo: sendBtn.leadingAnchor, constant: -8),
            tf.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            tf.heightAnchor.constraint(equalToConstant: 26),

            sendBtn.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8),
            sendBtn.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            scrollView.topAnchor.constraint(equalTo: cv.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bar.topAnchor),
        ])
    }

    // MARK: - Button Bar (once mode)

    private func setupButtonBar(_ cv: NSView) {
        let bar = NSView(frame: .zero)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(white: 0.96, alpha: 1.0).cgColor
        cv.addSubview(bar)

        let copyBtn = NSButton(title: "Copy", target: self, action: #selector(copyLastResponse))
        copyBtn.translatesAutoresizingMaskIntoConstraints = false
        copyBtn.bezelStyle = .rounded
        copyBtn.controlSize = .regular
        bar.addSubview(copyBtn)

        let closeBtn = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        closeBtn.bezelStyle = .rounded
        closeBtn.controlSize = .regular
        bar.addSubview(closeBtn)

        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 40),

            copyBtn.trailingAnchor.constraint(equalTo: closeBtn.leadingAnchor, constant: -8),
            copyBtn.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            closeBtn.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            closeBtn.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            scrollView.topAnchor.constraint(equalTo: cv.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bar.topAnchor),
        ])
    }

    // MARK: - Public API

    /// Add a screenshot thumbnail at the top of the chat
    func addScreenshotThumbnail(_ image: NSImage) {
        let msg = ChatMessage(role: .image, text: "", image: image)
        messages.append(msg)
        appendImageBubble(image)
    }

    /// Add a user message bubble
    func addUserMessage(_ text: String) {
        let msg = ChatMessage(role: .user, text: text)
        messages.append(msg)
        appendBubble(msg)
    }

    /// Show a loading indicator bubble
    func showLoading() {
        let bubble = makeTextBubble(text: "Thinking...", role: .loading)
        loadingBubble = bubble
        chatStackView.addArrangedSubview(bubble)
        bubble.widthAnchor.constraint(lessThanOrEqualTo: chatStackView.widthAnchor, multiplier: 0.85, constant: -24).isActive = true
        scrollToBottom()
    }

    /// Remove loading indicator and add the assistant response (rendered as Markdown)
    func addAssistantMessage(_ text: String) {
        if let lb = loadingBubble {
            chatStackView.removeArrangedSubview(lb)
            lb.removeFromSuperview()
            loadingBubble = nil
        }

        let msg = ChatMessage(role: .assistant, text: text)
        messages.append(msg)
        appendMarkdownBubble(text)

        inputField?.isEnabled = true
        inputField?.placeholderString = "Follow up..."
    }

    // MARK: - Screenshot Thumbnail

    private func appendImageBubble(_ image: NSImage) {
        let maxThumbWidth: CGFloat = 200
        let maxThumbHeight: CGFloat = 150

        let imgSize = image.size
        let scale = min(maxThumbWidth / imgSize.width, maxThumbHeight / imgSize.height, 1.0)
        let thumbW = imgSize.width * scale
        let thumbH = imgSize.height * scale

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.cornerRadius = 8
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.separatorColor.cgColor

        let imageView = NSImageView(image: image)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        container.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: container.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            container.widthAnchor.constraint(equalToConstant: thumbW),
            container.heightAnchor.constraint(equalToConstant: thumbH),
        ])

        chatStackView.addArrangedSubview(container)
        scrollToBottom()
    }

    // MARK: - Text Bubble (user messages)

    private func appendBubble(_ msg: ChatMessage) {
        let bubble = makeTextBubble(text: msg.text, role: msg.role)

        if msg.role == .user {
            // User messages: right-aligned
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            let wrapper = NSStackView(views: [spacer, bubble])
            wrapper.orientation = .horizontal
            wrapper.distribution = .fill
            wrapper.translatesAutoresizingMaskIntoConstraints = false
            chatStackView.addArrangedSubview(wrapper)
            wrapper.widthAnchor.constraint(equalTo: chatStackView.widthAnchor, constant: -24).isActive = true
            bubble.widthAnchor.constraint(lessThanOrEqualTo: chatStackView.widthAnchor, multiplier: 0.75, constant: -24).isActive = true
        } else {
            chatStackView.addArrangedSubview(bubble)
            bubble.widthAnchor.constraint(lessThanOrEqualTo: chatStackView.widthAnchor, multiplier: 0.85, constant: -24).isActive = true
        }

        scrollToBottom()
    }

    private func makeTextBubble(text: String, role: ChatMessage.Role) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.cornerRadius = 10

        switch role {
        case .user:
            container.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
        case .assistant, .loading:
            container.layer?.backgroundColor = NSColor(white: 0.92, alpha: 1.0).cgColor
        case .image:
            break
        }

        let label = NSTextField(wrappingLabelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = role == .loading
            ? NSFont.systemFont(ofSize: 12, weight: .light)
            : NSFont.systemFont(ofSize: 13)
        label.textColor = role == .loading ? .secondaryLabelColor : .labelColor
        label.isEditable = false
        label.isSelectable = true
        label.drawsBackground = false
        label.isBordered = false
        label.lineBreakMode = .byWordWrapping
        label.usesSingleLineMode = false
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = 280
        container.addSubview(label)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
        ])

        return container
    }

    // MARK: - Markdown Bubble (assistant messages) with Copy button

    private func appendMarkdownBubble(_ markdown: String) {
        // Outer wrapper: vertical stack with bubble + copy button
        let wrapper = NSStackView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.orientation = .vertical
        wrapper.alignment = .leading
        wrapper.spacing = 4

        // Markdown bubble container
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.backgroundColor = NSColor(white: 0.92, alpha: 1.0).cgColor

        let webView = MarkdownWebView(markdown: markdown, parentScrollView: scrollView)
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
        ])

        wrapper.addArrangedSubview(container)

        // Copy button below the bubble
        let copyBtn = NSButton(frame: .zero)
        copyBtn.translatesAutoresizingMaskIntoConstraints = false
        copyBtn.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
        copyBtn.title = " Copy"
        copyBtn.imagePosition = .imageLeading
        copyBtn.bezelStyle = .recessed
        copyBtn.controlSize = .small
        copyBtn.isBordered = false
        copyBtn.font = NSFont.systemFont(ofSize: 11)
        copyBtn.contentTintColor = .secondaryLabelColor
        copyBtn.target = self
        copyBtn.action = #selector(copyBubbleText(_:))
        // Store the markdown text in the identifier for retrieval
        copyBtn.identifier = NSUserInterfaceItemIdentifier(markdown)
        wrapper.addArrangedSubview(copyBtn)

        chatStackView.addArrangedSubview(wrapper)
        container.widthAnchor.constraint(equalTo: chatStackView.widthAnchor, constant: -24).isActive = true

        scrollToBottom()

        // Re-scroll after WebView finishes rendering
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.scrollToBottom()
        }
    }

    @objc private func copyBubbleText(_ sender: NSButton) {
        guard let text = sender.identifier?.rawValue else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Visual feedback
        let originalTitle = sender.title
        sender.title = " Copied!"
        sender.contentTintColor = .controlAccentColor
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            sender.title = originalTitle
            sender.contentTintColor = .secondaryLabelColor
        }
    }

    private func scrollToBottom() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let docView = self.scrollView.documentView else { return }
            docView.layoutSubtreeIfNeeded()
            let maxY = docView.frame.height - self.scrollView.contentSize.height
            if maxY > 0 {
                self.scrollView.contentView.scroll(to: NSPoint(x: 0, y: maxY))
                self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
            }
        }
    }

    // MARK: - Actions

    @objc private func inputSubmitted(_ sender: NSTextField) {
        let text = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        sender.stringValue = ""
        sender.isEnabled = false
        sender.placeholderString = "Waiting for response..."

        addUserMessage(text)
        showLoading()
        onSendFollowUp?(text)
    }

    @objc private func sendButtonPressed() {
        guard let tf = inputField else { return }
        inputSubmitted(tf)
    }

    @objc private func copyLastResponse() {
        if let lastAssistant = messages.last(where: { $0.role == .assistant }) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(lastAssistant.text, forType: .string)

            let originalTitle = title
            title = "\(originalTitle) — Copied!"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.title = originalTitle
            }
        }
    }

    @objc private func closeWindow() {
        cleanupAndClose()
    }

    private func cleanupAndClose() {
        if let path = imagePath {
            try? FileManager.default.removeItem(at: path)
        }
        orderOut(nil)
    }

    override func close() {
        if let path = imagePath {
            try? FileManager.default.removeItem(at: path)
        }
        super.close()
    }
}

// MARK: - Flipped View (for top-aligned scroll content)
class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Markdown WebView
// A lightweight WKWebView that renders Markdown as styled HTML.
// Auto-resizes its height to fit content.
// Scroll events are forwarded to the parent NSScrollView so the
// chat window scrolls normally when the mouse is over a markdown bubble.
class MarkdownWebView: WKWebView, WKNavigationDelegate {

    private var heightConstraint: NSLayoutConstraint!
    private weak var parentScrollView: NSScrollView?

    init(markdown: String, parentScrollView: NSScrollView? = nil) {
        let config = WKWebViewConfiguration()
        super.init(frame: .zero, configuration: config)

        self.parentScrollView = parentScrollView
        self.navigationDelegate = self
        self.setValue(false, forKey: "drawsBackground")

        // Disable WebView's own scrolling so scroll events pass through
        // to the parent NSScrollView
        if let innerScrollView = findEnclosedScrollView() {
            innerScrollView.hasVerticalScroller = false
            innerScrollView.hasHorizontalScroller = false
            innerScrollView.scrollerStyle = .overlay
        }

        heightConstraint = heightAnchor.constraint(equalToConstant: 40)
        heightConstraint.isActive = true

        let html = Self.wrapMarkdown(markdown)
        loadHTMLString(html, baseURL: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Find the internal scroll view inside WKWebView to disable its scrolling
    private func findEnclosedScrollView() -> NSScrollView? {
        for subview in subviews {
            if let sv = subview as? NSScrollView {
                return sv
            }
        }
        return nil
    }

    override func scrollWheel(with event: NSEvent) {
        // Forward all scroll events to the parent scroll view
        // so the chat window scrolls instead of the WebView
        if let parent = parentScrollView {
            parent.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Disable internal scrolling via JS as well
        evaluateJavaScript("document.body.style.overflow='hidden'; document.documentElement.style.overflow='hidden';", completionHandler: nil)

        evaluateJavaScript("document.body.scrollHeight") { [weak self] result, _ in
            if let h = result as? CGFloat {
                self?.heightConstraint.constant = max(h + 8, 30)
                // Also disable the internal scroll view after content loads
                if let innerSV = self?.findEnclosedScrollView() {
                    innerSV.hasVerticalScroller = false
                    innerSV.hasHorizontalScroller = false
                }
                // Trigger parent layout update
                if let chatWindow = self?.window as? PluginChatWindow {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        chatWindow.contentView?.needsLayout = true
                    }
                }
            }
        }
    }

    // Open links in default browser
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    /// Wrap Markdown text in a minimal HTML page with a <script> tag for marked.js CDN
    /// and styling that matches the chat bubble aesthetic.
    static func wrapMarkdown(_ md: String) -> String {
        let escaped = md
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"></script>
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            html, body {
                overflow: hidden !important;
            }
            body {
                font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
                font-size: 13px;
                line-height: 1.5;
                color: #1d1d1f;
                padding: 6px 8px;
                -webkit-font-smoothing: antialiased;
                background: transparent;
            }
            @media (prefers-color-scheme: dark) {
                body { color: #f5f5f7; }
                code { background: rgba(255,255,255,0.1); }
                pre { background: rgba(255,255,255,0.08); }
                blockquote { border-left-color: #555; }
            }
            p { margin-bottom: 8px; }
            p:last-child { margin-bottom: 0; }
            code {
                font-family: "SF Mono", Menlo, monospace;
                font-size: 12px;
                background: rgba(0,0,0,0.06);
                padding: 1px 4px;
                border-radius: 3px;
            }
            pre {
                background: rgba(0,0,0,0.05);
                padding: 8px 10px;
                border-radius: 6px;
                overflow-x: auto;
                margin: 8px 0;
            }
            pre code {
                background: none;
                padding: 0;
                font-size: 11.5px;
                line-height: 1.4;
            }
            h1, h2, h3, h4 {
                font-weight: 600;
                margin: 10px 0 4px;
            }
            h1 { font-size: 16px; }
            h2 { font-size: 14px; }
            h3 { font-size: 13px; }
            ul, ol { padding-left: 20px; margin: 4px 0; }
            li { margin-bottom: 2px; }
            blockquote {
                border-left: 3px solid #ccc;
                padding-left: 10px;
                color: #666;
                margin: 6px 0;
            }
            a { color: #0066cc; text-decoration: none; }
            a:hover { text-decoration: underline; }
            table { border-collapse: collapse; margin: 6px 0; width: 100%; }
            th, td { border: 1px solid #ddd; padding: 4px 8px; text-align: left; font-size: 12px; }
            th { background: rgba(0,0,0,0.04); font-weight: 600; }
            img { max-width: 100%; border-radius: 4px; }
            hr { border: none; border-top: 1px solid #ddd; margin: 8px 0; }
        </style>
        </head>
        <body>
        <div id="content"></div>
        <script>
            const md = `\(escaped)`;
            document.getElementById('content').innerHTML = marked.parse(md);
        </script>
        </body>
        </html>
        """
    }
}
