struct PinRecoveryRecord<Value, Position> {
    let value: Value
    let position: Position
}

enum PinImageSelection<Value, Position> {
    case recovered(PinRecoveryRecord<Value, Position>)
    case fallback(PinRecoveryRecord<Value, Position>)
}

let defaultPinRecoveryHistoryCapacity = 10

struct PinRecoveryState<Value, Position> {
    private let capacity: Int
    private var unpinnedRecords: [PinRecoveryRecord<Value, Position>] = []

    init(capacity: Int = defaultPinRecoveryHistoryCapacity) {
        precondition(capacity > 0, "Pin recovery history capacity must be positive")
        self.capacity = capacity
    }

    mutating func recordUnpin(_ value: Value, at position: Position) {
        unpinnedRecords.append(PinRecoveryRecord(value: value, position: position))
        if unpinnedRecords.count > capacity {
            unpinnedRecords.removeFirst(unpinnedRecords.count - capacity)
        }
    }

    // A normal pin is independent of recovery history and must not clear it.
    func recordPin() {}

    mutating func selectImage(
        fallback: () -> PinRecoveryRecord<Value, Position>?
    ) -> PinImageSelection<Value, Position>? {
        if let recovered = unpinnedRecords.popLast() {
            return .recovered(recovered)
        }

        guard let fallbackValue = fallback() else { return nil }
        return .fallback(fallbackValue)
    }
}
