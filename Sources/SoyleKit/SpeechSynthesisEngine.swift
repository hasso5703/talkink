import Foundation
import MLX
import MLXAudioTTS

// MARK: - Voice catalog

/// One selectable Kokoro voice. `id` is the Kokoro voice name (its first letter
/// encodes the language); `language` is the explicit G2P code we pass so French
/// never has to be guessed from the prefix. Persisted by `id`.
public struct TTSVoiceOption: Identifiable, Sendable, Equatable, Hashable {
    public let id: String          // Kokoro voice, e.g. "ff_siwis"
    public let language: String?   // explicit lexicon/G2P code, e.g. "fr" (nil = auto)
    public let displayName: String
    public let flag: String

    public init(id: String, language: String?, displayName: String, flag: String) {
        self.id = id
        self.language = language
        self.displayName = displayName
        self.flag = flag
    }
}

/// The one TTS model we ship (Kokoro 82M, Apache-2.0, native French) and its
/// voices. A single model serves every voice — only `voice`/`language` change
/// per call — so unlike the ASR catalog there is nothing to download per voice.
public enum TTSCatalog {
    /// MLX-quantised Kokoro. Same repo the mlx-audio-swift Kokoro loader expects.
    public static let modelRepo = "mlx-community/Kokoro-82M-bf16"
    /// On-disk size of the weights, for the download pre-flight / progress copy.
    public static let modelSizeGB = 0.33

    public static let voices: [TTSVoiceOption] = [
        .init(id: "ff_siwis",  language: "fr",    displayName: "French · Siwis",      flag: "🇫🇷"),
        .init(id: "af_heart",  language: "en-us", displayName: "English · Heart",     flag: "🇺🇸"),
        .init(id: "am_michael", language: "en-us", displayName: "English · Michael",  flag: "🇺🇸"),
        .init(id: "bf_emma",   language: "en-gb", displayName: "British · Emma",      flag: "🇬🇧"),
    ]

    /// French is the default — this is built for reading Claude Code in French.
    public static let `default` = voices[0]

    public static func voice(forID id: String) -> TTSVoiceOption? {
        voices.first { $0.id == id }
    }
}

public enum SpeechSynthesisError: Error, LocalizedError {
    case modelNotLoaded
    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded: return "The speech model isn't loaded yet."
        }
    }
}

// MARK: - Engine

/// Loads Kokoro once and turns text into 24 kHz mono Float samples. Deliberately
/// a sibling of `TranscriptionEngine`, with its **own** `NSLock` — the ASR and
/// TTS engines share no lock, so transcription and reading never block each
/// other and can run together. `generate` is async (the model resolves its
/// language lexicon on demand), so callers serialise themselves by driving one
/// synthesis at a time (the `SpeechPlayer` pipeline does exactly that).
public final class SpeechSynthesisEngine: @unchecked Sendable {
    private let repo: String
    private var model: (any SpeechGenerationModel)?
    private let lock = NSLock()   // guards `model` only

    /// Called on the main actor with 0…1 progress while the model downloads
    /// (first run only). Not called when the cache is already warm.
    public var onDownloadProgress: (@MainActor @Sendable (Double) -> Void)?

    public init(repo: String = TTSCatalog.modelRepo) {
        self.repo = repo
    }

    public var isLoaded: Bool {
        lock.lock(); defer { lock.unlock() }
        return model != nil
    }

    /// 24 kHz for Kokoro; the default keeps callers safe before `load()`.
    public var sampleRate: Int {
        lock.lock(); defer { lock.unlock() }
        return model?.sampleRate ?? 24_000
    }

    /// Download (first run) + load weights. Idempotent; safe to call again.
    public func load() async throws {
        if isLoaded { return }
        try await predownloadReportingProgress()
        await ensureVoicesDownloaded()
        // espeak-ng G2P for French (matches what Kokoro was trained on); falls
        // back to the bundled lexicon processor when espeak isn't present.
        let loaded = try await TTS.loadModel(modelRepo: repo, textProcessor: EspeakG2PProcessor())
        lock.lock(); if model == nil { model = loaded }; lock.unlock()
    }

    /// Kokoro keeps each voice as a small embedding file under `voices/` in the
    /// repo. The mlx-audio cache check only validates the root weights and skips
    /// the snapshot once they exist, so those per-voice files can be missing —
    /// fetch the ones we offer directly (a few hundred KB each). Best-effort: a
    /// voice that fails to download simply isn't selectable until the next load.
    private func ensureVoicesDownloaded() async {
        let voicesDir = ModelDownloader.modelDirectory(forRepo: repo)
            .appendingPathComponent("voices")
        try? FileManager.default.createDirectory(at: voicesDir, withIntermediateDirectories: true)
        let token = ProcessInfo.processInfo.environment["HF_TOKEN"]
        for voice in TTSCatalog.voices {
            let dest = voicesDir.appendingPathComponent("\(voice.id).safetensors")
            if FileManager.default.fileExists(atPath: dest.path) { continue }
            guard let url = URL(string:
                "https://huggingface.co/\(repo)/resolve/main/voices/\(voice.id).safetensors")
            else { continue }
            var request = URLRequest(url: url)
            if let token, !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { continue }
                try data.write(to: dest)
            } catch {
                Log.download.error("voice \(voice.id, privacy: .public) download failed (\(error.localizedDescription, privacy: .public))")
            }
        }
    }

    /// Pre-warm the same cache `TTS.loadModel` reads from with our resumable
    /// downloader (the loader has no progress hook). No-op when already cached;
    /// a downloader failure never blocks loading — the library path takes over.
    private func predownloadReportingProgress() async throws {
        if ModelDownloader.isCached(repo: repo) { return }
        let handler = onDownloadProgress
        do {
            try await ModelDownloader.download(repo: repo) { fraction in
                guard let handler else { return }
                Task { @MainActor in handler(fraction) }
            }
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            Log.download.error("TTS model download failed (\(error.localizedDescription, privacy: .public)) — falling back to library download")
        }
        try Task.checkCancellation()
    }

    private func currentModel() -> (any SpeechGenerationModel)? {
        lock.lock(); defer { lock.unlock() }
        return model
    }

    /// Synthesise one chunk to 24 kHz mono Float samples. Empty in → empty out.
    public func synthesize(text: String, voice: String, language: String?) async throws -> [Float] {
        guard let model = currentModel() else { throw SpeechSynthesisError.modelNotLoaded }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let audio = try await model.generate(
            text: trimmed,
            voice: voice,
            refAudio: nil,
            refText: nil,
            language: language
        )
        return audio.asArray(Float.self)
    }

    /// Compile the Metal pipeline and load the language lexicon ahead of the
    /// first real block, so a conversation never stalls on cold start. Cheap
    /// after the first call (lexicon stays in memory).
    public func warmUp(voice: String, language: String?) async {
        do {
            _ = try await synthesize(text: "Bonjour.", voice: voice, language: language)
        } catch {
            Log.tts.error("TTS warm-up failed (\(error.localizedDescription, privacy: .public))")
        }
    }

    /// Drop the model and hand MLX's Metal buffers back to the OS — called when
    /// the feature is switched off so we don't keep ~0.3 GB resident for nothing.
    public func unload() {
        lock.lock(); model = nil; lock.unlock()
        DispatchQueue.global(qos: .utility).async { Memory.clearCache() }
    }
}
