import Foundation

private struct TestFailure: Error {
    let message: String
}

private struct TestPosition: Equatable {
    let x: Int
    let y: Int
}

private struct TestPlacement: Equatable {
    let position: TestPosition
    let scale: Double
}

@main
private enum PinRecoveryStateTests {
    private static var testCount = 0

    static func main() throws {
        try test("multiple recoveries are strict LIFO with their own placement") {
            var state = PinRecoveryState<String, TestPlacement>()
            state.recordUnpin("first", placement: placement(10, 20, scale: 0.5))
            state.recordUnpin("second", placement: placement(-300, 40, scale: 1.75))
            state.recordUnpin("third", placement: placement(500, -60, scale: 2.5))
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

            try expect(third?.value == "third" && third?.placement == placement(500, -60, scale: 2.5), "third record was not first out with its placement")
            try expect(second?.value == "second" && second?.placement == placement(-300, 40, scale: 1.75), "second record was not second out with its placement")
            try expect(first?.value == "first" && first?.placement == placement(10, 20, scale: 0.5), "first record was not last out with its placement")
            try expect(fallbackReads == 0, "fallback was read while recovery records remained")
        }

        try test("stack exhaustion falls back centered at default scale") {
            var state = PinRecoveryState<String, TestPlacement>()
            state.recordUnpin("unpinned", placement: placement(20, 30, scale: 2.0))
            _ = state.selectImage { nil }

            let selection = state.selectImage { fallbackRecord() }
            let record = selectedFallbackRecord(of: selection)
            try expect(record?.value == "changed clipboard", "clipboard fallback was not selected")
            try expect(record?.placement == placement(500, 400, scale: 1.0), "clipboard fallback placement changed")
        }

        try test("capacity evicts only the oldest records") {
            var state = PinRecoveryState<String, TestPlacement>(capacity: 3)
            for index in 1...4 {
                state.recordUnpin("image-\(index)", placement: placement(index, -index, scale: Double(index)))
            }

            let values = (0..<3).compactMap { _ in
                recoveredRecord(of: state.selectImage { nil })?.value
            }
            try expect(values == ["image-4", "image-3", "image-2"], "capacity did not evict the oldest record: \(values)")
            try expect(state.selectImage { nil } == nil, "evicted oldest record remained recoverable")
        }

        try test("default capacity is the conservative ten-record limit") {
            try expect(defaultPinRecoveryHistoryCapacity == 10, "default recovery capacity changed")
            var state = PinRecoveryState<String, TestPlacement>()
            for index in 1...11 {
                state.recordUnpin("image-\(index)", placement: placement(index, index, scale: 1.0))
            }

            let values = (0..<10).compactMap { _ in
                recoveredRecord(of: state.selectImage { nil })?.value
            }
            try expect(values.last == "image-2", "default capacity did not evict image-1")
            try expect(state.selectImage { nil } == nil, "default history retained more than ten records")
        }

        try test("a recovered image can be unpinned with its updated placement") {
            var state = PinRecoveryState<String, TestPlacement>()
            state.recordUnpin("image", placement: placement(10, 20, scale: 0.75))
            let recovered = recoveredRecord(of: state.selectImage { nil })
            let updatedPlacement = placement(700, 300, scale: 2.25)
            state.recordUnpin(recovered!.value, placement: updatedPlacement)

            let recoveredAgain = recoveredRecord(of: state.selectImage { nil })
            try expect(recoveredAgain?.value == "image", "re-unpinned image was not recoverable")
            try expect(recoveredAgain?.placement == updatedPlacement, "re-unpin did not use its updated position and scale")
        }

        try test("ordinary new pins do not clear recovery history") {
            var state = PinRecoveryState<String, TestPlacement>()
            state.recordUnpin("first", placement: placement(10, 20, scale: 0.5))
            state.recordUnpin("second", placement: placement(30, 40, scale: 2.0))
            state.recordPin()

            let second = recoveredRecord(of: state.selectImage { nil })
            let first = recoveredRecord(of: state.selectImage { nil })
            try expect(second?.value == "second" && first?.value == "first", "ordinary pin cleared recovery history")
        }

        try test("returns nil when neither recovery nor fallback exists") {
            var state = PinRecoveryState<String, TestPlacement>()
            try expect(state.selectImage { nil } == nil, "empty state unexpectedly selected an image")
        }

        print("PinRecoveryStateTests: \(testCount) tests passed")
    }

    private static func placement(_ x: Int, _ y: Int, scale: Double) -> TestPlacement {
        TestPlacement(position: TestPosition(x: x, y: y), scale: scale)
    }

    private static func fallbackRecord() -> PinRecoveryRecord<String, TestPlacement> {
        PinRecoveryRecord(
            value: "changed clipboard",
            placement: placement(500, 400, scale: 1.0)
        )
    }

    private static func recoveredRecord(
        of selection: PinImageSelection<String, TestPlacement>?
    ) -> PinRecoveryRecord<String, TestPlacement>? {
        if case .recovered(let record) = selection { return record }
        return nil
    }

    private static func selectedFallbackRecord(
        of selection: PinImageSelection<String, TestPlacement>?
    ) -> PinRecoveryRecord<String, TestPlacement>? {
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
