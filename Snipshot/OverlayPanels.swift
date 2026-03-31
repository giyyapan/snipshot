import Cocoa

// MARK: - Solid Background Panel
private func makeSolidPanel(frame: NSRect, cornerRadius: CGFloat = 6) -> NSView {
    let panel = NSView(frame: frame)
    panel.wantsLayer = true
    panel.layer?.backgroundColor = NSColor(white: 0.95, alpha: 0.92).cgColor
    panel.layer?.cornerRadius = cornerRadius
    panel.layer?.masksToBounds = true
    return panel
}

// MARK: - OverlayView Panel Methods
extension OverlayView {

    // MARK: - Panel Lifecycle
    func showAllPanels() {
        removeAllPanels()
        showInfoPanel()
        showBottomBar()
        showSecondaryPanel()
    }

    func removeAllPanels() {
        infoPanelView?.removeFromSuperview(); infoPanelView = nil
        bottomBarView?.removeFromSuperview(); bottomBarView = nil
        secondaryPanelView?.removeFromSuperview(); secondaryPanelView = nil
        textField?.removeFromSuperview(); textField = nil
        ocrPanelView?.removeFromSuperview(); ocrPanelView = nil
        toolButtons.removeAll()
        colorDots.removeAll()
        undoButton = nil
        redoButton = nil
    }

    func panelYPosition() -> CGFloat {
        let panelGap: CGFloat = 6
        let panelHeight: CGFloat = 36
        // Try below the selection first
        let belowY = selectionRect.origin.y - panelHeight - panelGap
        if belowY >= bounds.minY + 4 { return belowY }
        // Try above the selection
        let aboveY = selectionRect.maxY + panelGap
        if aboveY + panelHeight <= bounds.maxY - 4 { return aboveY }
        // Fallback: inside the selection, aligned to the bottom
        return selectionRect.origin.y + panelGap
    }

    func isPointInPanel(_ point: NSPoint) -> Bool {
        for panel in [bottomBarView, infoPanelView, secondaryPanelView, ocrPanelView] {
            if let p = panel, p.frame.contains(point) { return true }
        }
        return false
    }

    func refreshPanels() {
        removeAllPanels(); showAllPanels(); needsDisplay = true
    }

    func refreshSecondaryPanel() {
        secondaryPanelView?.removeFromSuperview(); secondaryPanelView = nil
        showSecondaryPanel()
    }

    // MARK: - Info Panel (dimensions)
    private func showInfoPanel() {
        let scale = window?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let pixelW = Int(selectionRect.width * scale)
        let pixelH = Int(selectionRect.height * scale)
        let infoText = "\(pixelW) \u{00D7} \(pixelH)"
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let hPadding: CGFloat = 10
        let panelHeight: CGFloat = 30
        let y = panelYPosition()

        // Create label first and let it size itself to avoid clipping
        let label = NSTextField(labelWithString: infoText)
        label.font = font; label.textColor = NSColor(white: 0.4, alpha: 1.0)
        label.isBordered = false; label.isEditable = false; label.drawsBackground = false
        label.sizeToFit()
        let labelWidth = ceil(label.frame.width)
        let labelHeight = ceil(label.frame.height)

        let panelWidth = labelWidth + hPadding * 2
        let panel = makeSolidPanel(frame: NSRect(x: selectionRect.origin.x, y: y, width: panelWidth, height: panelHeight))

        label.frame = NSRect(x: hPadding, y: (panelHeight - labelHeight) / 2, width: labelWidth, height: labelHeight)
        panel.addSubview(label)

        addSubview(panel)
        infoPanelView = panel
    }

    // MARK: - Bottom Bar
    private func showBottomBar() {
        let btnSize: CGFloat = 26
        let spacing: CGFloat = 2
        let padding: CGFloat = 6
        let dividerW: CGFloat = 12

        let tools = AnnotationTool.allCases
        let toolCount = CGFloat(tools.count)
        let undoRedoCount: CGFloat = 2
        let ocrCount: CGFloat = 2
        let actionCount: CGFloat = 4

        let toolsWidth = toolCount * btnSize + (toolCount - 1) * spacing
        let undoRedoWidth = undoRedoCount * btnSize + (undoRedoCount - 1) * spacing
        let ocrWidth = ocrCount * btnSize + (ocrCount - 1) * spacing
        let actionsWidth = actionCount * btnSize + (actionCount - 1) * spacing
        let totalWidth = padding + toolsWidth + dividerW + undoRedoWidth + dividerW + ocrWidth + dividerW + actionsWidth + padding
        let h: CGFloat = 30

        let x = selectionRect.origin.x + selectionRect.width - totalWidth
        let y = panelYPosition()

        let panel = makeSolidPanel(frame: NSRect(x: x, y: y, width: totalWidth, height: h))

        let by = (h - btnSize) / 2
        var bx = padding

        // Tool buttons
        for tool in tools {
            let btn = HoverIconButton(frame: NSRect(x: bx, y: by, width: btnSize, height: btnSize), symbolName: tool.symbolName, tooltip: tool.displayName)
            btn.isActive = (annoState.currentTool == tool)
            btn.onPress = { [weak self] in self?.selectTool(tool) }
            panel.addSubview(btn)
            toolButtons[tool] = btn
            bx += btnSize + spacing
        }

        // Divider 1 (after tools, before undo/redo)
        bx += (dividerW - spacing) / 2
        let divider1 = NSView(frame: NSRect(x: bx - 0.5, y: 6, width: 1, height: h - 12))
        divider1.wantsLayer = true; divider1.layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.4).cgColor
        panel.addSubview(divider1)
        bx += (dividerW - spacing) / 2

        // Undo button
        let undoBtn = HoverIconButton(frame: NSRect(x: bx, y: by, width: btnSize, height: btnSize), symbolName: "arrow.uturn.backward", tooltip: "Undo  \u{2318}Z")
        undoBtn.isDisabled = !annoState.canUndo
        undoBtn.onPress = { [weak self] in
            guard let self = self else { return }
            self.annoState.undo()
            self.refreshPanels()
        }
        panel.addSubview(undoBtn); bx += btnSize + spacing
        self.undoButton = undoBtn

        // Redo button
        let redoBtn = HoverIconButton(frame: NSRect(x: bx, y: by, width: btnSize, height: btnSize), symbolName: "arrow.uturn.forward", tooltip: "Redo  \u{21E7}\u{2318}Z")
        redoBtn.isDisabled = !annoState.canRedo
        redoBtn.onPress = { [weak self] in
            guard let self = self else { return }
            self.annoState.redo()
            self.refreshPanels()
        }
        panel.addSubview(redoBtn); bx += btnSize
        self.redoButton = redoBtn

        // Divider 2 (before OCR)
        bx += (dividerW) / 2
        let divider1b = NSView(frame: NSRect(x: bx - 0.5, y: 6, width: 1, height: h - 12))
        divider1b.wantsLayer = true; divider1b.layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.4).cgColor
        panel.addSubview(divider1b)
        bx += (dividerW) / 2

        // OCR button
        let ocrBtn = HoverIconButton(frame: NSRect(x: bx, y: by, width: btnSize, height: btnSize), symbolName: "doc.text.viewfinder", tooltip: "OCR Text Recognition  O")
        ocrBtn.onPress = { [weak self] in self?.enterOCRMode() }
        panel.addSubview(ocrBtn); bx += btnSize + spacing

        // Translate button
        let translateBtn = HoverIconButton(frame: NSRect(x: bx, y: by, width: btnSize, height: btnSize), symbolName: "character.book.closed", tooltip: "Translate  Y")
        translateBtn.onPress = { [weak self] in self?.enterTranslateMode() }
        panel.addSubview(translateBtn); bx += btnSize

        // Divider 3 (before actions)
        bx += (dividerW) / 2
        let divider3 = NSView(frame: NSRect(x: bx - 0.5, y: 6, width: 1, height: h - 12))
        divider3.wantsLayer = true; divider3.layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.4).cgColor
        panel.addSubview(divider3)
        bx += (dividerW) / 2

        // Action buttons: pin, save, cancel, copy
        let pinBtn = HoverIconButton(frame: NSRect(x: bx, y: by, width: btnSize, height: btnSize), symbolName: "pin", tooltip: "Pin to Screen  F3")
        pinBtn.onPress = { [weak self] in self?.performAction(.pin) }
        panel.addSubview(pinBtn); bx += btnSize + spacing

        let saveBtn = HoverIconButton(frame: NSRect(x: bx, y: by, width: btnSize, height: btnSize), symbolName: "square.and.arrow.down", tooltip: "Save Image  \u{2318}S")
        saveBtn.onPress = { [weak self] in self?.performAction(.save) }
        panel.addSubview(saveBtn); bx += btnSize + spacing

        let cancelBtn = HoverIconButton(frame: NSRect(x: bx, y: by, width: btnSize, height: btnSize), symbolName: "xmark", tooltip: "Close  Esc")
        cancelBtn.onPress = { [weak self] in self?.performAction(.cancel) }
        panel.addSubview(cancelBtn); bx += btnSize + spacing

        let copyBtn = HoverIconButton(frame: NSRect(x: bx, y: by, width: btnSize, height: btnSize), symbolName: "doc.on.doc", tooltip: "Copy & Done  \u{21A9}")
        copyBtn.onPress = { [weak self] in self?.performAction(.copy) }
        panel.addSubview(copyBtn)

        addSubview(panel)
        bottomBarView = panel
    }

    // MARK: - Secondary Panel (property bar)
    //
    // Decoupled logic:
    // - If an element is selected (single): show that element's properties (color + stroke) + Delete/Duplicate
    // - If multi-selected: show only Delete button
    // - If no element selected: show properties for the current drawing tool (if it's a drawing tool)
    // - If select tool with no selection: no secondary panel
    private func showSecondaryPanel() {
        guard let barFrame = bottomBarView?.frame else { return }

        let hasSingleSelection = annoState.selectedElement != nil
        let hasMultiSelection = annoState.hasMultiSelection

        if hasMultiSelection {
            // Multi-select: only show delete button
            showMultiSelectPanel(barFrame: barFrame)
            return
        }

        if hasSingleSelection {
            // Single selection: show element properties + delete/duplicate
            let element = annoState.selectedElement!
            showElementPropertyPanel(barFrame: barFrame, element: element)
            return
        }

        // No selection: show tool properties if a drawing tool is active
        guard let tool = annoState.currentTool, tool.isDrawingTool else { return }
        showToolPropertyPanel(barFrame: barFrame, tool: tool)
    }

    /// Show property panel for a drawing tool (no element selected)
    private func showToolPropertyPanel(barFrame: NSRect, tool: AnnotationTool) {
        let showColors = (tool != .mosaic)
        let colors = AnnotationState.availableColors
        let colorSize: CGFloat = 18
        let colorSpacing: CGFloat = 3
        let padding: CGFloat = 8

        // Width label for stroke width
        let swText = String(format: "%.0f", annoState.strokeWidths[tool] ?? 3)
        let swFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        let swAttrs: [NSAttributedString.Key: Any] = [.font: swFont]
        let swSize = (swText as NSString).size(withAttributes: swAttrs)

        let colorsWidth = showColors ? CGFloat(colors.count) * colorSize + CGFloat(colors.count - 1) * colorSpacing : 0
        let dividerW: CGFloat = 12
        let minusBtnW: CGFloat = 18
        let plusBtnW: CGFloat = 18
        let widthLabelW = swSize.width + 8
        let widthSectionW = minusBtnW + 4 + widthLabelW + 4 + plusBtnW
        let totalWidth = padding + colorsWidth + (showColors ? dividerW : 0) + widthSectionW + padding
        let h: CGFloat = 28

        let gap: CGFloat = 4
        let x = barFrame.maxX - totalWidth
        let y = barFrame.maxY + gap

        let panel = makeSolidPanel(frame: NSRect(x: x, y: y, width: totalWidth, height: h), cornerRadius: 5)

        var bx = padding

        // Color dots (hidden for mosaic)
        if showColors {
            let cy = (h - colorSize) / 2
            for color in colors {
                let dot = ColorDot(frame: NSRect(x: bx, y: cy, width: colorSize, height: colorSize), color: color)
                dot.isSelected = annoState.currentColor.isEqual(to: color)
                dot.onPress = { [weak self] in self?.selectColor(color) }
                panel.addSubview(dot)
                colorDots[color] = dot
                bx += colorSize + colorSpacing
            }

            // Divider
            bx += (dividerW - colorSpacing) / 2
            let divider = NSView(frame: NSRect(x: bx - 0.5, y: 5, width: 1, height: h - 10))
            divider.wantsLayer = true; divider.layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.4).cgColor
            panel.addSubview(divider)
            bx += (dividerW - colorSpacing) / 2
        }

        // Minus button
        let btnH: CGFloat = 20
        let btnY = (h - btnH) / 2
        let minusBtn = SmallButton(frame: NSRect(x: bx, y: btnY, width: minusBtnW, height: btnH), text: "\u{2212}")
        minusBtn.onPress = { [weak self] in
            self?.annoState.decrementStrokeWidth()
            self?.refreshSecondaryPanel()
            self?.needsDisplay = true
        }
        panel.addSubview(minusBtn)
        bx += minusBtnW + 4

        // Stroke width label
        let widthLabel = NSTextField(labelWithString: swText)
        widthLabel.font = swFont
        widthLabel.textColor = NSColor(white: 0.4, alpha: 1.0)
        widthLabel.alignment = .center
        widthLabel.frame = NSRect(x: bx, y: (h - swSize.height) / 2, width: widthLabelW, height: swSize.height)
        panel.addSubview(widthLabel)
        bx += widthLabelW + 4

        // Plus button
        let plusBtn = SmallButton(frame: NSRect(x: bx, y: btnY, width: plusBtnW, height: btnH), text: "+")
        plusBtn.onPress = { [weak self] in
            self?.annoState.incrementStrokeWidth()
            self?.refreshSecondaryPanel()
            self?.needsDisplay = true
        }
        panel.addSubview(plusBtn)

        addSubview(panel)
        secondaryPanelView = panel
    }

    /// Show property panel for a selected element (single selection) with Delete/Duplicate buttons
    private func showElementPropertyPanel(barFrame: NSRect, element: AnnotationElement) {
        let elementTool = element.tool
        let showColors = (elementTool != .mosaic)
        let colors = AnnotationState.availableColors
        let colorSize: CGFloat = 18
        let colorSpacing: CGFloat = 3
        let padding: CGFloat = 8

        // Width label for stroke width
        let swText = String(format: "%.0f", element.strokeWidth)
        let swFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        let swAttrs: [NSAttributedString.Key: Any] = [.font: swFont]
        let swSize = (swText as NSString).size(withAttributes: swAttrs)

        let colorsWidth = showColors ? CGFloat(colors.count) * colorSize + CGFloat(colors.count - 1) * colorSpacing : 0
        let dividerW: CGFloat = 12
        let minusBtnW: CGFloat = 18
        let plusBtnW: CGFloat = 18
        let widthLabelW = swSize.width + 8
        let widthSectionW = minusBtnW + 4 + widthLabelW + 4 + plusBtnW
        let actionBtnSize: CGFloat = 22
        let actionSpacing: CGFloat = 2
        let actionSectionW = actionBtnSize * 2 + actionSpacing  // delete + duplicate
        let totalWidth = padding + colorsWidth + (showColors ? dividerW : 0) + widthSectionW + dividerW + actionSectionW + padding
        let h: CGFloat = 28

        let gap: CGFloat = 4
        let x = barFrame.maxX - totalWidth
        let y = barFrame.maxY + gap

        let panel = makeSolidPanel(frame: NSRect(x: x, y: y, width: totalWidth, height: h), cornerRadius: 5)

        var bx = padding

        // Color dots (hidden for mosaic)
        if showColors {
            let cy = (h - colorSize) / 2
            for color in colors {
                let dot = ColorDot(frame: NSRect(x: bx, y: cy, width: colorSize, height: colorSize), color: color)
                dot.isSelected = element.color.isEqual(to: color)
                dot.onPress = { [weak self] in self?.selectColor(color) }
                panel.addSubview(dot)
                colorDots[color] = dot
                bx += colorSize + colorSpacing
            }

            // Divider
            bx += (dividerW - colorSpacing) / 2
            let divider = NSView(frame: NSRect(x: bx - 0.5, y: 5, width: 1, height: h - 10))
            divider.wantsLayer = true; divider.layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.4).cgColor
            panel.addSubview(divider)
            bx += (dividerW - colorSpacing) / 2
        }

        // Minus button
        let btnH: CGFloat = 20
        let btnY = (h - btnH) / 2
        let minusBtn = SmallButton(frame: NSRect(x: bx, y: btnY, width: minusBtnW, height: btnH), text: "\u{2212}")
        minusBtn.onPress = { [weak self] in
            guard let self = self else { return }
            self.annoState.pushUndoForPropertyChange(kind: .strokeWidth)
            self.annoState.strokeWidths[elementTool] = max(1, element.strokeWidth - 1)
            element.strokeWidth = self.annoState.strokeWidths[elementTool] ?? element.strokeWidth
            self.refreshSecondaryPanel()
            self.needsDisplay = true
        }
        panel.addSubview(minusBtn)
        bx += minusBtnW + 4

        // Stroke width label
        let widthLabel = NSTextField(labelWithString: swText)
        widthLabel.font = swFont
        widthLabel.textColor = NSColor(white: 0.4, alpha: 1.0)
        widthLabel.alignment = .center
        widthLabel.frame = NSRect(x: bx, y: (h - swSize.height) / 2, width: widthLabelW, height: swSize.height)
        panel.addSubview(widthLabel)
        bx += widthLabelW + 4

        // Plus button
        let plusBtn = SmallButton(frame: NSRect(x: bx, y: btnY, width: plusBtnW, height: btnH), text: "+")
        plusBtn.onPress = { [weak self] in
            guard let self = self else { return }
            self.annoState.pushUndoForPropertyChange(kind: .strokeWidth)
            self.annoState.strokeWidths[elementTool] = min(20, element.strokeWidth + 1)
            element.strokeWidth = self.annoState.strokeWidths[elementTool] ?? element.strokeWidth
            self.refreshSecondaryPanel()
            self.needsDisplay = true
        }
        panel.addSubview(plusBtn)
        bx += plusBtnW

        // Divider before action buttons
        bx += dividerW / 2
        let actionDivider = NSView(frame: NSRect(x: bx - 0.5, y: 5, width: 1, height: h - 10))
        actionDivider.wantsLayer = true; actionDivider.layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.4).cgColor
        panel.addSubview(actionDivider)
        bx += dividerW / 2

        // Duplicate button
        let abY = (h - actionBtnSize) / 2
        let dupBtn = HoverIconButton(frame: NSRect(x: bx, y: abY, width: actionBtnSize, height: actionBtnSize), symbolName: "plus.square.on.square", tooltip: "Duplicate", pointSize: 10)
        dupBtn.onPress = { [weak self] in
            guard let self = self else { return }
            self.annoState.duplicateSelected()
            self.removeAllPanels()
            self.showAllPanels()
            self.needsDisplay = true
        }
        panel.addSubview(dupBtn)
        bx += actionBtnSize + actionSpacing

        // Delete button
        let delBtn = HoverIconButton(frame: NSRect(x: bx, y: abY, width: actionBtnSize, height: actionBtnSize), symbolName: "trash", tooltip: "Delete  \u{232B}", pointSize: 10)
        delBtn.onPress = { [weak self] in
            guard let self = self else { return }
            self.annoState.deleteSelected()
            self.removeAllPanels()
            self.showAllPanels()
            self.needsDisplay = true
        }
        panel.addSubview(delBtn)

        addSubview(panel)
        secondaryPanelView = panel
    }

    /// Show panel for multi-selection: only delete button
    private func showMultiSelectPanel(barFrame: NSRect) {
        let padding: CGFloat = 8
        let actionBtnSize: CGFloat = 22
        let h: CGFloat = 28
        let totalWidth = padding + actionBtnSize + padding

        let gap: CGFloat = 4
        let x = barFrame.maxX - totalWidth
        let y = barFrame.maxY + gap

        let panel = makeSolidPanel(frame: NSRect(x: x, y: y, width: totalWidth, height: h), cornerRadius: 5)

        let abY = (h - actionBtnSize) / 2
        let delBtn = HoverIconButton(frame: NSRect(x: padding, y: abY, width: actionBtnSize, height: actionBtnSize), symbolName: "trash", tooltip: "Delete Selected  \u{232B}", pointSize: 10)
        delBtn.onPress = { [weak self] in
            guard let self = self else { return }
            self.annoState.deleteSelected()
            self.removeAllPanels()
            self.showAllPanels()
            self.needsDisplay = true
        }
        panel.addSubview(delBtn)

        addSubview(panel)
        secondaryPanelView = panel
    }
}
