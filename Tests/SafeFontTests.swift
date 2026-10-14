import Cocoa

private struct TestFailure: Error {
    let message: String
}

/// Simulates an AppKit factory that is imported as nonnull but returns nil at
/// runtime, which is what crashed Snipshot 0.10.0 in drawDimensionLabel.
private final class NilFontSource: NSObject {
    @objc func make() -> NSFont? { nil }
}

@main
private enum SafeFontTests {
    private static var testCount = 0

    static func main() throws {
        try test("nonNil detects a nil font returned through a nonnull signature") {
            let source = NilFontSource()
            let selector = #selector(NilFontSource.make)
            typealias NonnullFactory = @convention(c) (AnyObject, Selector) -> NSFont
            let factory = unsafeBitCast(source.method(for: selector), to: NonnullFactory.self)
            let lyingFont = factory(source, selector)
            try expect(SafeFont.nonNil(lyingFont) == nil, "nil font was not detected")
        }

        try test("nonNil passes a real font through") {
            let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
            try expect(SafeFont.nonNil(font) === font, "real font was rejected")
        }

        try test("fonts match the AppKit factories they replace") {
            let mono = SafeFont.monospacedSystem(ofSize: 11, weight: .medium)
            let expectedMono = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
            try expect(mono.fontName == expectedMono.fontName && mono.pointSize == 11, "monospaced mismatch: \(mono)")

            let bold = SafeFont.system(ofSize: 12, weight: .bold)
            let expectedBold = NSFont.systemFont(ofSize: 12, weight: .bold)
            try expect(bold.fontName == expectedBold.fontName && bold.pointSize == 12, "bold mismatch: \(bold)")

            let plain = SafeFont.system(ofSize: 13)
            let expectedPlain = NSFont.systemFont(ofSize: 13)
            try expect(plain.fontName == expectedPlain.fontName && plain.pointSize == 13, "default weight mismatch: \(plain)")
        }

        try test("fonts are cached per design, size and weight") {
            let a = SafeFont.monospacedSystem(ofSize: 11, weight: .medium)
            let b = SafeFont.monospacedSystem(ofSize: 11, weight: .medium)
            try expect(a === b, "same key returned different instances")
            let c = SafeFont.monospacedSystem(ofSize: 11, weight: .regular)
            try expect(c.pointSize == 11, "different weight returned wrong size")
            let d = SafeFont.system(ofSize: 11, weight: .medium)
            try expect(!(a === d), "system and monospaced share a cache entry")
        }

        try test("dimension label attributes measure without throwing") {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: SafeFont.monospacedSystem(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
            let size = ("2560 \u{00D7} 1440" as NSString).size(withAttributes: attrs)
            try expect(size.width > 0 && size.height > 0, "unexpected size \(size)")
        }

        print("SafeFontTests: \(testCount) tests passed")
    }

    private static func test(_ name: String, _ body: () throws -> Void) throws {
        testCount += 1
        do {
            try body()
        } catch let failure as TestFailure {
            print("FAIL: \(name): \(failure.message)")
            exit(1)
        }
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw TestFailure(message: message) }
    }
}
