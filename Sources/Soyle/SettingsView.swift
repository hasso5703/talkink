import SwiftUI
import AppKit
import SoyleKit

/// Onboarding + settings (the "Settings" tab). Live permission status with grant
/// buttons, dictation prefs, behaviour, and an update notice. NVIDIA-green accents.
struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var perms: PermissionsModel
    @ObservedObject var downloads = ModelDownloadCenter.shared
    @ObservedObject var errorLog = ErrorLog.shared
    @ObservedObject var vocabulary = Vocabulary.shared
    @State private var deleteCandidate: ASRModelOption?
    @State private var showReport = false
    @State private var editingEntry: VocabularyEntry?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                Form {
                    permissionsSection
                    dictationSection
                    vocabularySection
                    modelSection
                    behaviourSection
                    supportSection
                }
                .formStyle(.grouped)
                .onAppear {
                    // A download in progress is why the window opened — put it
                    // on screen instead of leaving it below the fold.
                    guard downloads.anyDownloading else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        withAnimation { proxy.scrollTo("model-\(settings.modelID)", anchor: .center) }
                    }
                }
            }
            footer
        }
        .sheet(isPresented: $showReport) { ReportProblemView() }
        .sheet(item: $editingEntry) { entry in
            VocabularyEditSheet(entry: entry, vocabulary: vocabulary)
        }
        .onReceive(NotificationCenter.default.publisher(for: .soyleOpenReport)) { _ in
            showReport = true
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.nvidia)
                Image(systemName: "mic.fill").font(.system(size: 23, weight: .bold)).foregroundStyle(.black)
            }
            .frame(width: 50, height: 50)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("Talkink").font(.system(size: 22, weight: .bold))
                    if let version = settings.justUpdatedToVersion {
                        Text("UPDATED TO v\(version)")
                            .font(.system(size: 8.5, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.nvidia.opacity(0.18)))
                            .foregroundStyle(Color.nvidia)
                    }
                }
                Text("Hold \(settings.pttKey.displayName), speak, release.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    // MARK: Permissions

    private var permissionsSection: some View {
        Section {
            permRow(title: "Microphone", granted: perms.microphone,
                    hint: "To record your voice (nothing is sent over the Internet).",
                    button: perms.microphone ? nil : (Permissions.microphoneDenied ? "Open Settings" : "Allow")) {
                if Permissions.microphoneDenied { Permissions.openMicrophoneSettings() }
                else { Permissions.requestMicrophone { _ in perms.refresh() } }
            }
            permRow(title: "Accessibility", granted: perms.accessibility,
                    hint: "To notice your dictation key and paste at the cursor. Talkink is already in the list, just switch it on.",
                    button: perms.accessibility ? nil : "Allow") {
                // The AX prompt has its own "Open System Settings" button;
                // ours is only the fallback. AXIsProcessTrustedWithOptions also
                // registers the app in the list, so there's no "+" to click.
                Permissions.requestAccessibility()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    if !Permissions.hasAccessibility { Permissions.openAccessibilitySettings() }
                }
            }
        } header: {
            Text("Permissions")
        } footer: {
            if perms.essentialsGranted {
                Label("Everything is ready.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Color.nvidia).font(.caption)
            } else {
                Text("Microphone + Accessibility are required to function.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func permRow(title: String, granted: Bool, hint: String,
                         button: String?, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 18))
                .foregroundStyle(granted ? Color.nvidia : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let button {
                Button(button, action: action).buttonStyle(.bordered).tint(.nvidia)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: Dictation

    private var dictationSection: some View {
        Section {
            Picker("Push-to-talk key", selection: $settings.pttKey) {
                ForEach(PushToTalk.Key.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Picker("Language", selection: $settings.language) {
                ForEach(SoyleLanguage.allCases) { Text($0.displayName).tag($0) }
            }
            Toggle("Double-tap for hands-free", isOn: $settings.handsFreeDoubleTap)
        } header: {
            Text("Dictation")
        } footer: {
            Text("Hands-free: tap \(settings.pttKey.displayName) twice quickly to keep recording without holding, tap once to stop.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Vocabulary — names and jargon, fixed on-device after transcription.

    private var vocabularySection: some View {
        Section {
            ForEach(vocabulary.entries) { entry in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.phrase).font(.system(size: 13, weight: .semibold))
                        if !entry.variants.isEmpty {
                            Text("heard as: \(entry.variants.joined(separator: ", "))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button { editingEntry = entry } label: {
                        Image(systemName: "pencil").font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .help("Edit")
                    Button { vocabulary.remove(entry) } label: {
                        Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove")
                }
                .padding(.vertical, 1)
            }
            if let vocabError = vocabulary.lastError {
                Label(vocabError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            Button {
                editingEntry = VocabularyEntry(phrase: "")
            } label: {
                Label("Add Word…", systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
            .tint(.nvidia)
        } header: {
            Text("Vocabulary")
        } footer: {
            Text("Names and jargon, written your way, fixed on this Mac right after transcription (e.g. “Talkink”, heard as “Talking”). Unknown words close to one of yours are corrected automatically; real words are never touched.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Model picker — full catalog with size / quality / speed, so the
    // choice is informed (sizes are real weights, ratings from our own bench).

    private var modelSection: some View {
        Section {
            ForEach(ASRCatalog.options) { option in
                modelRow(option)
                    .id("model-\(option.id)")
                statusRow(for: option)
            }
        } header: {
            Text("Model")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let actionError = downloads.lastActionError {
                    Label(actionError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text("Models download once and stay on your Mac, you can grab several at the same time and switch instantly.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// The select action (radio + text) and the per-model controls are
    /// SEPARATE buttons side by side — nesting them made the small controls
    /// unreliable to hit and easy to mis-tap as "select".
    private func modelRow(_ option: ASRModelOption) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Button {
                settings.modelID = option.id
            } label: {
                HStack(alignment: .top, spacing: 11) {
                    Image(systemName: settings.modelID == option.id ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(settings.modelID == option.id ? Color.nvidia : Color.secondary)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 7) {
                            Text(option.displayName).font(.system(size: 13, weight: .semibold))
                            if option == ASRCatalog.default {
                                Text("RECOMMENDED")
                                    .font(.system(size: 8.5, weight: .bold))
                                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                                    .background(Capsule().fill(Color.nvidia.opacity(0.18)))
                                    .foregroundStyle(Color.nvidia)
                            }
                        }
                        Text(option.note)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 12) {
                            meter("Quality", option.quality)
                            meter("Speed", option.speed)
                        }
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            trailingControls(for: option)
        }
        .padding(.vertical, 2)
    }

    /// Right-hand side of a model row: size, on-disk status, and the actions
    /// that go with it (download / delete / retry).
    @ViewBuilder
    private func trailingControls(for option: ASRModelOption) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(option.sizeLabel)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.secondary)
            switch downloads.state(of: option) {
            case .active:
                Text("ACTIVE")
                    .font(.system(size: 8.5, weight: .bold))
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.nvidia))
                    .foregroundStyle(.black)
                    .help("The model in use, select another one to free or delete it.")
            case .preparing:
                Label("On this Mac", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.nvidia)
            case .downloaded:
                HStack(spacing: 6) {
                    Label("On this Mac", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.nvidia)
                    Button {
                        deleteCandidate = option
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Delete from this Mac (\(option.sizeLabel)), you can download it again anytime.")
                }
            case .downloading(let fraction):
                Text(String(format: "%.0f%%", fraction * 100))
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.nvidia)
            case .notDownloaded:
                // One click pre-fetches without switching models — several can
                // download at once.
                Button {
                    downloads.ensureDownloaded(option)
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.borderless)
                .tint(.nvidia)
            case .paused(let fraction):
                HStack(spacing: 6) {
                    Button {
                        downloads.ensureDownloaded(option)
                    } label: {
                        Label(String(format: "Resume, %.0f%% here", fraction * 100),
                              systemImage: "arrow.down.circle")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .tint(.nvidia)
                    .help("The interrupted download is safe on disk, continue where it stopped.")
                    Button {
                        deleteCandidate = option
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Discard the partial download.")
                }
            case .failed:
                Button {
                    downloads.ensureDownloaded(option)
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.borderless)
                .tint(.orange)
            }
        }
        .confirmationDialog(
            "Delete \(deleteCandidate?.displayName ?? "") (\(deleteCandidate?.sizeLabel ?? "")) from this Mac?",
            isPresented: Binding(
                get: { deleteCandidate == option },
                set: { if !$0 { deleteCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let candidate = deleteCandidate { downloads.deleteFromDisk(candidate) }
                deleteCandidate = nil
            }
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
        } message: {
            Text("You can download it again anytime.")
        }
    }

    /// Extra row under a model while something is happening to it: live
    /// progress bar (with cancel) during download, spinner while loading.
    @ViewBuilder
    private func statusRow(for option: ASRModelOption) -> some View {
        switch downloads.state(of: option) {
        case .downloading(let fraction):
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: max(0.01, fraction))
                        .tint(.nvidia)
                    HStack {
                        Text("Downloading \(option.displayName)…")
                        Spacer()
                        Text(String(format: "%.0f%% of %@", fraction * 100, option.sizeLabel))
                            .monospacedDigit()
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    downloads.cancelDownload(option)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Pause, picks up right here next time")
            }
            .padding(.leading, 26).padding(.vertical, 3)
        case .preparing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Preparing the model…").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.leading, 26).padding(.vertical, 3)
        case .failed(let reason):
            // The actual reason (offline / rate-limit / disk full…), not a
            // generic shrug — the user should know what to fix before Retry.
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
                .padding(.leading, 26).padding(.vertical, 3)
        default:
            EmptyView()
        }
    }

    private func meter(_ label: String, _ value: Int) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { i in
                    Circle()
                        .fill(i < value ? Color.nvidia : Color.secondary.opacity(0.25))
                        .frame(width: 5, height: 5)
                }
            }
        }
    }

    // MARK: Behaviour

    private var behaviourSection: some View {
        Section {
            Toggle("Paste automatically at the cursor", isOn: $settings.autoPaste)
            Toggle("Feedback sounds", isOn: $settings.playSounds)
            Toggle("Launch at login", isOn: $settings.launchAtLogin)
            if let loginError = settings.loginItemError {
                Label(loginError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            Toggle("Check for updates automatically", isOn: $settings.checkForUpdates)
            Toggle("Allow URL automation (talkink://)", isOn: $settings.allowURLAutomation)
        } header: {
            Text("Behaviour")
        } footer: {
            Text("URL automation lets Raycast, Shortcuts or a terminal start dictation (talkink://toggle). Off by default, any app could trigger the microphone otherwise.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Support — the error journal is user-visible by design: nothing
    // fails silently, and a GitHub report is one click away.

    private var supportSection: some View {
        Section {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Something not working?").font(.system(size: 13, weight: .medium))
                    Text("The report shows exactly what would be shared, never your transcripts.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Report a Problem…") { showReport = true }
                    .buttonStyle(.bordered).tint(.nvidia)
            }
            .padding(.vertical, 2)
            if !errorLog.entries.isEmpty {
                DisclosureGroup("Recent issues (\(errorLog.entries.count))") {
                    ForEach(errorLog.entries.prefix(5)) { entry in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.message)
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("\(entry.component) · \(entry.date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    Button("Clear journal") { ErrorLog.shared.clear() }
                        .buttonStyle(.borderless).font(.caption)
                }
                .font(.system(size: 12))
            }
        } header: {
            Text("Support")
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            // Reflects the model actually in use — the catalog is multi-engine now.
            Text("v\(appVersion) · 100% local · \(settings.modelOption.displayName) + MLX")
                .font(.caption2).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
    }

    private var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
    }
}

/// Add/edit one vocabulary entry. Presented with `.sheet(item:)`, so `entry`
/// is the source of truth for new-vs-existing (an id already in the store
/// means edit).
private struct VocabularyEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var phrase: String
    @State private var variantsText: String
    private let entryID: UUID
    private let isNew: Bool
    private let vocabulary: Vocabulary

    init(entry: VocabularyEntry, vocabulary: Vocabulary) {
        _phrase = State(initialValue: entry.phrase)
        _variantsText = State(initialValue: entry.variants.joined(separator: ", "))
        entryID = entry.id
        isNew = !vocabulary.entries.contains { $0.id == entry.id }
        self.vocabulary = vocabulary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "Add Word" : "Edit Word")
                .font(.system(size: 15, weight: .bold))
            VStack(alignment: .leading, spacing: 4) {
                Text("Write it as").font(.caption).foregroundStyle(.secondary)
                TextField("Talkink", text: $phrase)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Heard as (optional, comma-separated)")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Talking, tall kink", text: $variantsText)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(isNew ? "Add" : "Save") {
                    var entry = VocabularyEntry(
                        phrase: phrase,
                        variants: variantsText.split(separator: ",").map(String.init))
                    entry.id = entryID
                    if isNew { vocabulary.add(entry) } else { vocabulary.update(entry) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .tint(.nvidia)
                .disabled(phrase.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 400)
    }
}
