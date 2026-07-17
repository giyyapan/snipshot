struct PinRecoveryRecord<Value, Position> {
    let value: Value
    let position: Position
}

enum PinImageSelection<Value, Position> {
    case recovered(PinRecoveryRecord<Value, Position>)
    case fallback(PinRecoveryRecord<Value, Position>)
}

struct PinRecoveryState<Value, Position> {
    private var mostRecentUnpinned: PinRecoveryRecord<Value, Position>?

    mutating func recordUnpin(_ value: Value, at position: Position) {
        mostRecentUnpinned = PinRecoveryRecord(value: value, position: position)
    }

    mutating func recordPin() {
        mostRecentUnpinned = nil
    }

    mutating func selectImage(
        fallback: () -> PinRecoveryRecord<Value, Position>?
    ) -> PinImageSelection<Value, Position>? {
        if let recovered = mostRecentUnpinned {
            mostRecentUnpinned = nil
            return .recovered(recovered)
        }

        guard let fallbackValue = fallback() else { return nil }
        return .fallback(fallbackValue)
    }
}
