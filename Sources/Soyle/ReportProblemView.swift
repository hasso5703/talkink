import SwiftUI
import AppKit
import SoyleKit

/// Transparent problem reporting: the report is shown in full BEFORE anything
/// leaves the Mac, then opens as a prefilled GitHub issue the user can still
/// edit. The full text is also copied to the clipboard (URLs get truncated).
/// No transcripts, no audio, no hidden telemetry — the journal only.
struct ReportProblemView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var report = ""
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Report a Problem")
                .font(.system(size: 17, weight: .bold))
            Text("This is everything that would be shared, your environment and the recent error journal. Never your transcripts or audio. \"Open GitHub Issue\" lets you review and edit before posting (GitHub account needed).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                Text(report)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))

            HStack(spacing: 10) {
                Button("Copy Report") {
                    copied = Clipboard.copy(report)
                }
                if copied {
                    Label("Copied", systemImage: "checkmark")
                        .font(.caption).foregroundStyle(Color.nvidia)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Open GitHub Issue…") {
                    // Clipboard carries the untruncated report, in case the
                    // URL-embedded copy got capped.
                    _ = Clipboard.copy(report)
                    if let url = DiagnosticsReport.gitHubIssueURL(report: report) {
                        NSWorkspace.shared.open(url)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .tint(.nvidia)
            }
        }
        .padding(18)
        .frame(width: 560, height: 440)
        .onAppear { report = DiagnosticsReport.compose() }
    }
}
