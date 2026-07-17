struct PinRecoveryRecord<Value, Placement> {
    let value: Value
    let placement: Placement
}

enum PinImageSelection<Value, Placement> {
    case recovered(PinRecoveryRecord<Value, Placement>)
    case fallback(PinRecoveryRecord<Value, Placement>)
}

let defaultPinRecoveryHistoryCapacity = 10

struct PinRecoveryState<Value, Placement> {
    private let capacity: Int
    private var unpinnedRecords: [PinRecoveryRecord<Value, Placement>] = []

    init(capacity: Int = defaultPinRecoveryHistoryCapacity) {
        precondition(capacity > 0, "Pin recovery history capacity must be positive")
        self.capacity = capacity
    }

    mutating func recordUnpin(_ value: Value, placement: Placement) {
        unpinnedRecords.append(PinRecoveryRecord(value: value, placement: placement))
        if unpinnedRecords.count > capacity {
            unpinnedRecords.removeFirst(unpinnedRecords.count - capacity)
        }
    }

    // A normal pin is independent of recovery history and must not clear it.
    func recordPin() {}

    mutating func selectImage(
        fallback: () -> PinRecoveryRecord<Value, Placement>?
    ) -> PinImageSelection<Value, Placement>? {
        if let recovered = unpinnedRecords.popLast() {
            return .recovered(recovered)
        }

        guard let fallbackValue = fallback() else { return nil }
        return .fallback(fallbackValue)
    }
}
