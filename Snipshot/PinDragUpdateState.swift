let pinDragUpdateIntervalSeconds = 1.0 / 120.0

struct PinDragUpdateState<Position> {
    private var pendingPosition: Position?
    private var updateScheduled = false

    mutating func submit(_ position: Position) -> Bool {
        pendingPosition = position
        guard !updateScheduled else { return false }
        updateScheduled = true
        return true
    }

    mutating func takePending() -> Position? {
        updateScheduled = false
        defer { pendingPosition = nil }
        return pendingPosition
    }

    mutating func cancel() {
        pendingPosition = nil
        updateScheduled = false
    }
}
