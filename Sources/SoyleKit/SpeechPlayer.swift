import Foundation
import AVFoundation

/// Sequential, gap-aware speech playback with barge-in. You `enqueue` cleaned,
/// sentence-sized chunks; the player synthesises them one at a time (off the
/// main thread — the `await` frees the main actor so dictation/UI keep running)
/// and schedules the audio on an `AVAudioPlayerNode`, which plays the buffers
/// back-to-back in order. Synthesis of the next chunk overlaps playback of the
/// current one, so there are no gaps; back-pressure caps how far ahead we run so
/// a long answer neither floods memory nor wastes work that a barge-in discards.
///
/// `@MainActor` so every `AVAudioEngine` touch happens on one consistent thread.
/// This is a separate `AVAudioEngine` from the recorder's input engine, so
/// reading aloud and dictating coexist.
@MainActor
public final class SpeechPlayer {
    private let synth: SpeechSynthesisEngine
    private var voice: String
    private var language: String?

    private let audioEngine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var attached = false

    private var queue: [String] = []
    private var worker: Task<Void, Never>?
    /// Bumped by `stop()`; stale synthesis/playback completions compare against
    /// it and bail, so a barge-in can't be undone by work already in flight.
    private var generation = 0

    private var inFlight = 0
    private let maxInFlight = 2
    private var capacityWaiter: CheckedContinuation<Void, Never>?

    public init(synth: SpeechSynthesisEngine,
                voice: String = TTSCatalog.default.id,
                language: String? = TTSCatalog.default.language) {
        self.synth = synth
        self.voice = voice
        self.language = language
    }

    public func setVoice(_ id: String, language: String?) {
        voice = id
        self.language = language
    }

    public var isSpeaking: Bool { worker != nil || inFlight > 0 }

    /// Queue a ready-to-speak chunk (already markdown-cleaned + sentence-sized).
    public func enqueue(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        queue.append(t)
        startWorkerIfNeeded()
    }

    /// Barge-in: silence immediately, drop everything pending, cancel in-flight
    /// synthesis. Safe to call when already idle.
    public func stop() {
        generation &+= 1
        worker?.cancel(); worker = nil
        queue.removeAll()
        if attached {
            node.stop()
            node.reset()
        }
        inFlight = 0
        resumeCapacityWaiter()
    }

    /// Full teardown for when the feature is switched off: stop, then release the
    /// audio engine so nothing stays warm.
    public func shutdown() {
        stop()
        if audioEngine.isRunning { audioEngine.stop() }
    }

    // MARK: - Worker loop

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        let gen = generation
        worker = Task { [weak self] in
            await self?.drain(generation: gen)
        }
    }

    private func drain(generation gen: Int) async {
        while !Task.isCancelled, gen == generation {
            guard !queue.isEmpty else { break }
            let chunk = queue.removeFirst()
            await awaitCapacity(generation: gen)
            if Task.isCancelled || gen != generation { break }
            do {
                let samples = try await synth.synthesize(text: chunk, voice: voice, language: language)
                if Task.isCancelled || gen != generation { break }
                schedule(samples, generation: gen)
            } catch {
                Log.tts.error("synthesis failed (\(error.localizedDescription, privacy: .public))")
            }
        }
        if gen == generation { worker = nil }
    }

    /// Suspend the worker while `maxInFlight` buffers are already queued, so we
    /// stay ~2 sentences ahead and no further. Resumed by a played-back buffer
    /// or by `stop()`.
    private func awaitCapacity(generation gen: Int) async {
        guard inFlight >= maxInFlight, gen == generation else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            capacityWaiter = cont
        }
    }

    private func resumeCapacityWaiter() {
        capacityWaiter?.resume()
        capacityWaiter = nil
    }

    // MARK: - Audio output

    private func schedule(_ samples: [Float], generation gen: Int) {
        guard !samples.isEmpty,
              let buffer = Self.makeBuffer(samples, sampleRate: synth.sampleRate) else { return }
        ensureStarted(format: buffer.format)
        guard audioEngine.isRunning else { return }
        inFlight += 1
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.bufferFinished(generation: gen) }
        }
        if !node.isPlaying { node.play() }
    }

    private func bufferFinished(generation gen: Int) {
        guard gen == generation else { return }   // a barge-in already reset us
        inFlight = max(0, inFlight - 1)
        resumeCapacityWaiter()
    }

    /// Start the engine once, connecting the player node at the synth's sample
    /// rate; the main mixer resamples to the hardware output rate.
    private func ensureStarted(format: AVAudioFormat) {
        // Attach + connect once (the synth's sample rate never changes); the main
        // mixer resamples to the hardware output rate. The engine itself may be
        // stopped on disable and is restarted here on the next block.
        if !attached {
            audioEngine.attach(node)
            audioEngine.connect(node, to: audioEngine.mainMixerNode, format: format)
            attached = true
        }
        if !audioEngine.isRunning {
            audioEngine.prepare()
            do {
                try audioEngine.start()
            } catch {
                Log.tts.error("audio engine start failed (\(error.localizedDescription, privacy: .public))")
            }
        }
    }

    private static func makeBuffer(_ samples: [Float], sampleRate: Int) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Double(sampleRate),
                                         channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { channel.update(from: base, count: samples.count) }
        }
        return buffer
    }
}
