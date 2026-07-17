import Foundation

private struct TestFailure: Error {
    let message: String
}

@main
private enum PinFocusFallbackTests {
    private static var testCount = 0

    static func main() throws {
        try test("three pins fall back from front to back") {
            let firstOrder = snapshots(["pin-3", "pin-2", "pin-1"])
            try expect(candidate(in: firstOrder, closing: "pin-3") == "pin-2", "pin-3 did not focus pin-2")

            let secondOrder = snapshots(["pin-2", "pin-1"])
            try expect(candidate(in: secondOrder, closing: "pin-2") == "pin-1", "pin-2 did not focus pin-1")

            let finalOrder = snapshots(["pin-1"])
            try expect(candidate(in: finalOrder, closing: "pin-1") == nil, "last pin found a focus candidate")
        }

        try test("closing the penultimate pin prefers the pin behind it") {
            let ordered = snapshots(["front", "closing", "behind"])
            try expect(candidate(in: ordered, closing: "closing") == "behind", "front pin was chosen before the pin behind")
        }

        try test("current z-order determines fallback") {
            let firstOrder = snapshots(["pin-1", "pin-3", "pin-2"])
            try expect(candidate(in: firstOrder, closing: "pin-1") == "pin-3", "first z-order was ignored")

            let reordered = snapshots(["pin-1", "pin-2", "pin-3"])
            try expect(candidate(in: reordered, closing: "pin-1") == "pin-2", "changed z-order was ignored")
        }

        try test("invisible and unmanaged windows are skipped") {
            let ordered = [
                snapshot("closing"),
                snapshot("closed-pin", visible: false),
                snapshot("settings", managed: false),
                snapshot("next-pin")
            ]
            try expect(candidate(in: ordered, closing: "closing") == "next-pin", "ineligible window interfered with fallback")
        }

        try test("frontmost eligible pin is used when none are behind") {
            let ordered = snapshots(["frontmost", "middle", "closing"])
            try expect(candidate(in: ordered, closing: "closing") == "frontmost", "frontmost remaining pin was not selected")
        }

        try test("missing closing window safely selects the frontmost eligible pin") {
            let ordered = [snapshot("settings", managed: false), snapshot("pin")]
            try expect(candidate(in: ordered, closing: "missing") == "pin", "missing closing window was not handled")
        }

        try test("no eligible candidate returns nil") {
            let ordered = [
                snapshot("closing"),
                snapshot("hidden", visible: false),
                snapshot("overlay", managed: false)
            ]
            try expect(candidate(in: ordered, closing: "closing") == nil, "ineligible window was selected")
        }

        print("PinFocusFallbackTests: \(testCount) tests passed")
    }

    private static func snapshots(_ ids: [String]) -> [PinFocusWindowSnapshot<String>] {
        ids.map { snapshot($0) }
    }

    private static func snapshot(
        _ id: String,
        managed: Bool = true,
        visible: Bool = true
    ) -> PinFocusWindowSnapshot<String> {
        PinFocusWindowSnapshot(id: id, isManagedPin: managed, isVisible: visible)
    }

    private static func candidate(
        in ordered: [PinFocusWindowSnapshot<String>],
        closing: String
    ) -> String? {
        PinFocusFallback.nextCandidate(in: ordered, closingID: closing)
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
