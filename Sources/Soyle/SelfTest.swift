import Foundation
import AVFoundation
import SoyleKit
import MLX

/// Headless verification used by scripts/CI: loads the model and transcribes a
/// file inside the assembled .app, so we can confirm the bundled Metal library
/// and weights work WITHOUT needing the GUI, microphone or Input Monitoring.
/// Usage: Talkink.app/Contents/MacOS/Soyle --selftest AUDIO.wav
enum SelfTest {
    static func run(audioPath: String) -> Never {
        guard !audioPath.isEmpty else {
            FileHandle.standardError.write(Data("[selftest] missing audio path\n".utf8))
            exit(2)
        }
        let url = URL(fileURLWithPath: (audioPath as NSString).expandingTildeInPath)
        // Self-test pins the lightest model: its job is validating the bundled
        // Metal library + pipeline, not transcription quality.
        let nemotron8 = ASRCatalog.option(forID: "mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit")!
        let engine = TranscriptionEngine(model: nemotron8)
        final class LastPct: @unchecked Sendable { var value = -1 }
        let last = LastPct()
        engine.onDownloadProgress = { fraction in
            let pct = Int(fraction * 20) * 5   // 5% steps
            if pct != last.value {
                last.value = pct
                FileHandle.standardError.write(Data("[selftest] downloading model… \(pct)%\n".utf8))
            }
        }
        Task {
            do {
                try await engine.load()
                let r = try engine.transcribe(fileURL: url, language: nil)
                FileHandle.standardError.write(Data(String(
                    format: "[selftest] OK — audio=%.1fs infer=%.2fs %.0fx RT\n",
                    r.audioSeconds, r.inferSeconds, r.realtimeFactor).utf8))
                // Exact-variant vocabulary pass only (the fuzzy layer needs the
                // main-thread spell checker — exercised in the app, not here).
                let corrected = Vocabulary.shared.apply(to: r.text)
                if corrected != r.text {
                    FileHandle.standardError.write(Data("[selftest] vocabulary: \"\(r.text)\" → \"\(corrected)\"\n".utf8))
                }
                print(corrected)
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("[selftest] ERROR: \(error)\n".utf8))
                exit(1)
            }
        }
        // Park the main thread as the main-queue executor: the engine's
        // download-progress handler is @MainActor — a blocked main thread
        // (semaphore) would deadlock the whole load.
        dispatchMain()
    }

    /// Headless TTS check: loads Kokoro and synthesises a French phrase to a WAV,
    /// proving the native voice path (model + lexicon + iSTFT vocoder) works
    /// without the GUI or an audio device. Usage:
    ///   Soyle --ttstest ["some text"]   → writes /tmp/talkink_tts_test.wav
    static func runTTSTest(text: String) -> Never {
        let engine = SpeechSynthesisEngine()
        final class LastPct: @unchecked Sendable { var value = -1 }
        let last = LastPct()
        engine.onDownloadProgress = { fraction in
            let pct = Int(fraction * 20) * 5
            if pct != last.value {
                last.value = pct
                FileHandle.standardError.write(Data("[ttstest] downloading voice… \(pct)%\n".utf8))
            }
        }
        let voice = TTSCatalog.default   // French ff_siwis
        Task {
            do {
                try await engine.load()
                let t0 = CFAbsoluteTimeGetCurrent()
                let samples = try await engine.synthesize(text: text, voice: voice.id, language: voice.language)
                let infer = CFAbsoluteTimeGetCurrent() - t0
                let sr = engine.sampleRate
                guard !samples.isEmpty else {
                    FileHandle.standardError.write(Data("[ttstest] ERROR: empty audio\n".utf8))
                    exit(1)
                }
                let seconds = Double(samples.count) / Double(sr)
                let out = URL(fileURLWithPath: "/tmp/talkink_tts_test.wav")
                try writeWAV(samples: samples, sampleRate: sr, to: out)
                FileHandle.standardError.write(Data(String(
                    format: "[ttstest] OK — voice=%@ lang=%@ audio=%.2fs synth=%.2fs %.1fx RT sr=%d\n",
                    voice.id, voice.language ?? "auto", seconds, infer,
                    infer > 0 ? seconds / infer : 0, sr).utf8))
                print(out.path)
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("[ttstest] ERROR: \(error)\n".utf8))
                exit(1)
            }
        }
        dispatchMain()
    }

    private static func writeWAV(samples: [Float], sampleRate: Int, to url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: Double(sampleRate),
                                   channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                      frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress {
                buffer.floatChannelData![0].update(from: base, count: samples.count)
            }
        }
        try file.write(from: buffer)
    }

    /// Coexistence test: loads BOTH the ASR and TTS models in one process and
    /// runs transcription and synthesis concurrently, proving they share the GPU
    /// without a Metal/stream crash — i.e. dictation and reading-aloud can run at
    /// the same time. Usage: Soyle --cotest AUDIO.wav
    static func runCoexistenceTest(audioPath: String) -> Never {
        guard !audioPath.isEmpty else { note("[cotest] usage: --cotest AUDIO.wav"); exit(2) }
        let asr = TranscriptionEngine(
            model: ASRCatalog.option(forID: "mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit")!)
        let tts = SpeechSynthesisEngine()
        let url = URL(fileURLWithPath: (audioPath as NSString).expandingTildeInPath)
        Task {
            do {
                try await asr.load()
                try await tts.load()
                note("[cotest] both models loaded — running ASR + TTS concurrently…")
                async let ttsCount = ttsLoop(tts, rounds: 5)   // child task, runs in parallel
                let asrCount = try asrLoop(asr, url: url, rounds: 5)   // runs on this task
                let ttsOK = try await ttsCount
                note("[cotest] DONE — ASR \(asrCount)/5, TTS \(ttsOK)/5 — no crash = coexistence OK")
                exit((asrCount == 5 && ttsOK == 5) ? 0 : 1)
            } catch {
                note("[cotest] ERROR: \(error)")
                exit(1)
            }
        }
        dispatchMain()
    }

    private static func asrLoop(_ asr: TranscriptionEngine, url: URL, rounds: Int) throws -> Int {
        var ok = 0
        for i in 0..<rounds {
            let r = try asr.transcribe(fileURL: url, language: "fr-FR")
            note("[cotest]   ASR#\(i) \(Int(r.realtimeFactor))x RT")
            if !r.text.isEmpty { ok += 1 }
        }
        return ok
    }

    private static func ttsLoop(_ tts: SpeechSynthesisEngine, rounds: Int) async throws -> Int {
        let voice = TTSCatalog.default
        var ok = 0
        for i in 0..<rounds {
            let s = try await tts.synthesize(
                text: "Lecture et dictée en même temps, essai numéro \(i).",
                voice: voice.id, language: voice.language)
            note("[cotest]   TTS#\(i) \(s.count) samples")
            if !s.isEmpty { ok += 1 }
        }
        return ok
    }

    private static func note(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }

    /// Memory regression test: loads the biggest cached Qwen, switches to the
    /// smallest Nemotron, and proves the old weights actually left the process
    /// (MLX active memory + buffer cache + OS footprint). Guards the
    /// switchModel → clearCache contract.
    /// Usage: Talkink.app/Contents/MacOS/Soyle --memtest
    static func runMemTest() -> Never {
        func report(_ label: String) -> (active: Int, cache: Int) {
            let active = Memory.activeMemory
            let cache = Memory.cacheMemory
            FileHandle.standardError.write(Data(String(
                format: "[memtest] %@ — MLX active=%4d MB cache=%4d MB\n",
                label, active / 1_048_576, cache / 1_048_576).utf8))
            return (active, cache)
        }
        let big = ASRCatalog.option(forID: "mlx-community/Qwen3-ASR-1.7B-8bit")!
        let small = ASRCatalog.option(forID: "mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit")!
        let engine = TranscriptionEngine(model: big)
        Task {
            do {
                try await engine.load()
                engine.warmUp()
                let loaded = report("after loading \(big.displayName)")
                engine.switchModel(to: small)
                try await engine.load()
                engine.warmUp()
                // switchModel clears the MLX cache asynchronously — give it a beat.
                try await Task.sleep(nanoseconds: 1_500_000_000)
                let switched = report("after switching to \(small.displayName)")
                let releasedMB = (loaded.active - switched.active) / 1_048_576
                FileHandle.standardError.write(Data("[memtest] released \(releasedMB) MB of weights\n".utf8))
                // 1.7B-8bit weights ≈ 2.4 GB, nemotron ≈ 0.8 GB → at least ~1 GB
                // must have left MLX's active set, and the cache must be small.
                let ok = releasedMB > 1_000 && switched.cache < 500 * 1_048_576
                FileHandle.standardError.write(Data("[memtest] \(ok ? "OK" : "FAIL — old model still resident")\n".utf8))
                exit(ok ? 0 : 1)
            } catch {
                FileHandle.standardError.write(Data("[memtest] ERROR: \(error)\n".utf8))
                exit(1)
            }
        }
        dispatchMain()
    }

    /// Records ~1.2s from the default microphone and reports the sample count —
    /// proves capture works (incl. the audio-input entitlement on hardened
    /// runtime builds). Usage: Talkink.app/Contents/MacOS/Soyle --mictest
    static func runMicTest() -> Never {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        FileHandle.standardError.write(Data("[mictest] mic TCC status=\(status.rawValue) (3=authorized)\n".utf8))
        let recorder = Recorder()
        do {
            try recorder.start()
        } catch {
            FileHandle.standardError.write(Data("[mictest] ERROR starting capture: \(error)\n".utf8))
            exit(1)
        }
        Thread.sleep(forTimeInterval: 1.2)
        let samples = recorder.stop()
        let rms = samples.isEmpty ? 0 : (samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
        FileHandle.standardError.write(Data(String(
            format: "[mictest] captured %d samples (%.2fs @16kHz) rms=%.5f\n",
            samples.count, Double(samples.count) / 16_000, rms).utf8))
        exit(samples.count > 8_000 ? 0 : 1)
    }

#if SOYLE_DEVTOOLS
    /// Compares our RMS-based `SpeechStats` gate against Silero VAD on real
    /// audio files, so we can see where they agree and where Silero is better
    /// before swapping it into the hallucination guard.
    /// Usage: Talkink.app/Contents/MacOS/Soyle --vadtest FILE...
    static func runVADTest(paths: [String]) -> Never {
        func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
        func f(_ v: Double, _ d: Int = 2) -> String { String(format: "%.\(d)f", v) }
        guard !paths.isEmpty else { err("[vadtest] usage: --vadtest FILE..."); exit(2) }
        Task {
            do {
                err("[vadtest] loading Silero VAD (mlx-community/silero-vad)…")
                let vad = try await SileroSpeechDetector.load()
                err("[vadtest] ready — RMS SpeechStats vs Silero on \(paths.count) file(s):\n")
                var differ = 0
                for p in paths {
                    let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
                    let name = url.lastPathComponent
                    let samples: [Float]
                    do { samples = try AudioLoader.load16kMono(url: url) }
                    catch { err("  \(name): could not load (\(error))"); continue }
                    let rms = SpeechStats.analyze(samples: samples)
                    let sil = try vad.analyze(samples: samples)
                    if rms.likelySpeech != sil.likelySpeech { differ += 1 }
                    let flag = rms.likelySpeech == sil.likelySpeech ? "agree" : "DIFFER"
                    let rmsV = (rms.likelySpeech ? "SPEECH" : "silence").padding(toLength: 7, withPad: " ", startingAt: 0)
                    let silV = (sil.likelySpeech ? "SPEECH" : "silence").padding(toLength: 7, withPad: " ", startingAt: 0)
                    let row = name.padding(toLength: 22, withPad: " ", startingAt: 0)
                        + " " + f(rms.duration) + "s"
                        + " | RMS " + rmsV
                        + " (act " + f(rms.activeSeconds) + "s peak " + f(Double(rms.peakRMS), 3)
                        + " floor " + f(Double(rms.noiseFloor), 4) + ")"
                        + " | Silero " + silV
                        + " (" + String(sil.segments) + " seg, " + f(sil.speechSeconds) + "s)"
                        + " | " + flag
                    print(row)
                }
                err("\n[vadtest] done, \(differ) disagreement(s) RMS vs Silero")
                exit(0)
            } catch {
                err("[vadtest] ERROR: \(error)")
                exit(1)
            }
        }
        dispatchMain()
    }

    /// Replays the real delivery decision (speech gate, transcription, the
    /// hallucination guard's decide()) on audio files, mirroring the live
    /// dictation path without GUI/mic/clipboard. The best offline proxy for
    /// "what would the app actually do with this clip".
    /// Usage: Soyle [--lang fr-FR] --dictatetest FILE...
    static func runDictateTest(language: String?, modelID: String?, paths: [String]) -> Never {
        func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
        guard !paths.isEmpty else { err("[dictatetest] usage: --dictatetest FILE... [--lang CODE] [--model REPO_ID]"); exit(2) }
        let model: ASRModelOption
        if let modelID {
            guard let picked = ASRCatalog.option(forID: modelID) else {
                err("[dictatetest] unknown --model \(modelID). Options:")
                for o in ASRCatalog.options { err("    \(o.id)") }
                exit(2)
            }
            model = picked
        } else {
            model = SettingsStore.shared.modelOption
        }
        let engine = TranscriptionEngine(model: model)
        Task {
            do {
                err("[dictatetest] model: \(model.displayName) | forced language: \(language ?? "auto")")
                try await engine.load()
                engine.warmUp()
                let vad = try? await SileroSpeechDetector.load()
                err("[dictatetest] Silero VAD: \(vad == nil ? "UNAVAILABLE (RMS fallback)" : "loaded")\n")
                for p in paths {
                    let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
                    let name = url.lastPathComponent
                    let samples: [Float]
                    do { samples = try AudioLoader.load16kMono(url: url) }
                    catch { err("  \(name): could not load (\(error))"); continue }
                    let stats = SpeechStats.analyze(samples: samples)
                    let sil = vad.flatMap { try? $0.analyze(samples: samples) }
                    let gate = SpeechGate.resolve(silero: sil, rms: stats)
                    var result = try engine.transcribe(samples: samples, language: language)
                    var rescued = false
                    if result.text.isEmpty, language != nil, gate.hasSpeech {
                        let r = try engine.transcribe(samples: samples, language: nil)
                        if !r.text.isEmpty { result = r; rescued = true }
                    }
                    let corrected = Vocabulary.shared.apply(to: result.text)
                    let outcome: String
                    switch AppDelegate.decide(text: corrected, hasSpeech: gate.hasSpeech, forcedLanguage: language != nil) {
                    case .deliver(let t):  outcome = "DELIVER\(rescued ? " (rescued to auto)" : ""): \"\(t)\""
                    case .noSpeech(let d): outcome = "NO SPEECH, nothing pasted" + (d > 0 ? " (discarded \(d) hallucinated chars)" : "")
                    case .wrongLanguage:   outcome = "WRONG LANGUAGE, nothing pasted"
                    case .notRecognized:   outcome = "NOT RECOGNIZED, nothing pasted"
                    }
                    print(name.padding(toLength: 20, withPad: " ", startingAt: 0)
                          + " [gate \(gate.source.rawValue)/\(gate.hasSpeech ? "speech" : "silence")] -> " + outcome)
                }
                exit(0)
            } catch {
                err("[dictatetest] ERROR: \(error)")
                exit(1)
            }
        }
        dispatchMain()
    }
#endif
}
