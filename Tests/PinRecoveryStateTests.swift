import Foundation

private struct TestFailure: Error {
    let message: String
}

@main
private enum PinRecoveryStateTests {
    private static var testCount = 0

    static func main() throws {
        try test("falls back when there is no unpin history") {
            var state = PinRecoveryState<String>()
            let selection = state.selectImage { "clipboard" }
            try expect(value(of: selection) == "clipboard", "clipboard fallback was not selected")
            try expect(isFallback(selection), "selection source was not fallback")
        }

        try test("prefers unpinned image without reading clipboard") {
            var state = PinRecoveryState<String>()
            state.recordUnpin("unpinned")
            var fallbackRead = false

            let selection = state.selectImage {
                fallbackRead = true
                return "clipboard"
            }

            try expect(value(of: selection) == "unpinned", "unpinned image was not restored")
            try expect(isRecovered(selection), "selection source was not recovered")
            try expect(!fallbackRead, "clipboard was read despite available unpin history")
        }

        try test("restored image is consumed") {
            var state = PinRecoveryState<String>()
            state.recordUnpin("unpinned")
            _ = state.selectImage { "first clipboard" }

            let selection = state.selectImage { "current clipboard" }
            try expect(value(of: selection) == "current clipboard", "consumed recovery candidate was reused")
            try expect(isFallback(selection), "second selection did not fall back")
        }

        try test("latest unpin replaces earlier history") {
            var state = PinRecoveryState<String>()
            state.recordUnpin("first")
            state.recordUnpin("second")

            let selection = state.selectImage { "clipboard" }
            try expect(value(of: selection) == "second", "latest unpinned image was not selected")
        }

        try test("pinning a new image clears stale unpin history") {
            var state = PinRecoveryState<String>()
            state.recordUnpin("stale")
            state.recordPin()

            let selection = state.selectImage { "clipboard" }
            try expect(value(of: selection) == "clipboard", "stale unpin history survived a new pin")
            try expect(isFallback(selection), "selection did not fall back after a new pin")
        }

        try test("returns nil when neither recovery nor fallback exists") {
            var state = PinRecoveryState<String>()
            try expect(state.selectImage { nil } == nil, "empty state unexpectedly selected an image")
        }

        print("PinRecoveryStateTests: \(testCount) tests passed")
    }

    private static func value(of selection: PinImageSelection<String>?) -> String? {
        switch selection {
        case .recovered(let value), .fallback(let value): return value
        case nil: return nil
        }
    }

    private static func isRecovered(_ selection: PinImageSelection<String>?) -> Bool {
        if case .recovered = selection { return true }
        return false
    }

    private static func isFallback(_ selection: PinImageSelection<String>?) -> Bool {
        if case .fallback = selection { return true }
        return false
    }

    private static func test(_ name: String, _ body: () throws -> Void) throws {
        do {
            try body()
            testCount += 1
            print("PASS: \(name)")
        } catch {
            throw TestFailure(message: "FAIL: \(name): \(error)")
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw TestFailure(message: message) }
    }
}
