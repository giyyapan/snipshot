import Foundation

private struct TestFailure: Error {
    let message: String
}

@main
private enum StitchingDecisionTests {
    private static var testCount = 0

    static func main() throws {
        try test("normal match is accepted") {
            let result = StitchMatchValidator().validate(measurement(verticalDelta: 24, residual: 0.03))
            try expect(result == .accepted(pixelDelta: 24), "unexpected validation: \(result)")
        }

        try test("low-confidence and ambiguous matches are rejected") {
            let validator = StitchMatchValidator()
            try expect(
                validator.validate(measurement(verticalDelta: 20, residual: 0.3)) == .rejected(.highResidual),
                "high residual was accepted"
            )
            try expect(
                validator.validate(measurement(verticalDelta: 20, residual: 0.04, secondBest: 0.045)) == .rejected(.ambiguousMatch),
                "ambiguous match was accepted"
            )
            try expect(
                validator.validate(measurement(verticalDelta: 800, overlap: 0.2)) == .rejected(.insufficientOverlap),
                "low-overlap match was accepted"
            )
            try expect(
                validator.validate(measurement(horizontalOffset: 3, verticalDelta: 20)) == .rejected(.horizontalMovement),
                "horizontal movement was accepted"
            )
            try expect(
                validator.validate(measurement(verticalDelta: 20, currentSize: (1000, 801))) == .rejected(.frameGeometryChanged),
                "geometry change was accepted"
            )
        }

        try test("small movement is ignored") {
            let validator = StitchMatchValidator()
            try expect(
                validator.validate(measurement(verticalDelta: 2.4)) == .ignoredSmallMovement,
                "small movement should not change position"
            )
        }

        try test("fractional Retina offsets use deterministic integer pixels") {
            let validator = StitchMatchValidator()
            try expect(
                validator.validate(measurement(verticalDelta: 10.49)) == .accepted(pixelDelta: 10),
                "10.49 should round to 10"
            )
            try expect(
                validator.validate(measurement(verticalDelta: 10.51)) == .accepted(pixelDelta: 11),
                "10.51 should round to 11"
            )
            try expect(
                validator.validate(measurement(verticalDelta: -10.51)) == .accepted(pixelDelta: -11),
                "negative Retina offset rounded inconsistently"
            )
        }

        try test("direction lock commits all pre-lock movement") {
            var tracker = StitchPositionTracker(lockThreshold: 5)
            try expect(tracker.consume(pixelDelta: 3).action == .none, "locked too early")
            let update = tracker.consume(pixelDelta: 4)
            try expect(update.lockedDirection == .down, "direction did not lock down")
            try expect(update.action == .append(pixelHeight: 7), "pre-lock pixels were lost: \(update)")
            try expect(tracker.position == 7 && tracker.peakPosition == 7, "position was not initialized from all movement")
        }

        try test("upward direction lock and forward growth are symmetric") {
            var tracker = StitchPositionTracker(lockThreshold: 5)
            _ = tracker.consume(pixelDelta: -3)
            let locked = tracker.consume(pixelDelta: -3)
            try expect(locked.lockedDirection == .up, "direction did not lock up")
            try expect(locked.action == .append(pixelHeight: 6), "upward initial append is wrong")
            try expect(tracker.consume(pixelDelta: -8).action == .append(pixelHeight: 8), "upward growth is wrong")
        }

        try test("single reverse match cannot destructively crop") {
            var tracker = StitchPositionTracker(lockThreshold: 5, reverseConfirmationCount: 2)
            _ = tracker.consume(pixelDelta: 6)
            _ = tracker.consume(pixelDelta: 20)
            let firstReverse = tracker.consume(pixelDelta: -5)
            try expect(firstReverse.action == .none, "single reverse frame cropped the image")
            try expect(tracker.position == 26, "unconfirmed reverse changed committed position")
            let confirmed = tracker.consume(pixelDelta: -7)
            try expect(confirmed.action == .crop(position: 14), "confirmed reverse did not include both deltas")
        }

        try test("forward motion cancels an unconfirmed reversal without duplication") {
            var tracker = StitchPositionTracker(lockThreshold: 5, reverseConfirmationCount: 2)
            _ = tracker.consume(pixelDelta: 6)
            _ = tracker.consume(pixelDelta: 10)
            _ = tracker.consume(pixelDelta: -4)
            let update = tracker.consume(pixelDelta: 9)
            try expect(update.action == .append(pixelHeight: 5), "net forward movement should append only 5px: \(update)")
            try expect(tracker.position == 21, "position did not use net pending movement")
        }

        try test("FIFO drain runs after previously enqueued frame work") {
            let queue = StitchSerialDrainQueue(label: "test.stitch.drain")
            let lock = NSLock()
            var order: [Int] = []
            let drained = DispatchSemaphore(value: 0)

            for value in 1...4 {
                queue.enqueue {
                    lock.lock()
                    order.append(value)
                    lock.unlock()
                }
            }
            queue.drain {
                lock.lock()
                order.append(5)
                lock.unlock()
                drained.signal()
            }

            try expect(drained.wait(timeout: .now() + 2) == .success, "drain timed out")
            lock.lock()
            let result = order
            lock.unlock()
            try expect(result == [1, 2, 3, 4, 5], "drain completed out of order: \(result)")
        }

        print("StitchingDecisionTests: \(testCount) tests passed")
    }

    private static func measurement(
        horizontalOffset: Double = 0,
        verticalDelta: Double,
        overlap: Double = 0.75,
        residual: Double = 0.03,
        secondBest: Double? = 0.08,
        previousSize: (Int, Int) = (1000, 800),
        currentSize: (Int, Int) = (1000, 800)
    ) -> StitchMatchMeasurement {
        StitchMatchMeasurement(
            horizontalOffset: horizontalOffset,
            verticalDelta: verticalDelta,
            overlapRatio: overlap,
            residual: residual,
            secondBestResidual: secondBest,
            previousSize: (previousSize.0, previousSize.1),
            currentSize: (currentSize.0, currentSize.1)
        )
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
