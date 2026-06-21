import XCTest
@testable import SoyleKit

/// Pure-logic tests for the Markdown→speech cleaner and sentence splitter that
/// feed the Claude Code reader. No model, no audio — runs anywhere.
final class SpeechTextTests: XCTestCase {

    // MARK: clean

    func testStripsFencedCodeBlocks() {
        let s = SpeechText.clean("Voici le code :\n```swift\nlet x = 1\n```\nVoilà.")
        XCTAssertFalse(s.contains("let x"))
        XCTAssertTrue(s.contains("Voici le code"))
        XCTAssertTrue(s.contains("Voilà"))
    }

    func testKeepsShortInlineCodeButDropsPaths() {
        XCTAssertEqual(SpeechText.clean("Lance `preset` maintenant."), "Lance preset maintenant.")
        let withPath = SpeechText.clean("Le fichier `~/.claude/tts/x.py` est là.")
        XCTAssertFalse(withPath.contains(".py"))
        XCTAssertFalse(withPath.contains("/"))
        XCTAssertTrue(withPath.contains("Le fichier"))
        XCTAssertTrue(withPath.contains("est là"))
    }

    func testLinksBecomeTextAndUrlsGo() {
        XCTAssertEqual(SpeechText.clean("Voir [la doc](https://x.com/y) ici."), "Voir la doc ici.")
        let bare = SpeechText.clean("Va sur https://example.com/page voir.")
        XCTAssertFalse(bare.contains("http"))
        XCTAssertTrue(bare.contains("Va sur"))
    }

    func testEmphasisAndHeadersRemoved() {
        let s = SpeechText.clean("# Titre\nUn **mot** _en italique_.")
        XCTAssertFalse(s.contains("#"))
        XCTAssertFalse(s.contains("*"))
        XCTAssertFalse(s.contains("_"))
        XCTAssertTrue(s.contains("Titre"))
        XCTAssertTrue(s.contains("mot"))
        XCTAssertTrue(s.contains("en italique"))
    }

    func testStripsEmojiAndSymbols() {
        let s = SpeechText.clean("C'est fait ✅ et poussé 🚀 sur GitHub 🎯.")
        XCTAssertFalse(s.unicodeScalars.contains { $0.properties.generalCategory == .otherSymbol })
        XCTAssertTrue(s.contains("C'est fait"))
        XCTAssertTrue(s.contains("GitHub"))
        XCTAssertFalse(s.contains("✅"))
    }

    // MARK: sentences

    func testSplitsOnSentenceEnders() {
        let out = SpeechText.sentences("Phrase une. Phrase deux ! Phrase trois ?")
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out.first, "Phrase une.")
    }

    func testDecimalIsNotASentenceBoundary() {
        // No space after the dot in "3.14" → it must stay one sentence.
        XCTAssertEqual(SpeechText.sentences("La valeur est 3.14 environ.").count, 1)
    }

    func testHardWrapsOverlongSentence() {
        let long = Array(repeating: "mot", count: 100).joined(separator: " ") + "."
        let out = SpeechText.sentences(long, maxLength: 80)
        XCTAssertGreaterThan(out.count, 1)
        XCTAssertTrue(out.allSatisfy { $0.count <= 80 }, "every chunk respects the limit")
    }

    func testEmptyAndBlankYieldNothing() {
        XCTAssertTrue(SpeechText.sentences("").isEmpty)
        XCTAssertTrue(SpeechText.sentences("   \n  ").isEmpty)
    }
}
