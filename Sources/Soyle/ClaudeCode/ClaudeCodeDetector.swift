import Foundation

/// Detects whether Claude Code (the CLI) is installed and where it keeps its
/// session transcripts. A menu-bar app launched by launchd does **not** inherit
/// the user's interactive shell `PATH`, so `which claude` is unreliable — we
/// stat the known install locations and the config footprint directly instead.
enum ClaudeCodeDetector {

    private static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    /// `~/.claude/projects` — one folder per project, each holding the session
    /// transcripts (`<uuid>.jsonl`) the reader tails. Created by Claude Code,
    /// never by us.
    static var projectsDirectory: URL {
        home.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// Known `claude` binary locations, in order: the native installer, then
    /// Homebrew, then a global npm prefix.
    private static var binaryCandidates: [URL] {
        [
            home.appendingPathComponent(".local/bin/claude"),
            home.appendingPathComponent(".claude/local/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
        ]
    }

    /// True when Claude Code is installed. The binary is the strongest signal;
    /// the config footprint (`~/.claude.json` plus a `projects` folder — neither
    /// created by this app or any TTS tool) confirms it has actually run.
    static func isInstalled() -> Bool {
        let fm = FileManager.default
        if binaryCandidates.contains(where: { fm.isExecutableFile(atPath: $0.path) }) {
            return true
        }
        let dotJSON = home.appendingPathComponent(".claude.json")
        return fm.fileExists(atPath: dotJSON.path)
            && fm.fileExists(atPath: projectsDirectory.path)
    }
}
