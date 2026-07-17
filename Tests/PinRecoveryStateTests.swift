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
        try test("multiple recoveries are strict LIFO with their own positions") {
            var state = PinRecoveryState<String, TestPosition>()
            state.recordUnpin("first", at: TestPosition(x: 10, y: 20))
            state.recordUnpin("second", at: TestPosition(x: -300, y: 40))
            state.recordUnpin("third", at: TestPosition(x: 500, y: -60))
            var fallbackReads = 0

            let third = recoveredRecord(of: state.selectImage {
                fallbackReads += 1
                return fallbackRecord()
            })
            let second = recoveredRecord(of: state.selectImage {
                fallbackReads += 1
                return fallbackRecord()
            })
            let first = recoveredRecord(of: state.selectImage {
                fallbackReads += 1
                return fallbackRecord()
            })

            try expect(third?.value == "third" && third?.position == TestPosition(x: 500, y: -60), "third record was not first out")
            try expect(second?.value == "second" && second?.position == TestPosition(x: -300, y: 40), "second record was not second out")
            try expect(first?.value == "first" && first?.position == TestPosition(x: 10, y: 20), "first record was not last out")
            try expect(fallbackReads == 0, "fallback was read while recovery records remained")
        }

        try test("stack exhaustion falls back with centered clipboard position") {
            var state = PinRecoveryState<String, TestPosition>()
            state.recordUnpin("unpinned", at: TestPosition(x: 20, y: 30))
            _ = state.selectImage { nil }

            let centered = TestPosition(x: 500, y: 400)
            let selection = state.selectImage {
                PinRecoveryRecord(value: "changed clipboard", position: centered)
            }
            let record = selectedFallbackRecord(of: selection)
            try expect(record?.value == "changed clipboard", "clipboard fallback was not selected")
            try expect(record?.position == centered, "clipboard fallback lost its centered position")
        }

        try test("capacity evicts only the oldest records") {
            var state = PinRecoveryState<String, TestPosition>(capacity: 3)
            for index in 1...4 {
                state.recordUnpin("image-\(index)", at: TestPosition(x: index, y: -index))
            }

            let values = (0..<3).compactMap { _ in
                recoveredRecord(of: state.selectImage { nil })?.value
            }
            try expect(values == ["image-4", "image-3", "image-2"], "capacity did not evict the oldest record: \(values)")
            try expect(state.selectImage { nil } == nil, "evicted oldest record remained recoverable")
        }

        try test("default capacity is the conservative ten-record limit") {
            try expect(defaultPinRecoveryHistoryCapacity == 10, "default recovery capacity changed")
            var state = PinRecoveryState<String, TestPosition>()
            for index in 1...11 {
                state.recordUnpin("image-\(index)", at: TestPosition(x: index, y: index))
            }

            let values = (0..<10).compactMap { _ in
                recoveredRecord(of: state.selectImage { nil })?.value
            }
            try expect(values.last == "image-2", "default capacity did not evict image-1")
            try expect(state.selectImage { nil } == nil, "default history retained more than ten records")
        }

        try test("a recovered image can be unpinned back onto the stack") {
            var state = PinRecoveryState<String, TestPosition>()
            state.recordUnpin("image", at: TestPosition(x: 10, y: 20))
            let recovered = recoveredRecord(of: state.selectImage { nil })
            let newPosition = TestPosition(x: 700, y: 300)
            state.recordUnpin(recovered!.value, at: newPosition)

            let recoveredAgain = recoveredRecord(of: state.selectImage { nil })
            try expect(recoveredAgain?.value == "image", "re-unpinned image was not recoverable")
            try expect(recoveredAgain?.position == newPosition, "re-unpin did not use its new position")
        }

        try test("ordinary new pins do not clear recovery history") {
            var state = PinRecoveryState<String, TestPosition>()
            state.recordUnpin("first", at: TestPosition(x: 10, y: 20))
            state.recordUnpin("second", at: TestPosition(x: 30, y: 40))
            state.recordPin()

            let second = recoveredRecord(of: state.selectImage { nil })
            let first = recoveredRecord(of: state.selectImage { nil })
            try expect(second?.value == "second" && first?.value == "first", "ordinary pin cleared recovery history")
        }

        try test("returns nil when neither recovery nor fallback exists") {
            var state = PinRecoveryState<String, TestPosition>()
            try expect(state.selectImage { nil } == nil, "empty state unexpectedly selected an image")
        }

        print("PinRecoveryStateTests: \(testCount) tests passed")
    }

    private static func fallbackRecord() -> PinRecoveryRecord<String, TestPosition> {
        PinRecoveryRecord(value: "clipboard", position: TestPosition(x: 500, y: 400))
    }

    private static func recoveredRecord(
        of selection: PinImageSelection<String, TestPosition>?
    ) -> PinRecoveryRecord<String, TestPosition>? {
        if case .recovered(let record) = selection { return record }
        return nil
    }

    private static func selectedFallbackRecord(
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
