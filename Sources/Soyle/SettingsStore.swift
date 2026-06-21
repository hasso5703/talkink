import Foundation
import Combine
import ServiceManagement
import SoyleKit

/// Available transcription languages — the intersection both prompt-driven
/// engines support, verified against Nemotron's prompt_dictionary and Qwen3's
/// config.supportLanguages (real model configs, 2026-06). Stored as BCP-47;
/// each engine receives its own format via the engine-side mapping.
/// `auto` lets the model detect the language.
enum SoyleLanguage: String, CaseIterable, Identifiable {
    // The original nine first — familiar order for existing users.
    case auto, frFR = "fr-FR", enUS = "en-US", deDE = "de-DE", esES = "es-ES",
         itIT = "it-IT", ptPT = "pt-PT", trTR = "tr-TR", arSA = "ar-SA", nlNL = "nl-NL",
         // Then the rest, alphabetically by English name.
         zhCN = "zh-CN", csCZ = "cs-CZ", daDK = "da-DK", fiFI = "fi-FI",
         elGR = "el-GR", hiIN = "hi-IN", huHU = "hu-HU", idID = "id-ID",
         jaJP = "ja-JP", koKR = "ko-KR", msMY = "ms-MY", faIR = "fa-IR",
         plPL = "pl-PL", roRO = "ro-RO", ruRU = "ru-RU", svSE = "sv-SE",
         thTH = "th-TH", viVN = "vi-VN"

    var id: String { rawValue }

    /// nil means "auto" for the engine.
    var engineCode: String? { self == .auto ? nil : rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto (detect)"
        case .frFR: return "French"
        case .enUS: return "English"
        case .deDE: return "German"
        case .esES: return "Spanish"
        case .itIT: return "Italian"
        case .ptPT: return "Portuguese"
        case .trTR: return "Turkish"
        case .arSA: return "Arabic"
        case .nlNL: return "Dutch"
        case .zhCN: return "Chinese"
        case .csCZ: return "Czech"
        case .daDK: return "Danish"
        case .fiFI: return "Finnish"
        case .elGR: return "Greek"
        case .hiIN: return "Hindi"
        case .huHU: return "Hungarian"
        case .idID: return "Indonesian"
        case .jaJP: return "Japanese"
        case .koKR: return "Korean"
        case .msMY: return "Malay"
        case .faIR: return "Persian"
        case .plPL: return "Polish"
        case .roRO: return "Romanian"
        case .ruRU: return "Russian"
        case .svSE: return "Swedish"
        case .thTH: return "Thai"
        case .viVN: return "Vietnamese"
        }
    }

    var flag: String {
        switch self {
        case .auto: return "🌐"
        case .frFR: return "🇫🇷"
        case .enUS: return "🇬🇧"
        case .deDE: return "🇩🇪"
        case .esES: return "🇪🇸"
        case .itIT: return "🇮🇹"
        case .ptPT: return "🇵🇹"
        case .trTR: return "🇹🇷"
        case .arSA: return "🇸🇦"
        case .nlNL: return "🇳🇱"
        case .zhCN: return "🇨🇳"
        case .csCZ: return "🇨🇿"
        case .daDK: return "🇩🇰"
        case .fiFI: return "🇫🇮"
        case .elGR: return "🇬🇷"
        case .hiIN: return "🇮🇳"
        case .huHU: return "🇭🇺"
        case .idID: return "🇮🇩"
        case .jaJP: return "🇯🇵"
        case .koKR: return "🇰🇷"
        case .msMY: return "🇲🇾"
        case .faIR: return "🇮🇷"
        case .plPL: return "🇵🇱"
        case .roRO: return "🇷🇴"
        case .ruRU: return "🇷🇺"
        case .svSE: return "🇸🇪"
        case .thTH: return "🇹🇭"
        case .viVN: return "🇻🇳"
        }
    }
}

/// User preferences, persisted in UserDefaults. Defaults are sane for everyone;
/// everything is overridable in Settings.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let defaults = UserDefaults.standard
    private enum K {
        static let language = "soyle.language"
        static let model = "soyle.model"
        static let pttKey = "soyle.pttKey"
        static let playSounds = "soyle.playSounds"
        static let autoPaste = "soyle.autoPaste"
        static let handsFreeDoubleTap = "soyle.handsFreeDoubleTap"
        static let allowURLAutomation = "soyle.allowURLAutomation"
        static let checkForUpdates = "soyle.checkForUpdates"
        static let hasOnboarded = "soyle.hasOnboarded"
        static let hasPickedLanguage = "soyle.hasPickedLanguage"
        static let hasCompletedOnboarding = "soyle.hasCompletedOnboarding"
        static let claudeCodeTTSEnabled = "soyle.claudeCodeTTSEnabled"
        static let claudeCodeTTSVoice = "soyle.claudeCodeTTSVoice"
    }

    @Published var language: SoyleLanguage {
        didSet { defaults.set(language.rawValue, forKey: K.language) }
    }
    /// Selected ASR model, persisted by Hugging Face repo id. Legacy installs
    /// stored Nemotron repo ids, which still exist in the catalog → seamless.
    @Published var modelID: String {
        didSet { defaults.set(modelID, forKey: K.model) }
    }
    var modelOption: ASRModelOption { ASRCatalog.option(forID: modelID) ?? ASRCatalog.default }
    @Published var pttKey: PushToTalk.Key {
        didSet { defaults.set(pttKey.rawValue, forKey: K.pttKey) }
    }
    @Published var playSounds: Bool {
        didSet { defaults.set(playSounds, forKey: K.playSounds) }
    }
    @Published var autoPaste: Bool {
        didSet { defaults.set(autoPaste, forKey: K.autoPaste) }
    }
    /// Double-tap the push-to-talk key to lock recording on (tap again to stop).
    @Published var handsFreeDoubleTap: Bool {
        didSet { defaults.set(handsFreeDoubleTap, forKey: K.handsFreeDoubleTap) }
    }
    /// talkink:// dictation commands. OFF by default: any app can open a URL,
    /// and starting the microphone must stay the user's explicit choice.
    @Published var allowURLAutomation: Bool {
        didSet { defaults.set(allowURLAutomation, forKey: K.allowURLAutomation) }
    }
    @Published var checkForUpdates: Bool {
        didSet { defaults.set(checkForUpdates, forKey: K.checkForUpdates) }
    }
    @Published var launchAtLogin: Bool {
        didSet { applyLoginItem(launchAtLogin) }
    }
    @Published var hasOnboarded: Bool {
        didSet { defaults.set(hasOnboarded, forKey: K.hasOnboarded) }
    }
    @Published var hasPickedLanguage: Bool {
        didSet { defaults.set(hasPickedLanguage, forKey: K.hasPickedLanguage) }
    }
    /// The full guided onboarding (language + permissions + try-it) finished.
    /// Until then the window shows the wizard instead of the History/Settings tabs.
    @Published var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: K.hasCompletedOnboarding) }
    }
    /// Read Claude Code's replies aloud with the native Kokoro voice. Off by
    /// default; only meaningful when Claude Code is installed.
    @Published var claudeCodeTTSEnabled: Bool {
        didSet { defaults.set(claudeCodeTTSEnabled, forKey: K.claudeCodeTTSEnabled) }
    }
    /// Kokoro voice id used for reading Claude Code (default = French ff_siwis).
    @Published var claudeCodeTTSVoice: String {
        didSet { defaults.set(claudeCodeTTSVoice, forKey: K.claudeCodeTTSVoice) }
    }
    /// Set on the first launch of a new version — drives this session's
    /// "updated" banner. Not persisted.
    @Published var justUpdatedToVersion: String?
    /// Why "Launch at login" couldn't be applied (shown under the toggle).
    @Published var loginItemError: String?
    private var revertingLoginItem = false

    private init() {
        language = SoyleLanguage(rawValue: defaults.string(forKey: K.language) ?? "") ?? .auto
        // Default = our bench winner (Qwen3-ASR 1.7B 8-bit); unknown stored ids
        // (e.g. after a future catalog change) also fall back to the default.
        let storedModel = defaults.string(forKey: K.model) ?? ""
        modelID = ASRCatalog.option(forID: storedModel)?.id ?? ASRCatalog.default.id
        let keyRaw = defaults.object(forKey: K.pttKey) as? Int
        pttKey = PushToTalk.Key(rawValue: keyRaw ?? PushToTalk.Key.rightOption.rawValue) ?? .rightOption
        playSounds = defaults.object(forKey: K.playSounds) as? Bool ?? true
        autoPaste = defaults.object(forKey: K.autoPaste) as? Bool ?? true
        handsFreeDoubleTap = defaults.object(forKey: K.handsFreeDoubleTap) as? Bool ?? true
        allowURLAutomation = defaults.object(forKey: K.allowURLAutomation) as? Bool ?? false
        checkForUpdates = defaults.object(forKey: K.checkForUpdates) as? Bool ?? true
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
        hasOnboarded = defaults.bool(forKey: K.hasOnboarded)
        hasPickedLanguage = defaults.bool(forKey: K.hasPickedLanguage)
        hasCompletedOnboarding = defaults.bool(forKey: K.hasCompletedOnboarding)
        claudeCodeTTSEnabled = defaults.object(forKey: K.claudeCodeTTSEnabled) as? Bool ?? false
        claudeCodeTTSVoice = defaults.string(forKey: K.claudeCodeTTSVoice) ?? TTSCatalog.default.id
    }

    private func applyLoginItem(_ on: Bool) {
        guard !revertingLoginItem else { return }
        do {
            if on {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
            loginItemError = nil
        } catch {
            loginItemError = "Couldn't \(on ? "enable" : "disable") it, \(error.localizedDescription)"
            ErrorLog.shared.record(component: "settings",
                                   message: "Launch-at-login toggle failed",
                                   detail: error.localizedDescription)
            // Snap the toggle back to what the system actually says.
            revertingLoginItem = true
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
            revertingLoginItem = false
        }
    }
}
