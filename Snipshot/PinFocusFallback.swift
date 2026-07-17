struct PinFocusWindowSnapshot<ID: Equatable> {
    let id: ID
    let isManagedPin: Bool
    let isVisible: Bool
}

enum PinFocusFallback {
    static func nextCandidate<ID: Equatable>(
        in orderedWindows: [PinFocusWindowSnapshot<ID>],
        closingID: ID
    ) -> ID? {
        func isEligible(_ window: PinFocusWindowSnapshot<ID>) -> Bool {
            window.id != closingID && window.isManagedPin && window.isVisible
        }

        guard let closingIndex = orderedWindows.firstIndex(where: { $0.id == closingID }) else {
            return orderedWindows.first(where: isEligible)?.id
        }

        if let behind = orderedWindows[(closingIndex + 1)...].first(where: isEligible) {
            return behind.id
        }

        return orderedWindows[..<closingIndex].first(where: isEligible)?.id
    }
}
