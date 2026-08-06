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
        showBottomBar()
        showInfoPanel()
        showSecondaryPanel()
    }

    func removeAllPanels() {
        dismissToolbarMenu()
        toolButtons.removeAll()
        infoPanelView?.removeFromSuperview(); infoPanelView = nil
        bottomBarView?.removeFromSuperview(); bottomBarView = nil
        secondaryPanelView?.removeFromSuperview(); secondaryPanelView = nil
        textField?.removeFromSuperview(); textField = nil
        ocrPanelView?.removeFromSuperview(); ocrPanelView = nil
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

    private func clampedPanelX(preferredX: CGFloat, width: CGFloat) -> CGFloat {
        let margin: CGFloat = 4
        guard width <= bounds.width - margin * 2 else { return bounds.minX + margin }
        return min(max(preferredX, bounds.minX + margin), bounds.maxX - width - margin)
    }

    private func secondaryPanelOrigin(barFrame: NSRect, size: NSSize) -> NSPoint {
        let gap: CGFloat = 4
        let x = clampedPanelX(preferredX: barFrame.maxX - size.width, width: size.width)
        let aboveY = barFrame.maxY + gap
        if aboveY + size.height <= bounds.maxY - 4 {
            return NSPoint(x: x, y: aboveY)
        }
        return NSPoint(x: x, y: max(bounds.minY + 4, barFrame.minY - gap - size.height))
    }

    func isPointInPanel(_ point: NSPoint) -> Bool {
        for panel in [bottomBarView, infoPanelView, secondaryPanelView, ocrPanelView, toolbarMenuView] {
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
        var y = panelYPosition()

        // Create label first and let it size itself to avoid clipping
        let label = NSTextField(labelWithString: infoText)
        label.font = font; label.textColor = NSColor(white: 0.4, alpha: 1.0)
        label.isBordered = false; label.isEditable = false; label.drawsBackground = false
        label.sizeToFit()
        let labelWidth = ceil(label.frame.width)
        let labelHeight = ceil(label.frame.height)

        let panelWidth = labelWidth + hPadding * 2
        let x = clampedPanelX(preferredX: selectionRect.origin.x, width: panelWidth)
        var proposedFrame = NSRect(x: x, y: y, width: panelWidth, height: panelHeight)
        if let barFrame = bottomBarView?.frame, proposedFrame.intersects(barFrame) {
            let aboveBarY = barFrame.maxY + 4
            if aboveBarY + panelHeight <= bounds.maxY - 4 {
                y = aboveBarY
            } else {
                y = max(bounds.minY + 4, barFrame.minY - panelHeight - 4)
            }
            proposedFrame.origin.y = y
        }
        let panel = makeSolidPanel(frame: proposedFrame)

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

        let toolGroups = AnnotationTool.toolbarGroups
        let toolCount = CGFloat(toolGroups.count)
        let groupedToolCount = CGFloat(toolGroups.filter { $0.count > 1 }.count)
        let toolMenuTriggerW: CGFloat = 12
        let undoRedoCount: CGFloat = 2
        let ocrChevronW: CGFloat = 14
        let ocrCount: CGFloat = 2
        let scrollCaptureCount: CGFloat = 1
        let actionCount: CGFloat = 4

        let toolsWidth = toolCount * btnSize + groupedToolCount * toolMenuTriggerW + (toolCount - 1) * spacing
        let undoRedoWidth = undoRedoCount * btnSize + (undoRedoCount - 1) * spacing
        let ocrWidth = ocrCount * btnSize + (ocrCount - 1) * spacing + ocrChevronW
        let scrollCaptureWidth = scrollCaptureCount * btnSize
        let actionsWidth = actionCount * btnSize + (actionCount - 1) * spacing
        let totalWidth = padding + toolsWidth + dividerW + undoRedoWidth + dividerW + ocrWidth + dividerW + scrollCaptureWidth + dividerW + actionsWidth + padding
        let h: CGFloat = 30

        let preferredX = selectionRect.origin.x + selectionRect.width - totalWidth
        let x = clampedPanelX(preferredX: preferredX, width: totalWidth)
        let y = panelYPosition()

        let panel = makeSolidPanel(frame: NSRect(x: x, y: y, width: totalWidth, height: h))

        let by = (h - btnSize) / 2
        var bx = padding

        // Tool buttons
        for group in toolGroups {
            guard !group.isEmpty else { continue }
            let displayedTool = annoState.rememberedTool(in: group)
            let tooltip = group.map(\.displayName).joined(separator: " / ")
            let btn = HoverIconButton(
                frame: NSRect(x: bx, y: by, width: btnSize, height: btnSize),
                symbolName: displayedTool.symbolName,
                tooltip: group.count == 1 ? tooltip : displayedTool.displayName
            )
            btn.isActive = group.contains(annoState.currentTool ?? .select)
            btn.onPress = { [weak self] in self?.selectTool(displayedTool) }
            panel.addSubview(btn)
            for tool in group { toolButtons[tool] = btn }
            bx += btnSize

            if group.count > 1 {
                let menuButton = HoverIconButton(
                    frame: NSRect(x: bx, y: by, width: toolMenuTriggerW, height: btnSize),
                    symbolName: "chevron.up",
                    tooltip: "More",
                    pointSize: 6
                )
                menuButton.onPress = { [weak self, weak menuButton] in
                    guard let self, let menuButton else { return }
                    self.showToolGroupMenu(group, from: menuButton)
                }
                panel.addSubview(menuButton)
                bx += toolMenuTriggerW
            }
            bx += spacing
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
        panel.addSubview(ocrBtn); bx += btnSize

        // OCR action-menu trigger
        let chevronBtn = HoverIconButton(
            frame: NSRect(x: bx, y: by, width: ocrChevronW, height: btnSize),
            symbolName: "chevron.up",
            tooltip: "More",
            pointSize: 7
        )
        chevronBtn.onPress = { [weak self] in
            guard let self = self else { return }
            self.showOCRActionMenu(from: chevronBtn)
        }
        panel.addSubview(chevronBtn); bx += ocrChevronW + spacing

        // Translate button
        let translateBtn = HoverIconButton(frame: NSRect(x: bx, y: by, width: btnSize, height: btnSize), symbolName: "character.book.closed", tooltip: "Translate  Y")
        translateBtn.onPress = { [weak self] in self?.enterTranslateMode() }
        panel.addSubview(translateBtn); bx += btnSize

        // Divider 2b (before scroll capture)
        bx += (dividerW) / 2
        let divider2b = NSView(frame: NSRect(x: bx - 0.5, y: 6, width: 1, height: h - 12))
        divider2b.wantsLayer = true; divider2b.layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.4).cgColor
        panel.addSubview(divider2b)
        bx += (dividerW) / 2

        // Scroll Capture button
        let scrollBtn = HoverIconButton(frame: NSRect(x: bx, y: by, width: btnSize, height: btnSize), symbolName: "rectangle.bottomhalf.inset.filled", tooltip: "Scroll Capture  L")
        scrollBtn.onPress = { [weak self] in self?.performAction(.scrollCapture) }
        panel.addSubview(scrollBtn); bx += btnSize

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
        guard tool != .highlight else { return }
        let showColors = tool.showsColorControls
        let showFill = tool.supportsShapeFill
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
        let fillControlW: CGFloat = 54
        let fillSectionW = showFill ? dividerW + fillControlW : 0
        let totalWidth = padding + colorsWidth + (showColors ? dividerW : 0) + widthSectionW + fillSectionW + padding
        let h: CGFloat = 28

        let origin = secondaryPanelOrigin(barFrame: barFrame, size: NSSize(width: totalWidth, height: h))

        let panel = makeSolidPanel(frame: NSRect(origin: origin, size: NSSize(width: totalWidth, height: h)), cornerRadius: 5)

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
        bx += plusBtnW

        if showFill {
            bx += dividerW / 2
            let fillDivider = NSView(frame: NSRect(x: bx - 0.5, y: 5, width: 1, height: h - 10))
            fillDivider.wantsLayer = true
            fillDivider.layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.4).cgColor
            panel.addSubview(fillDivider)
            bx += dividerW / 2

            let fillButton = FillToggleButton(
                frame: NSRect(x: bx, y: (h - 22) / 2, width: fillControlW, height: 22),
                isOn: annoState.shapeFillEnabled
            )
            fillButton.onToggle = { [weak self] enabled in
                self?.annoState.setFillEnabled(enabled)
                self?.refreshSecondaryPanel()
                self?.needsDisplay = true
            }
            panel.addSubview(fillButton)
        }

        addSubview(panel)
        secondaryPanelView = panel
    }

    /// Show property panel for a selected element (single selection) with Delete/Duplicate buttons
    private func showElementPropertyPanel(barFrame: NSRect, element: AnnotationElement) {
        if element.tool == .highlight {
            showHighlightElementPanel(barFrame: barFrame)
            return
        }
        let elementTool = element.tool
        let showColors = elementTool.showsColorControls
        let showFill = elementTool.supportsShapeFill
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
        let fillControlW: CGFloat = 54
        let fillSectionW = showFill ? dividerW + fillControlW : 0
        let actionBtnSize: CGFloat = 22
        let actionSpacing: CGFloat = 2
        let actionSectionW = actionBtnSize * 2 + actionSpacing  // delete + duplicate
        let totalWidth = padding + colorsWidth + (showColors ? dividerW : 0) + widthSectionW + fillSectionW + dividerW + actionSectionW + padding
        let h: CGFloat = 28

        let origin = secondaryPanelOrigin(barFrame: barFrame, size: NSSize(width: totalWidth, height: h))

        let panel = makeSolidPanel(frame: NSRect(origin: origin, size: NSSize(width: totalWidth, height: h)), cornerRadius: 5)

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

        if showFill {
            bx += dividerW / 2
            let fillDivider = NSView(frame: NSRect(x: bx - 0.5, y: 5, width: 1, height: h - 10))
            fillDivider.wantsLayer = true
            fillDivider.layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.4).cgColor
            panel.addSubview(fillDivider)
            bx += dividerW / 2

            let fillButton = FillToggleButton(
                frame: NSRect(x: bx, y: (h - 22) / 2, width: fillControlW, height: 22),
                isOn: element.isFilled
            )
            fillButton.onToggle = { [weak self] enabled in
                self?.annoState.setFillEnabled(enabled, for: element)
                self?.refreshSecondaryPanel()
                self?.needsDisplay = true
            }
            panel.addSubview(fillButton)
            bx += fillControlW
        }

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

    /// Highlight is a single global spotlight effect, so its selected-state
    /// panel only offers deletion (duplicating it would stack/replace the mask).
    private func showHighlightElementPanel(barFrame: NSRect) {
        let padding: CGFloat = 8
        let actionBtnSize: CGFloat = 22
        let h: CGFloat = 28
        let totalWidth = padding + actionBtnSize + padding
        let origin = secondaryPanelOrigin(barFrame: barFrame, size: NSSize(width: totalWidth, height: h))
        let panel = makeSolidPanel(frame: NSRect(origin: origin, size: NSSize(width: totalWidth, height: h)), cornerRadius: 5)

        let buttonY = (h - actionBtnSize) / 2
        let deleteButton = HoverIconButton(
            frame: NSRect(x: padding, y: buttonY, width: actionBtnSize, height: actionBtnSize),
            symbolName: "trash",
            tooltip: "Delete Highlight  \u{232B}",
            pointSize: 10
        )
        deleteButton.onPress = { [weak self] in
            guard let self else { return }
            self.annoState.deleteSelected()
            self.refreshPanels()
        }
        panel.addSubview(deleteButton)
        addSubview(panel)
        secondaryPanelView = panel
    }

    // MARK: - Grouped Annotation Tool Menu
    func showToolGroupMenu(_ tools: [AnnotationTool], from view: NSView) {
        if toolbarMenuTriggerView === view {
            dismissToolbarMenu()
            return
        }
        dismissToolbarMenu()

        let menuWidth: CGFloat = 154
        let rowHeight: CGFloat = 30
        let padding: CGFloat = 4
        let menuHeight = padding * 2 + rowHeight * CGFloat(tools.count)
        let triggerFrame = view.convert(view.bounds, to: self)
        let menuFrame = ToolbarMenuLayout.frame(
            triggerFrame: triggerFrame,
            menuSize: NSSize(width: menuWidth, height: menuHeight),
            in: bounds
        )

        let menu = makeSolidPanel(
            frame: menuFrame,
            cornerRadius: 6
        )
        let rememberedTool = annoState.rememberedTool(in: tools)
        for (index, tool) in tools.enumerated() {
            let rowY = padding + CGFloat(tools.count - 1 - index) * rowHeight
            let item = ToolbarMenuItem(
                frame: NSRect(x: padding, y: rowY, width: menuWidth - padding * 2, height: rowHeight),
                tool: tool,
                isSelected: rememberedTool == tool
            )
            item.onPress = { [weak self] in
                guard let self else { return }
                self.selectTool(tool)
            }
            menu.addSubview(item)
        }
        addSubview(menu)
        toolbarMenuView = menu
        toolbarMenuTriggerView = view
    }

    func dismissToolbarMenu() {
        toolbarMenuView?.removeFromSuperview()
        toolbarMenuView = nil
        toolbarMenuTriggerView = nil
    }

    // MARK: - OCR Action Menu
    func showOCRActionMenu(from view: NSView) {
        if toolbarMenuTriggerView === view {
            dismissToolbarMenu()
            return
        }
        dismissToolbarMenu()

        let menuWidth: CGFloat = 218
        let rowHeight: CGFloat = 30
        let padding: CGFloat = 4
        let menuSize = NSSize(width: menuWidth, height: rowHeight + padding * 2)
        let triggerFrame = view.convert(view.bounds, to: self)
        let menu = makeSolidPanel(
            frame: ToolbarMenuLayout.frame(triggerFrame: triggerFrame, menuSize: menuSize, in: bounds),
            cornerRadius: 6
        )
        let item = ToolbarMenuItem(
            frame: NSRect(x: padding, y: padding, width: menuWidth - padding * 2, height: rowHeight),
            symbolName: "doc.on.doc",
            title: "Copy All Text & Done",
            shortcut: "\u{21E7}O"
        )
        item.onPress = { [weak self] in
            guard let self else { return }
            self.dismissToolbarMenu()
            self.ocrCopyAllAndDone()
        }
        menu.addSubview(item)
        addSubview(menu)
        toolbarMenuView = menu
        toolbarMenuTriggerView = view
    }

    /// Show panel for multi-selection: only delete button
    private func showMultiSelectPanel(barFrame: NSRect) {
        let padding: CGFloat = 8
        let actionBtnSize: CGFloat = 22
        let h: CGFloat = 28
        let totalWidth = padding + actionBtnSize + padding

        let origin = secondaryPanelOrigin(barFrame: barFrame, size: NSSize(width: totalWidth, height: h))

        let panel = makeSolidPanel(frame: NSRect(origin: origin, size: NSSize(width: totalWidth, height: h)), cornerRadius: 5)

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
