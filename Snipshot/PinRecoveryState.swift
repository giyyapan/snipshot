import Foundation

struct PinRecoveryRecord<Value, Placement> {
    let value: Value
    let placement: Placement
}

enum PinImageSelection<Value, Placement> {
    case recovered(PinRecoveryRecord<Value, Placement>)
    case fallback(PinRecoveryRecord<Value, Placement>)
}

let defaultPinRecoveryHistoryCapacity = 10
let defaultPinRecoveryExpirationInterval: TimeInterval = 5 * 60

struct PinRecoveryState<Value, Placement> {
    private let capacity: Int
    private let expirationInterval: TimeInterval
    private let now: () -> TimeInterval
    private var unpinnedRecords: [ExpiringRecord] = []

    private struct ExpiringRecord {
        let record: PinRecoveryRecord<Value, Placement>
        let expiresAt: TimeInterval
    }

    init(
        capacity: Int = defaultPinRecoveryHistoryCapacity,
        expirationInterval: TimeInterval = defaultPinRecoveryExpirationInterval,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        precondition(capacity > 0, "Pin recovery history capacity must be positive")
        precondition(expirationInterval > 0, "Pin recovery expiration interval must be positive")
        self.capacity = capacity
        self.expirationInterval = expirationInterval
        self.now = now
    }

    mutating func recordUnpin(_ value: Value, placement: Placement) {
        let currentTime = now()
        removeExpired(at: currentTime)
        unpinnedRecords.append(ExpiringRecord(
            record: PinRecoveryRecord(value: value, placement: placement),
            expiresAt: currentTime + expirationInterval
        ))
        if unpinnedRecords.count > capacity {
            unpinnedRecords.removeFirst(unpinnedRecords.count - capacity)
        }
    }

    // A normal pin is independent of recovery history and must not clear it.
    func recordPin() {}

    mutating func selectImage(
        fallback: () -> PinRecoveryRecord<Value, Placement>?
    ) -> PinImageSelection<Value, Placement>? {
        removeExpired(at: now())
        if let recovered = unpinnedRecords.popLast() {
            return .recovered(recovered.record)
        }

        guard let fallbackValue = fallback() else { return nil }
        return .fallback(fallbackValue)
    }

    private mutating func removeExpired(at currentTime: TimeInterval) {
        unpinnedRecords.removeAll { $0.expiresAt <= currentTime }
    }
}
