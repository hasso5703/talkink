import Foundation
import SoyleKit

/// Watches Claude Code's session transcripts and speaks each assistant block
/// aloud as it lands — the native Swift replacement for the old Python daemon.
///
/// No hooks, no subprocess, no files written into `~/.claude`: it simply tails
/// the most recently active `~/.claude/projects/**/<uuid>.jsonl`. A short poll
/// (the bottleneck is synthesis, not detection) reads only the bytes appended
/// since last time, parses the JSONL, and for every new `assistant` text block
/// (deduplicated by `uuid`) cleans the Markdown, splits it into sentences and
/// feeds them to the `SpeechPlayer`. A new `user` prompt is a barge-in.
///
/// All file I/O and tail state stay on a private serial queue; the player (which
/// is `@MainActor`) is driven through `DispatchQueue.main` so calls arrive in
/// order.
final class ClaudeCodeReader: @unchecked Sendable {
    private let player: SpeechPlayer
    private let queue = DispatchQueue(label: "io.github.hasso5703.soyle.ccreader", qos: .utility)

    // Everything below is touched only on `queue`.
    private var timer: DispatchSourceTimer?
    private var currentFile: URL?
    private var offset: UInt64 = 0
    private var partial = ""
    private var seen = Set<String>()
    private var tickCount = 0
    private var firstAttach = true

    private static let pollInterval: DispatchTimeInterval = .milliseconds(300)
    private static let rescanEveryNTicks = 4   // ~1.2s between "is there a newer session?" scans

    init(player: SpeechPlayer) {
        self.player = player
    }

    // MARK: - Lifecycle (called from the main actor)

    func start() {
        queue.async { [weak self] in self?.beginTailing() }
    }

    func stop() {
        queue.async { [weak self] in self?.endTailing() }
        bargeIn()
    }

    private func beginTailing() {
        guard timer == nil else { return }
        seen.removeAll()
        partial = ""
        currentFile = nil
        offset = 0
        tickCount = 0
        firstAttach = true
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(50), repeating: Self.pollInterval)
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    private func endTailing() {
        timer?.cancel()
        timer = nil
        currentFile = nil
        partial = ""
        seen.removeAll()
    }

    // MARK: - Poll loop (on `queue`)

    private func tick() {
        tickCount &+= 1
        if currentFile == nil || tickCount % Self.rescanEveryNTicks == 0 {
            if let newest = findNewestTranscript(), newest != currentFile {
                attach(to: newest)
            }
        }
        readAppended()
    }

    /// Attach to a transcript. The first attach after the feature is switched on
    /// starts at end-of-file, so we read only what comes next instead of replaying
    /// the whole past conversation. A later switch means a brand-new session: read
    /// it from the top and silence any trailing speech from the old one.
    private func attach(to file: URL) {
        if firstAttach {
            offset = fileSize(file)
            firstAttach = false
        } else {
            offset = 0
            bargeIn()
        }
        currentFile = file
        partial = ""
    }

    private func readAppended() {
        guard let file = currentFile else { return }
        let size = fileSize(file)
        if size < offset { offset = 0; partial = "" }   // file rotated/truncated
        guard size > offset else { return }
        guard let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            offset += UInt64(data.count)
            guard !data.isEmpty else { return }
            var lines = (partial + String(decoding: data, as: UTF8.self))
                .components(separatedBy: "\n")
            partial = lines.removeLast()   // keep the trailing, still-incomplete line
            for line in lines { process(line) }
        } catch {
            Log.tts.error("transcript read failed (\(error.localizedDescription, privacy: .public))")
        }
    }

    // MARK: - Parsing

    private func process(_ line: String) {
        guard !line.isEmpty,
              let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "assistant": handleAssistant(obj)
        case "user":      handleUser(obj)
        default:          break
        }
    }

    private func handleAssistant(_ obj: [String: Any]) {
        guard let uuid = obj["uuid"] as? String, !seen.contains(uuid),
              let message = obj["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return }
        let texts = content.compactMap { block -> String? in
            (block["type"] as? String) == "text" ? (block["text"] as? String) : nil
        }
        guard !texts.isEmpty else { return }
        seen.insert(uuid)
        let cleaned = SpeechText.clean(texts.joined(separator: " "))
        for sentence in SpeechText.sentences(cleaned) {
            enqueue(sentence)
        }
    }

    private func handleUser(_ obj: [String: Any]) {
        // A real typed prompt carries a plain-string content; tool results are
        // also `type: "user"` but carry an array — those must NOT barge in.
        guard let message = obj["message"] as? [String: Any],
              message["content"] is String else { return }
        bargeIn()
    }

    // MARK: - Player bridge (hop to the main actor, FIFO order preserved)

    private func enqueue(_ sentence: String) {
        let player = self.player
        DispatchQueue.main.async {
            MainActor.assumeIsolated { player.enqueue(sentence) }
        }
    }

    private func bargeIn() {
        let player = self.player
        DispatchQueue.main.async {
            MainActor.assumeIsolated { player.stop() }
        }
    }

    // MARK: - Filesystem helpers (on `queue`)

    private func findNewestTranscript() -> URL? {
        let fm = FileManager.default
        let projects = ClaudeCodeDetector.projectsDirectory
        guard let subdirs = try? fm.contentsOfDirectory(
            at: projects, includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
        var newest: URL?
        var newestDate = Date.distantPast
        for dir in subdirs {
            let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            guard let files = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                if date > newestDate { newestDate = date; newest = file }
            }
        }
        return newest
    }

    private func fileSize(_ url: URL) -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
    }
}
