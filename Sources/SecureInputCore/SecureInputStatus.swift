import Foundation

public struct SecureInputSnapshot: Equatable, Sendable {
    public let isSecureInputEnabled: Bool
    public let isAccessibilityTrusted: Bool
    public let isShortcutListenerAvailable: Bool
    public let reportedPID: Int32?
    public let reportedApplicationName: String?

    public init(
        isSecureInputEnabled: Bool,
        isAccessibilityTrusted: Bool,
        isShortcutListenerAvailable: Bool,
        reportedPID: Int32? = nil,
        reportedApplicationName: String? = nil
    ) {
        self.isSecureInputEnabled = isSecureInputEnabled
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.isShortcutListenerAvailable = isShortcutListenerAvailable
        self.reportedPID = reportedPID
        self.reportedApplicationName = reportedApplicationName
    }
}

public enum GlobalShortcutHealth: Equatable, Sendable {
    case ready
    case blockedBySecureInput
    case accessibilityRequired
    case shortcutListenerUnavailable
}

public struct SecureInputMenuPresentation: Equatable, Sendable {
    public let shortcutStatusTitle: String
    public let secureInputStatusTitle: String
    public let fixTitle: String
    public let isFixEnabled: Bool

    public init(snapshot: SecureInputSnapshot) {
        let health: GlobalShortcutHealth
        if snapshot.isSecureInputEnabled {
            health = .blockedBySecureInput
        } else if !snapshot.isAccessibilityTrusted {
            health = .accessibilityRequired
        } else if !snapshot.isShortcutListenerAvailable {
            health = .shortcutListenerUnavailable
        } else {
            health = .ready
        }

        switch health {
        case .ready:
            shortcutStatusTitle = "Global Shortcuts: Ready"
        case .blockedBySecureInput:
            shortcutStatusTitle = "Global Shortcuts: Blocked"
        case .accessibilityRequired:
            shortcutStatusTitle = "Global Shortcuts: Accessibility Required"
        case .shortcutListenerUnavailable:
            shortcutStatusTitle = "Global Shortcuts: Listener Unavailable"
        }

        if snapshot.isSecureInputEnabled {
            var hintParts: [String] = []
            if let name = snapshot.reportedApplicationName, !name.isEmpty {
                hintParts.append(name)
            }
            if let pid = snapshot.reportedPID {
                hintParts.append("PID \(pid)")
            }

            if hintParts.isEmpty {
                secureInputStatusTitle = "Secure Input: On — source unknown"
            } else {
                secureInputStatusTitle = "Secure Input: On — \(hintParts.joined(separator: ", ")) (diagnostic hint)"
            }
        } else {
            secureInputStatusTitle = "Secure Input: Off"
        }

        fixTitle = "Fix Secure Input…"
        isFixEnabled = snapshot.isSecureInputEnabled
    }
}

public enum SecureInputDiagnostics {
    public static func reportedPID(fromIORegistryOutput text: String) -> Int32? {
        guard let expression = try? NSRegularExpression(
            pattern: #"kCGSSessionSecureInputPID"\s*=\s*(\d+)"#
        ),
        let match = expression.firstMatch(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        ),
        let range = Range(match.range(at: 1), in: text) else {
            return nil
        }

        return Int32(text[range])
    }
}
