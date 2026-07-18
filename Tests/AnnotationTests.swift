import Cocoa

private struct AnnotationTestFailure: Error {
    let message: String
}

@main
private enum AnnotationTests {
    private static var testCount = 0

    static func main() throws {
        try test("toolbar groups stay compact and cycle deterministically", testToolGroupsAndCycling)
        try test("grouped tool preferences persist across annotation states", testGroupedToolPersistence)
        try test("toolbar menus avoid their dedicated triggers", testToolbarMenuPlacement)
        try test("toolbar menu shortcuts keep contrast on the light surface", testToolbarMenuShortcutContrast)
        try test("line geometry uses segment hit testing and endpoint handles", testLineGeometry)
        try test("circle geometry only hits the ellipse border", testCircleGeometry)
        try test("circle and highlight resize from four corners", testBoxResizeHandles)
        try test("new elements participate in move, duplicate, undo, and redo", testStateOperations)
        try test("line and circle render as unfilled strokes", testLineAndCircleRendering)
        try test("highlight renders a stronger outside dim and lighter focus", testHighlightRendering)
        try test("glow style is shared, scoped, and scales with stroke width", testGlowStyleAndBounds)
        try test("vector and marker tools render a clear edge glow", testVectorGlowRendering)
        try test("glow preserves the sharp vector body color and alpha", testGlowPreservesBodyColorAndAlpha)
        try test("overlay and export share rendering without exporting selection UI", testOverlayAndExportRendering)
        try test("vector glow clips safely at screenshot edges", testGlowAtScreenshotEdges)
        try test("text typography supports English, Chinese, and mixed content", testTextTypographyAndFallback)
        try test("text layout handles empty, single-line, and explicit newlines", testTextLayoutVariants)
        try test("text editor and renderer share TextKit bounds without soft wrapping", testTextEditorMatchesRenderer)
        try test("text bounds, hit testing, and rendering cover the same glyph area", testTextBoundsHitTestingAndRendering)
        try test("text re-edit layout and undo redo preserve typography state", testTextReEditAndUndoRedo)

        print("AnnotationTests: \(testCount) tests passed")
    }

    private static func testToolGroupsAndCycling() throws {
        try expect(AnnotationTool.toolbarGroups.count == 6, "top-level annotation slot count changed")
        try expect(AnnotationTool.toolbarGroups[1] == [.arrow, .line], "Arrow/Line group is wrong")
        try expect(AnnotationTool.toolbarGroups[2] == [.rectangle, .circle], "Rectangle/Circle group is wrong")
        try expect(AnnotationTool.toolbarGroups[5] == [.mosaic, .highlight], "Mosaic/Highlight group is wrong")

        try expect(AnnotationTool.cycledTool(in: [.arrow, .line], current: nil) == .arrow, "A did not start at Arrow")
        try expect(AnnotationTool.cycledTool(in: [.arrow, .line], current: .arrow) == .line, "A did not advance to Line")
        try expect(AnnotationTool.cycledTool(in: [.arrow, .line], current: .line) == .arrow, "A did not wrap to Arrow")
        try expect(AnnotationTool.cycledTool(in: [.rectangle, .circle], current: .text) == .rectangle, "R did not start at Rectangle")
        try expect(AnnotationTool.cycledTool(in: [.mosaic, .highlight], current: .mosaic) == .highlight, "M did not advance to Highlight")

        let suiteName = "AnnotationTests.toolGroups.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw AnnotationTestFailure(message: "could not create isolated tool-group defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let state = AnnotationState(userDefaults: defaults)
        state.currentTool = .arrow
        try expect(state.toolForGroupShortcut([.arrow, .line]) == .line, "active Arrow did not cycle to Line")
        state.currentTool = .line
        state.currentTool = .select
        try expect(state.rememberedTool(in: [.arrow, .line]) == .line, "Select reset the visible group member to Arrow")
        try expect(state.toolForGroupShortcut([.arrow, .line]) == .line, "A did not restore remembered Line from Select")
        state.currentTool = .circle
        state.currentTool = .select
        try expect(state.rememberedTool(in: [.rectangle, .circle]) == .circle, "Select reset the visible group member to Rectangle")
        state.currentTool = .highlight
        state.currentTool = .select
        try expect(state.rememberedTool(in: [.mosaic, .highlight]) == .highlight, "Select reset the visible group member to Mosaic")
    }

    private static func testGroupedToolPersistence() throws {
        let suiteName = "AnnotationTests.toolPersistence.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw AnnotationTestFailure(message: "could not create isolated persistence defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstState = AnnotationState(userDefaults: defaults)
        firstState.currentTool = .line
        firstState.currentTool = .circle
        firstState.currentTool = .highlight
        firstState.currentTool = .select

        let restoredState = AnnotationState(userDefaults: defaults)
        try expect(restoredState.rememberedTool(in: [.arrow, .line]) == .line, "Line preference was not restored")
        try expect(restoredState.rememberedTool(in: [.rectangle, .circle]) == .circle, "Circle preference was not restored")
        try expect(restoredState.rememberedTool(in: [.mosaic, .highlight]) == .highlight, "Highlight preference was not restored")
    }

    private static func testToolbarMenuPlacement() throws {
        let overlayBounds = NSRect(x: 0, y: 0, width: 900, height: 700)
        let menuSize = NSSize(width: 190, height: 68)

        let lowerTrigger = NSRect(x: 420, y: 80, width: 12, height: 26)
        let above = ToolbarMenuLayout.frame(triggerFrame: lowerTrigger, menuSize: menuSize, in: overlayBounds)
        try expect(above.minY == lowerTrigger.maxY + ToolbarMenuLayout.gap, "toolbar menu did not prefer the space above")
        try expect(!above.intersects(lowerTrigger), "toolbar menu covered its lower trigger")

        let upperTrigger = NSRect(x: 420, y: 660, width: 12, height: 26)
        let below = ToolbarMenuLayout.frame(triggerFrame: upperTrigger, menuSize: menuSize, in: overlayBounds)
        try expect(below.maxY == upperTrigger.minY - ToolbarMenuLayout.gap, "toolbar menu did not fall back below near the top edge")
        try expect(!below.intersects(upperTrigger), "toolbar menu covered its upper trigger")

        let rightEdgeTrigger = NSRect(x: 888, y: 80, width: 12, height: 26)
        let clamped = ToolbarMenuLayout.frame(triggerFrame: rightEdgeTrigger, menuSize: menuSize, in: overlayBounds)
        try expect(clamped.maxX <= overlayBounds.maxX - ToolbarMenuLayout.margin, "toolbar menu escaped the right screen edge")
        try expect(clamped.minX >= overlayBounds.minX + ToolbarMenuLayout.margin, "toolbar menu escaped the left screen edge")
    }

    private static func testToolbarMenuShortcutContrast() throws {
        guard let color = ToolbarMenuItem.shortcutTextColor.usingColorSpace(.deviceRGB) else {
            throw AnnotationTestFailure(message: "could not resolve toolbar shortcut color")
        }
        try expect(color.brightnessComponent < 0.6, "toolbar shortcut is too light for the fixed light menu surface")
        try expect(color.alphaComponent == 1, "toolbar shortcut contrast was reduced by transparency")
    }

    private static func testLineGeometry() throws {
        let line = element(.line, from: NSPoint(x: 10, y: 20), to: NSPoint(x: 90, y: 20), strokeWidth: 3)
        try expect(line.hasRenderableGeometry, "valid Line was rejected")
        try expect(line.hitTest(point: NSPoint(x: 50, y: 23)), "Line missed a nearby point")
        try expect(!line.hitTest(point: NSPoint(x: 50, y: 40)), "Line hit a distant point")
        try expect(line.hitTestResizeHandle(point: NSPoint(x: 10, y: 20)) == .startPoint, "Line start handle is missing")
        try expect(line.hitTestResizeHandle(point: NSPoint(x: 90, y: 20)) == .endPoint, "Line end handle is missing")

        line.applyResize(handle: .endPoint, to: NSPoint(x: 80, y: 60))
        try expect(line.endPoint == NSPoint(x: 80, y: 60), "Line end handle did not resize")
        let tiny = element(.line, from: .zero, to: NSPoint(x: 2, y: 2))
        try expect(!tiny.hasRenderableGeometry, "tiny Line should not be committed")
    }

    private static func testCircleGeometry() throws {
        let circle = element(.circle, from: NSPoint(x: 90, y: 70), to: NSPoint(x: 10, y: 10), strokeWidth: 2)
        try expect(circle.normalizedRect == NSRect(x: 10, y: 10, width: 80, height: 60), "Circle drag box was not normalized")
        try expect(circle.hitTest(point: NSPoint(x: 50, y: 70)), "Circle missed its top border")
        try expect(circle.hitTest(point: NSPoint(x: 90, y: 40)), "Circle missed its right border")
        try expect(!circle.hitTest(point: NSPoint(x: 50, y: 40)), "Circle incorrectly hit its interior")
        try expect(!circle.hitTest(point: NSPoint(x: 95, y: 75)), "Circle incorrectly hit outside its ellipse")
        try expect(circle.hasRenderableGeometry, "valid Circle was rejected")
        try expect(!element(.circle, from: .zero, to: NSPoint(x: 20, y: 2)).hasRenderableGeometry, "flat Circle should not be committed")
    }

    private static func testBoxResizeHandles() throws {
        for tool in [AnnotationTool.circle, .highlight] {
            let box = element(tool, from: NSPoint(x: 10, y: 10), to: NSPoint(x: 50, y: 40))
            try expect(box.hitTestResizeHandle(point: NSPoint(x: 10, y: 40)) == .topLeft, "\(tool) top-left handle is missing")
            try expect(box.hitTestResizeHandle(point: NSPoint(x: 50, y: 10)) == .bottomRight, "\(tool) bottom-right handle is missing")
            box.applyResize(handle: .topRight, to: NSPoint(x: 70, y: 60))
            try expect(box.normalizedRect == NSRect(x: 10, y: 10, width: 60, height: 50), "\(tool) corner resize is wrong")
        }

        let highlight = element(.highlight, from: NSPoint(x: 20, y: 20), to: NSPoint(x: 60, y: 50))
        try expect(highlight.hitTest(point: NSPoint(x: 40, y: 35)), "Highlight focus area was not selectable")
        try expect(!highlight.hitTest(point: NSPoint(x: 10, y: 10)), "Highlight outside mask should not capture hit testing")
    }

    private static func testStateOperations() throws {
        let state = AnnotationState()
        let line = element(.line, from: NSPoint(x: 10, y: 20), to: NSPoint(x: 80, y: 20))
        let circle = element(.circle, from: NSPoint(x: 20, y: 20), to: NSPoint(x: 70, y: 60))
        state.elements = [line, circle]

        state.selectedElementId = line.id
        state.duplicateSelected()
        try expect(state.elements.count == 3, "Line duplicate was not added")
        try expect(state.selectedElement?.tool == .line, "Line duplicate did not preserve its type")
        try expect(state.selectedElement?.id != line.id, "Line duplicate reused identity")
        try expect(state.selectedElement?.startPoint == NSPoint(x: 25, y: 5), "Line duplicate offset changed")
        state.undo()
        try expect(state.elements.count == 2, "duplicate undo failed")
        state.redo()
        try expect(state.elements.count == 3, "duplicate redo failed")

        let moved = state.elements[1]
        let oldStart = moved.startPoint
        moved.move(dx: 7, dy: -3)
        try expect(moved.startPoint == NSPoint(x: oldStart.x + 7, y: oldStart.y - 3), "Circle move failed")

        let highlight = element(.highlight, from: NSPoint(x: 5, y: 5), to: NSPoint(x: 50, y: 40))
        state.elements.append(highlight)
        state.selectedElementId = highlight.id
        let beforeCount = state.elements.count
        state.duplicateSelected()
        try expect(state.elements.count == beforeCount, "singular Highlight was duplicated")
    }

    private static func testLineAndCircleRendering() throws {
        let size = NSSize(width: 100, height: 80)
        let transparent = makeSolidImage(size: size, color: .clear)

        let line = element(.line, from: NSPoint(x: 10, y: 40), to: NSPoint(x: 90, y: 40), strokeWidth: 4)
        line.color = .systemRed
        let lineImage = AnnotationRenderer.renderAnnotationsOntoImage(
            baseImage: transparent,
            annotations: [line],
            selectionRect: NSRect(origin: .zero, size: size),
            screenshot: transparent
        )
        let lineCenter = try color(in: lineImage, at: NSPoint(x: 50, y: 40))
        let lineHeadArea = try color(in: lineImage, at: NSPoint(x: 80, y: 50))
        try expect(lineCenter.alphaComponent > 0.5, "Line center was not rendered")
        try expect(lineHeadArea.alphaComponent < 0.1, "Line rendered an Arrow-style head")

        let circle = element(.circle, from: NSPoint(x: 20, y: 15), to: NSPoint(x: 80, y: 65), strokeWidth: 4)
        circle.color = .systemBlue
        let circleImage = AnnotationRenderer.renderAnnotationsOntoImage(
            baseImage: transparent,
            annotations: [circle],
            selectionRect: NSRect(origin: .zero, size: size),
            screenshot: transparent
        )
        let circleBorder = try color(in: circleImage, at: NSPoint(x: 50, y: 64))
        let circleCenter = try color(in: circleImage, at: NSPoint(x: 50, y: 40))
        try expect(circleBorder.alphaComponent > 0.2, "Circle border was not rendered")
        try expect(circleCenter.alphaComponent < 0.1, "Circle interior was filled")
    }

    private static func testHighlightRendering() throws {
        try expect(AnnotationRenderer.highlightOutsideOpacity != AnnotationRenderer.highlightInsideOpacity, "Highlight alpha values were coupled")
        try expect(AnnotationRenderer.highlightOutsideOpacity > AnnotationRenderer.highlightInsideOpacity, "outside dim is not stronger than inside lift")

        let size = NSSize(width: 100, height: 80)
        let gray = NSColor(deviceWhite: 0.4, alpha: 1)
        let base = makeSolidImage(size: size, color: gray)
        let highlight = element(.highlight, from: NSPoint(x: 30, y: 20), to: NSPoint(x: 70, y: 60))
        let rendered = AnnotationRenderer.renderAnnotationsOntoImage(
            baseImage: base,
            annotations: [highlight],
            selectionRect: NSRect(origin: .zero, size: size),
            screenshot: base
        )

        let outside = try color(in: rendered, at: NSPoint(x: 10, y: 10)).brightnessComponent
        let inside = try color(in: rendered, at: NSPoint(x: 50, y: 40)).brightnessComponent
        try expect(outside < 0.3, "Highlight outside was not visibly dimmed: \(outside)")
        try expect(inside > 0.42, "Highlight focus was not lightly lifted: \(inside)")
        try expect(inside - outside > 0.2, "Highlight did not create enough focus contrast")
    }

    private static func testGlowStyleAndBounds() throws {
        let vectorTools: [AnnotationTool] = [.arrow, .line, .rectangle, .circle, .marker]
        for tool in vectorTools {
            try expect(AnnotationGlowStyle.style(for: tool, strokeWidth: 3) != nil, "\(tool) did not opt into the shared glow style")
        }

        for tool in [AnnotationTool.select, .text, .mosaic, .highlight] {
            try expect(AnnotationGlowStyle.style(for: tool, strokeWidth: 3) == nil, "\(tool) unexpectedly opted into vector glow")
        }

        let thin = try requireGlowStyle(for: .line, strokeWidth: 1)
        let thick = try requireGlowStyle(for: .line, strokeWidth: 12)
        try expect(thick.blurRadius > thin.blurRadius, "glow radius did not scale with stroke width")
        try expect(thick.opacity > thin.opacity, "glow intensity did not scale with stroke width")
        try expect(thin.opacity >= 0.40, "glow baseline became too weak")
        try expect(thick.opacity <= 0.52, "glow opacity is no longer restrained")

        let rectangle = element(.rectangle, from: NSPoint(x: 20, y: 20), to: NSPoint(x: 80, y: 60), strokeWidth: 4)
        let rectangleStyle = try requireGlowStyle(for: .rectangle, strokeWidth: rectangle.strokeWidth)
        let requiredOutset = rectangle.strokeWidth / 2 + rectangleStyle.drawingOutset
        try expect(rectangle.boundingRect.minX <= rectangle.normalizedRect.minX - requiredOutset, "rectangle bounds clip the glow on the left")
        try expect(rectangle.boundingRect.maxY >= rectangle.normalizedRect.maxY + requiredOutset, "rectangle bounds clip the glow on top")

        let shortThickArrow = element(.arrow, from: NSPoint(x: 50, y: 50), to: NSPoint(x: 55, y: 50), strokeWidth: 20)
        guard let arrowDrawingBounds = AnnotationRenderer.vectorDrawingBounds(for: shortThickArrow) else {
            throw AnnotationTestFailure(message: "could not calculate Arrow drawing bounds")
        }
        try expect(shortThickArrow.boundingRect.contains(arrowDrawingBounds), "short Arrow bounds clip its head or glow")

        let marker = element(.marker, from: NSPoint(x: 50, y: 50), to: NSPoint(x: 50, y: 50), strokeWidth: 8)
        guard let markerDrawingBounds = AnnotationRenderer.vectorDrawingBounds(for: marker) else {
            throw AnnotationTestFailure(message: "could not calculate Marker drawing bounds")
        }
        try expect(marker.boundingRect.contains(markerDrawingBounds), "Marker bounds clip its glow")

        let mosaic = element(.mosaic, from: NSPoint(x: 20, y: 20), to: NSPoint(x: 80, y: 60), strokeWidth: 4)
        try expect(mosaic.boundingRect == mosaic.normalizedRect.insetBy(dx: -4, dy: -4), "non-glowing Mosaic bounds changed")
    }

    private static func testVectorGlowRendering() throws {
        let size = NSSize(width: 120, height: 100)
        let samples: [(AnnotationTool, NSPoint, NSPoint, NSPoint, NSPoint)] = [
            (.arrow, NSPoint(x: 25, y: 50), NSPoint(x: 95, y: 50), NSPoint(x: 55, y: 50), NSPoint(x: 55, y: 54)),
            (.line, NSPoint(x: 25, y: 50), NSPoint(x: 95, y: 50), NSPoint(x: 55, y: 50), NSPoint(x: 55, y: 54)),
            (.rectangle, NSPoint(x: 25, y: 20), NSPoint(x: 95, y: 80), NSPoint(x: 55, y: 20), NSPoint(x: 55, y: 16)),
            (.circle, NSPoint(x: 25, y: 20), NSPoint(x: 95, y: 80), NSPoint(x: 60, y: 80), NSPoint(x: 60, y: 84)),
            (.marker, NSPoint(x: 60, y: 50), NSPoint(x: 60, y: 50), NSPoint(x: 60, y: 50), NSPoint(x: 75, y: 50))
        ]

        for (tool, start, end, bodyPoint, glowPoint) in samples {
            let strokeWidth: CGFloat = tool == .marker ? 8 : 4
            let annotation = element(tool, from: start, to: end, strokeWidth: strokeWidth)
            annotation.markerNumber = 1
            annotation.color = .systemRed
            let rendered = renderExport(annotation, size: size)
            let body = try color(in: rendered, at: bodyPoint)
            let glow = try color(in: rendered, at: glowPoint)
            let far = try color(in: rendered, at: NSPoint(x: 5, y: 5))

            try expect(body.alphaComponent > 0.9, "\(tool) body was not rendered sharply")
            try expect(glow.alphaComponent > 0.005, "\(tool) edge glow was not visible")
            try expect(glow.alphaComponent < 0.30, "\(tool) edge glow is too heavy")
            try expect(far.alphaComponent < 0.001, "\(tool) glow polluted a distant pixel")
        }
    }

    private static func testGlowPreservesBodyColorAndAlpha() throws {
        let size = NSSize(width: 100, height: 80)
        let annotation = element(.line, from: NSPoint(x: 15, y: 40), to: NSPoint(x: 85, y: 40), strokeWidth: 6)
        annotation.color = NSColor(deviceRed: 0.18, green: 0.72, blue: 0.36, alpha: 0.62)

        let rendered = renderExport(annotation, size: size)
        let body = try color(in: rendered, at: NSPoint(x: 50, y: 40))
        let colorReference = makeSolidImage(size: size, color: annotation.color)
        let expected = try color(in: colorReference, at: NSPoint(x: 50, y: 40))

        try expect(abs(body.redComponent - expected.redComponent) < 0.02, "glow changed the body red component: \(body.redComponent) vs \(expected.redComponent)")
        try expect(abs(body.greenComponent - expected.greenComponent) < 0.02, "glow changed the body green component: \(body.greenComponent) vs \(expected.greenComponent)")
        try expect(abs(body.blueComponent - expected.blueComponent) < 0.02, "glow changed the body blue component: \(body.blueComponent) vs \(expected.blueComponent)")
        try expect(abs(body.alphaComponent - expected.alphaComponent) < 0.02, "glow changed the body alpha: \(body.alphaComponent) vs \(expected.alphaComponent)")
    }

    private static func testOverlayAndExportRendering() throws {
        let size = NSSize(width: 110, height: 90)
        let annotation = element(.rectangle, from: NSPoint(x: 25, y: 20), to: NSPoint(x: 85, y: 70), strokeWidth: 4)
        annotation.color = .systemRed

        let overlay = renderDirect(annotation, size: size, isSelected: false)
        let exported = renderExport(annotation, size: size)
        for point in [NSPoint(x: 55, y: 20), NSPoint(x: 55, y: 15), NSPoint(x: 5, y: 5)] {
            let overlayColor = try color(in: overlay, at: point)
            let exportColor = try color(in: exported, at: point)
            try expect(colorsMatch(overlayColor, exportColor, tolerance: 0.01), "overlay/export rendering diverged at \(point)")
        }

        let selectedOverlay = renderDirect(annotation, size: size, isSelected: true)
        let overlaySelectionPixels = try countSelectionBluePixels(in: selectedOverlay)
        let exportSelectionPixels = try countSelectionBluePixels(in: exported)
        try expect(overlaySelectionPixels > 0, "selected overlay did not render its editing UI")
        try expect(exportSelectionPixels == 0, "selection box or resize handles leaked into export")
    }

    private static func testGlowAtScreenshotEdges() throws {
        let size = NSSize(width: 50, height: 40)
        let edgeElements = [
            element(.arrow, from: NSPoint(x: 0, y: 1), to: NSPoint(x: 35, y: 1), strokeWidth: 4),
            element(.line, from: NSPoint(x: -5, y: 20), to: NSPoint(x: 30, y: 20), strokeWidth: 4),
            element(.rectangle, from: NSPoint(x: -4, y: -3), to: NSPoint(x: 30, y: 25), strokeWidth: 4),
            element(.circle, from: NSPoint(x: 25, y: 15), to: NSPoint(x: 54, y: 43), strokeWidth: 4)
        ]

        let transparent = makeSolidImage(size: size, color: .clear)
        let rendered = AnnotationRenderer.renderAnnotationsOntoImage(
            baseImage: transparent,
            annotations: edgeElements,
            selectionRect: NSRect(origin: .zero, size: size),
            screenshot: transparent
        )
        try expect(rendered.size == size, "edge rendering changed the output dimensions")
        let visiblePixels = try countVisiblePixels(in: rendered)
        try expect(visiblePixels > 0, "edge-clipped vectors did not render")
    }

    private static func testTextTypographyAndFallback() throws {
        let fontSize: CGFloat = 16
        let font = AnnotationTextLayout.font(ofSize: fontSize)
        try expect(font.fontName == AnnotationTextLayout.primaryFontName, "text did not use the Avenir Next primary face")

        let english = AnnotationTextLayout.layout(text: "Readable English", fontSize: fontSize, color: .black)
        let chinese = AnnotationTextLayout.layout(text: "清晰中文标注", fontSize: fontSize, color: .black)
        let mixed = AnnotationTextLayout.layout(text: "Snipshot 截图标注 2026", fontSize: fontSize, color: .black)

        for (name, layout) in [("English", english), ("Chinese", chinese), ("mixed", mixed)] {
            try expect(layout.usedRect.width > 0 && layout.usedRect.height > 0, "\(name) text did not produce layout bounds")
            try expect(layout.lineFragmentCount == 1, "\(name) text unexpectedly wrapped")
            try expect(layout.layoutManager.numberOfGlyphs > 0, "\(name) text did not resolve renderable glyphs")
        }
        try expect(mixed.usedRect.width > chinese.usedRect.width, "mixed fallback layout lost its Latin run")
    }

    private static func testTextLayoutVariants() throws {
        let fontSize: CGFloat = 16
        let empty = AnnotationTextLayout.layout(text: "", fontSize: fontSize, color: .systemRed)
        try expect(empty.usedRect == .zero, "empty text should have zero final bounds")
        try expect(empty.lineFragmentCount == 0, "empty text should not create a rendered line")

        let single = AnnotationTextLayout.layout(text: "Single line 单行", fontSize: fontSize, color: .systemRed)
        let multiline = AnnotationTextLayout.layout(
            text: "First line 第一行\nSecond line 第二行",
            fontSize: fontSize,
            color: .systemRed
        )
        try expect(single.lineFragmentCount == 1, "single-line text created multiple fragments")
        try expect(multiline.lineFragmentCount == 2, "explicit newline was not preserved")
        try expect(multiline.usedRect.height > single.usedRect.height, "explicit newline did not increase text height")

        let longestExplicitLine = max(
            AnnotationTextLayout.layout(text: "First line 第一行", fontSize: fontSize, color: .systemRed).usedRect.width,
            AnnotationTextLayout.layout(text: "Second line 第二行", fontSize: fontSize, color: .systemRed).usedRect.width
        )
        try expect(approximatelyEqual(multiline.usedRect.width, longestExplicitLine), "multiline width did not match its longest explicit line")
    }

    private static func testTextEditorMatchesRenderer() throws {
        let fontSize: CGFloat = 16
        let text = "A long English 中文 mixed annotation near the old wrapping boundary"
        let finalLayout = AnnotationTextLayout.layout(text: text, fontSize: fontSize, color: .systemBlue)
        try expect(finalLayout.usedRect.width > 80, "long-text fixture did not cross the editor boundary")
        try expect(finalLayout.lineFragmentCount == 1, "unconstrained final layout soft-wrapped")

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 80, height: 20))
        AnnotationTextLayout.configure(
            textView: textView,
            text: text,
            fontSize: fontSize,
            color: .systemBlue
        )
        let editorUsedRect = AnnotationTextLayout.usedRect(in: textView)
        try expect(approximatelyEqual(editorUsedRect, finalLayout.usedRect), "editor and final TextKit usedRect differ")
        try expect(editorUsedRect.width > 80, "editor wrapped instead of expanding horizontally")

        let topLeft = NSPoint(x: 35, y: 140)
        let editorFrame = AnnotationTextLayout.frame(topLeft: topLeft, size: editorUsedRect.size)
        let finalBounds = AnnotationTextLayout.boundingRect(
            text: text,
            fontSize: fontSize,
            color: .systemBlue,
            topLeft: topLeft
        )
        try expect(approximatelyEqual(editorFrame, finalBounds), "editor frame and final bounds do not share the same top-left anchor")
    }

    private static func testTextBoundsHitTestingAndRendering() throws {
        let text = element(.text, from: NSPoint(x: 18, y: 92), to: .zero, strokeWidth: 4)
        text.text = "Bounds 边界\nHit test 命中"
        text.color = .systemPurple
        let bounds = text.boundingRect
        try expect(bounds.width > 0 && bounds.height > 0, "text element did not expose layout bounds")
        try expect(text.hitTest(point: NSPoint(x: bounds.midX, y: bounds.midY)), "text missed a point inside rendered bounds")
        try expect(!text.hitTest(point: NSPoint(x: bounds.maxX + 2, y: bounds.midY)), "text hit outside its rendered width")
        try expect(!text.hitTest(point: NSPoint(x: bounds.midX, y: bounds.minY - 2)), "text hit below its rendered height")

        let imageSize = NSSize(width: 240, height: 120)
        let transparent = makeSolidImage(size: imageSize, color: .clear)
        let rendered = AnnotationRenderer.renderAnnotationsOntoImage(
            baseImage: transparent,
            annotations: [text],
            selectionRect: NSRect(origin: .zero, size: imageSize),
            screenshot: transparent
        )
        let inkBounds = try nonTransparentBounds(in: rendered)
        try expect(!inkBounds.isNull && inkBounds.width > 0 && inkBounds.height > 0, "mixed text did not render visible pixels")
        try expect(inkBounds.minX >= bounds.minX - 1, "text rendered left of its selection bounds: ink=\(inkBounds), layout=\(bounds)")
        try expect(inkBounds.maxX <= bounds.maxX + 1, "text rendered right of its selection bounds: ink=\(inkBounds), layout=\(bounds)")
        try expect(inkBounds.minY >= bounds.minY - 1, "text rendered below its selection bounds: ink=\(inkBounds), layout=\(bounds)")
        try expect(inkBounds.maxY <= bounds.maxY + 1, "text rendered above its selection bounds: ink=\(inkBounds), layout=\(bounds)")
    }

    private static func testTextReEditAndUndoRedo() throws {
        let original = element(.text, from: NSPoint(x: 42, y: 96), to: .zero, strokeWidth: 4)
        original.text = "Re-edit 重编辑\nkeeps layout"
        original.color = .systemOrange

        let firstLayout = AnnotationTextLayout.layout(
            text: original.text,
            fontSize: AnnotationTextLayout.fontSize(forStrokeWidth: original.strokeWidth),
            color: original.color
        )
        let reEditView = NSTextView(frame: NSRect(origin: .zero, size: firstLayout.size))
        AnnotationTextLayout.configure(
            textView: reEditView,
            text: original.text,
            fontSize: AnnotationTextLayout.fontSize(forStrokeWidth: original.strokeWidth),
            color: original.color
        )
        let reEditLayout = AnnotationTextLayout.usedRect(in: reEditView)
        try expect(approximatelyEqual(firstLayout.usedRect, reEditLayout), "re-entering edit mode changed text layout")

        let state = AnnotationState()
        state.elements = [original]
        state.pushUndo()
        original.text = "Changed 已修改\nwith explicit line"
        original.startPoint = NSPoint(x: 60, y: 88)
        original.strokeWidth = 5
        original.color = .systemGreen
        let changedBounds = original.boundingRect

        state.undo()
        guard let undone = state.elements.first else {
            throw AnnotationTestFailure(message: "text undo removed the element")
        }
        try expect(undone.text == "Re-edit 重编辑\nkeeps layout", "text undo did not restore content")
        try expect(undone.startPoint == NSPoint(x: 42, y: 96), "text undo did not restore position")
        try expect(undone.strokeWidth == 4, "text undo did not restore size")
        try expect(undone.color.isEqual(to: NSColor.systemOrange), "text undo did not restore color")

        state.redo()
        guard let redone = state.elements.first else {
            throw AnnotationTestFailure(message: "text redo removed the element")
        }
        try expect(redone.text == "Changed 已修改\nwith explicit line", "text redo did not restore content")
        try expect(redone.startPoint == NSPoint(x: 60, y: 88), "text redo did not restore position")
        try expect(redone.strokeWidth == 5, "text redo did not restore size")
        try expect(redone.color.isEqual(to: NSColor.systemGreen), "text redo did not restore color")
        try expect(approximatelyEqual(redone.boundingRect, changedBounds), "redo changed the committed text bounds")
    }

    private static func element(
        _ tool: AnnotationTool,
        from start: NSPoint,
        to end: NSPoint,
        strokeWidth: CGFloat = 3
    ) -> AnnotationElement {
        AnnotationElement(tool: tool, color: .systemRed, strokeWidth: strokeWidth, startPoint: start, endPoint: end)
    }

    private static func makeSolidImage(size: NSSize, color: NSColor) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        return image
    }

    private static func renderExport(_ element: AnnotationElement, size: NSSize) -> NSImage {
        let transparent = makeSolidImage(size: size, color: .clear)
        return AnnotationRenderer.renderAnnotationsOntoImage(
            baseImage: transparent,
            annotations: [element],
            selectionRect: NSRect(origin: .zero, size: size),
            screenshot: transparent
        )
    }

    private static func renderDirect(_ element: AnnotationElement, size: NSSize, isSelected: Bool) -> NSImage {
        let image = makeSolidImage(size: size, color: .clear)
        image.lockFocus()
        if let context = NSGraphicsContext.current {
            AnnotationRenderer.draw(
                element: element,
                in: context,
                selectionOrigin: .zero,
                isSelected: isSelected,
                screenshot: image,
                selectionRect: NSRect(origin: .zero, size: size)
            )
        }
        image.unlockFocus()
        return image
    }

    private static func color(in image: NSImage, at point: NSPoint) throws -> NSColor {
        guard let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data) else {
            throw AnnotationTestFailure(message: "could not create bitmap for render assertion")
        }
        let pixelX = min(bitmap.pixelsWide - 1, max(0, Int(point.x / image.size.width * CGFloat(bitmap.pixelsWide))))
        let pixelY = min(bitmap.pixelsHigh - 1, max(0, Int(point.y / image.size.height * CGFloat(bitmap.pixelsHigh))))
        guard let sampled = bitmap.colorAt(x: pixelX, y: pixelY)?.usingColorSpace(.deviceRGB) else {
            throw AnnotationTestFailure(message: "could not sample rendered pixel")
        }
        return sampled
    }

    private static func requireGlowStyle(for tool: AnnotationTool, strokeWidth: CGFloat) throws -> AnnotationGlowStyle {
        guard let style = AnnotationGlowStyle.style(for: tool, strokeWidth: strokeWidth) else {
            throw AnnotationTestFailure(message: "missing glow style for \(tool)")
        }
        return style
    }

    private static func colorsMatch(_ lhs: NSColor, _ rhs: NSColor, tolerance: CGFloat) -> Bool {
        abs(lhs.redComponent - rhs.redComponent) <= tolerance &&
        abs(lhs.greenComponent - rhs.greenComponent) <= tolerance &&
        abs(lhs.blueComponent - rhs.blueComponent) <= tolerance &&
        abs(lhs.alphaComponent - rhs.alphaComponent) <= tolerance
    }

    private static func countSelectionBluePixels(in image: NSImage) throws -> Int {
        try countPixels(in: image) { color in
            color.blueComponent > 0.55 && color.blueComponent > color.redComponent * 1.5 && color.alphaComponent > 0.25
        }
    }

    private static func countVisiblePixels(in image: NSImage) throws -> Int {
        try countPixels(in: image) { $0.alphaComponent > 0.01 }
    }

    private static func countPixels(in image: NSImage, matching predicate: (NSColor) -> Bool) throws -> Int {
        guard let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data) else {
            throw AnnotationTestFailure(message: "could not create bitmap for pixel count")
        }

        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), predicate(color) {
                    count += 1
                }
            }
        }
        return count
    }

    private static func nonTransparentBounds(in image: NSImage) throws -> NSRect {
        guard let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data) else {
            throw AnnotationTestFailure(message: "could not create bitmap for alpha-bound assertion")
        }

        var minX = bitmap.pixelsWide
        var minY = bitmap.pixelsHigh
        var maxX = -1
        var maxY = -1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.02 {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return .null }

        let scaleX = image.size.width / CGFloat(bitmap.pixelsWide)
        let scaleY = image.size.height / CGFloat(bitmap.pixelsHigh)
        return NSRect(
            x: CGFloat(minX) * scaleX,
            y: image.size.height - CGFloat(maxY + 1) * scaleY,
            width: CGFloat(maxX - minX + 1) * scaleX,
            height: CGFloat(maxY - minY + 1) * scaleY
        )
    }

    private static func approximatelyEqual(_ lhs: CGFloat, _ rhs: CGFloat, tolerance: CGFloat = 0.01) -> Bool {
        abs(lhs - rhs) <= tolerance
    }

    private static func approximatelyEqual(_ lhs: NSRect, _ rhs: NSRect, tolerance: CGFloat = 0.01) -> Bool {
        approximatelyEqual(lhs.origin.x, rhs.origin.x, tolerance: tolerance) &&
            approximatelyEqual(lhs.origin.y, rhs.origin.y, tolerance: tolerance) &&
            approximatelyEqual(lhs.size.width, rhs.size.width, tolerance: tolerance) &&
            approximatelyEqual(lhs.size.height, rhs.size.height, tolerance: tolerance)
    }

    private static func test(_ name: String, _ body: () throws -> Void) throws {
        do {
            try body()
            testCount += 1
            print("PASS: \(name)")
        } catch {
            throw AnnotationTestFailure(message: "FAIL: \(name): \(error)")
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw AnnotationTestFailure(message: message) }
    }
}
