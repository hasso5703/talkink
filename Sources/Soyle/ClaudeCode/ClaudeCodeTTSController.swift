import Foundation
import SoyleKit

/// Owns the native "read Claude Code aloud" feature and its lifecycle: the
/// Kokoro synthesis engine, the audio player, and the transcript reader. Turning
/// it on loads the model (downloading on first run, with progress), warms it up,
/// then starts tailing; turning it off stops everything and frees the weights.
///
/// `@MainActor`, so enable / disable / load completion are serialised on one
/// actor — there is no window where a half-finished load can race a disable.
/// It is wholly independent of the ASR path (its own engine, player and audio
/// engine), so dictation keeps working while Claude Code is being read.
@MainActor
final class ClaudeCodeTTSController {

    enum Status: Equatable {
        case off
        case unavailable                 // Claude Code isn't installed
        case loading(progress: Int?)     // downloading/loading the voice model
        case on
        case failed(String)
    }

    private let settings: SettingsStore
    private let synth = SpeechSynthesisEngine()
    private let player: SpeechPlayer
    private let reader: ClaudeCodeReader
    private var loadTask: Task<Void, Never>?

    /// Fired on every status change so the menu can refresh.
    var onStatusChange: (() -> Void)?
    private(set) var status: Status = .off {
        didSet { if oldValue != status { onStatusChange?() } }
    }

    init(settings: SettingsStore) {
        self.settings = settings
        let voice = TTSCatalog.voice(forID: settings.claudeCodeTTSVoice) ?? TTSCatalog.default
        self.player = SpeechPlayer(synth: synth, voice: voice.id, language: voice.language)
        self.reader = ClaudeCodeReader(player: player)
        synth.onDownloadProgress = { [weak self] fraction in
            // @MainActor closure (the engine hops here for us).
            guard let self, case .loading = self.status else { return }
            self.status = .loading(progress: min(99, Int(fraction * 100)))
        }
    }

    /// Whether Claude Code is installed on this machine (re-checked live).
    var isAvailable: Bool { ClaudeCodeDetector.isInstalled() }

    /// Apply the persisted preference at launch.
    func applyInitialState() {
        if settings.claudeCodeTTSEnabled { enable() }
    }

    func setEnabled(_ on: Bool) {
        on ? enable() : disable()
    }

    func setVoice(_ id: String) {
        guard let voice = TTSCatalog.voice(forID: id) else { return }
        settings.claudeCodeTTSVoice = id
        player.setVoice(voice.id, language: voice.language)
    }

    // MARK: - Enable / disable

    private func enable() {
        guard isAvailable else { status = .unavailable; return }
        guard loadTask == nil, status != .on else { return }
        status = .loading(progress: nil)
        let voice = TTSCatalog.voice(forID: settings.claudeCodeTTSVoice) ?? TTSCatalog.default
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.synth.load()
                await self.synth.warmUp(voice: voice.id, language: voice.language)
                if Task.isCancelled { return }
                self.player.setVoice(voice.id, language: voice.language)
                self.reader.start()
                self.status = .on
            } catch is CancellationError {
                // Disabled mid-load — disable() already reset the state.
            } catch {
                ErrorLog.shared.record(component: "tts",
                                       message: "Claude Code reading failed to start",
                                       detail: error.localizedDescription)
                self.status = .failed(Self.friendly(error))
            }
            self.loadTask = nil
        }
    }

    private func disable() {
        loadTask?.cancel()
        loadTask = nil
        reader.stop()
        player.shutdown()
        synth.unload()
        status = .off
    }

    private static func friendly(_ error: Error) -> String {
        if (error as? URLError) != nil { return "couldn't download the voice (offline?)" }
        return error.localizedDescription
    }
}
