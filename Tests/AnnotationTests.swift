import Cocoa

private struct AnnotationTestFailure: Error {
    let message: String
}

@main
private enum AnnotationTests {
    private static var testCount = 0

    static func main() throws {
        try test("toolbar groups stay compact and cycle deterministically", testToolGroupsAndCycling)
        try test("line geometry uses segment hit testing and endpoint handles", testLineGeometry)
        try test("circle geometry only hits the ellipse border", testCircleGeometry)
        try test("circle and highlight resize from four corners", testBoxResizeHandles)
        try test("new elements participate in move, duplicate, undo, and redo", testStateOperations)
        try test("line and circle render as unfilled strokes", testLineAndCircleRendering)
        try test("highlight renders a stronger outside dim and lighter focus", testHighlightRendering)
        try test("glow style is shared, scoped, and scales with stroke width", testGlowStyleAndBounds)
        try test("all four vector tools render a restrained edge glow", testVectorGlowRendering)
        try test("glow preserves the sharp vector body color and alpha", testGlowPreservesBodyColorAndAlpha)
        try test("overlay and export share rendering without exporting selection UI", testOverlayAndExportRendering)
        try test("vector glow clips safely at screenshot edges", testGlowAtScreenshotEdges)

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

        let state = AnnotationState()
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
        let vectorTools: [AnnotationTool] = [.arrow, .line, .rectangle, .circle]
        for tool in vectorTools {
            try expect(AnnotationGlowStyle.style(for: tool, strokeWidth: 3) != nil, "\(tool) did not opt into the shared glow style")
        }

        for tool in [AnnotationTool.select, .text, .marker, .mosaic, .highlight] {
            try expect(AnnotationGlowStyle.style(for: tool, strokeWidth: 3) == nil, "\(tool) unexpectedly opted into vector glow")
        }

        let thin = try requireGlowStyle(for: .line, strokeWidth: 1)
        let thick = try requireGlowStyle(for: .line, strokeWidth: 12)
        try expect(thick.blurRadius > thin.blurRadius, "glow radius did not scale with stroke width")
        try expect(thick.opacity > thin.opacity, "glow intensity did not scale with stroke width")
        try expect(thick.opacity <= 0.40, "glow opacity is no longer restrained")

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

        let mosaic = element(.mosaic, from: NSPoint(x: 20, y: 20), to: NSPoint(x: 80, y: 60), strokeWidth: 4)
        try expect(mosaic.boundingRect == mosaic.normalizedRect.insetBy(dx: -4, dy: -4), "non-glowing Mosaic bounds changed")
    }

    private static func testVectorGlowRendering() throws {
        let size = NSSize(width: 120, height: 100)
        let samples: [(AnnotationTool, NSPoint, NSPoint, NSPoint, NSPoint)] = [
            (.arrow, NSPoint(x: 25, y: 50), NSPoint(x: 95, y: 50), NSPoint(x: 55, y: 50), NSPoint(x: 55, y: 54)),
            (.line, NSPoint(x: 25, y: 50), NSPoint(x: 95, y: 50), NSPoint(x: 55, y: 50), NSPoint(x: 55, y: 54)),
            (.rectangle, NSPoint(x: 25, y: 20), NSPoint(x: 95, y: 80), NSPoint(x: 55, y: 20), NSPoint(x: 55, y: 16)),
            (.circle, NSPoint(x: 25, y: 20), NSPoint(x: 95, y: 80), NSPoint(x: 60, y: 80), NSPoint(x: 60, y: 84))
        ]

        for (tool, start, end, bodyPoint, glowPoint) in samples {
            let annotation = element(tool, from: start, to: end, strokeWidth: 4)
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
