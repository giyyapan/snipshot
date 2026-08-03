import Cocoa
import Carbon.HIToolbox

/// Recovers from a stuck Secure Input session by gracefully cycling user apps.
///
/// macOS does not allow one process to release another process's Secure Input
/// assertion. The only safe recovery available to us is to ask candidate apps
/// to terminate normally, stop as soon as every assertion clears, and then
/// reopen only the apps that were closed by this recovery run.
final class SecureInputRecoveryController {
    private static let terminationPollInterval: TimeInterval = 0.25
    private static let terminationPollAttempts = 40
    private static let postTerminationSecureInputPollAttempts = 8

    private struct ClosedApplication {
        let name: String
        let bundleURL: URL
    }

    private let workspace = NSWorkspace.shared
    private var attemptedProcessIdentifiers = Set<pid_t>()
    private var closedApplications: [ClosedApplication] = []
    private var isRunning = false
    private var completion: (() -> Void)?

    func currentSnapshot(shortcutListenerAvailable: Bool) -> SecureInputSnapshot {
        let isEnabled = IsSecureEventInputEnabled()
        let reportedPID = isEnabled ? reportedSecureInputPID() : nil
        let reportedApplicationName = reportedPID
            .flatMap(NSRunningApplication.init(processIdentifier:))?
            .localizedName

        return SecureInputSnapshot(
            isSecureInputEnabled: isEnabled,
            isAccessibilityTrusted: AXIsProcessTrusted(),
            isShortcutListenerAvailable: shortcutListenerAvailable,
            reportedPID: reportedPID,
            reportedApplicationName: reportedApplicationName
        )
    }

    func start(completion: @escaping () -> Void) {
        guard !isRunning else { return }

        guard IsSecureEventInputEnabled() else {
            showAlert(
                title: "Secure Input Is Already Off",
                message: "Global keyboard shortcuts should be available. If they still do not work, check Accessibility permission or restart the affected shortcut app."
            )
            completion()
            return
        }

        let reportedHint = reportedSecureInputApplication()?.localizedName ?? "an unknown process"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Fix Secure Input?"
        alert.informativeText = "The diagnostic PID currently points to \(reportedHint), but that hint can be stale and more than one app may hold an assertion. Snipshot will ask user apps to quit normally, stopping as soon as Secure Input clears, then reopen the apps it closed.\n\nApps with unsaved work may ask you to save. Snipshot will never force-quit them."
        alert.addButton(withTitle: "Fix and Reopen Apps")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            completion()
            return
        }

        isRunning = true
        self.completion = completion
        attemptedProcessIdentifiers.removeAll()
        closedApplications.removeAll()
        recoverNextApplication()
    }

    private func recoverNextApplication() {
        if !IsSecureEventInputEnabled() {
            finish(success: true, detail: nil)
            return
        }

        guard let application = nextCandidateApplication() else {
            finish(
                success: false,
                detail: "No more user applications can be closed safely. Lock and unlock your Mac, or log out and back in, to reset any remaining system-level assertion."
            )
            return
        }

        let name = application.localizedName ?? application.bundleIdentifier ?? "Unknown App"
        attemptedProcessIdentifiers.insert(application.processIdentifier)

        guard let bundleURL = topLevelApplicationURL(for: application), application.terminate() else {
            logMessage("Secure Input recovery could not request termination of \(name).")
            recoverNextApplication()
            return
        }

        logMessage("Secure Input recovery requested normal termination of \(name) (pid \(application.processIdentifier)).")
        waitForTermination(
            of: application,
            name: name,
            bundleURL: bundleURL,
            attemptsRemaining: Self.terminationPollAttempts
        )
    }

    private func waitForTermination(
        of application: NSRunningApplication,
        name: String,
        bundleURL: URL,
        attemptsRemaining: Int
    ) {
        let decision = SecureInputRecoveryDecisions.waitDecision(
            isSecureInputEnabled: IsSecureEventInputEnabled(),
            isApplicationTerminated: application.isTerminated,
            attemptsRemaining: attemptsRemaining
        )

        switch decision {
        case .secureInputCleared(let applicationTerminated):
            logMessage("Secure Input recovery observed Secure Input off while waiting for \(name).")
            if applicationTerminated {
                rememberClosedApplication(name: name, bundleURL: bundleURL)
                finish(success: true, detail: nil)
            } else {
                reopenIfTerminationCompletes(
                    application,
                    name: name,
                    bundleURL: bundleURL,
                    attemptsRemaining: Self.terminationPollAttempts
                )
                finish(
                    success: true,
                    detail: "Secure Input was cleared after asking \(name) to quit. If it finishes quitting, it will be reopened automatically."
                )
            }

        case .applicationTerminated:
            rememberClosedApplication(name: name, bundleURL: bundleURL)
            waitForSecureInputToSettle(
                attemptsRemaining: Self.postTerminationSecureInputPollAttempts
            )

        case .timedOut:
            finish(
                success: false,
                detail: "\(name) did not quit, possibly because it is waiting for you to save a document. Handle that prompt, then run the fix again."
            )

        case .continueWaiting:
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.terminationPollInterval) { [weak self] in
                self?.waitForTermination(
                    of: application,
                    name: name,
                    bundleURL: bundleURL,
                    attemptsRemaining: attemptsRemaining - 1
                )
            }
        }
    }

    private func waitForSecureInputToSettle(attemptsRemaining: Int) {
        if !IsSecureEventInputEnabled() {
            logMessage("Secure Input recovery observed Secure Input off after application termination.")
            finish(success: true, detail: nil)
            return
        }

        guard attemptsRemaining > 0 else {
            recoverNextApplication()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.terminationPollInterval) { [weak self] in
            self?.waitForSecureInputToSettle(attemptsRemaining: attemptsRemaining - 1)
        }
    }

    private func rememberClosedApplication(name: String, bundleURL: URL) {
        if !closedApplications.contains(where: { $0.bundleURL == bundleURL }) {
            closedApplications.append(ClosedApplication(name: name, bundleURL: bundleURL))
        }
    }

    private func reopenIfTerminationCompletes(
        _ application: NSRunningApplication,
        name: String,
        bundleURL: URL,
        attemptsRemaining: Int
    ) {
        if application.isTerminated {
            reopenApplication(ClosedApplication(name: name, bundleURL: bundleURL))
            return
        }

        guard attemptsRemaining > 0 else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.terminationPollInterval) { [weak self] in
            self?.reopenIfTerminationCompletes(
                application,
                name: name,
                bundleURL: bundleURL,
                attemptsRemaining: attemptsRemaining - 1
            )
        }
    }

    private func nextCandidateApplication() -> NSRunningApplication? {
        let applications = candidateApplications()

        if let reported = reportedSecureInputApplication(),
           let reportedTopLevelURL = topLevelApplicationURL(for: reported),
           let matchingApplication = applications.first(where: {
               topLevelApplicationURL(for: $0) == reportedTopLevelURL && !wasAttempted($0)
           }) {
            return matchingApplication
        }

        return applications.first(where: { !wasAttempted($0) })
    }

    private func candidateApplications() -> [NSRunningApplication] {
        let currentPID = ProcessInfo.processInfo.processIdentifier

        return workspace.runningApplications
            .filter { application in
                guard !application.isTerminated,
                      application.processIdentifier != currentPID,
                      application.activationPolicy != .prohibited,
                      let bundleURL = topLevelApplicationURL(for: application),
                      !bundleURL.path.hasPrefix("/System/") else {
                    return false
                }

                let identifier = application.bundleIdentifier ?? ""
                return identifier != "com.apple.finder" && identifier != "com.apple.loginwindow"
            }
            .sorted { left, right in
                if left.activationPolicy != right.activationPolicy {
                    return left.activationPolicy == .regular
                }
                return (left.localizedName ?? "") < (right.localizedName ?? "")
            }
    }

    private func wasAttempted(_ application: NSRunningApplication) -> Bool {
        attemptedProcessIdentifiers.contains(application.processIdentifier)
    }

    private func reportedSecureInputApplication() -> NSRunningApplication? {
        guard let pid = reportedSecureInputPID() else { return nil }
        return NSRunningApplication(processIdentifier: pid)
    }

    /// Reads the diagnostic PID exposed by WindowServer. This value is only a
    /// hint: macOS can report a stale or top-level PID when a helper owns the
    /// actual assertion, so recovery never treats it as authoritative.
    private func reportedSecureInputPID() -> pid_t? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        process.arguments = ["-l", "-d", "1", "-w", "0"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            logMessage("Secure Input recovery could not run ioreg: \(error.localizedDescription)")
            return nil
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return SecureInputDiagnostics.reportedPID(fromIORegistryOutput: text)
    }

    private func topLevelApplicationURL(for application: NSRunningApplication) -> URL? {
        guard let bundleURL = application.bundleURL else { return nil }
        let components = bundleURL.standardizedFileURL.pathComponents
        guard let appIndex = components.firstIndex(where: { $0.hasSuffix(".app") }) else {
            return nil
        }

        let path = NSString.path(withComponents: Array(components.prefix(through: appIndex)))
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    private func finish(success: Bool, detail: String?) {
        let closedNames = closedApplications.map(\.name)
        reopenClosedApplications()

        let summary: String
        if success {
            if let detail {
                summary = detail
            } else if closedNames.isEmpty {
                summary = "Secure Input cleared before any applications needed to quit."
            } else {
                summary = "Secure Input was cleared after closing \(closedNames.joined(separator: ", ")). Those applications are being reopened now."
            }
        } else {
            let closedSummary = closedNames.isEmpty
                ? "No applications were closed."
                : "Reopening: \(closedNames.joined(separator: ", "))."
            summary = [detail, closedSummary].compactMap { $0 }.joined(separator: "\n\n")
        }

        logMessage("Secure Input recovery finished with success=\(success); closed applications: \(closedNames.joined(separator: ", ")).")

        showAlert(
            title: success ? "Secure Input Fixed" : "Secure Input Is Still On",
            message: summary,
            style: success ? .informational : .warning
        )

        isRunning = false
        let callback = completion
        completion = nil
        callback?()
    }

    private func reopenClosedApplications() {
        var reopenedPaths = Set<String>()
        for application in closedApplications {
            guard reopenedPaths.insert(application.bundleURL.path).inserted else { continue }
            reopenApplication(application)
        }
    }

    private func reopenApplication(_ application: ClosedApplication) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        workspace.openApplication(at: application.bundleURL, configuration: configuration) { _, error in
            if let error {
                logMessage("Could not reopen \(application.name): \(error.localizedDescription)")
            }
        }
    }

    private func showAlert(
        title: String,
        message: String,
        style: NSAlert.Style = .informational
    ) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
