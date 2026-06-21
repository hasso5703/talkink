import Foundation
import MLXAudioTTS

/// French (and other non-English) grapheme-to-phoneme via system **espeak-ng** —
/// the phonemizer Kokoro was actually trained with, and what the previous Python
/// tool used. The bundled lexicon processor returns *raw graphemes* for any word
/// it doesn't know (English terms, inflected/rare French, names, numbers), which
/// Kokoro then mangles into noise. espeak phonemizes **everything** into IPA that
/// maps cleanly onto Kokoro's vocab (verified: zero out-of-vocab symbols), so the
/// result is intelligible and natural.
///
/// English keeps Kokoro's own Misaki G2P (higher quality there). If espeak-ng
/// isn't on the machine, we fall back to the lexicon processor so the feature
/// still works (just less natural on unknown words) — until espeak is bundled.
public final class EspeakG2PProcessor: TextProcessor, @unchecked Sendable {
    private let espeakPath: String?
    private let fallback = KokoroMultilingualProcessor()

    /// A menu-bar app launched by launchd has no shell `PATH`, so stat the known
    /// espeak-ng locations directly (Apple-Silicon brew, Intel brew, system).
    public init() {
        let candidates = [
            "/opt/homebrew/bin/espeak-ng", "/usr/local/bin/espeak-ng",
            "/usr/bin/espeak-ng", "/opt/homebrew/bin/espeak", "/usr/local/bin/espeak",
        ]
        espeakPath = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// `KokoroModel.fromModelDirectory` calls this once at load. Warm the English
    /// (Misaki) path the fallback uses, since the model won't call its
    /// language-specific `prepare(for:)` for a non-Kokoro processor.
    public func prepare() async throws {
        try? await fallback.prepare(for: "en-us")
    }

    public func process(text: String, language: String?) throws -> String {
        let lang = (language ?? "").lowercased()
        // espeak for everything non-English; Misaki (via the fallback) for English.
        if espeakPath != nil, !lang.isEmpty, !lang.hasPrefix("en"),
           let phonemes = runEspeak(text: text, voice: espeakVoice(for: lang)),
           !phonemes.isEmpty {
            return phonemes
        }
        return try fallback.process(text: text, language: language)
    }

    /// Map a Kokoro language code to an espeak-ng voice name (e.g. "fr", "es").
    private func espeakVoice(for lang: String) -> String {
        if lang.hasPrefix("pt") { return "pt" }
        return String(lang.prefix(2))
    }

    private func runEspeak(text: String, voice: String) -> String? {
        guard let path = espeakPath else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        // --ipa: IPA phonemes; -q: no audio; -v: language voice.
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
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            Log.tts.error("espeak-ng failed (\(error.localizedDescription, privacy: .public))")
            return nil
        }
    }
}
