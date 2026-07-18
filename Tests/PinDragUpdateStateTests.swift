import Foundation

private struct TestFailure: Error {
    let message: String
}

@main
private enum PinDragUpdateStateTests {
    private static var testCount = 0

    static func main() throws {
        try test("high-frequency positions coalesce to the latest update") {
            var state = PinDragUpdateState<Int>()
            try expect(state.submit(1), "first update did not request scheduling")
            try expect(!state.submit(2), "second update scheduled duplicate work")
            try expect(!state.submit(3), "third update scheduled duplicate work")
            try expect(state.takePending() == 3, "latest pending position was not retained")
        }

        try test("a flushed update allows the next display-cycle schedule") {
            var state = PinDragUpdateState<Int>()
            _ = state.submit(1)
            _ = state.takePending()
            try expect(state.submit(2), "next update was not scheduled after flush")
            try expect(state.takePending() == 2, "next position was not retained")
        }

        try test("cancel discards pending drag work") {
            var state = PinDragUpdateState<Int>()
            _ = state.submit(1)
            state.cancel()
            try expect(state.takePending() == nil, "cancelled position was still applied")
            try expect(state.submit(2), "cancel did not reset scheduling state")
        }

        try test("drag update interval targets 120Hz") {
            try expect(abs(pinDragUpdateIntervalSeconds - (1.0 / 120.0)) < 0.000_001, "drag interval changed")
        }

        print("PinDragUpdateStateTests: \(testCount) tests passed")
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
