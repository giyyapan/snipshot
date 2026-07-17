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
