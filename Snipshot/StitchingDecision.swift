import Foundation

enum StitchScrollDirection: String, Equatable {
    case unknown
    case down
    case up
}

struct StitchMatchPolicy: Equatable {
    var minimumVerticalOffset = 2
    var maximumHorizontalOffset = 2.0
    var minimumOverlapRatio = 0.25
    var maximumResidual = 0.16
    var minimumUniquenessGap = 0.008
}

struct StitchMatchMeasurement: Equatable {
    let horizontalOffset: Double
    let verticalDelta: Double
    let overlapRatio: Double
    let residual: Double
    let secondBestResidual: Double?
    let previousSize: (width: Int, height: Int)
    let currentSize: (width: Int, height: Int)

    static func == (lhs: StitchMatchMeasurement, rhs: StitchMatchMeasurement) -> Bool {
        lhs.horizontalOffset == rhs.horizontalOffset &&
        lhs.verticalDelta == rhs.verticalDelta &&
        lhs.overlapRatio == rhs.overlapRatio &&
        lhs.residual == rhs.residual &&
        lhs.secondBestResidual == rhs.secondBestResidual &&
        lhs.previousSize.width == rhs.previousSize.width &&
        lhs.previousSize.height == rhs.previousSize.height &&
        lhs.currentSize.width == rhs.currentSize.width &&
        lhs.currentSize.height == rhs.currentSize.height
    }
}

enum StitchMatchRejection: String, Equatable {
    case nonFiniteMeasurement = "non_finite"
    case frameGeometryChanged = "frame_geometry_changed"
    case horizontalMovement = "horizontal_movement"
    case insufficientOverlap = "insufficient_overlap"
    case highResidual = "high_residual"
    case ambiguousMatch = "ambiguous_match"
}

enum StitchMatchValidation: Equatable {
    case accepted(pixelDelta: Int)
    case ignoredSmallMovement
    case rejected(StitchMatchRejection)
}

struct StitchMatchValidator {
    let policy: StitchMatchPolicy

    init(policy: StitchMatchPolicy = StitchMatchPolicy()) {
        self.policy = policy
    }

    func validate(_ measurement: StitchMatchMeasurement) -> StitchMatchValidation {
        let values = [
            measurement.horizontalOffset,
            measurement.verticalDelta,
            measurement.overlapRatio,
            measurement.residual,
            measurement.secondBestResidual ?? 0,
        ]
        guard values.allSatisfy(\.isFinite) else {
            return .rejected(.nonFiniteMeasurement)
        }
        guard measurement.previousSize == measurement.currentSize else {
            return .rejected(.frameGeometryChanged)
        }
        guard abs(measurement.horizontalOffset) <= policy.maximumHorizontalOffset else {
            return .rejected(.horizontalMovement)
        }
        guard measurement.overlapRatio >= policy.minimumOverlapRatio else {
            return .rejected(.insufficientOverlap)
        }
        guard measurement.residual <= policy.maximumResidual else {
            return .rejected(.highResidual)
        }
        if let secondBest = measurement.secondBestResidual,
           secondBest - measurement.residual < policy.minimumUniquenessGap {
            return .rejected(.ambiguousMatch)
        }

        // Vision offsets can be fractional on Retina displays. All state and crop
        // boundaries use one consistently rounded backing-pixel value.
        let pixelDelta = Int(measurement.verticalDelta.rounded())
        guard abs(pixelDelta) > policy.minimumVerticalOffset else {
            return .ignoredSmallMovement
        }
        return .accepted(pixelDelta: pixelDelta)
    }
}

enum StitchPositionAction: Equatable {
    case none
    case append(pixelHeight: Int)
    case crop(position: Int)
}

struct StitchPositionUpdate: Equatable {
    let action: StitchPositionAction
    let lockedDirection: StitchScrollDirection?
}

/// Pure state machine for turning trusted, integer frame deltas into append/crop actions.
/// Uncommitted movement is retained while direction or a reversal is being confirmed.
struct StitchPositionTracker {
    private(set) var direction: StitchScrollDirection = .unknown
    private(set) var position = 0
    private(set) var peakPosition = 0
    private(set) var pendingDelta = 0
    private(set) var reverseEvidenceCount = 0

    let lockThreshold: Int
    let reverseConfirmationCount: Int

    init(lockThreshold: Int = 5, reverseConfirmationCount: Int = 2) {
        self.lockThreshold = lockThreshold
        self.reverseConfirmationCount = reverseConfirmationCount
    }

    mutating func consume(pixelDelta: Int) -> StitchPositionUpdate {
        guard pixelDelta != 0 else {
            return StitchPositionUpdate(action: .none, lockedDirection: nil)
        }

        if direction == .unknown {
            pendingDelta += pixelDelta
            guard abs(pendingDelta) >= lockThreshold else {
                return StitchPositionUpdate(action: .none, lockedDirection: nil)
            }

            direction = pendingDelta > 0 ? .down : .up
            let initialMovement = abs(pendingDelta)
            pendingDelta = 0
            position = initialMovement
            peakPosition = initialMovement
            return StitchPositionUpdate(
                action: .append(pixelHeight: initialMovement),
                lockedDirection: direction
            )
        }

        let forwardDelta = direction == .down ? pixelDelta : -pixelDelta
        pendingDelta += forwardDelta

        if forwardDelta < 0 {
            reverseEvidenceCount += 1
            guard reverseEvidenceCount >= reverseConfirmationCount else {
                return StitchPositionUpdate(action: .none, lockedDirection: nil)
            }
        } else {
            reverseEvidenceCount = 0
            if pendingDelta < 0 {
                // Forward motion has not yet cancelled the uncommitted reversal.
                return StitchPositionUpdate(action: .none, lockedDirection: nil)
            }
        }

        let committedDelta = pendingDelta
        pendingDelta = 0
        reverseEvidenceCount = 0
        guard committedDelta != 0 else {
            return StitchPositionUpdate(action: .none, lockedDirection: nil)
        }

        let previousPosition = position
        position = max(0, position + committedDelta)

        if position > peakPosition {
            let growth = position - peakPosition
            peakPosition = position
            return StitchPositionUpdate(action: .append(pixelHeight: growth), lockedDirection: nil)
        }

        if position < previousPosition {
            peakPosition = position
            return StitchPositionUpdate(action: .crop(position: position), lockedDirection: nil)
        }

        return StitchPositionUpdate(action: .none, lockedDirection: nil)
    }
}

/// Small wrapper that gives callers an explicit FIFO drain operation. Enqueuing the
/// drain callback after all frame work guarantees that completion observes the final state.
final class StitchSerialDrainQueue {
    private let queue: DispatchQueue

    init(label: String, qos: DispatchQoS = .userInitiated) {
        queue = DispatchQueue(label: label, qos: qos)
    }

    func enqueue(_ work: @escaping () -> Void) {
        queue.async(execute: work)
    }

    func drain(_ completion: @escaping () -> Void) {
        queue.async(execute: completion)
    }
}
