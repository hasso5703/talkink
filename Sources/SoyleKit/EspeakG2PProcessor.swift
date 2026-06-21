import Foundation
import MLXAudioTTS

/// Grapheme-to-phoneme via system **espeak-ng**, with **per-word code-switching**
/// so an English word inside French prose is pronounced in English. The model was
/// trained on espeak-style IPA, and both espeak-fr and espeak-en output map onto
/// Kokoro's vocab (verified), so we can switch voice per run and concatenate.
///
/// Language detection uses the French IPA lexicon (≈90k words) as a dictionary:
/// a token is French if it carries French diacritics, an apostrophe (elision),
/// or appears in the lexicon — otherwise an ASCII token is treated as English
/// ("push", "GitHub", identifiers). English voices keep Kokoro's own Misaki G2P.
/// Falls back to the lexicon processor when espeak isn't installed.
public final class EspeakG2PProcessor: TextProcessor, @unchecked Sendable {
    private let espeakPath: String?
    private let fallback = KokoroMultilingualProcessor()
    private let lock = NSLock()
    private var frenchCache: Set<String>?

    private static let lexiconRepo = "beshkenadze/kokoro-ipa-lexicons"

    public init() {
        let candidates = [
            "/opt/homebrew/bin/espeak-ng", "/usr/local/bin/espeak-ng",
            "/usr/bin/espeak-ng", "/opt/homebrew/bin/espeak", "/usr/local/bin/espeak",
        ]
        espeakPath = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Called once at load. Warm the English (Misaki) fallback and make sure the
    /// French lexicon — our code-switching dictionary — is on disk.
    public func prepare() async throws {
        try? await fallback.prepare(for: "en-us")
        try? await fallback.prepare(for: "fr")
    }

    public func process(text: String, language: String?) throws -> String {
        let lang = (language ?? "").lowercased()
        guard let espeak = espeakPath, !lang.isEmpty, !lang.hasPrefix("en") else {
            return try fallback.process(text: text, language: language)
        }
        let phonemes = codeSwitched(text, frenchVoice: espeakVoice(for: lang), espeak: espeak)
        return phonemes.isEmpty ? (try fallback.process(text: text, language: language)) : phonemes
    }

    // MARK: - Code-switching

    private func codeSwitched(_ text: String, frenchVoice: String, espeak: String) -> String {
        let french = frenchWords()
        var runs: [(english: Bool, words: [String])] = []
        for token in text.split(separator: " ", omittingEmptySubsequences: true) {
            let english = !french.isEmpty && isEnglish(String(token), french: french)
            if let last = runs.last, last.english == english {
                runs[runs.count - 1].words.append(String(token))
            } else {
                runs.append((english, [String(token)]))
            }
        }
        var out = ""
        for run in runs {
            let voice = run.english ? "en-us" : frenchVoice
            guard let p = runEspeak(run.words.joined(separator: " "), voice: voice, espeak: espeak),
                  !p.isEmpty else { continue }
            out += out.isEmpty ? p : " " + p
        }
        return out
    }

    /// A token is English when it's a plain ASCII word the French dictionary
    /// doesn't know (and isn't an elision or accented). Numbers and punctuation
    /// stay French — espeak-fr verbalises numbers in French.
    private func isEnglish(_ token: String, french: Set<String>) -> Bool {
        let lower = token.lowercased()
        if lower.contains("'") || lower.contains("\u{2019}") { return false }   // French elision
        let core = lower.filter { $0.isLetter }
        guard core.count >= 2 else { return false }
        if core.contains(where: { "àâäçéèêëîïôöùûüÿœæ".contains($0) }) { return false }
        if french.contains(core) { return false }
        return core.unicodeScalars.allSatisfy { $0.isASCII }
    }

    /// The lexicon's word list, loaded once. Empty (→ no code-switching, all
    /// French) if the file isn't there yet.
    private func frenchWords() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        if let cached = frenchCache { return cached }
        var set = Set<String>()
        let tsv = ModelDownloader.modelDirectory(forRepo: Self.lexiconRepo)
            .appendingPathComponent("fr_lexicon.tsv")
        if let content = try? String(contentsOf: tsv, encoding: .utf8) {
            set.reserveCapacity(100_000)
            for line in content.split(separator: "\n") {
                if let tab = line.firstIndex(of: "\t") {
                    set.insert(String(line[line.startIndex..<tab]).lowercased())
                }
            }
        }
        frenchCache = set
        return set
    }

    // MARK: - espeak

    private func espeakVoice(for lang: String) -> String {
        lang.hasPrefix("pt") ? "pt" : String(lang.prefix(2))
    }

    private func runEspeak(_ text: String, voice: String, espeak: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: espeak)
        process.arguments = ["-v", voice, "--ipa", "-q", text]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(decoding: data, as: UTF8.self)
                .replacingOccurrences(of: "\n", with: " ")
                // espeak emits literal language-switch markers like "(en)…(fr)"
                // for words it auto-detects as foreign — strip them or they tokenize as noise.
                .replacingOccurrences(of: #"\([a-z]{2,3}\)"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            Log.tts.error("espeak-ng failed (\(error.localizedDescription, privacy: .public))")
            return nil
        }
    }
}
