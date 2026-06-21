import Foundation
import MLXAudioTTS

/// French (and other espeak-language) G2P that **faithfully reproduces the
/// official Kokoro pipeline** — `misaki.espeak.EspeakG2P(language='fr-fr')` with
/// no version, exactly what `kokoro.KPipeline(lang_code='f')` builds.
///
/// Kokoro was trained on misaki's phoneme output, NOT on raw espeak IPA, so we
/// run espeak-ng the way phonemizer does (fr-fr, stress, `--tie=^`, drop
/// language-switch flags) and then apply misaki's post-processing verbatim: merge
/// the tied digraphs/affricates into Kokoro's symbols, strip the ties, and (the
/// version=None branch) drop hyphens. No heuristics, no code-switching — that is
/// not part of the reference pipeline, and bolting English handling onto French
/// is the documented cause of "French that sounds like accented English"
/// (kokoro-onnx #68/#108). English voices keep Kokoro's own Misaki G2P; if
/// espeak isn't installed we fall back to the bundled lexicon processor.
public final class EspeakG2PProcessor: TextProcessor, @unchecked Sendable {
    private let espeakPath: String?
    private let fallback = KokoroMultilingualProcessor()

    /// misaki's tied-digraph → Kokoro-symbol map (the base set; the optional 2.0
    /// nasal-vowel remap is NOT applied because `EspeakG2P('fr-fr')` passes no
    /// version, so French nasals stay as IPA ɔ̃/ɑ̃/ɛ̃/œ̃).
    private static let e2m: [(String, String)] = [
        ("a^ɪ", "I"), ("a^ʊ", "W"), ("d^z", "ʣ"), ("d^ʒ", "ʤ"), ("e^ɪ", "A"),
        ("o^ʊ", "O"), ("ə^ʊ", "Q"), ("s^s", "S"), ("t^s", "ʦ"), ("t^ʃ", "ʧ"),
        ("ɔ^ɪ", "Y"),
    ]

    public init() {
        let candidates = [
            "/opt/homebrew/bin/espeak-ng", "/usr/local/bin/espeak-ng",
            "/usr/bin/espeak-ng", "/opt/homebrew/bin/espeak", "/usr/local/bin/espeak",
        ]
        espeakPath = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func prepare() async throws {
        try? await fallback.prepare(for: "en-us")   // English voices route to Misaki
    }

    public func process(text: String, language: String?) throws -> String {
        let lang = (language ?? "").lowercased()
        guard let espeak = espeakPath, !lang.isEmpty, !lang.hasPrefix("en") else {
            return try fallback.process(text: text, language: language)
        }
        let phonemes = misakiPhonemize(text, espeakLanguage: espeakLanguage(for: lang), espeak: espeak)
        return phonemes.isEmpty ? (try fallback.process(text: text, language: language)) : phonemes
    }

    /// Faithful port of `misaki.espeak.EspeakG2P.__call__` (version=None).
    private func misakiPhonemize(_ text: String, espeakLanguage lang: String, espeak: String) -> String {
        // misaki swaps parentheses for guillemets so espeak doesn't choke on them.
        var input = text.replacingOccurrences(of: "«", with: "\u{201C}")
                        .replacingOccurrences(of: "»", with: "\u{201D}")
        input = input.replacingOccurrences(of: "(", with: "«").replacingOccurrences(of: ")", with: "»")
        guard var ps = runEspeak(input, language: lang, espeak: espeak) else { return "" }
        // phonemizer language_switch='remove-flags' — drop "(en)…(fr)" markers.
        ps = ps.replacingOccurrences(of: #"\([a-z]{2,3}\)"#, with: "", options: .regularExpression)
        for (old, new) in Self.e2m { ps = ps.replacingOccurrences(of: old, with: new) }
        ps = ps.replacingOccurrences(of: "^", with: "")   // strip ties
        ps = ps.replacingOccurrences(of: "-", with: "")   // version=None: drop hyphens
        ps = ps.replacingOccurrences(of: "«", with: "(").replacingOccurrences(of: "»", with: ")")
        return ps.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// kokoro's `LANG_CODES`: f → fr-fr, e → es, i → it, p → pt-br.
    private func espeakLanguage(for lang: String) -> String {
        switch lang.prefix(2) {
        case "fr": return "fr-fr"
        case "pt": return "pt-br"
        default:   return String(lang.prefix(2))
        }
    }

    private func runEspeak(_ text: String, language: String, espeak: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: espeak)
        // phonemizer EspeakBackend(with_stress=True, tie='^'): --ipa carries stress.
        process.arguments = ["-v", language, "--ipa", "--tie=^", "-q", text]
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
