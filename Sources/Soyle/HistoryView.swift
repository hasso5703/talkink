import SwiftUI
import AppKit
import SoyleKit

/// Browsable history of past transcriptions. Click a row to re-copy it.
struct HistoryView: View {
    @ObservedObject var history = HistoryStore.shared
    @State private var query = ""
    @State private var copiedID: UUID?

    private var filtered: [HistoryItem] {
        query.isEmpty ? history.items
            : history.items.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let storageError = history.lastError {
                Label(storageError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                Divider()
            }
            if history.items.isEmpty {
                emptyState
            } else if filtered.isEmpty {
                noMatch
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { item in
                            row(item)
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 12))
            TextField("Search history…", text: $query)
                .textFieldStyle(.plain)
            Spacer()
            if !history.items.isEmpty {
                Text(statsLine)
                    .font(.caption2).foregroundStyle(.secondary)
                    .help("Across the dictations kept in History")
                Button(role: .destructive) { history.clear() } label: {
                    Text("Clear all").font(.caption)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var statsLine: String {
        let stats = HistoryStore.stats(of: history.items)
        var parts = ["\(stats.words.formatted()) words"]
        if stats.spokenSeconds >= 60 {
            parts.append("\(Int(stats.spokenSeconds / 60)) min spoken")
        }
        if let wpm = stats.wordsPerMinute {
            parts.append("\(wpm) wpm")
        }
        return parts.joined(separator: " · ")
    }

    private func row(_ item: HistoryItem) -> some View {
        Button {
            // Show the checkmark only when the text actually landed on the
            // clipboard — a fake "Copied" would hide a real failure.
            guard Clipboard.copy(item.text) else {
                ErrorLog.shared.record(component: "paste",
                                       message: "Clipboard write failed when re-copying from History")
                return
            }
            withAnimation { copiedID = item.id }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                if copiedID == item.id { withAnimation { copiedID = nil } }
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.text)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        Text(item.date.formatted(date: .abbreviated, time: .shortened))
                        if let lang = item.language { Text("· \(lang)") }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Group {
                    if copiedID == item.id {
                        Label("Copied", systemImage: "checkmark")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(Color.nvidia)
                    } else {
                        Image(systemName: "doc.on.doc").foregroundStyle(.secondary).opacity(0.6)
                    }
                }
                .font(.system(size: 13))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Copy") {
                if !Clipboard.copy(item.text) {
                    ErrorLog.shared.record(component: "paste",
                                           message: "Clipboard write failed when copying from History")
                }
            }
            Button("Delete", role: .destructive) { history.delete(item) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("No transcriptions yet").font(.headline)
            Text("Hold your key, speak, release, everything will appear here.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var noMatch: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 26)).foregroundStyle(.secondary)
            Text("No results").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
