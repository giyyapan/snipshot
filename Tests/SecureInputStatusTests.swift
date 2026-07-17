import Foundation

private struct TestFailure: Error {
    let message: String
}

@main
private enum SecureInputStatusTests {
    private static var testCount = 0

    static func main() throws {
        try test("ready presentation") {
            let presentation = SecureInputMenuPresentation(snapshot: .init(
                isSecureInputEnabled: false,
                isAccessibilityTrusted: true,
                isShortcutListenerAvailable: true
            ))

            try expect(presentation.shortcutStatusTitle == "Global Shortcuts: Ready", "ready health was not shown")
            try expect(presentation.secureInputStatusTitle == "Secure Input: Off", "off state was not shown")
            try expect(!presentation.isFixEnabled, "fix was enabled while Secure Input was off")
        }

        try test("Secure Input takes precedence and enables Fix") {
            let presentation = SecureInputMenuPresentation(snapshot: .init(
                isSecureInputEnabled: true,
                isAccessibilityTrusted: false,
                isShortcutListenerAvailable: false,
                reportedPID: 4321,
                reportedApplicationName: "Password App"
            ))

            try expect(presentation.shortcutStatusTitle == "Global Shortcuts: Blocked", "blocked state did not take precedence")
            try expect(
                presentation.secureInputStatusTitle == "Secure Input: On — Password App, PID 4321 (diagnostic hint)",
                "diagnostic hint was formatted incorrectly"
            )
            try expect(presentation.fixTitle == "Fix Secure Input…", "Fix action was not explicit")
            try expect(presentation.isFixEnabled, "Fix was disabled while Secure Input was on")
        }

        try test("unknown Secure Input source does not invent an owner") {
            let presentation = SecureInputMenuPresentation(snapshot: .init(
                isSecureInputEnabled: true,
                isAccessibilityTrusted: true,
                isShortcutListenerAvailable: true
            ))

            try expect(presentation.secureInputStatusTitle == "Secure Input: On — source unknown", "unknown source was misrepresented")
            try expect(presentation.isFixEnabled, "Fix was disabled for an unknown source")
        }

        try test("non-Secure Input health failures remain non-fixable") {
            let accessibility = SecureInputMenuPresentation(snapshot: .init(
                isSecureInputEnabled: false,
                isAccessibilityTrusted: false,
                isShortcutListenerAvailable: false
            ))
            try expect(
                accessibility.shortcutStatusTitle == "Global Shortcuts: Accessibility Required",
                "Accessibility state was not shown"
            )
            try expect(!accessibility.isFixEnabled, "Fix was enabled for an Accessibility problem")

            let listener = SecureInputMenuPresentation(snapshot: .init(
                isSecureInputEnabled: false,
                isAccessibilityTrusted: true,
                isShortcutListenerAvailable: false
            ))
            try expect(
                listener.shortcutStatusTitle == "Global Shortcuts: Listener Unavailable",
                "listener state was not shown"
            )
            try expect(!listener.isFixEnabled, "Fix was enabled for a listener problem")
        }

        try test("diagnostic PID parsing") {
            let output = #"| |   "kCGSSessionSecureInputPID" = 9876"#
            try expect(
                SecureInputDiagnostics.reportedPID(fromIORegistryOutput: output) == 9876,
                "valid PID was not parsed"
            )
            try expect(
                SecureInputDiagnostics.reportedPID(fromIORegistryOutput: "unrelated output") == nil,
                "unrelated output produced a PID"
            )
        }

        print("SecureInputStatusTests: \(testCount) tests passed")
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
