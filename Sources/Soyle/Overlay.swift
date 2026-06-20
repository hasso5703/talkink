import AppKit
import SwiftUI

/// NVIDIA green.
extension Color {
    static let nvidia = Color(red: 0x76 / 255, green: 0xB9 / 255, blue: 0x00 / 255)
}
extension NSColor {
    static let nvidia = NSColor(red: 0x76 / 255, green: 0xB9 / 255, blue: 0x00 / 255, alpha: 1)
}

/// How a dictation ended — each case gets its own honest pill wording, so the
/// user always knows what happened (and why auto-paste didn't, when it didn't).
enum DictationOutcome: Equatable {
    case pasted
    case copied                    // auto-paste disabled in Settings
    case copiedNoAccessibility     // wanted to paste, Accessibility not granted
    case copiedSecureField         // OS blocks synthetic ⌘V into password fields
    case noSpeech                  // silence — nothing worth transcribing
    case notRecognized             // speech detected, model produced nothing
    case wrongLanguage(String)     // speech detected, forced language produced nothing
}

enum OverlayState: Equatable {
    case hidden
    case recording(handsFree: Bool)
    case transcribing
    case done(DictationOutcome)
    case error(String)
}

/// Observable state shared between the panel and SwiftUI view.
final class OverlayModel: ObservableObject {
    @Published var state: OverlayState = .hidden
    @Published var level: Float = 0
}

// MARK: - View

struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        ZStack {
            if model.state != .hidden {
                pill
                    .transition(.scale(scale: 0.85, anchor: .bottom)
                        .combined(with: .opacity)
                        .combined(with: .move(edge: .bottom)))
            }
        }
        .padding(24)   // breathing room so the capsule's glow/shadow isn't clipped
        .animation(.spring(response: 0.36, dampingFraction: 0.7), value: model.state)
    }

    private var pill: some View {
        HStack(spacing: 11) {
            content
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(minWidth: 150)
        .background(
            ZStack {
                // Dark HUD so white text stays readable on ANY background (incl. white).
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.55))
            }
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.nvidia.opacity(0.7), lineWidth: 1.2)
            )
        )
        .compositingGroup()
        .shadow(color: .nvidia.opacity(0.35), radius: 16)
        .shadow(color: .black.opacity(0.30), radius: 10, y: 5)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .hidden:
            EmptyView()
        case .recording(let handsFree):
            RecordingDot()
            LiveWaveform(level: model.level)
            label(handsFree ? "Speak, tap to stop" : "Speak…")
        case .transcribing:
            BouncingDots()
            label("Transcribing…")
        case .done(let outcome):
            Image(systemName: doneSymbol(outcome))
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(doneIsSuccess(outcome) ? Color.nvidia : Color.orange)
                .transition(.scale.combined(with: .opacity))
            label(doneLabel(outcome))
        case .error(let msg):
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.orange)
            label(msg)
        }
    }

    private func doneLabel(_ outcome: DictationOutcome) -> String {
        switch outcome {
        case .pasted: return "Pasted"
        case .copied: return "Copied"
        case .copiedNoAccessibility: return "Copied, allow Accessibility to auto-paste"
        case .copiedSecureField: return "Copied, secure field, paste with ⌘V"
        case .noSpeech: return "No speech detected"
        case .notRecognized: return "Heard speech, but couldn't make out words"
        case .wrongLanguage(let lang): return "Heard speech, but nothing in \(lang). Try Auto?"
        }
    }

    private func doneSymbol(_ outcome: DictationOutcome) -> String {
        doneIsSuccess(outcome) ? "checkmark.circle.fill" : "waveform.slash"
    }

    /// A green check only when there IS text on the clipboard — an empty
    /// result with a checkmark would be a small lie.
    private func doneIsSuccess(_ outcome: DictationOutcome) -> Bool {
        switch outcome {
        case .pasted, .copied, .copiedNoAccessibility, .copiedSecureField: return true
        case .noSpeech, .notRecognized, .wrongLanguage: return false
        }
    }

    private func label(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 13.5, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 1, y: 0.5)
            .multilineTextAlignment(.center)
            .lineLimit(4)                  // long status lines wrap instead of cropping
            .minimumScaleFactor(0.82)      // shrink a touch before spilling past 4 lines
            .frame(maxWidth: 250)          // wrap width — keeps the capsule a sane shape
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Animated pieces

/// Pulsing green "recording" dot.
private struct RecordingDot: View {
    @State private var pulse = false
    var body: some View {
        Circle()
            .fill(Color.nvidia)
            .frame(width: 9, height: 9)
            .shadow(color: .nvidia.opacity(0.8), radius: pulse ? 5 : 1)
            .opacity(pulse ? 1 : 0.4)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.65).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}

/// Live waveform that breathes continuously and grows with the mic level.
private struct LiveWaveform: View {
    var level: Float
    private let bars = 7

    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<bars, id: \.self) { i in
                    Capsule()
                        .fill(Color.nvidia)
                        .frame(width: 3.2, height: height(i, t))
                }
            }
            .frame(height: 24)
        }
    }

    private func height(_ i: Int, _ t: Double) -> CGFloat {
        let lvl = Double(max(0.05, min(1, level)))
        let phase = Double(i) * 0.8
        let wave = (sin(t * 8 + phase) + 1) / 2            // 0...1
        let amp = 5 + lvl * 19 * (0.45 + 0.55 * wave)
        return CGFloat(amp)
    }
}

/// Three green dots bouncing in sequence (transcribing indicator).
private struct BouncingDots: View {
    private let n = 3
    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<n, id: \.self) { i in
                    Circle()
                        .fill(Color.nvidia)
                        .frame(width: 6.5, height: 6.5)
                        .offset(y: -CGFloat(max(0, sin(t * 6 - Double(i) * 0.7))) * 5)
                }
            }
            .frame(height: 24)
        }
    }
}

// MARK: - Controller

/// Manages the borderless floating NSPanel that hosts the overlay.
final class OverlayController {
    let model = OverlayModel()
    private var panel: NSPanel?
    private var host: NSHostingView<OverlayView>?
    private var hideWorkItem: DispatchWorkItem?

    // The panel is invisible (clear background); only the centered capsule
    // shows. It's resized to the SwiftUI content's fitting size on every
    // state change, so a short status hugs tight and a long one wraps onto
    // several lines without ever being clipped. This is the ceiling.
    private let maxPanelSize = NSSize(width: 460, height: 260)

    init() {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: maxPanelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false

        let host = NSHostingView(rootView: OverlayView(model: model))
        host.frame = NSRect(origin: .zero, size: maxPanelSize)
        panel.contentView = host
        self.panel = panel
        self.host = host
    }

    func show(_ state: OverlayState, autoHideAfter seconds: Double? = nil) {
        DispatchQueue.main.async {
            self.hideWorkItem?.cancel()
            self.model.state = state
            self.resizeToContent()                  // fit the panel to this message
            self.panel?.orderFrontRegardless()
            if let seconds {
                let work = DispatchWorkItem { [weak self] in self?.hide() }
                self.hideWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
            }
        }
    }

    /// Size the panel to the SwiftUI content (clamped to the ceiling) and
    /// re-anchor it, so the capsule grows/shrinks with the message instead of
    /// cropping it.
    private func resizeToContent() {
        guard let panel, let host else { return }
        host.layoutSubtreeIfNeeded()
        var size = host.fittingSize
        size.width = min(max(size.width, 96), maxPanelSize.width)
        size.height = min(max(size.height, 64), maxPanelSize.height)
        host.frame = NSRect(origin: .zero, size: size)
        panel.setContentSize(size)
        position(size: size)
    }

    func updateLevel(_ level: Float) {
        DispatchQueue.main.async { self.model.level = level }
    }

    func hide() {
        DispatchQueue.main.async {
            self.model.state = .hidden               // plays the exit transition
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.model.state == .hidden else { return }
                self.panel?.orderOut(nil)
            }
            self.hideWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        }
    }

    private func position(size: NSSize) {
        guard let panel else { return }
        // Anchor the pill to the window the user is dictating into — a fixed
        // screen-bottom anchor lands on whatever window sits behind when the
        // active window is small, and on the wrong display on multi-screen
        // setups (NSScreen.main is OUR key window's screen, not the user's).
        let window = WindowLocator.activeWindowFrame()
        let screen = window.flatMap { w in NSScreen.screens.first { $0.frame.intersects(w) } }
            ?? screenWithMouse() ?? NSScreen.main ?? NSScreen.screens.first
        guard let vf = screen?.visibleFrame, vf.width > 0 else { return }

        var pillCenter: NSPoint
        if let w = window {
            pillCenter = NSPoint(x: w.midX, y: w.minY + 76)    // just above the window's bottom edge
        } else {
            pillCenter = NSPoint(x: vf.midX, y: vf.minY + 180) // bottom-center of the screen
        }
        // Keep the pill comfortably on screen, using its actual size.
        pillCenter.x = min(max(pillCenter.x, vf.minX + size.width / 2), vf.maxX - size.width / 2)
        pillCenter.y = min(max(pillCenter.y, vf.minY + size.height / 2), vf.maxY - size.height / 2)
        panel.setFrameOrigin(NSPoint(x: pillCenter.x - size.width / 2,
                                     y: pillCenter.y - size.height / 2))
    }

    private func screenWithMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
    }
}
