import SwiftUI
import SoyleKit

// MARK: - Try-it probe

/// Lets the live dictation path surface the last recognized text to the
/// onboarding's "try it" step, without coupling the wizard to AppDelegate.
/// Only written while onboarding is in progress.
final class OnboardingProbe: ObservableObject {
    static let shared = OnboardingProbe()
    @Published var lastHeard: String?
    private init() {}
}

// MARK: - Steps

enum OnboardingStep: Int, CaseIterable {
    case welcome, language, microphone, accessibility, ready

    var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
    var previous: OnboardingStep? { rawValue > 0 ? OnboardingStep(rawValue: rawValue - 1) : nil }
}

// MARK: - Wizard

/// Full-window guided setup shown on first launch: welcome, language, then the
/// three permissions walked one at a time (with a live status that advances the
/// wizard the moment each grant lands), and a "try it" finish. Replaces dropping
/// the user on the Settings tab to fend for themselves.
struct OnboardingView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var perms: PermissionsModel
    @State private var step: OnboardingStep

    init(settings: SettingsStore, perms: PermissionsModel, initialStep: OnboardingStep = .welcome) {
        self.settings = settings
        self.perms = perms
        _step = State(initialValue: initialStep)
    }

    var body: some View {
        VStack(spacing: 0) {
            ProgressDots(current: step)
                .padding(.top, 22)

            Spacer(minLength: 0)

            Group {
                switch step {
                case .welcome:         WelcomeStep(onStart: { go(.language) })
                case .language:        LanguageStep(settings: settings, onPick: { go(.microphone) })
                case .microphone:      MicrophoneStep(perms: perms)
                case .accessibility:   AccessibilityStep(perms: perms)
                case .ready:           ReadyStep(settings: settings, onFinish: finish)
                }
            }
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)))
            .id(step)

            Spacer(minLength: 0)

            navBar
                .padding(.horizontal, 28)
                .padding(.bottom, 22)
        }
        .frame(width: 500, height: 620)
        .background(
            LinearGradient(colors: [Color(nsColor: .windowBackgroundColor),
                                    Color.nvidia.opacity(0.06)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea())
        .onAppear { perms.startPolling() }
        .onDisappear { perms.stopPolling() }
        // Advance the moment a required grant lands, so the user never has to
        // come back and click "Continue".
        .onChange(of: perms.microphone) { _, granted in
            if granted, step == .microphone { go(.accessibility, after: 0.7) }
        }
        .onChange(of: perms.accessibility) { _, granted in
            if granted, step == .accessibility { go(.ready, after: 0.7) }
        }
    }

    // MARK: Navigation

    @ViewBuilder private var navBar: some View {
        HStack {
            if let prev = step.previous, step != .ready {
                Button("Back") { go(prev) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Spacer()
            switch step {
            case .welcome, .language, .ready:
                EmptyView()   // these steps own their primary button
            case .microphone:
                continueOrSkip(enabled: perms.microphone, skip: nil, next: .accessibility)
            case .accessibility:
                continueOrSkip(enabled: perms.accessibility, skip: nil, next: .ready)
            }
        }
        .frame(height: 30)
    }

    @ViewBuilder
    private func continueOrSkip(enabled: Bool, skip: String?, next: OnboardingStep) -> some View {
        HStack(spacing: 14) {
            if let skip {
                Button(skip) { go(next) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Button("Continue") { go(next) }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.4)
        }
    }

    private func go(_ to: OnboardingStep, after delay: Double = 0) {
        let move = { withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { step = to } }
        if delay > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: move) }
        else { move() }
    }

    private func finish() {
        settings.hasPickedLanguage = true
        settings.hasOnboarded = true
        settings.hasCompletedOnboarding = true
    }
}

// MARK: - Progress dots

private struct ProgressDots: View {
    let current: OnboardingStep
    var body: some View {
        HStack(spacing: 7) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { s in
                Capsule()
                    .fill(s.rawValue <= current.rawValue ? Color.nvidia : Color.secondary.opacity(0.25))
                    .frame(width: s == current ? 22 : 7, height: 7)
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: current)
            }
        }
    }
}

// MARK: - Shared chrome

/// Icon + title + subtitle scaffold so every step reads the same.
private struct StepChrome<Content: View>: View {
    let symbol: String
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().fill(Color.nvidia.opacity(0.12)).frame(width: 88, height: 88)
                Image(systemName: symbol)
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(Color.nvidia)
            }
            Text(title)
                .font(.system(size: 23, weight: .bold))
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.system(size: 13.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
            content
        }
        .padding(.horizontal, 30)
    }
}

private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 22).padding(.vertical, 10)
            .background(Capsule().fill(Color.nvidia))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

/// Live "granted / waiting" status line shared by the permission steps.
private struct GrantStatus: View {
    let granted: Bool
    let waitingText: String
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(granted ? Color.nvidia : .secondary)
            Text(granted ? "Granted" : waitingText)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(granted ? Color.nvidia : .secondary)
        }
        .animation(.easeInOut, value: granted)
    }
}

// MARK: - Steps

private struct WelcomeStep: View {
    let onStart: () -> Void
    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LinearGradient(colors: [Color.nvidia, Color.nvidia.opacity(0.65)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 96, height: 96)
                    .shadow(color: .nvidia.opacity(0.4), radius: 16, y: 6)
                Image(systemName: "waveform")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(.white)
            }
            Text("Welcome to Talkink")
                .font(.system(size: 26, weight: .bold))
            Text("On-device dictation. Hold a key, speak, and your words are typed wherever your cursor is. Nothing ever leaves your Mac.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
            Button("Get started", action: onStart)
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 4)
        }
        .padding(.horizontal, 30)
    }
}

private struct LanguageStep: View {
    @ObservedObject var settings: SettingsStore
    let onPick: () -> Void
    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        VStack(spacing: 14) {
            Text("👋").font(.system(size: 36))
            Text("Which language will you speak?")
                .font(.system(size: 21, weight: .bold))
            Text("Talkink transcribes best when it knows your language. You can change it anytime in Settings.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(SoyleLanguage.allCases.filter { $0 != .auto }) { lang in
                        Button {
                            settings.language = lang
                            settings.hasPickedLanguage = true
                            onPick()
                        } label: {
                            VStack(spacing: 5) {
                                Text(lang.flag).font(.system(size: 25))
                                Text(lang.displayName).font(.system(size: 11.5, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 11).fill(Color.nvidia.opacity(0.10)))
                            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.nvidia.opacity(0.35)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 300)

            Button {
                settings.language = .auto
                settings.hasPickedLanguage = true
                onPick()
            } label: {
                Text("🌐  I speak several, detect automatically")
                    .font(.system(size: 12.5, weight: .medium))
            }
            .buttonStyle(.link).tint(.nvidia)
        }
        .padding(.horizontal, 26)
    }
}

private struct MicrophoneStep: View {
    @ObservedObject var perms: PermissionsModel
    var body: some View {
        StepChrome(symbol: "mic.fill",
                   title: "Allow the microphone",
                   subtitle: "Talkink turns your voice into text right on your Mac. The audio is never uploaded anywhere.") {
            VStack(spacing: 14) {
                if !perms.microphone {
                    Button(Permissions.microphoneDenied ? "Open System Settings" : "Allow Microphone") {
                        if Permissions.microphoneDenied { Permissions.openMicrophoneSettings() }
                        else { Permissions.requestMicrophone { _ in perms.refresh() } }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                GrantStatus(granted: perms.microphone, waitingText: "Waiting for permission…")
            }
            .padding(.top, 6)
        }
    }
}

private struct AccessibilityStep: View {
    @ObservedObject var perms: PermissionsModel
    var body: some View {
        StepChrome(symbol: "accessibility",
                   title: "Allow Accessibility",
                   subtitle: "One switch lets Talkink notice your dictation key and type the words at your cursor. Talkink is already in the list, just flip it on, no dragging.") {
            VStack(spacing: 14) {
                if !perms.accessibility {
                    Button("Allow Accessibility") {
                        Permissions.requestAccessibility()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            if !Permissions.hasAccessibility { Permissions.openAccessibilitySettings() }
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                GrantStatus(granted: perms.accessibility, waitingText: "Waiting for the switch…")
            }
            .padding(.top, 6)
        }
    }
}

private struct ReadyStep: View {
    @ObservedObject var settings: SettingsStore
    let onFinish: () -> Void
    @ObservedObject private var center = ModelDownloadCenter.shared
    @ObservedObject private var probe = OnboardingProbe.shared

    private var modelState: ModelDownloadCenter.ModelState { center.state(of: settings.modelOption) }

    var body: some View {
        StepChrome(symbol: "checkmark.seal.fill",
                   title: "You're all set!",
                   subtitle: "Hold ⌥ Right Option, say something, and let go. Your words appear at the cursor.") {
            VStack(spacing: 14) {
                modelStatus
                tryItCard
                Button("Finish", action: onFinish)
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, 2)
            }
            .padding(.top, 6)
        }
    }

    @ViewBuilder private var modelStatus: some View {
        switch modelState {
        case .downloading(let f), .paused(let f):
            VStack(spacing: 6) {
                ProgressView(value: f).tint(.nvidia).frame(width: 240)
                Text("Downloading the model… \(Int(f * 100))% (you can start once it's ready)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .preparing:
            Text("Preparing the model…").font(.caption).foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var tryItCard: some View {
        VStack(spacing: 8) {
            if let heard = probe.lastHeard, !heard.isEmpty {
                Label("It works!", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.nvidia)
                Text("“\(heard)”")
                    .font(.system(size: 13)).italic()
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            } else {
                Text("Try it now: hold ⌥ Right Option and say “hello”.")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 12).padding(.horizontal, 16)
        .frame(maxWidth: 380)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.nvidia.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.nvidia.opacity(0.25)))
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: probe.lastHeard)
    }
}
