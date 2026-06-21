import Foundation

/// Turns a raw assistant message (GitHub-flavoured Markdown) into clean,
/// sentence-sized chunks fit for a TTS voice. Ported from the Python reader so
/// the spoken result matches what users already heard, and kept pure + static
/// so it can be unit-tested without a model. Two stages: `clean` strips markup
/// and code that shouldn't be read out, `sentences` splits into short pieces for
/// low-latency synthesis and steady pacing.
public enum SpeechText {

    // MARK: - Cleaning

    /// Strip Markdown/code/URLs so the voice reads prose, not syntax.
    public static func clean(_ raw: String) -> String {
        var s = stripSymbols(raw)
        // Fenced code blocks are never read aloud.
        s = replacing(s, #"```[\s\S]*?```"#, with: " ")
        s = replacing(s, #"~~~[\s\S]*?~~~"#, with: " ")
        // Inline code: keep a short, simple span (it's usually a word like
        // `preset`), but drop anything long or path-like that would read as noise.
        s = replacingInlineCode(s)
        // Images first (drop), then links → their visible text.
        s = replacing(s, #"!\[[^\]]*\]\([^)]*\)"#, with: " ")
        s = replacing(s, #"\[([^\]]+)\]\([^)]*\)"#, with: "$1")
        // Bare URLs.
        s = replacing(s, #"https?://[^\s)]+"#, with: " ")
        // --- Technical-noise normalization (so the voice doesn't read code) ---
        // Commit hashes / hex blobs — require a digit so real words ("face") survive.
        s = replacing(s, #"\b(?=[0-9a-fA-F]*[0-9])[0-9a-fA-F]{7,}\b"#, with: " ")
        // Repo slugs and file paths (a slash between word-ish chars).
        s = replacing(s, #"[\w.~@-]+/[\w./~@-]+"#, with: " ")
        // Drop a code-file extension so "Foo.swift" reads as "Foo".
        s = replacing(s, #"(\b[\w-]+)\.(swift|py|js|ts|jsx|tsx|json|md|sh|ya?ml|toml|cfg|ini|app|safetensors|wav|png|jpe?g|txt|xml|html?|css|rs|go|cpp|hpp|java|rb|php)\b"#, with: "$1")
        // Make identifiers speakable rather than dropping them: split snake_case
        // and camelCase into words ("unicodeScalars" → "unicode Scalars").
        s = replacing(s, #"(?<=\p{L})_(?=\p{L})"#, with: " ")
        s = replacing(s, #"(\p{Ll}|\d)(\p{Lu})"#, with: "$1 $2")
        // Line-leading markup: ATX headers, list bullets, block quotes, table pipes.
        s = replacing(s, #"(?m)^\s{0,3}#{1,6}\s*"#, with: " ")
        s = replacing(s, #"(?m)^\s{0,3}[-*+]\s+"#, with: " ")
        s = replacing(s, #"(?m)^\s{0,3}>\s?"#, with: " ")
        // Emphasis / strikethrough / leftover code ticks → gone.
        s = replacing(s, #"[*_`~]+"#, with: "")
        // Table cell separators read as nothing useful.
        s = replacing(s, #"\s*\|\s*"#, with: " ")
        // Collapse the whitespace the substitutions left behind.
        s = replacing(s, #"[ \t]+"#, with: " ")
        s = replacing(s, #"\s*\n\s*"#, with: "\n")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Keep `short` inline code, drop long or path-like spans (a backtick block
    /// such as `~/.claude/tts/x.py` reads terribly).
    private static func replacingInlineCode(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"`([^`\n]*)`"#) else { return s }
        let ns = s as NSString
        var result = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let inner = ns.substring(with: m.range(at: 1))
            result += (inner.count <= 24 && !inner.contains("/")) ? inner : " "
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    // MARK: - Sentence splitting

    /// Split cleaned text into chunks no longer than `maxLength`, breaking on
    /// sentence enders first and hard-wrapping anything still too long. Kokoro
    /// sounds best around 100–200 characters; short chunks also mean the first
    /// words are heard sooner.
    public static func sentences(_ text: String, maxLength: Int = 220) -> [String] {
        let normalized = replacing(text, #"\s+"#, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        var out: [String] = []
        for raw in splitOnEnders(normalized) {
            let piece = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if piece.isEmpty { continue }
            if piece.count <= maxLength {
                out.append(piece)
            } else {
                out.append(contentsOf: hardWrap(piece, maxLength: maxLength))
            }
        }
        return out.filter(isSpeakable)
    }

    /// Worth speaking? True only when the chunk holds at least two letters —
    /// drops leftovers like "→ 5 / 5", lone numbers or stray punctuation that a
    /// voice would either skip or stumble on.
    public static func isSpeakable(_ s: String) -> Bool {
        s.filter(\.isLetter).count >= 2
    }

    /// Break after `.`, `!`, `?`, `…` (and ellipsis) when followed by space.
    private static func splitOnEnders(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        let enders: Set<Character> = [".", "!", "?", "…"]
        let chars = Array(text)
        for (i, ch) in chars.enumerated() {
            current.append(ch)
            if enders.contains(ch) {
                let next = i + 1 < chars.count ? chars[i + 1] : " "
                if next == " " {
                    result.append(current)
                    current = ""
                }
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Split an over-long sentence on the last comma/space before the limit, so
    /// no chunk exceeds `maxLength` while still breaking at a natural pause.
    private static func hardWrap(_ sentence: String, maxLength: Int) -> [String] {
        var pieces: [String] = []
        var rest = Substring(sentence)
        while rest.count > maxLength {
            let window = rest.prefix(maxLength)
            let breakIndex = window.lastIndex(of: ",")
                ?? window.lastIndex(of: " ")
                ?? window.index(before: window.endIndex)
            let cut = rest.index(after: breakIndex)
            pieces.append(rest[..<cut].trimmingCharacters(in: .whitespaces))
            rest = rest[cut...]
        }
        let tail = rest.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { pieces.append(tail) }
        return pieces.filter { !$0.isEmpty }
    }

    // MARK: - Regex helper

    private static func replacing(_ s: String, _ pattern: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(location: 0, length: (s as NSString).length)
        return re.stringByReplacingMatches(in: s, range: range, withTemplate: template)
    }

    /// Drop emoji and pictographic symbols — they're decorative and the voice
    /// only stumbles on them. Keeps letters (incl. accents), digits, punctuation.
    private static func stripSymbols(_ s: String) -> String {
        var view = String.UnicodeScalarView()
        for sc in s.unicodeScalars {
            if sc.properties.generalCategory == .otherSymbol { continue }
            switch sc.value {
            case 0x1F000...0x1FAFF,   // emoji & pictographs
                 0x2600...0x27BF,     // misc symbols, dingbats
                 0x2B00...0x2BFF,     // arrows, stars
                 0xFE00...0xFE0F,     // variation selectors
                 0x200D:              // zero-width joiner
                continue
            default:
                view.append(sc)
            }
        }
        return String(view)
    }
}
