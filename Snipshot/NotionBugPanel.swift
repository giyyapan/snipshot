import AppKit

// MARK: - Notion Bug Panel
// macOS System Settings style: grouped rows in rounded white cards on a light gray background.

class NotionBugPanel: NSPanel {

    struct Result {
        let title: String
        let notes: String
        let priority: String
        let feedbackType: String
    }

    var onSubmit: ((Result) -> Void)?
    var onCancel: (() -> Void)?

    private var titleField: NSTextField!
    private var notesField: NSTextField!
    private var priorityPopup: NSPopUpButton!
    private var feedbackTypePopup: NSPopUpButton!
    private var submitButton: NSButton!
    private var cancelButton: NSButton!
    private var statusLabel: NSTextField!

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 380),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.title = "Create Notion Bug Case"
        self.titlebarAppearsTransparent = true
        self.isMovableByWindowBackground = true
        self.level = .floating
        self.isReleasedWhenClosed = false
        self.backgroundColor = NSColor(white: 0.94, alpha: 1.0)
        setupUI()
    }

    // MARK: - UI Setup

    private func setupUI() {
        guard let cv = contentView else { return }
        cv.wantsLayer = true
        cv.layer?.backgroundColor = NSColor(white: 0.94, alpha: 1.0).cgColor

        let margin: CGFloat = 24
        let cardInsetX: CGFloat = 16
        let cardW = cv.bounds.width - margin * 2
        let rowH: CGFloat = 44
        let cardCorner: CGFloat = 10
        let labelW: CGFloat = 80
        let fieldX = cardInsetX + labelW
        let fieldW = cardW - fieldX - cardInsetX

        // Native component heights
        let labelH: CGFloat = 17   // NSTextField label natural height
        let textFieldH: CGFloat = 22  // NSTextField input natural height
        let popupH: CGFloat = 25   // NSPopUpButton natural height

        // Start below the title bar with generous spacing
        var y = cv.bounds.height - 64

        // ── Card 1: Title & Notes (2 rows) ──
        let card1H = rowH * 2 + 1
        let card1 = makeCard(frame: NSRect(x: margin, y: y - card1H, width: cardW, height: card1H), cornerRadius: cardCorner)
        cv.addSubview(card1)

        // Row 1: Title — center label and field in row using natural heights
        let row1Y = rowH + 1
        let titleLabel = makeRowLabel("Title")
        titleLabel.frame = NSRect(x: cardInsetX, y: row1Y + (rowH - labelH) / 2, width: labelW, height: labelH)
        card1.addSubview(titleLabel)

        titleField = NSTextField()
        titleField.placeholderString = "Brief description of the bug"
        styleTextField(titleField)
        titleField.frame = NSRect(x: fieldX, y: row1Y + (rowH - textFieldH) / 2, width: fieldW, height: textFieldH)
        card1.addSubview(titleField)

        // Separator
        let sep1 = makeSeparator(frame: NSRect(x: cardInsetX, y: rowH, width: cardW - cardInsetX, height: 1))
        card1.addSubview(sep1)

        // Row 2: Notes — center in row
        let row2Y: CGFloat = 0
        let notesLabel = makeRowLabel("Notes")
        notesLabel.frame = NSRect(x: cardInsetX, y: row2Y + (rowH - labelH) / 2, width: labelW, height: labelH)
        card1.addSubview(notesLabel)

        notesField = NSTextField()
        notesField.placeholderString = "Steps to reproduce, context…"
        styleTextField(notesField)
        notesField.frame = NSRect(x: fieldX, y: row2Y + (rowH - textFieldH) / 2, width: fieldW, height: textFieldH)
        card1.addSubview(notesField)

        y -= (card1H + 16)

        // ── Card 2: Priority & Type (2 rows) ──
        let card2H = rowH * 2 + 1
        let card2 = makeCard(frame: NSRect(x: margin, y: y - card2H, width: cardW, height: card2H), cornerRadius: cardCorner)
        cv.addSubview(card2)

        // Row 1: Priority — center in row
        let row3Y = rowH + 1
        let priorityLabel = makeRowLabel("Priority")
        priorityLabel.frame = NSRect(x: cardInsetX, y: row3Y + (rowH - labelH) / 2, width: labelW, height: labelH)
        card2.addSubview(priorityLabel)

        priorityPopup = NSPopUpButton()
        priorityPopup.addItems(withTitles: ["P0 (Critical)", "P1 (High)", "P2 (Normal)", "长期优化"])
        priorityPopup.selectItem(at: 2)
        priorityPopup.font = .systemFont(ofSize: 13)
        priorityPopup.isBordered = false
        priorityPopup.frame = NSRect(x: cardW - cardInsetX - 200, y: row3Y + (rowH - popupH) / 2, width: 200, height: popupH)
        card2.addSubview(priorityPopup)

        // Separator
        let sep2 = makeSeparator(frame: NSRect(x: cardInsetX, y: rowH, width: cardW - cardInsetX, height: 1))
        card2.addSubview(sep2)

        // Row 2: Type — center in row
        let row4Y: CGFloat = 0
        let typeLabel = makeRowLabel("Type")
        typeLabel.frame = NSRect(x: cardInsetX, y: row4Y + (rowH - labelH) / 2, width: labelW, height: labelH)
        card2.addSubview(typeLabel)

        feedbackTypePopup = NSPopUpButton()
        feedbackTypePopup.addItems(withTitles: ["前端页面", "后端问题", "设计系统", "ROI"])
        feedbackTypePopup.selectItem(at: 0)
        feedbackTypePopup.font = .systemFont(ofSize: 13)
        feedbackTypePopup.isBordered = false
        feedbackTypePopup.frame = NSRect(x: cardW - cardInsetX - 200, y: row4Y + (rowH - popupH) / 2, width: 200, height: popupH)
        card2.addSubview(feedbackTypePopup)

        // ── Status label ──
        y -= (card2H + 12)
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: margin, y: y - 18, width: cardW, height: 18)
        cv.addSubview(statusLabel)

        // ── Buttons — both custom-drawn, identical size ──
        let btnW: CGFloat = 120
        let btnH: CGFloat = 34
        let btnGap: CGFloat = 12
        let btnBottomMargin: CGFloat = 32
        let btnY = btnBottomMargin

        // Cancel button
        cancelButton = NSButton(frame: NSRect(x: cv.bounds.width - margin - btnW * 2 - btnGap, y: btnY, width: btnW, height: btnH))
        cancelButton.title = ""
        cancelButton.isBordered = false
        cancelButton.wantsLayer = true
        cancelButton.layer?.cornerRadius = 7
        cancelButton.layer?.backgroundColor = NSColor(white: 0.82, alpha: 1.0).cgColor
        cancelButton.attributedTitle = NSAttributedString(
            string: "Cancel",
            attributes: [
                .foregroundColor: NSColor.labelColor,
                .font: NSFont.systemFont(ofSize: 13, weight: .regular)
            ]
        )
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cv.addSubview(cancelButton)

        // Submit button
        submitButton = NSButton(frame: NSRect(x: cv.bounds.width - margin - btnW, y: btnY, width: btnW, height: btnH))
        submitButton.title = ""
        submitButton.isBordered = false
        submitButton.keyEquivalent = "\r"
        submitButton.wantsLayer = true
        submitButton.layer?.cornerRadius = 7
        submitButton.layer?.backgroundColor = NSColor.systemBlue.cgColor
        submitButton.attributedTitle = NSAttributedString(
            string: "Submit",
            attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 13, weight: .medium)
            ]
        )
        submitButton.target = self
        submitButton.action = #selector(submitTapped)
        cv.addSubview(submitButton)
    }

    // MARK: - Helpers

    private func makeCard(frame: NSRect, cornerRadius: CGFloat) -> NSView {
        let card = NSView(frame: frame)
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.white.cgColor
        card.layer?.cornerRadius = cornerRadius
        card.layer?.masksToBounds = true
        card.shadow = NSShadow()
        card.layer?.shadowColor = NSColor.black.withAlphaComponent(0.06).cgColor
        card.layer?.shadowOffset = CGSize(width: 0, height: -1)
        card.layer?.shadowRadius = 2
        card.layer?.shadowOpacity = 1
        return card
    }

    private func makeRowLabel(_ text: String) -> NSTextField {
        let lbl = NSTextField(labelWithString: text)
        lbl.font = .systemFont(ofSize: 13, weight: .regular)
        lbl.textColor = .labelColor
        lbl.alignment = .left
        return lbl
    }

    private func makeSeparator(frame: NSRect) -> NSView {
        let sep = NSView(frame: frame)
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor.separatorColor.cgColor
        return sep
    }

    private func styleTextField(_ field: NSTextField) {
        field.font = .systemFont(ofSize: 13)
        field.isBordered = false
        field.focusRingType = .none
        field.drawsBackground = false
    }

    // MARK: - Actions

    @objc private func cancelTapped() {
        close()
        onCancel?()
    }

    @objc private func submitTapped() {
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            statusLabel.stringValue = "⚠️ Title is required"
            statusLabel.textColor = .systemOrange
            return
        }

        let priorityMap = ["P0", "P1", "P2", "长期优化"]
        let feedbackMap = ["前端页面", "后端问题", "设计系统", "ROI"]

        let priority = priorityMap[safe: priorityPopup.indexOfSelectedItem] ?? "P2"
        let feedbackType = feedbackMap[safe: feedbackTypePopup.indexOfSelectedItem] ?? "前端页面"

        submitButton.isEnabled = false
        statusLabel.stringValue = "Uploading to Notion…"
        statusLabel.textColor = .secondaryLabelColor

        let result = Result(
            title: title,
            notes: notesField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            priority: priority,
            feedbackType: feedbackType
        )
        onSubmit?(result)
    }

    func showSuccess(pageUrl: String) {
        statusLabel.stringValue = "✅ Created! Opening in Notion…"
        statusLabel.textColor = .systemGreen
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.close()
            if let url = URL(string: pageUrl) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func showError(_ message: String) {
        submitButton.isEnabled = true
        statusLabel.stringValue = "❌ \(message)"
        statusLabel.textColor = .systemRed
    }
}

// MARK: - Safe Array Subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
