import AppKit
import SoyleKit

extension Notification.Name {
    /// Posted by the menu's "Report a Problem…" — the Settings window opens
    /// the report sheet in response.
    static let soyleOpenReport = Notification.Name("soyle.openReport")
    /// talkink://history and talkink://settings select the matching tab.
    static let soyleShowHistory = Notification.Name("soyle.showHistory")
    static let soyleShowSettings = Notification.Name("soyle.showSettings")
}

/// Detects unclean exits: the marker exists at launch ⇔ the previous session
/// never reached applicationWillTerminate (crash, force quit, power loss).
/// One journal entry per incident — it then shows up in "Recent issues" and
/// in problem reports, instead of the crash being invisible.
enum CrashSentinel {
    private static var url: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Soyle", isDirectory: true)
            .appendingPathComponent("running.sentinel")
    }

    @discardableResult
    static func checkAndArm() -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let crashed = fm.fileExists(atPath: url.path)
        if crashed {
            ErrorLog.shared.record(component: "app",
                message: "Talkink didn't shut down cleanly last time (crash, force quit, or power loss)")
        }
        try? Data().write(to: url)
        return crashed
    }

    static func disarm() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// The "Report a Problem" payload: environment + the recent error journal.
/// NEVER transcripts or audio — the report is shown to the user in full
/// before anything leaves the Mac.
enum DiagnosticsReport {

    static func compose() -> String {
        let bundle = Bundle.main
        let version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
        let build = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "?"
        let chip = sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon"
        let ramGB = Double(SystemResources.physicalMemoryBytes) / 1_073_741_824
        let disk = SystemResources.freeDiskBytes(for: FileManager.default.homeDirectoryForCurrentUser)
            .map { String(format: "%.1f GB free", Double($0) / 1_000_000_000) } ?? "unknown"
        let settings = SettingsStore.shared

        var lines: [String] = []
        lines.append("### Environment")
        lines.append("- Talkink \(version) (build \(build))")
        lines.append("- macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append(String(format: "- %@, %.0f GB RAM", chip, ramGB))
        lines.append("- Disk: \(disk)")
        lines.append("- Model: \(settings.modelOption.displayName) [\(settings.modelOption.id)]")
        lines.append("- Language: \(settings.language.displayName)")
        lines.append("- Permissions: microphone \(mark(Permissions.hasMicrophone)) · accessibility \(mark(Permissions.hasAccessibility))")

        let errors = ErrorLog.shared.recent(8)
        lines.append("")
        lines.append("### Recent issues (\(errors.count))")
        if errors.isEmpty {
            lines.append("(none recorded)")
        } else {
            let formatter = ISO8601DateFormatter()
            for entry in errors {
                var line = "- \(formatter.string(from: entry.date)) [\(entry.component)] \(entry.message)"
                if let detail = entry.detail { line += ", \(detail)" }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Prefilled GitHub issue. Browsers/GitHub truncate very long URLs, so the
    /// embedded report is capped — the full text is also put on the clipboard.
    static func gitHubIssueURL(report: String) -> URL? {
        var components = URLComponents(string: "https://github.com/hasso5703/talkink/issues/new")
        let body = """
        <!-- What happened, and what did you expect? -->


        ---
        \(report)
        """
        components?.queryItems = [
            URLQueryItem(name: "title", value: "Problem report: "),
            URLQueryItem(name: "labels", value: "bug"),
            URLQueryItem(name: "body", value: String(body.prefix(5_500))),
        ]
        return components?.url
    }

    private static func mark(_ granted: Bool) -> String { granted ? "✓" : "✗" }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
