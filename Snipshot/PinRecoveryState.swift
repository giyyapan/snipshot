enum PinImageSelection<Value> {
    case recovered(Value)
    case fallback(Value)
}

struct PinRecoveryState<Value> {
    private var mostRecentUnpinned: Value?

    mutating func recordUnpin(_ value: Value) {
        mostRecentUnpinned = value
    }

    mutating func recordPin() {
        mostRecentUnpinned = nil
    }

    mutating func selectImage(fallback: () -> Value?) -> PinImageSelection<Value>? {
        if let recovered = mostRecentUnpinned {
            mostRecentUnpinned = nil
            return .recovered(recovered)
        }

        guard let fallbackValue = fallback() else { return nil }
        return .fallback(fallbackValue)
    }
}
