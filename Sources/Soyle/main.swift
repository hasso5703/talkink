import AppKit

// Headless self-test path (no GUI). Verifies bundled metallib + model + transcription.
if let i = CommandLine.arguments.firstIndex(of: "--selftest") {
    let path = (i + 1 < CommandLine.arguments.count) ? CommandLine.arguments[i + 1] : ""
    SelfTest.run(audioPath: path) // never returns
}

// Headless mic capture check — verifies the capture pipeline (and, on hardened
// runtime builds, the audio-input entitlement) without the GUI.
if CommandLine.arguments.contains("--mictest") {
    SelfTest.runMicTest() // never returns
}

// Headless memory regression check — proves a model switch releases the old
// weights (MLX active set + buffer cache) instead of stacking models in RAM.
if CommandLine.arguments.contains("--memtest") {
    SelfTest.runMemTest() // never returns
}

// Headless TTS check — native Kokoro French synthesis to a WAV (no GUI/audio device).
if let i = CommandLine.arguments.firstIndex(of: "--ttstest") {
    let next = (i + 1 < CommandLine.arguments.count) ? CommandLine.arguments[i + 1] : ""
    let text = (next.isEmpty || next.hasPrefix("--"))
        ? "Bonjour Hasan. Ceci est un test de la voix française, intégrée nativement dans Talkink."
        : next
    SelfTest.runTTSTest(text: text) // never returns
}

// Headless coexistence check — ASR + TTS concurrently in one process (proves the
// two share the GPU without a crash). Usage: Soyle --cotest AUDIO.wav
if let i = CommandLine.arguments.firstIndex(of: "--cotest") {
    let path = (i + 1 < CommandLine.arguments.count) ? CommandLine.arguments[i + 1] : ""
    SelfTest.runCoexistenceTest(audioPath: path) // never returns
}

#if SOYLE_DEVTOOLS
// Headless Silero VAD vs RMS comparison on real audio files (no GUI/model).
if let i = CommandLine.arguments.firstIndex(of: "--vadtest") {
    SelfTest.runVADTest(paths: Array(CommandLine.arguments[(i + 1)...])) // never returns
}

// Full real-decision replay on files (gate + transcribe + decide), mirroring
// the live dictation path. Usage: Soyle [--lang fr-FR] --dictatetest FILE...
if let i = CommandLine.arguments.firstIndex(of: "--dictatetest") {
    var lang: String? = nil
    if let li = CommandLine.arguments.firstIndex(of: "--lang"), li + 1 < CommandLine.arguments.count {
        let v = CommandLine.arguments[li + 1]
        lang = (v == "auto") ? nil : v
    }
    var modelID: String? = nil
    if let mi = CommandLine.arguments.firstIndex(of: "--model"), mi + 1 < CommandLine.arguments.count {
        modelID = CommandLine.arguments[mi + 1]
    }
    let files = Array(CommandLine.arguments[(i + 1)...]).filter {
        !$0.hasPrefix("--") && $0 != lang && $0 != modelID
    }
    SelfTest.runDictateTest(language: lang, modelID: modelID, paths: files) // never returns
}

// Render every onboarding step to PNG offscreen (no GUI window, no prompts).
if let i = CommandLine.arguments.firstIndex(of: "--onboarding-shots") {
    let dir = (i + 1 < CommandLine.arguments.count) ? CommandLine.arguments[i + 1] : "/tmp/onboarding_shots"
    OnboardingShots.run(outDir: dir)
}
#endif

#if SOYLE_DEVTOOLS
// Guided dataset recorder (GUI). Reuses the app's 16 kHz capture and mic
// permission to build a labelled voice dataset. Usage: Soyle --record-dataset
if CommandLine.arguments.contains("--record-dataset") {
    let studioApp = NSApplication.shared
    let studio = RecordingStudioAppDelegate()
    studioApp.delegate = studio
    studioApp.run()
    exit(0)
}
#endif

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
