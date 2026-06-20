import Foundation
import MLX
import MLXAudioSTT
import MLXAudioCore

// MARK: - Model catalog

public enum ASREngine: String, Sendable {
    case nemotron, qwen3, voxtral
}

/// One selectable ASR model. `id` is the Hugging Face repo and is what gets
/// persisted in user defaults (legacy installs stored Nemotron repo ids, which
/// are present in the catalog — so old settings migrate for free).
public struct ASRModelOption: Identifiable, Sendable, Equatable, Hashable {
    public let id: String
    public let engine: ASREngine
    public let family: String
    public let variant: String
    public let sizeGB: Double
    public let quality: Int   // 1…5, from our own multilingual bench (2026-06)
    public let speed: Int     // 1…5, measured on Apple Silicon
    public let note: String

    public var displayName: String { "\(family) · \(variant)" }
    public var sizeLabel: String {
        sizeGB >= 1 ? String(format: "%.1f GB", sizeGB)
                    : String(format: "%.0f MB", sizeGB * 1000)
    }
}

/// Sizes are the real safetensors weights on Hugging Face (checked 2026-06).
/// Quality/speed ratings come from our own benchmark (TTS corpus FR/EN/TR,
/// exact ground truth, M-series hardware) — not from marketing.
public enum ASRCatalog {
    public static let options: [ASRModelOption] = [
        .init(id: "mlx-community/Qwen3-ASR-1.7B-8bit", engine: .qwen3,
              family: "Qwen3-ASR 1.7B", variant: "8-bit", sizeGB: 2.46,
              quality: 5, speed: 3,
              note: "Best quality, 30 languages. Matched full precision in our tests, at half the size. Recommended."),
        .init(id: "mlx-community/Qwen3-ASR-1.7B-bf16", engine: .qwen3,
              family: "Qwen3-ASR 1.7B", variant: "bf16", sizeGB: 4.08,
              quality: 5, speed: 2,
              note: "Full 16-bit precision, measured no better than 8-bit, just heavier and slower."),
        .init(id: "mlx-community/Qwen3-ASR-0.6B-8bit", engine: .qwen3,
              family: "Qwen3-ASR 0.6B", variant: "8-bit", sizeGB: 1.01,
              quality: 4, speed: 5,
              note: "Fast and accurate, the best balance under 1 GB."),
        .init(id: "mlx-community/Qwen3-ASR-0.6B-bf16", engine: .qwen3,
              family: "Qwen3-ASR 0.6B", variant: "bf16", sizeGB: 1.56,
              quality: 4, speed: 4,
              note: "Same model at full precision, minor gains, slower."),
        .init(id: "mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit", engine: .nemotron,
              family: "Nemotron 3.5", variant: "8-bit", sizeGB: 0.76,
              quality: 3, speed: 5,
              note: "Lightest and fastest, trades a little accuracy."),
        .init(id: "mlx-community/nemotron-3.5-asr-streaming-0.6b", engine: .nemotron,
              family: "Nemotron 3.5", variant: "bf16", sizeGB: 1.28,
              quality: 3, speed: 5,
              note: "Same model at full precision, measured identical to 8-bit."),
        .init(id: "mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit", engine: .voxtral,
              family: "Voxtral Mini 4B", variant: "4-bit", sizeGB: 3.13,
              quality: 4, speed: 1,
              note: "13 languages, always auto-detected; slow on long sentences."),
    ]

    public static let `default` = options[0]

    public static func option(forID id: String) -> ASRModelOption? {
        options.first { $0.id == id }
    }
}

// MARK: - Results & errors

/// Result of one transcription.
public struct SoyleTranscription: Sendable {
    public let text: String
    public let language: String?
    public let audioSeconds: Double
    public let inferSeconds: Double
    public var realtimeFactor: Double { inferSeconds > 0 ? audioSeconds / inferSeconds : 0 }
}

public enum SoyleError: Error, LocalizedError {
    case modelNotLoaded
    case audioLoadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded: return "The model isn't loaded yet."
        case .audioLoadFailed(let p): return "Audio loading failed: \(p)"
        }
    }
}

// MARK: - Engine

/// Loads one model from the catalog and transcribes 16 kHz mono audio. All
/// engines share the `STTGenerationModel` interface. Call `load()` (async)
/// before transcribing; transcribe is safe from a background queue (MLX
/// inference is serialized internally).
public final class TranscriptionEngine: @unchecked Sendable {
    public private(set) var model: ASRModelOption
    private var asr: (any STTGenerationModel)?
    private let lock = NSLock()
    private let inferLock = NSLock()   // serialize MLX inference (warmUp vs transcribe must not overlap)

    /// Called on the main actor with 0…1 progress while the model downloads
    /// (first run). Not called when the cache is already warm.
    public var onDownloadProgress: (@MainActor @Sendable (Double) -> Void)?

    public init(model: ASRModelOption = ASRCatalog.default) {
        self.model = model
    }

    public var isLoaded: Bool {
        lock.lock(); defer { lock.unlock() }
        return asr != nil
    }

    /// Download (first run) + load weights into memory. Idempotent per model.
    public func load() async throws {
        if isLoaded { return }
        let target = currentTargetModel()
        try await predownloadReportingProgress(target)
        let loaded: any STTGenerationModel
        switch target.engine {
        case .nemotron: loaded = try await NemotronASRModel.fromPretrained(target.id)
        case .qwen3:    loaded = try await Qwen3ASRModel.fromPretrained(target.id)
        case .voxtral:  loaded = try await VoxtralRealtimeModel.fromPretrained(target.id)
        }
        install(loaded, ifStillTargeting: target)
    }

    /// Resolve (download on first run) the weights with progress — the
    /// `fromPretrained` entry points have no progress hook and no resume, so we
    /// pre-warm the same cache they read from with our resumable downloader.
    /// No-op cost when already cached. A downloader failure never blocks
    /// loading: `fromPretrained` falls back to the library download path.
    private func predownloadReportingProgress(_ target: ASRModelOption) async throws {
        if ModelDownloader.isCached(repo: target.id) { return }
        let handler = onDownloadProgress
        do {
            try await ModelDownloader.download(repo: target.id) { [weak self] fraction in
                // A switchModel() may have raced us — never report a stale
                // model's progress as the current one's.
                guard let self, self.currentTargetModel() == target, let handler else { return }
                Task { @MainActor in handler(fraction) }
            }
        } catch {
            // URLSession surfaces task cancellation as URLError.cancelled.
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            Log.download.error("resumable download failed (\(error.localizedDescription, privacy: .public)) — falling back to library download")
        }
        try Task.checkCancellation()
    }

    private func currentTargetModel() -> ASRModelOption {
        lock.lock(); defer { lock.unlock() }
        return model
    }

    private func install(_ loaded: any STTGenerationModel, ifStillTargeting target: ASRModelOption) {
        lock.lock(); defer { lock.unlock() }
        // A switchModel() may have raced this load — never install stale weights.
        if model == target { asr = loaded }
    }

    /// Run a tiny dummy inference to compile/warm the Metal pipeline, so the
    /// first real transcription isn't penalised by shader warm-up.
    public func warmUp() {
        guard let asr = currentModel() else { return }
        let silence = [Float](repeating: 0, count: 8_000) // 0.5s @ 16kHz
        inferLock.lock(); defer { inferLock.unlock() }
        _ = asr.generate(audio: MLXArray(silence), generationParameters: STTGenerateParameters(language: nil))
    }

    /// Switch model weights; the new weights load on the next `load()`.
    /// The old model is released immediately: dropping the last reference
    /// returns its MLXArrays to MLX's Metal buffer cache, and `clearCache()`
    /// hands that memory back to the OS — otherwise a 1.7B→0.6B switch would
    /// keep gigabytes resident (verified against mlx-swift's Memory API).
    public func switchModel(to newModel: ASRModelOption) {
        guard newModel != model else { return }
        lock.lock(); model = newModel; asr = nil; lock.unlock()
        releaseMLXCacheSoon()
    }

    /// Return MLX's cached Metal buffers to the OS, off the calling thread.
    /// Serialized with inference: an in-flight generate() holds its own
    /// reference to the old weights for up to seconds, so we wait for it —
    /// otherwise those buffers would just re-enter the cache after the clear.
    private func releaseMLXCacheSoon() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            self.inferLock.lock(); defer { self.inferLock.unlock() }
            Memory.clearCache()
        }
    }

    private func currentModel() -> (any STTGenerationModel)? {
        lock.lock(); defer { lock.unlock() }
        return asr
    }

    /// Transcribe an audio file (any format/rate — resampled to 16 kHz mono).
    /// `language` is a BCP-47 prompt key ("en-US", "fr-FR") or nil for auto.
    public func transcribe(fileURL: URL, language: String?) throws -> SoyleTranscription {
        guard let asr = currentModel() else { throw SoyleError.modelNotLoaded }
        let sr: Int
        let audio: MLXArray
        do {
            (sr, audio) = try loadAudioArray(from: fileURL, sampleRate: 16_000)
        } catch {
            throw SoyleError.audioLoadFailed(fileURL.path)
        }
        return run(asr: asr, audio: audio, sampleRate: sr, language: language)
    }

    /// Transcribe in-memory float samples already at 16 kHz mono.
    public func transcribe(samples: [Float], language: String?) throws -> SoyleTranscription {
        guard let asr = currentModel() else { throw SoyleError.modelNotLoaded }
        return run(asr: asr, audio: MLXArray(samples), sampleRate: 16_000, language: language)
    }

    /// Each engine wants the language in a different shape (verified against
    /// the lib + real model configs, 2026-06):
    /// - Nemotron: BCP-47 keys from its prompt_dictionary — all our languages
    ///   exist except Arabic, which is only listed as "ar"/"ar-AR".
    /// - Qwen3: full English names matched against config.supportLanguages;
    ///   anything else lands verbatim (malformed) in the decoder prompt.
    /// - Voxtral: ignores the parameter entirely (always auto-detects).
    private func engineLanguage(_ bcp47: String?) -> String? {
        Self.engineLanguage(bcp47, for: currentTargetModel().engine)
    }

    /// Static and side-effect-free so tests can pin every engine's mapping.
    public static func engineLanguage(_ bcp47: String?, for engine: ASREngine) -> String? {
        guard let bcp47 else { return nil }
        switch engine {
        case .nemotron:
            return bcp47 == "ar-SA" ? "ar" : bcp47
        case .qwen3:
            return qwenLanguageNames[String(bcp47.prefix(2)).lowercased()]
        case .voxtral:
            return nil
        }
    }

    /// Short code → the exact names in Qwen3's config.supportLanguages.
    private static let qwenLanguageNames: [String: String] = [
        "fr": "French", "en": "English", "de": "German", "es": "Spanish",
        "it": "Italian", "pt": "Portuguese", "tr": "Turkish", "ar": "Arabic",
        "nl": "Dutch", "zh": "Chinese", "cs": "Czech", "da": "Danish",
        "fi": "Finnish", "el": "Greek", "hi": "Hindi", "hu": "Hungarian",
        "id": "Indonesian", "ja": "Japanese", "ko": "Korean", "ms": "Malay",
        "fa": "Persian", "pl": "Polish", "ro": "Romanian", "ru": "Russian",
        "sv": "Swedish", "th": "Thai", "vi": "Vietnamese",
    ]

    private func run(asr: any STTGenerationModel, audio: MLXArray, sampleRate: Int, language: String?) -> SoyleTranscription {
        let frames = audio.shape.first ?? 0
        let duration = Double(frames) / Double(sampleRate)
        // Nothing meaningful to transcribe in < 0.1s — avoids feeding a near-empty
        // array into the models (untested edge in generate()).
        guard frames >= 1_600 else {
            return SoyleTranscription(text: "", language: language, audioSeconds: duration, inferSeconds: 0)
        }
        let params = STTGenerateParameters(language: engineLanguage(language))
        let t0 = CFAbsoluteTimeGetCurrent()
        inferLock.lock()
        let out = asr.generate(audio: audio, generationParameters: params)
        inferLock.unlock()
        let infer = CFAbsoluteTimeGetCurrent() - t0
        return SoyleTranscription(
            text: out.text.trimmingCharacters(in: .whitespacesAndNewlines),
            language: language,
            audioSeconds: duration,
            inferSeconds: infer
        )
    }
}
