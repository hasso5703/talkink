import Foundation
import AVFoundation
import SoyleKit

/// Captures the microphone during a push-to-talk window and produces
/// 16 kHz mono Float32 samples (what all our models expect). AVAudioConverter
/// handles resampling (48k/44.1k → 16k) and downmix in one pass.
final class Recorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    // Constructible by definition (PCM Float32 mono 16k is always a valid
    // format) — the failure paths that exist in practice are guarded in
    // installTap (0 Hz device, converter creation).
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 16_000, channels: 1, interleaved: false)!
    private var samples: [Float] = []
    private let sampleLock = NSLock()
    private var isRecording = false
    private var configObserver: NSObjectProtocol?
    private var convertFailureLogged = false

    /// Called frequently on a background thread with a 0...1 input level (RMS),
    /// for the live waveform/meter.
    var onLevel: (Float) -> Void = { _ in }

    /// The capture broke mid-recording (device yanked, engine restart failed)
    /// and recovery failed — recording continues into the void unless the
    /// owner stops it and tells the user.
    var onFailure: (String) -> Void = { _ in }

    var recording: Bool { isRecording }

    /// Start capturing. Throws if the engine can't start (e.g. mic denied / no device).
    func start() throws {
        guard !isRecording else { return }
        sampleLock.lock(); samples.removeAll(keepingCapacity: true); sampleLock.unlock()
        convertFailureLogged = false

        try installTap()
        engine.prepare()
        try engine.start()
        isRecording = true

        // Survive a mic unplug / default-device or route change mid-recording.
        if configObserver == nil {
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in self?.handleConfigChange() }
        }
    }

    /// Stop capturing and return the accumulated 16 kHz mono samples.
    @discardableResult
    func stop() -> [Float] {
        guard isRecording else { return [] }
        isRecording = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        drainConverter()
        sampleLock.lock(); let out = samples; samples.removeAll(); sampleLock.unlock()
        return out
    }

    /// Pull whatever the resampler still buffers (filter delay) so the very end
    /// of the last word isn't dropped.
    private func drainConverter() {
        guard let converter,
              let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 4096) else { return }
        var err: NSError?
        let result = converter.convert(to: out, error: &err) { _, status in
            status.pointee = .endOfStream
            return nil
        }
        if result == .haveData, out.frameLength > 0, let ch = out.floatChannelData {
            sampleLock.lock()
            samples.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
            sampleLock.unlock()
        }
        self.converter = nil
    }

    // MARK: - Internals

    private func installTap() throws {
        let input = engine.inputNode
        let hwFormat = input.inputFormat(forBus: 0)
        // A disconnected/again-0Hz device reports a 0 Hz format that crashes installTap.
        guard hwFormat.sampleRate > 0 else {
            throw NSError(domain: "Soyle.Recorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No audio input device available."])
        }
        // A nil converter would silently drop every buffer in process() —
        // the user would speak into a recording that captures nothing.
        guard let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            throw NSError(domain: "Soyle.Recorder", code: 2,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Can't convert \(Int(hwFormat.sampleRate)) Hz input to 16 kHz."])
        }
        self.converter = converter
        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            self?.process(buffer: buffer, hwFormat: hwFormat)
        }
    }

    private func handleConfigChange() {
        guard isRecording else { return }
        engine.inputNode.removeTap(onBus: 0)
        do {
            try installTap()
            if !engine.isRunning { engine.prepare(); try engine.start() }
            Log.audio.notice("audio route changed mid-recording, capture re-armed")
        } catch {
            Log.audio.error("audio reconfig recovery failed: \(error.localizedDescription, privacy: .public)")
            onFailure("Microphone changed and couldn't be recovered (\(error.localizedDescription))")
        }
    }

    private func process(buffer: AVAudioPCMBuffer, hwFormat: AVAudioFormat) {
        guard isRecording, let converter else { return }  // ignore late buffers after removeTap
        let ratio = targetFormat.sampleRate / hwFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard capacity > 0,
              let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var fed = false
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        var err: NSError?
        let result = converter.convert(to: out, error: &err, withInputFrom: inputBlock)
        if let err, !convertFailureLogged {
            // Once per session — a converter that fails usually fails for
            // every buffer, and the empty capture is surfaced at stop time.
            convertFailureLogged = true
            Log.audio.error("sample conversion failing: \(err.localizedDescription, privacy: .public)")
        }
        guard result == .haveData, out.frameLength > 0, let ch = out.floatChannelData else { return }

        let n = Int(out.frameLength)
        let ptr = ch[0]
        var sum: Float = 0
        for i in 0..<n { sum += ptr[i] * ptr[i] }
        let rms = n > 0 ? (sum / Float(n)).squareRoot() : 0
        onLevel(min(1, rms * 6))

        sampleLock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(start: ptr, count: n))
        sampleLock.unlock()
    }
}
