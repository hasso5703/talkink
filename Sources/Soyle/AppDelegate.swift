import AppKit
import AVFoundation
import Combine
import SoyleKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    enum AppState: Equatable {
        case loadingModel(progress: Int?)   // percent while downloading (first run), nil while loading weights
        case ready
        case recording
        case transcribing
        case needsAccessibility
        case loadFailed(String)             // model load/download failed — reason stays visible in the menu
    }

    private let settings = SettingsStore.shared
    private let engine = TranscriptionEngine(model: SettingsStore.shared.modelOption)
    private let ptt = PushToTalk(key: SettingsStore.shared.pttKey)
    private let recorder = Recorder()
    private let overlay = OverlayController()
    private lazy var settingsWindowController = SettingsWindowController(settings: settings)
    /// Native "read Claude Code aloud" feature — fully independent of the ASR
    /// path above (own engine, player and audio engine), so the two coexist.
    /// Created in `applicationDidFinishLaunching` (the type is `@MainActor`).
    private var claudeCodeTTS: ClaudeCodeTTSController!

    private var statusItem: NSStatusItem!
    private var cancellables = Set<AnyCancellable>()
    private var armTimer: Timer?
    private var modelLoadFailed = false          // retry trigger (display lives in .loadFailed)
    private var lastLoadFailureReason: String?
    private var updateAvailableVersion: String?  // set by Sparkle → prominent menu item
    private var languageRescues = 0              // empty transcripts rescued by auto-detect
    private var loadTask: Task<Void, Never>?     // the one tracked selected-model load
    private var silero: SileroSpeechDetector?    // Silero VAD; nil falls back to RMS
    private var sileroLoadStarted = false
    private var pendingStop: DispatchWorkItem?   // release-grace timer (tail capture)
    private var dictationGeneration = 0          // ignore stale transcription completions
    private var recordingStartedAt: Date?        // wall clock, to spot dead-capture sessions
    private var transcriptionWatchdog: DispatchWorkItem?
    private var state: AppState = .loadingModel(progress: nil) { didSet { updateMenu(); updateStatusIcon() } }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        CrashSentinel.checkAndArm()
        // The reader feature is @MainActor and this delegate runs on the main
        // actor; bridge across the (non-isolated) AppKit delegate explicitly.
        MainActor.assumeIsolated {
            claudeCodeTTS = ClaudeCodeTTSController(settings: settings)
            claudeCodeTTS.onStatusChange = { [weak self] in self?.updateMenu() }
        }
        setupStatusItem()

        recorder.onLevel = { [weak self] lvl in self?.overlay.updateLevel(lvl) }
        recorder.onFailure = { [weak self] reason in
            DispatchQueue.main.async { self?.recordingBroke(reason) }
        }
        ptt.onStart = { [weak self] in self?.startRecording() }
        ptt.onStop = { [weak self] in self?.stopRecording() }
        ptt.onTapDisabled = { [weak self] in self?.tapDied() }
        // Menu-bar % follows the SELECTED model's download in the center
        // (downloads of other models run concurrently and don't touch it).
        ModelDownloadCenter.shared.$states
            .receive(on: DispatchQueue.main)
            .sink { [weak self] states in
                guard let self else { return }
                if case .downloading(let fraction) = states[self.settings.modelID] {
                    let pct = min(99, Int(fraction * 100))
                    if case .loadingModel(let current) = self.state, current != pct {
                        self.state = .loadingModel(progress: pct)
                    }
                }
            }
            .store(in: &cancellables)

        ptt.handsFreeEnabled = settings.handsFreeDoubleTap
        observeSettings()
        // Apply the saved on/off preference (a no-op, instantly, when it's off).
        MainActor.assumeIsolated { claudeCodeTTS.applyInitialState() }
        // Run the version-change check first: it marks onboarding complete for
        // updating users, which gates whether the wizard shows below.
        announceVersionChangeIfNeeded()
        requestPermissionsThenStart()
        loadModel()

        Updater.shared.automaticallyChecksForUpdates = settings.checkForUpdates
        settings.$checkForUpdates
            .dropFirst()
            .sink { Updater.shared.automaticallyChecksForUpdates = $0 }
            .store(in: &cancellables)
        // An available update should never hide behind "Check for Updates…" —
        // Sparkle's own alert pops, and the menu gets a prominent install item.
        Updater.shared.onUpdateAvailable = { [weak self] version in
            self?.updateAvailableVersion = version
            self?.updateMenu()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        CrashSentinel.disarm()
        ptt.stop()
        pendingStop?.cancel()
        _ = recorder.stop()
        armTimer?.invalidate()
    }

    /// First launch of a new version: open the window so the user SEES the
    /// update landed (menu-bar apps otherwise update invisibly) — and a failed
    /// post-update relaunch self-heals into a visible confirmation when the
    /// user relaunches manually.
    private func announceVersionChangeIfNeeded() {
        let current = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
        let key = "soyle.lastLaunchedVersion"
        let previous = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set(current, forKey: key)
        guard let previous, previous != current else { return }
        Log.app.notice("updated \(previous, privacy: .public) → \(current, privacy: .public)")
        // A user updating from an older build already set the app up — never drop
        // them into the new guided onboarding.
        if !settings.hasCompletedOnboarding { settings.hasCompletedOnboarding = true }
        settings.justUpdatedToVersion = current
        DispatchQueue.main.async { [weak self] in self?.openSettings() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        tryRearm()
        // Recover a failed model load (e.g. offline at first run) without a relaunch.
        if modelLoadFailed, !engine.isLoaded {
            loadModel()
        }
    }

    // Re-arm the push-to-talk tap once Accessibility is granted in-session,
    // so the user doesn't have to relaunch.
    private func startArmTimer() {
        armTimer?.invalidate()
        armTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.tryRearm()
        }
    }

    private func tryRearm() {
        guard state == .needsAccessibility, Permissions.hasAccessibility else { return }
        if ptt.start() {
            armTimer?.invalidate(); armTimer = nil
            if engine.isLoaded {
                state = .ready
            } else if modelLoadFailed {
                state = .loadFailed(lastLoadFailureReason ?? "Model not loaded, it retries when you dictate")
            } else {
                state = .loadingModel(progress: nil)
            }
        }
    }

    // MARK: Startup helpers

    private func requestPermissionsThenStart() {
        // Microphone: prompt at launch only for returning users. New users grant
        // it in context, from the guided onboarding's microphone step, instead of
        // being ambushed by a prompt before they know what the app is.
        if settings.hasCompletedOnboarding, AVCaptureDeviceStatusIsUndetermined() {
            Permissions.requestMicrophone { _ in }
        }
        // Accessibility grants the global key tap (and auto-paste); start()
        // succeeds once it's granted, otherwise we wait and re-arm.
        if ptt.start() {
            state = .loadingModel(progress: nil) // will flip to .ready once model loads
        } else {
            state = .needsAccessibility
            startArmTimer()       // auto-recover once the grant lands (no relaunch needed)
        }
        // Show the window for the wizard (onboarding unfinished) or when push-to-talk
        // permission is missing (a returning user needs to re-grant it).
        if !settings.hasCompletedOnboarding || !Permissions.hasAccessibility {
            DispatchQueue.main.async { [weak self] in self?.openSettings() }
        }
        settings.hasOnboarded = true
    }

    private func loadModel() {
        startModelLoad(of: settings.modelOption)
    }

    /// Loads the Silero VAD once, in the background. If it fails (offline at
    /// first run, model missing, etc.) the speech gate silently falls back to
    /// RMS; dictation is never blocked or broken by the VAD.
    private func loadSileroIfNeeded() {
        guard !sileroLoadStarted else { return }
        sileroLoadStarted = true
        Task { [weak self] in
            let detector = try? await SileroSpeechDetector.load()
            await MainActor.run {
                self?.silero = detector
                if detector == nil {
                    ErrorLog.shared.record(component: "vad",
                                           message: "Silero VAD unavailable, using RMS speech detection")
                }
            }
        }
    }

    /// One tracked load at a time: selecting another model cancels the wait on
    /// the previous one (its download keeps running concurrently in the
    /// center — resumable, never wasted) and the stale task can no longer
    /// touch UI state thanks to the post-await cancellation guards.
    private func startModelLoad(of target: ASRModelOption) {
        loadTask?.cancel()
        modelLoadFailed = false
        // Pre-flight: refuse a load that can't fit in unified memory — letting
        // MLX try anyway can abort the whole process (Metal allocation failure),
        // which to the user is "the app vanished".
        switch SystemResources.memoryVerdict(forWeightsGB: target.sizeGB) {
        case .insufficient(let message):
            registerLoadFailure(reason: message, target: target)
            overlay.show(.error(message), autoHideAfter: 5)
            return
        case .tight(let message):
            ErrorLog.shared.record(component: "model", message: "\(target.displayName): \(message)")
            overlay.show(.error(message), autoHideAfter: 4)
        case .ok:
            break
        }
        // Never clobber the permission gate — it owns the menu until the tap
        // is armed (otherwise the re-arm timer's guard can never fire and the
        // app shows "Ready" with a dead hotkey).
        if state != .needsAccessibility { state = .loadingModel(progress: nil) }
        let center = ModelDownloadCenter.shared
        loadTask = Task { @MainActor in
            do {
                try await center.ensureDownloaded(target).value
                guard !Task.isCancelled else { return }
                center.markPreparing(target)
                try await engine.load()
                guard !Task.isCancelled else { center.clearLoadMarker(target); return }
                await Task.detached(priority: .userInitiated) { [engine] in engine.warmUp() }.value
                guard !Task.isCancelled else { center.clearLoadMarker(target); return }
                // A concurrent model switch may have invalidated this load — only
                // a load whose weights are actually installed flips to .ready.
                if engine.isLoaded {
                    center.markActive(target)
                    loadSileroIfNeeded()
                    if state != .needsAccessibility { state = .ready } else { updateMenu() }
                } else {
                    center.clearLoadMarker(target)
                }
            } catch is CancellationError {
                center.clearLoadMarker(target)
            } catch {
                center.clearLoadMarker(target)
                let reason = Self.loadFailureMessage(for: error)
                registerLoadFailure(reason: reason, target: target, detail: String(describing: error))
                overlay.show(.error(reason), autoHideAfter: 4)
            }
        }
    }

    private func registerLoadFailure(reason: String, target: ASRModelOption, detail: String? = nil) {
        modelLoadFailed = true
        lastLoadFailureReason = reason
        ErrorLog.shared.record(component: "model",
                               message: "\(target.displayName) couldn't load, \(reason)",
                               detail: detail)
        if state != .needsAccessibility { state = .loadFailed(reason) }
    }

    /// Honest, actionable load-failure wording (offline vs disk vs generic).
    private static func loadFailureMessage(for error: Error) -> String {
        if let preflight = error as? PreflightError {
            return preflight.errorDescription ?? "Pre-flight check failed."
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .dataNotAllowed, .cannotFindHost, .dnsLookupFailed:
                return "Can't download the model, you appear to be offline. It retries when you dictate."
            case .timedOut, .networkConnectionLost:
                return "The model download was interrupted, it resumes when you dictate."
            default:
                break
            }
        }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteOutOfSpaceError {
            return "Not enough disk space to finish the model download."
        }
        return "The model couldn't load (\(ns.localizedDescription)). See Settings → Report a Problem."
    }

    private func observeSettings() {
        settings.$modelID
            .dropFirst()
            .sink { [weak self] id in
                guard let option = ASRCatalog.option(forID: id) else { return }
                self?.reloadModel(option)
            }
            .store(in: &cancellables)
        settings.$pttKey
            .dropFirst()
            .sink { [weak self] key in
                guard let self else { return }
                self.ptt.stop()
                self.ptt.setKey(key)
                _ = self.ptt.start()
            }
            .store(in: &cancellables)
        // The user adjusted the language — restart the mismatch detector.
        settings.$language
            .dropFirst()
            .sink { [weak self] _ in self?.languageRescues = 0 }
            .store(in: &cancellables)
        settings.$handsFreeDoubleTap
            .dropFirst()
            .sink { [weak self] enabled in self?.ptt.handsFreeEnabled = enabled }
            .store(in: &cancellables)
        settings.$claudeCodeTTSEnabled
            .dropFirst()
            .sink { [weak self] enabled in
                MainActor.assumeIsolated { self?.claudeCodeTTS.setEnabled(enabled) }
            }
            .store(in: &cancellables)
    }

    private func reloadModel(_ newModel: ASRModelOption) {
        // Refuse a switch that can't fit in memory BEFORE dropping the current
        // weights: the user keeps a working model and learns why.
        if case .insufficient(let message) = SystemResources.memoryVerdict(forWeightsGB: newModel.sizeGB) {
            ErrorLog.shared.record(component: "model",
                                   message: "\(newModel.displayName) selection refused, \(message)")
            presentModelRefused(newModel, reason: message)
            if settings.modelID != engine.model.id {
                settings.modelID = engine.model.id   // snap the picker back to reality
            }
            return
        }
        // Leaving .recording without stopping the recorder would swallow the
        // PTT release in stopRecording's guard and leave the mic running.
        abortRecordingIfNeeded()
        engine.switchModel(to: newModel)
        startModelLoad(of: newModel)
    }

    private func presentModelRefused(_ model: ASRModelOption, reason: String) {
        let alert = NSAlert()
        alert.messageText = "\(model.displayName) won't fit in memory"
        alert.informativeText = reason
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: Recording flow

    private func startRecording() {
        // Re-pressed during the release-grace window: flush the previous
        // dictation now and start fresh.
        if let pending = pendingStop {
            pending.cancel(); pendingStop = nil
            finishStop()
            if state == .transcribing { state = .ready }
        }
        guard state == .ready else {
            if case .loadingModel(let pct) = state {
                overlay.show(.error(pct != nil ? "Downloading model…" : "Model is loading…"),
                             autoHideAfter: 1.5)
            } else if case .loadFailed = state {
                // "Retries when you dictate" — keep that promise right here.
                overlay.show(.error("Model not loaded, retrying now…"), autoHideAfter: 2)
                loadModel()
            } else if state == .needsAccessibility {
                promptAccessibility()
            }
            return
        }
        guard Permissions.hasMicrophone else {
            if Permissions.microphoneDenied {
                overlay.show(.error("Microphone denied, see Settings"), autoHideAfter: 2.5)
                Permissions.openMicrophoneSettings()
            } else {
                Permissions.requestMicrophone { _ in }
            }
            return
        }
        do {
            if recorder.recording { _ = recorder.stop() }  // defensive: stale session
            try recorder.start()
            recordingStartedAt = Date()
            state = .recording
            overlay.show(.recording(handsFree: ptt.isHandsFreeLocked))
            playSound(start: true)
        } catch {
            ErrorLog.shared.record(component: "audio",
                                   message: "Recording couldn't start",
                                   detail: error.localizedDescription)
            overlay.show(.error("Microphone unavailable, \(error.localizedDescription)"), autoHideAfter: 3)
        }
    }

    /// Mid-recording capture failure (device yanked and recovery failed):
    /// stop cleanly and say so — never keep "recording" silence.
    private func recordingBroke(_ reason: String) {
        ErrorLog.shared.record(component: "audio", message: "Recording aborted, \(reason)")
        guard state == .recording else { return }
        abortRecordingIfNeeded()
        state = .ready
        overlay.show(.error("Microphone lost, dictation stopped"), autoHideAfter: 3)
    }

    /// The event tap died and PushToTalk's re-enable didn't stick: recreate it,
    /// or fall back to the permission gate — never a silently dead hotkey.
    private func tapDied() {
        ErrorLog.shared.record(component: "hotkey",
                               message: "Push-to-talk tap disabled by the system and re-enable failed")
        ptt.stop()
        if Permissions.hasAccessibility, ptt.start() {
            Log.app.notice("event tap recreated after system disable")
            return
        }
        state = .needsAccessibility
        startArmTimer()
        overlay.show(.error("Push-to-talk lost, check Accessibility"), autoHideAfter: 4)
    }

    private func stopRecording() {
        guard state == .recording else {
            // Defensive: never leave the mic running (e.g. if a model switch
            // yanked us out of .recording mid-hold).
            if recorder.recording, pendingStop == nil { _ = recorder.stop() }
            return
        }
        playSound(start: false)
        state = .transcribing
        overlay.show(.transcribing)

        // Keep capturing a short tail: people release the key on the last word,
        // and the resampler buffers a few extra milliseconds.
        let work = DispatchWorkItem { [weak self] in self?.finishStop() }
        pendingStop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func finishStop() {
        pendingStop = nil
        let samples = recorder.stop()
        let wallClock = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        recordingStartedAt = nil

        // Ignore accidental taps (< 0.25s of speech + the 0.25s tail) — but a
        // LONG hold that produced (near) nothing is a broken capture, not a
        // tap: the user spoke into a dead pipeline and must know.
        guard samples.count >= 8_000 else {
            if wallClock >= 1.5 {
                ErrorLog.shared.record(component: "audio", message: String(
                    format: "Held the key %.1fs but captured only %d samples, the input device produced no audio",
                    wallClock, samples.count))
                overlay.show(.error("No audio captured, check your input device (System Settings → Sound)"),
                             autoHideAfter: 4)
            } else {
                overlay.hide()
            }
            if state == .transcribing { state = .ready }
            return
        }

        dictationGeneration += 1
        let gen = dictationGeneration
        let lang = settings.language.engineCode

        // Watchdog: an inference that hangs (Metal stall, library bug) must not
        // leave "Transcribing…" on screen forever with the hotkey locked out.
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, self.state == .transcribing, gen == self.dictationGeneration else { return }
            ErrorLog.shared.record(component: "model",
                                   message: "Transcription still running after 120s, state reset so dictation keeps working")
            self.state = .ready
            self.overlay.show(.error("Transcription stalled, please try again (and Report a Problem)"),
                              autoHideAfter: 5)
        }
        transcriptionWatchdog?.cancel()
        transcriptionWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: watchdog)

        let detector = silero   // captured on main; nil means RMS fallback
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let stats = SpeechStats.analyze(samples: samples)
                // Silero VAD decides whether the user actually spoke; RMS
                // SpeechStats is the safety net when Silero is unavailable.
                let sileroResult = detector.flatMap { try? $0.analyze(samples: samples) }
                let gate = SpeechGate.resolve(silero: sileroResult, rms: stats)
                var result = try self.engine.transcribe(samples: samples, language: lang)
                // A model conditioned on the wrong language can return an
                // EMPTY transcript for perfectly good speech (verified:
                // Nemotron + sv-SE prompt on French audio → empty). One
                // silent retry in auto-detect rescues the dictation, but only
                // when there IS speech: rescuing silence just gives the model
                // a second chance to hallucinate.
                if result.text.isEmpty, lang != nil, gate.hasSpeech {
                    let rescue = try self.engine.transcribe(samples: samples, language: nil)
                    if !rescue.text.isEmpty {
                        result = rescue
                        DispatchQueue.main.async { self.noteLanguageRescue() }
                    }
                }
                let text = result.text
                DispatchQueue.main.async {
                    self.transcriptionWatchdog?.cancel()
                    self.deliver(text: text, stats: stats, gate: gate, forcedLanguage: lang, generation: gen)
                }
            } catch {
                DispatchQueue.main.async {
                    self.transcriptionWatchdog?.cancel()
                    ErrorLog.shared.record(component: "model",
                                           message: "Transcription failed",
                                           detail: error.localizedDescription)
                    if self.state == .transcribing, gen == self.dictationGeneration {
                        self.overlay.show(.error("Transcription error, \(error.localizedDescription)"),
                                          autoHideAfter: 3)
                        self.state = .ready
                    }
                }
            }
        }
    }

    /// What to do with a model output, given what the microphone actually
    /// heard. Pure and static so tests can pin every case — most importantly
    /// the hallucination guard: a model conditioned on a forced language
    /// INVENTS text on silence (verified: Qwen3 + French produces "Oui." on
    /// pure digital silence), so no-speech audio never delivers anything.
    enum DictationDecision: Equatable {
        case deliver(String)
        case noSpeech(discardedCharacters: Int)
        case notRecognized
        case wrongLanguage
    }

    static func decide(text: String, hasSpeech: Bool, forcedLanguage: Bool) -> DictationDecision {
        if !hasSpeech {
            return .noSpeech(discardedCharacters: text.count)
        }
        if text.isEmpty {
            return forcedLanguage ? .wrongLanguage : .notRecognized
        }
        return .deliver(text)
    }

    /// Hand the transcript to the user, with an honest account of what
    /// happened: empty results are explained (silence vs unrecognized speech
    /// vs language mismatch), hallucinated text on silence is discarded,
    /// clipboard writes are verified, and a skipped auto-paste always says why.
    private func deliver(text rawText: String, stats: SpeechStats, gate: SpeechGate.Verdict, forcedLanguage lang: String?, generation gen: Int) {
        // The user's vocabulary fixes names/jargon first, so History, the
        // clipboard and the paste all carry the corrected form. The spell-check
        // gate keeps the fuzzy layer away from real words (main-thread only).
        let corrected = Vocabulary.shared.apply(to: rawText, isKnownWord: SpellCheck.isKnownWord)
        let isCurrent = (state == .transcribing && gen == dictationGeneration)
        let outcome: DictationOutcome

        switch Self.decide(text: corrected, hasSpeech: gate.hasSpeech, forcedLanguage: lang != nil) {
        case .noSpeech(let discarded):
            if discarded > 0 {
                // The interesting case: the model produced text for audio with
                // no speech in it. Metadata only, never the text itself.
                ErrorLog.shared.record(component: "model", message: String(
                    format: "Discarded %d characters the model produced on no-speech audio (gate %@, peak %.3f, %.1fs active), hallucination guard",
                    discarded, gate.source.rawValue, stats.peakRMS, stats.activeSeconds))
            }
            outcome = .noSpeech
        case .wrongLanguage:
            // Auto-detect rescue already ran and stayed empty too.
            outcome = .wrongLanguage(settings.language.displayName)
            ErrorLog.shared.record(component: "model", message: String(
                format: "Speech detected (%.1fs active, peak %.3f) but empty transcript with language %@, auto rescue empty too",
                stats.activeSeconds, stats.peakRMS, settings.language.displayName))
        case .notRecognized:
            outcome = .notRecognized
            ErrorLog.shared.record(component: "model", message: String(
                format: "Speech detected (%.1fs active) but the model returned an empty transcript (language: auto)",
                stats.activeSeconds))
        case .deliver(let text):
            // Surface the first words to the onboarding "try it" step (no-op once
            // the user has finished setup).
            if !settings.hasCompletedOnboarding { OnboardingProbe.shared.lastHeard = text }
            if !AutoPaster.secureInputActive {
                // Words are never lost, even when a newer dictation owns the UI.
                HistoryStore.shared.add(text: text, language: lang, audioSeconds: stats.duration)
            }
            guard isCurrent else { return }   // stale: archived above, hands off the clipboard
            guard Clipboard.copy(text) else {
                // No ⌘V either — synthesizing it would paste the clipboard's
                // PREVIOUS content into the user's document.
                ErrorLog.shared.record(component: "paste",
                                       message: "Clipboard write failed, transcript NOT copied (it is in History)")
                overlay.show(.error("Couldn't copy, recover the text from History"), autoHideAfter: 4)
                state = .ready
                return
            }
            if settings.autoPaste {
                switch AutoPaster.paste() {
                case .pasted:
                    outcome = .pasted
                case .noAccessibility:
                    outcome = .copiedNoAccessibility
                    ErrorLog.shared.record(component: "paste",
                                           message: "Auto-paste skipped, Accessibility not granted")
                case .secureField:
                    outcome = .copiedSecureField
                }
            } else {
                outcome = .copied
            }
        }

        if isCurrent {
            overlay.show(.done(outcome), autoHideAfter: Self.hideDelay(for: outcome))
            state = .ready
        }
    }

    /// Successes vanish fast; anything the user should read lingers.
    private static func hideDelay(for outcome: DictationOutcome) -> Double {
        switch outcome {
        case .pasted, .copied: return 1.0
        case .noSpeech: return 1.6
        case .copiedSecureField: return 3.0
        case .copiedNoAccessibility, .notRecognized: return 3.5
        case .wrongLanguage: return 4.5
        }
    }

    /// Auto-detect had to rescue an empty transcript — the configured
    /// language doesn't match what's being spoken. After three rescues in a
    /// row, gently point at the setting (each rescue costs a second pass).
    private func noteLanguageRescue() {
        languageRescues += 1
        guard languageRescues == 3 else { return }
        let langName = settings.language.displayName
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            self?.overlay.show(
                .error("Tip: language is set to \(langName), Auto would fit your speech better (Settings → Language)."),
                autoHideAfter: 5)
        }
    }

    private func abortRecordingIfNeeded() {
        pendingStop?.cancel(); pendingStop = nil
        if recorder.recording { _ = recorder.stop() }
        if state == .recording { overlay.hide() }
    }

    private func playSound(start: Bool) {
        guard settings.playSounds else { return }
        NSSound(named: start ? "Tink" : "Pop")?.play()
    }

    // MARK: Status item + menu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()
        updateMenu()
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let symbol: String
        switch state {
        case .recording: symbol = "mic.fill"
        case .transcribing: symbol = "waveform"
        case .needsAccessibility, .loadFailed: symbol = "exclamationmark.triangle.fill"
        default: symbol = "mic"
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Talkink")
        button.image?.isTemplate = (state != .recording)
        button.contentTintColor = (state == .recording) ? .nvidia : nil
    }

    private func updateMenu() {
        let menu = NSMenu()

        let status = NSMenuItem(title: statusLine(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        // An available update gets a first-class item — nobody should have to
        // think of clicking "Check for Updates…" to learn about it.
        if let version = updateAvailableVersion {
            menu.addItem(item("⬆️ Update to \(version), Install…", #selector(checkForUpdates)))
            menu.addItem(.separator())
        }

        if state == .needsAccessibility {
            menu.addItem(item("Allow “Accessibility”…", #selector(promptAccessibilityMenu)))
            menu.addItem(.separator())
        }
        if case .loadFailed = state {
            menu.addItem(item("Retry Loading the Model", #selector(retryModelLoad)))
            menu.addItem(.separator())
        }

        // Language submenu
        let langItem = NSMenuItem(title: "Language: \(settings.language.displayName)", action: nil, keyEquivalent: "")
        let langMenu = NSMenu()
        for lang in SoyleLanguage.allCases {
            let mi = item(lang.displayName, #selector(selectLanguage(_:)))
            mi.representedObject = lang.rawValue
            mi.state = (lang == settings.language) ? .on : .off
            langMenu.addItem(mi)
        }
        langItem.submenu = langMenu
        menu.addItem(langItem)

        // Model submenu
        let modelItem = NSMenuItem(title: "Model: \(settings.modelOption.displayName)", action: nil, keyEquivalent: "")
        let modelMenu = NSMenu()
        for option in ASRCatalog.options {
            let suffix = option == ASRCatalog.default ? ", recommended" : ""
            let mi = item("\(option.displayName)  (\(option.sizeLabel))\(suffix)", #selector(selectModel(_:)))
            mi.representedObject = option.id
            mi.state = (option.id == settings.modelID) ? .on : .off
            modelMenu.addItem(mi)
        }
        modelItem.submenu = modelMenu
        menu.addItem(modelItem)

        // Key submenu
        let keyItem = NSMenuItem(title: "Key: \(settings.pttKey.displayName)", action: nil, keyEquivalent: "")
        let keyMenu = NSMenu()
        for k in PushToTalk.Key.allCases {
            let mi = item(k.displayName, #selector(selectKey(_:)))
            mi.representedObject = k.rawValue
            mi.state = (k == settings.pttKey) ? .on : .off
            keyMenu.addItem(mi)
        }
        keyItem.submenu = keyMenu
        menu.addItem(keyItem)

        let sounds = item("Feedback Sounds", #selector(toggleSounds))
        sounds.state = settings.playSounds ? .on : .off
        menu.addItem(sounds)

        addClaudeCodeReadingItems(to: menu)

        menu.addItem(.separator())
        menu.addItem(item("Open Talkink (history, settings)…", #selector(openSettings), key: ","))
        menu.addItem(item("Check for Updates…", #selector(checkForUpdates)))
        menu.addItem(item("Report a Problem…", #selector(reportProblem)))
        menu.addItem(item("About Talkink", #selector(about)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Talkink", #selector(quit), key: "q"))

        statusItem.menu = menu
    }

    private func statusLine() -> String {
        switch state {
        case .loadingModel(let pct):
            // The downloader only reports per-file completion (verified: the big
            // weights file lands at once), so a percent is usually stuck at 0 —
            // show it only if it ever moves.
            guard let pct else { return "⏳ Loading model…" }
            return pct > 0 ? "⏳ Downloading model… \(pct)%"
                           : "⏳ Downloading model (\(settings.modelOption.sizeLabel), one-time)…"
        case .ready: return "● Ready, hold \(settings.pttKey.displayName)"
        case .recording:
            return ptt.isHandsFreeLocked
                ? "🎙 Recording, tap \(settings.pttKey.displayName) to stop"
                : "🎙 Recording…"
        case .transcribing: return "✍️ Transcribing…"
        case .needsAccessibility: return "⚠️ Permission required"
        case .loadFailed(let reason): return "⚠️ \(String(reason.prefix(72)))"
        }
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = self
        return mi
    }

    // MARK: Menu actions

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let lang = SoyleLanguage(rawValue: raw) {
            settings.language = lang
            updateMenu()
        }
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String, ASRCatalog.option(forID: id) != nil {
            settings.modelID = id
            updateMenu()
        }
    }

    @objc private func selectKey(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? Int, let k = PushToTalk.Key(rawValue: raw) {
            settings.pttKey = k
            updateMenu()
        }
    }

    @objc private func toggleSounds() { settings.playSounds.toggle(); updateMenu() }

    /// "Read Claude Code Aloud" toggle + voice picker — shown only when Claude
    /// Code is installed (otherwise the feature has nothing to read).
    private func addClaudeCodeReadingItems(to menu: NSMenu) {
        guard let cc = claudeCodeTTS else { return }
        let snapshot = MainActor.assumeIsolated { (available: cc.isAvailable, status: cc.status) }
        guard snapshot.available else { return }
        menu.addItem(.separator())
        let title: String
        switch snapshot.status {
        case .loading(let pct):
            title = pct.map { "Read Claude Code Aloud — loading \($0)%…" }
                ?? "Read Claude Code Aloud — loading…"
        case .failed(let why):
            title = "Read Claude Code Aloud — \(why)"
        default:
            title = "Read Claude Code Aloud"
        }
        let read = item(title, #selector(toggleClaudeCodeTTS))
        read.state = settings.claudeCodeTTSEnabled ? .on : .off
        menu.addItem(read)

        guard settings.claudeCodeTTSEnabled else { return }
        let voiceName = (TTSCatalog.voice(forID: settings.claudeCodeTTSVoice) ?? TTSCatalog.default).displayName
        let voiceItem = NSMenuItem(title: "Reading Voice: \(voiceName)", action: nil, keyEquivalent: "")
        let voiceMenu = NSMenu()
        for voice in TTSCatalog.voices {
            let mi = item("\(voice.flag)  \(voice.displayName)", #selector(selectTTSVoice(_:)))
            mi.representedObject = voice.id
            mi.state = (voice.id == settings.claudeCodeTTSVoice) ? .on : .off
            voiceMenu.addItem(mi)
        }
        voiceItem.submenu = voiceMenu
        menu.addItem(voiceItem)
    }

    @objc private func toggleClaudeCodeTTS() {
        settings.claudeCodeTTSEnabled.toggle()
        updateMenu()
    }

    @objc private func selectTTSVoice(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String {
            MainActor.assumeIsolated { claudeCodeTTS.setVoice(id) }
            updateMenu()
        }
    }

    @objc private func openSettings() { settingsWindowController.show() }

    /// Re-opening the app (double-click in Applications, `open`, Dock) while
    /// it's already running should surface the UI — standard macOS behaviour,
    /// and the only discoverable "where did it go?" recovery for a menu-bar app.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { openSettings() }
        return true
    }

    // MARK: talkink:// automation (Raycast, Alfred, Shortcuts, `open` in a terminal)

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { handleCommandURL(url) }
    }

    private func handleCommandURL(_ url: URL) {
        guard url.scheme == "talkink" else { return }
        let command = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        Log.app.notice("URL command: \(command, privacy: .public)")
        switch command {
        case "settings":
            openSettings()
            NotificationCenter.default.post(name: .soyleShowSettings, object: nil)
        case "history":
            openSettings()
            NotificationCenter.default.post(name: .soyleShowHistory, object: nil)
        case "report":
            reportProblem()
        case "record", "stop", "toggle":
            // Any app can open a URL — starting the microphone stays the
            // user's explicit, opt-in choice.
            guard settings.allowURLAutomation else {
                ErrorLog.shared.record(component: "automation",
                    message: "URL command '\(command)' refused, “Allow URL automation” is off (Settings → Behaviour)")
                overlay.show(.error("URL automation is off, enable it in Settings → Behaviour"), autoHideAfter: 3.5)
                return
            }
            handleDictationCommand(command)
        default:
            ErrorLog.shared.record(component: "automation", message: "Unknown URL command '\(command)'")
            overlay.show(.error("Unknown command: talkink://\(command)"), autoHideAfter: 2.5)
        }
    }

    private func handleDictationCommand(_ command: String) {
        switch (command, state) {
        case ("record", .ready), ("toggle", .ready):
            startURLDictation()
        case ("stop", .recording), ("toggle", .recording):
            stopURLDictation()
        case ("record", .recording), ("stop", _):
            break   // already there — a no-op, not an error
        default:
            // loading/failed/permission states explain themselves via the
            // same path a key press takes.
            startRecording()
        }
    }

    /// URL-triggered dictation has no held key, so it's hands-free by design:
    /// the pill reads "tap to stop", the key or talkink://stop ends it.
    private func startURLDictation() {
        ptt.forceHandsFreeLock()
        startRecording()
        if state != .recording { ptt.resetHandsFree() }   // start refused — don't leave a stale lock
    }

    private func stopURLDictation() {
        ptt.resetHandsFree()
        stopRecording()
    }

    @objc private func checkForUpdates() { Updater.shared.checkForUpdates() }

    @objc private func retryModelLoad() { loadModel() }

    @objc private func reportProblem() {
        settingsWindowController.show()
        NotificationCenter.default.post(name: .soyleOpenReport, object: nil)
    }

    @objc private func promptAccessibilityMenu() { openSettings() }

    private func promptAccessibility() { openSettings() }

    @objc private func about() {
        let alert = NSAlert()
        alert.messageText = "Talkink"
        alert.informativeText = "On-device voice dictation, \(settings.modelOption.displayName) via Apple MLX.\nHold \(settings.pttKey.displayName), speak, release, the text is pasted at your cursor and copied."
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

private func AVCaptureDeviceStatusIsUndetermined() -> Bool {
    AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
}
