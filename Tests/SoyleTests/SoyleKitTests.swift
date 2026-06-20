import XCTest
@testable import SoyleKit

// MARK: - Catalog

final class ASRCatalogTests: XCTestCase {
    func testCatalogShapeAndInvariants() {
        let options = ASRCatalog.options
        XCTAssertEqual(options.count, 7)
        XCTAssertEqual(Set(options.map(\.id)).count, options.count, "repo ids must be unique")
        for option in options {
            XCTAssertTrue(option.id.contains("/"), "\(option.id) must be a HF repo id")
            XCTAssertGreaterThan(option.sizeGB, 0)
            XCTAssertLessThan(option.sizeGB, 10)
            XCTAssertTrue((1...5).contains(option.quality), "\(option.id) quality out of range")
            XCTAssertTrue((1...5).contains(option.speed), "\(option.id) speed out of range")
            XCTAssertFalse(option.note.isEmpty)
            XCTAssertEqual(ASRCatalog.option(forID: option.id), option)
        }
    }

    func testDefaultIsTheBenchWinner() {
        XCTAssertEqual(ASRCatalog.default.id, "mlx-community/Qwen3-ASR-1.7B-8bit")
        XCTAssertEqual(ASRCatalog.default, ASRCatalog.options[0])
    }

    func testUnknownIDFallsThrough() {
        XCTAssertNil(ASRCatalog.option(forID: "nope/never-existed"))
    }

    func testSizeLabelUnits() {
        XCTAssertEqual(ASRCatalog.default.sizeLabel, "2.5 GB")
        let nemotron = ASRCatalog.option(forID: "mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit")!
        XCTAssertEqual(nemotron.sizeLabel, "760 MB")
    }
}

// MARK: - Per-engine language mapping

final class EngineLanguageTests: XCTestCase {
    func testNilStaysAutoEverywhere() {
        for engine in [ASREngine.nemotron, .qwen3, .voxtral] {
            XCTAssertNil(TranscriptionEngine.engineLanguage(nil, for: engine))
        }
    }

    func testNemotronKeepsBCP47ExceptArabic() {
        XCTAssertEqual(TranscriptionEngine.engineLanguage("fr-FR", for: .nemotron), "fr-FR")
        XCTAssertEqual(TranscriptionEngine.engineLanguage("en-US", for: .nemotron), "en-US")
        // "ar-SA" is absent from the model's prompt_dictionary — only "ar" exists.
        XCTAssertEqual(TranscriptionEngine.engineLanguage("ar-SA", for: .nemotron), "ar")
    }

    func testQwenMapsToEnglishNames() {
        XCTAssertEqual(TranscriptionEngine.engineLanguage("fr-FR", for: .qwen3), "French")
        XCTAssertEqual(TranscriptionEngine.engineLanguage("tr-TR", for: .qwen3), "Turkish")
        XCTAssertEqual(TranscriptionEngine.engineLanguage("zh-CN", for: .qwen3), "Chinese")
        XCTAssertEqual(TranscriptionEngine.engineLanguage("ar-SA", for: .qwen3), "Arabic")
    }

    func testQwenUnknownCodeFallsBackToAutoNotVerbatim() {
        // An unmapped code must NOT reach the decoder prompt malformed.
        XCTAssertNil(TranscriptionEngine.engineLanguage("xx-XX", for: .qwen3))
    }

    func testVoxtralAlwaysAutoDetects() {
        XCTAssertNil(TranscriptionEngine.engineLanguage("fr-FR", for: .voxtral))
        XCTAssertNil(TranscriptionEngine.engineLanguage("en-US", for: .voxtral))
    }
}

// MARK: - Speech detection (VAD)

final class SpeechStatsTests: XCTestCase {
    private func tone(seconds: Double, amplitude: (Double) -> Float, rate: Int = 16_000) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { i in
            let t = Double(i) / Double(rate)
            return sinf(Float(2 * Double.pi * 220 * t)) * amplitude(t)
        }
    }

    func testSilenceIsNotSpeech() {
        let stats = SpeechStats.analyze(samples: [Float](repeating: 0, count: 16_000))
        XCTAssertFalse(stats.likelySpeech)
        XCTAssertEqual(stats.activeSeconds, 0, accuracy: 0.001)
    }

    func testQuietRoomHissIsNotSpeech() {
        let stats = SpeechStats.analyze(samples: tone(seconds: 2) { _ in 0.002 })
        XCTAssertFalse(stats.likelySpeech, "electrical hiss must stay below the absolute floor")
    }

    func testSpeechBurstsAreSpeech() {
        // 2s alternating 0.5s "words" (amp 0.15) and pauses (amp 0.003) —
        // the shape of real push-to-talk speech.
        let samples = tone(seconds: 2) { t in Int(t * 2) % 2 == 0 ? 0.15 : 0.003 }
        let stats = SpeechStats.analyze(samples: samples)
        XCTAssertTrue(stats.likelySpeech)
        XCTAssertGreaterThan(stats.activeSeconds, 0.5)
    }

    func testConstantFanNoiseIsNotSpeech() {
        // Uniform loud-ish noise: no dynamics above the session's own floor.
        let stats = SpeechStats.analyze(samples: tone(seconds: 2) { _ in 0.05 })
        XCTAssertFalse(stats.likelySpeech)
    }

    func testSpeechOverFanNoiseIsSpeech() {
        let samples = tone(seconds: 2) { t in Int(t * 2) % 2 == 0 ? 0.3 : 0.05 }
        XCTAssertTrue(SpeechStats.analyze(samples: samples).likelySpeech)
    }

    func testTooShortIsNotSpeech() {
        XCTAssertFalse(SpeechStats.analyze(samples: tone(seconds: 0.1) { _ in 0.2 }).likelySpeech)
    }
}

// MARK: - Memory pre-flight

final class MemoryVerdictTests: XCTestCase {
    private func gb(_ value: Double) -> UInt64 { UInt64(value * 1_073_741_824) }

    func testRefusedWhenBeyondMetalWorkingSet() {
        let verdict = SystemResources.memoryVerdict(
            neededBytes: gb(10), physicalBytes: gb(8), availableBytes: gb(4), metalLimitBytes: gb(5.6))
        guard case .insufficient(let message) = verdict else { return XCTFail("expected insufficient, got \(verdict)") }
        XCTAssertTrue(message.contains("smaller model"))
    }

    func testRefusedWhenBeyondPhysicalRAM() {
        let verdict = SystemResources.memoryVerdict(
            neededBytes: gb(9), physicalBytes: gb(8), availableBytes: nil, metalLimitBytes: nil)
        guard case .insufficient = verdict else { return XCTFail("expected insufficient, got \(verdict)") }
    }

    func testTightWhenSystemIsUnderPressure() {
        let verdict = SystemResources.memoryVerdict(
            neededBytes: gb(4), physicalBytes: gb(16), availableBytes: gb(2), metalLimitBytes: gb(12))
        guard case .tight(let message) = verdict else { return XCTFail("expected tight, got \(verdict)") }
        XCTAssertTrue(message.contains("Closing other apps"))
    }

    func testOKOnRoomyMachine() {
        XCTAssertEqual(SystemResources.memoryVerdict(
            neededBytes: gb(3), physicalBytes: gb(16), availableBytes: gb(10), metalLimitBytes: gb(12)), .ok)
    }

    func testUnknownAvailableNeverBlocks() {
        XCTAssertEqual(SystemResources.memoryVerdict(
            neededBytes: gb(3), physicalBytes: gb(16), availableBytes: nil, metalLimitBytes: gb(12)), .ok)
    }

    func testRuntimeEstimateCoversWeightsPlusMargin() {
        let estimate = SystemResources.estimatedRuntimeBytes(forWeightsGB: 2.46)
        XCTAssertGreaterThan(estimate, gb(2.46), "estimate must exceed raw weights")
        XCTAssertLessThan(estimate, gb(5), "estimate must stay realistic")
    }

    func testDefaultModelFitsOnTheSmallestSupportedMac() {
        // 8 GB is the smallest Apple Silicon config — the DEFAULT model must
        // never be refused there (first launch must work).
        let needed = SystemResources.estimatedRuntimeBytes(forWeightsGB: ASRCatalog.default.sizeGB)
        let verdict = SystemResources.memoryVerdict(
            neededBytes: needed, physicalBytes: gb(8), availableBytes: nil, metalLimitBytes: gb(5.6))
        XCTAssertEqual(verdict, .ok)
    }
}

// MARK: - Disk pre-flight

final class DiskPreflightTests: XCTestCase {
    private func gb(_ value: Double) -> Int64 { Int64(value * 1_000_000_000) }

    func testRoomyVolumePasses() {
        // 5 GB free, needs 2 GB (+1 GB margin = 3 GB) → fits with room to spare.
        XCTAssertNil(SystemResources.diskPreflight(neededBytes: gb(2), freeBytes: gb(5)))
    }

    func testTooLittleSpaceIsRefused() {
        let verdict = SystemResources.diskPreflight(neededBytes: gb(4), freeBytes: gb(1))
        guard case .notEnoughDisk = verdict else {
            return XCTFail("expected notEnoughDisk, got \(String(describing: verdict))")
        }
    }

    func testMarginIsEnforcedNotJustRawSize() {
        // 4.5 GB free, needs exactly 4 GB: the raw size fits, but the 1 GB
        // safety margin does not → refuse rather than fill the volume to the rim.
        let verdict = SystemResources.diskPreflight(neededBytes: gb(4), freeBytes: gb(4) + gb(0.5))
        guard case .notEnoughDisk = verdict else { return XCTFail("margin must be enforced") }
    }

    func testMessageNamesDiskAndAvoidsEmDash() {
        let message = SystemResources.diskPreflight(neededBytes: gb(4), freeBytes: gb(1))?.errorDescription ?? ""
        XCTAssertTrue(message.lowercased().contains("disk"), message)
        XCTAssertFalse(message.contains("\u{2014}"), "user-facing copy must not use em-dashes")
    }
}

// MARK: - Downloader logic (no network)

final class ModelDownloaderLogicTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("soyle-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testEmptyDirectoryIsNotCached() throws {
        XCTAssertFalse(ModelDownloader.isCachedDirectory(try makeTempDir()))
    }

    func testZeroByteWeightsAreNotCached() throws {
        let dir = try makeTempDir()
        FileManager.default.createFile(atPath: dir.appendingPathComponent("model.safetensors").path, contents: nil)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))
        XCTAssertFalse(ModelDownloader.isCachedDirectory(dir))
    }

    func testMissingConfigIsNotCached() throws {
        let dir = try makeTempDir()
        try Data([0x01, 0x02]).write(to: dir.appendingPathComponent("model.safetensors"))
        XCTAssertFalse(ModelDownloader.isCachedDirectory(dir))
    }

    func testCorruptConfigIsNotCached() throws {
        let dir = try makeTempDir()
        try Data([0x01, 0x02]).write(to: dir.appendingPathComponent("model.safetensors"))
        try Data("{truncated".utf8).write(to: dir.appendingPathComponent("config.json"))
        XCTAssertFalse(ModelDownloader.isCachedDirectory(dir))
    }

    func testCompleteModelIsCached() throws {
        let dir = try makeTempDir()
        try Data([0x01, 0x02]).write(to: dir.appendingPathComponent("model.safetensors"))
        try Data("{\"ok\": true}".utf8).write(to: dir.appendingPathComponent("config.json"))
        XCTAssertTrue(ModelDownloader.isCachedDirectory(dir))
    }

    func testPartialFractionMath() {
        XCTAssertNil(ModelDownloader.partialFraction(onDisk: 0, expectedBytes: 1_000))
        XCTAssertNil(ModelDownloader.partialFraction(onDisk: 100, expectedBytes: 0))
        XCTAssertEqual(ModelDownloader.partialFraction(onDisk: 500, expectedBytes: 1_000), 0.5)
        // Never report 100% for a partial — the UI would lie.
        XCTAssertEqual(ModelDownloader.partialFraction(onDisk: 2_000, expectedBytes: 1_000), 0.99)
    }
}

// MARK: - Vocabulary (custom dictionary)

final class VocabularyTests: XCTestCase {
    private let talkink = VocabularyEntry(phrase: "Talkink", variants: ["Talking", "tall kink"])

    func testExactVariantIsReplacedCaseInsensitively() {
        XCTAssertEqual(Vocabulary.apply(entries: [talkink], to: "I love talking"), "I love Talkink")
        XCTAssertEqual(Vocabulary.apply(entries: [talkink], to: "Talking is great"), "Talkink is great")
    }

    func testMultiWordVariant() {
        XCTAssertEqual(Vocabulary.apply(entries: [talkink], to: "open tall kink now"), "open Talkink now")
    }

    func testWordBoundariesAreRespected() {
        // "talkings" must NOT match the "talking" variant.
        XCTAssertEqual(Vocabulary.apply(entries: [talkink], to: "talkings"), "talkings")
    }

    func testFuzzyFixesUnknownWordsOnly() {
        let unknownGate: (String) -> Bool = { _ in false }   // language knows nothing
        let entries = [VocabularyEntry(phrase: "Talkink")]
        XCTAssertEqual(Vocabulary.apply(entries: entries, to: "open Talkynk now", isKnownWord: unknownGate),
                       "open Talkink now")
    }

    func testFuzzyNeverTouchesRealWords() {
        // "Talkint" is 1 edit from "Talkink", but the language says it's a
        // real word — the gate must win.
        let knownGate: (String) -> Bool = { _ in true }
        let entries = [VocabularyEntry(phrase: "Talkink")]
        XCTAssertEqual(Vocabulary.apply(entries: entries, to: "Talkint", isKnownWord: knownGate), "Talkint")
    }

    func testFuzzyRequiresSameFirstLetterAndSmallDistance() {
        let gate: (String) -> Bool = { _ in false }
        let entries = [VocabularyEntry(phrase: "Talkink")]
        XCTAssertEqual(Vocabulary.apply(entries: entries, to: "Walkink", isKnownWord: gate), "Walkink",
                       "different first letter must not match")
        XCTAssertEqual(Vocabulary.apply(entries: entries, to: "Taxxxnk", isKnownWord: gate), "Taxxxnk",
                       "distance beyond the cap must not match")
    }

    func testFuzzySkipsShortWordsAndCanonicalForms() {
        let gate: (String) -> Bool = { _ in false }
        let entries = [VocabularyEntry(phrase: "Talkink")]
        XCTAssertEqual(Vocabulary.apply(entries: entries, to: "tak", isKnownWord: gate), "tak")
        XCTAssertEqual(Vocabulary.apply(entries: entries, to: "talkink rules", isKnownWord: gate), "talkink rules",
                       "already-canonical words (any case) are left alone")
    }

    func testPunctuationAndSpacingSurviveFuzzyPass() {
        let gate: (String) -> Bool = { _ in false }
        let entries = [VocabularyEntry(phrase: "Talkink")]
        XCTAssertEqual(Vocabulary.apply(entries: entries, to: "Hey, Talkynk! Right?", isKnownWord: gate),
                       "Hey, Talkink! Right?")
    }

    func testLevenshteinWithCap() {
        XCTAssertEqual(Vocabulary.levenshtein("talkink", "talkynk", cap: 2), 1)
        XCTAssertEqual(Vocabulary.levenshtein("abc", "abc", cap: 1), 0)
        XCTAssertGreaterThan(Vocabulary.levenshtein("abcdefg", "zzzzzzz", cap: 2), 2)
    }

    func testNoEntriesIsIdentity() {
        XCTAssertEqual(Vocabulary.apply(entries: [], to: "anything at all"), "anything at all")
    }

    func testPersistenceRoundTripAndNormalization() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("soyle-vocab-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let journal = ErrorLog(fileURL: dir.appendingPathComponent("errors.json"))

        let store = Vocabulary(directory: dir, errorLog: journal)
        store.add(VocabularyEntry(phrase: "  PostgreSQL ", variants: [" postgres ql ", "", "PostgreSQL"]))
        store.add(VocabularyEntry(phrase: "   ", variants: ["ignored"]))   // empty phrase → rejected

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].phrase, "PostgreSQL")
        XCTAssertEqual(store.entries[0].variants, ["postgres ql"], "blank + phrase-identical variants are dropped")

        let reloaded = Vocabulary(directory: dir, errorLog: journal)
        XCTAssertEqual(reloaded.entries, store.entries)

        var edited = store.entries[0]
        edited.variants = ["postgresql db"]
        store.update(edited)
        XCTAssertEqual(store.entries[0].variants, ["postgresql db"])
        store.remove(store.entries[0])
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testCorruptVocabularyIsPreserved() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("soyle-vocab-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try Data("nope".utf8).write(to: dir.appendingPathComponent("vocabulary.json"))

        let journal = ErrorLog(fileURL: dir.appendingPathComponent("errors.json"))
        let store = Vocabulary(directory: dir, errorLog: journal)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertNotNil(store.lastError)
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("vocabulary.corrupt-") }
        XCTAssertEqual(backups.count, 1)
    }
}

// MARK: - Error journal

final class ErrorLogTests: XCTestCase {
    private func makeTempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("soyle-errorlog-\(UUID().uuidString).json")
    }

    func testRecordPersistsAndReloads() {
        let url = makeTempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let log = ErrorLog(fileURL: url)
        log.record(component: "test", message: "boom", detail: "details here")
        log.waitForWrites()

        XCTAssertEqual(log.recent(1).first?.message, "boom")
        let reloaded = ErrorLog(fileURL: url)
        XCTAssertEqual(reloaded.recent(1).first?.message, "boom")
        XCTAssertEqual(reloaded.recent(1).first?.detail, "details here")
    }

    func testNewestFirstAndCapped() {
        let url = makeTempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let log = ErrorLog(fileURL: url)
        for i in 1...120 { log.record(component: "test", message: "entry \(i)") }
        log.waitForWrites()
        XCTAssertEqual(log.recent(1).first?.message, "entry 120")
        XCTAssertEqual(log.recent(200).count, 100, "journal must stay capped")
    }

    func testClearRemovesEverything() {
        let url = makeTempFile()
        let log = ErrorLog(fileURL: url)
        log.record(component: "test", message: "gone soon")
        log.clear()
        log.waitForWrites()
        XCTAssertTrue(log.recent().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
