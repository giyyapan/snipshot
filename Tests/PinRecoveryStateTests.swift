import Foundation

private struct TestFailure: Error {
    let message: String
}

private struct TestPosition: Equatable {
    let x: Int
    let y: Int
}

@main
private enum PinRecoveryStateTests {
    private static var testCount = 0

    static func main() throws {
        try test("fallback keeps its centered position") {
            var state = PinRecoveryState<String, TestPosition>()
            let centered = TestPosition(x: 500, y: 400)
            let selection = state.selectImage {
                PinRecoveryRecord(value: "clipboard", position: centered)
            }

            let record = fallbackRecord(of: selection)
            try expect(record?.value == "clipboard", "clipboard fallback was not selected")
            try expect(record?.position == centered, "fallback centered position changed")
        }

        try test("recovery binds unpinned image and position without reading fallback") {
            var state = PinRecoveryState<String, TestPosition>()
            let unpinnedPosition = TestPosition(x: -1200, y: 275)
            state.recordUnpin("unpinned", at: unpinnedPosition)
            var fallbackRead = false

            let selection = state.selectImage {
                fallbackRead = true
                return PinRecoveryRecord(
                    value: "changed clipboard",
                    position: TestPosition(x: 500, y: 400)
                )
            }

            let record = recoveredRecord(of: selection)
            try expect(record?.value == "unpinned", "unpinned image was not restored")
            try expect(record?.position == unpinnedPosition, "unpinned position was not restored")
            try expect(!fallbackRead, "fallback was read despite available recovery")
        }

        try test("recovery is consumed before the next fallback") {
            var state = PinRecoveryState<String, TestPosition>()
            state.recordUnpin("unpinned", at: TestPosition(x: 20, y: 30))
            _ = state.selectImage { nil }

            let centered = TestPosition(x: 500, y: 400)
            let selection = state.selectImage {
                PinRecoveryRecord(value: "current clipboard", position: centered)
            }
            let record = fallbackRecord(of: selection)
            try expect(record?.value == "current clipboard", "consumed recovery was reused")
            try expect(record?.position == centered, "fallback did not retain centered position")
        }

        try test("latest unpin atomically replaces image and position") {
            var state = PinRecoveryState<String, TestPosition>()
            state.recordUnpin("first", at: TestPosition(x: 10, y: 20))
            let latestPosition = TestPosition(x: 300, y: -40)
            state.recordUnpin("second", at: latestPosition)

            let record = recoveredRecord(of: state.selectImage { nil })
            try expect(record?.value == "second", "latest unpinned image was not selected")
            try expect(record?.position == latestPosition, "position did not come from latest unpin")
        }

        try test("pinning a new image clears stale recovery record") {
            var state = PinRecoveryState<String, TestPosition>()
            state.recordUnpin("stale", at: TestPosition(x: 10, y: 20))
            state.recordPin()

            let centered = TestPosition(x: 500, y: 400)
            let selection = state.selectImage {
                PinRecoveryRecord(value: "clipboard", position: centered)
            }
            try expect(fallbackRecord(of: selection)?.position == centered, "stale recovery survived a new pin")
        }

        try test("returns nil when neither recovery nor fallback exists") {
            var state = PinRecoveryState<String, TestPosition>()
            try expect(state.selectImage { nil } == nil, "empty state unexpectedly selected an image")
        }

        print("PinRecoveryStateTests: \(testCount) tests passed")
    }

    private static func recoveredRecord(
        of selection: PinImageSelection<String, TestPosition>?
    ) -> PinRecoveryRecord<String, TestPosition>? {
        if case .recovered(let record) = selection { return record }
        return nil
    }

    private static func fallbackRecord(
        of selection: PinImageSelection<String, TestPosition>?
    ) -> PinRecoveryRecord<String, TestPosition>? {
        if case .fallback(let record) = selection { return record }
        return nil
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
