import Foundation
import Combine

/// One vocabulary entry: the canonical way to write a word or phrase, plus
/// the forms the models keep mishearing it as.
public struct VocabularyEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    /// Canonical form, exactly as it should appear ("Talkink", "PostgreSQL").
    public var phrase: String
    /// Misheard forms to replace verbatim ("Talking", "tall kink").
    public var variants: [String]

    public init(phrase: String, variants: [String] = []) {
        self.id = UUID()
        self.phrase = phrase
        self.variants = variants
    }
}

/// Custom dictionary — fixes names and jargon the models can't know, entirely
/// on this Mac, after transcription. Two layers:
///  1. exact replacements: the user's own variants, word-boundary matched,
///     case-insensitive — deterministic, applied always;
///  2. fuzzy correction toward canonical phrases — but NEVER on a real word
///     of the language (the injected `isKnownWord` gate): "Talking" stays
///     "Talking" unless the user explicitly lists it as a variant.
public final class Vocabulary: ObservableObject {
    public static let shared = Vocabulary()

    @Published public private(set) var entries: [VocabularyEntry] = []
    /// Last persistence problem — vocabulary edits must never vanish silently.
    @Published public private(set) var lastError: String?

    private let fileURL: URL
    private let errorLog: ErrorLog

    /// Directory and journal injectable so tests touch no real user data.
    public init(directory: URL? = nil, errorLog: ErrorLog = .shared) {
        self.errorLog = errorLog
        let dir = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Soyle", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("vocabulary.json")
        load()
    }

    // MARK: Editing

    public func add(_ entry: VocabularyEntry) {
        guard !entry.phrase.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        entries.append(normalized(entry))
        save()
    }

    public func update(_ entry: VocabularyEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = normalized(entry)
        save()
    }

    public func remove(_ entry: VocabularyEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    private func normalized(_ entry: VocabularyEntry) -> VocabularyEntry {
        var cleaned = entry
        cleaned.phrase = entry.phrase.trimmingCharacters(in: .whitespaces)
        cleaned.variants = entry.variants
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.lowercased() != cleaned.phrase.lowercased() }
        return cleaned
    }

    // MARK: Application

    /// Correct a transcript. `isKnownWord` guards the fuzzy layer: with the
    /// default (everything is a known word) only the user's explicit variants
    /// apply — the safe baseline.
    public func apply(to text: String, isKnownWord: (String) -> Bool = { _ in true }) -> String {
        Self.apply(entries: entries, to: text, isKnownWord: isKnownWord)
    }

    /// Pure core, directly testable.
    public static func apply(
        entries: [VocabularyEntry],
        to text: String,
        isKnownWord: (String) -> Bool = { _ in true }
    ) -> String {
        guard !entries.isEmpty, !text.isEmpty else { return text }
        var output = text

        // Layer 1 — exact user-listed variants, longest first so multi-word
        // variants win over single-word ones they may contain.
        let pairs = entries.flatMap { entry in entry.variants.map { ($0, entry.phrase) } }
            .sorted { $0.0.count > $1.0.count }
        for (variant, phrase) in pairs {
            let escaped = NSRegularExpression.escapedPattern(for: variant)
            guard let regex = try? NSRegularExpression(
                pattern: "\\b\(escaped)\\b", options: [.caseInsensitive]) else { continue }
            output = regex.stringByReplacingMatches(
                in: output, range: NSRange(output.startIndex..., in: output),
                withTemplate: NSRegularExpression.escapedTemplate(for: phrase))
        }

        // Layer 2 — fuzzy toward canonical phrases, for words the language
        // doesn't know (typically a mangled name). Strict by design.
        let candidates = entries.map(\.phrase).filter { $0.count >= 5 && !$0.contains(" ") }
        guard !candidates.isEmpty else { return output }

        var corrected: [String] = []
        var changed = false
        var index = output.startIndex
        // Walk word by word, preserving everything between words verbatim.
        while index < output.endIndex {
            if let range = output[index...].firstIndex(where: { $0.isLetter || $0.isNumber }) {
                corrected.append(String(output[index..<range]))
                var end = range
                while end < output.endIndex, output[end].isLetter || output[end].isNumber {
                    end = output.index(after: end)
                }
                let word = String(output[range..<end])
                if let fix = fuzzyMatch(word: word, candidates: candidates, isKnownWord: isKnownWord) {
                    corrected.append(fix)
                    changed = true
                } else {
                    corrected.append(word)
                }
                index = end
            } else {
                corrected.append(String(output[index...]))
                break
            }
        }
        return changed ? corrected.joined() : output
    }

    /// A fuzzy fix applies only when: the word isn't already canonical, the
    /// language doesn't know it, it starts with the same letter, and the edit
    /// distance is small for the length (1 up to 7 chars, 2 beyond).
    static func fuzzyMatch(word: String, candidates: [String], isKnownWord: (String) -> Bool) -> String? {
        guard word.count >= 4 else { return nil }
        let lowered = word.lowercased()
        if candidates.contains(where: { $0.lowercased() == lowered }) { return nil }
        guard !isKnownWord(word) else { return nil }
        var best: (phrase: String, distance: Int)?
        for phrase in candidates {
            let p = phrase.lowercased()
            guard p.first == lowered.first else { continue }
            let maxDistance = phrase.count <= 7 ? 1 : 2
            guard abs(p.count - lowered.count) <= maxDistance else { continue }
            let d = levenshtein(p, lowered, cap: maxDistance)
            if d <= maxDistance, d < (best?.distance ?? .max) {
                best = (phrase, d)
            }
        }
        return best?.phrase
    }

    /// Classic DP distance with an early-exit cap.
    static func levenshtein(_ a: String, _ b: String, cap: Int) -> Int {
        let s = Array(a.unicodeScalars), t = Array(b.unicodeScalars)
        if s.isEmpty { return t.count }
        if t.isEmpty { return s.count }
        var previous = Array(0...t.count)
        var current = [Int](repeating: 0, count: t.count + 1)
        for i in 1...s.count {
            current[0] = i
            var rowMin = current[0]
            for j in 1...t.count {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                rowMin = min(rowMin, current[j])
            }
            if rowMin > cap { return cap + 1 }   // can only grow — bail out
            swap(&previous, &current)
        }
        return previous[t.count]
    }

    // MARK: Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            entries = try JSONDecoder().decode([VocabularyEntry].self, from: data)
        } catch {
            let backup = fileURL.deletingLastPathComponent()
                .appendingPathComponent("vocabulary.corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            lastError = "Vocabulary couldn't be read, the damaged file was kept as \(backup.lastPathComponent)."
            errorLog.record(component: "vocabulary",
                            message: "vocabulary.json unreadable, moved aside",
                            detail: error.localizedDescription)
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
            if lastError != nil { lastError = nil }
        } catch {
            lastError = "Vocabulary couldn't be saved, \(error.localizedDescription)"
            errorLog.record(component: "vocabulary",
                            message: "vocabulary.json save failed",
                            detail: error.localizedDescription)
        }
    }
}
