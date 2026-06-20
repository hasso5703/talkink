import Foundation
import SoyleKit

extension ModelDownloadCenter.ModelState {
    /// True for any `.failed` payload — keeps call sites readable.
    var isFailed: Bool { if case .failed = self { return true } else { return false } }
}

/// Single source of truth for every catalog model's on-disk/download state.
/// Downloads run concurrently (one task per repo), are cancellable, and
/// resume byte-exactly thanks to `ModelDownloader`'s `.part` files — so the
/// user can queue several models at once, quit, relaunch, and lose nothing.
/// Selection (which model dictation uses) is deliberately independent.
@MainActor
final class ModelDownloadCenter: ObservableObject {
    static let shared = ModelDownloadCenter()

    enum ModelState: Equatable {
        case notDownloaded
        case paused(Double)        // interrupted download — this much already on disk
        case downloading(Double)   // 0…1, byte-accurate
        case downloaded            // complete on disk, not the active model
        case preparing             // selected: weights → memory / Metal warm-up
        case active                // selected, loaded, ready to dictate
        case failed(String)        // download failed — human-readable reason, retryable
    }

    @Published private(set) var states: [String: ModelState] = [:]
    /// Last non-download action that failed (delete…) — surfaced in Settings.
    @Published var lastActionError: String?

    private var downloadTasks: [String: Task<Void, Error>] = [:]

    private init() {
        refreshFromDisk()
    }

    func state(of option: ASRModelOption) -> ModelState {
        states[option.id] ?? .notDownloaded
    }

    var anyDownloading: Bool {
        states.values.contains { if case .downloading = $0 { return true } else { return false } }
    }

    /// Re-derive on-disk states from the cache without clobbering rows that
    /// are mid-download or loading. An interrupted download (quit, cancel,
    /// crash) shows up as `.paused` with its real on-disk fraction, so the
    /// user knows the bytes are safe and one click resumes.
    func refreshFromDisk() {
        for option in ASRCatalog.options {
            switch states[option.id] {
            case .downloading, .preparing, .active:
                continue
            default:
                if ModelDownloader.isCached(repo: option.id) {
                    states[option.id] = .downloaded
                } else if let fraction = ModelDownloader.partialFraction(
                    repo: option.id, expectedBytes: Int64(option.sizeGB * 1_000_000_000)) {
                    states[option.id] = .paused(fraction)
                } else {
                    states[option.id] = .notDownloaded
                }
            }
        }
    }

    /// Start (or join) the concurrent download of one model. Safe to call for
    /// a model that's already downloading or on disk.
    @discardableResult
    func ensureDownloaded(_ option: ASRModelOption) -> Task<Void, Error> {
        if let running = downloadTasks[option.id] { return running }
        switch state(of: option) {
        case .downloaded, .preparing, .active:
            return Task {}
        default:
            break
        }
        // Pre-flight: a download doomed by disk space should fail instantly
        // with the reason, not at 97% twenty minutes in. (The HF cache lives
        // under the home volume.)
        let neededBytes = max(Int64(option.sizeGB * 1_000_000_000) - ModelDownloader.diskUsage(repo: option.id), 0)
        if let free = SystemResources.freeDiskBytes(for: FileManager.default.homeDirectoryForCurrentUser),
           let shortfall = SystemResources.diskPreflight(neededBytes: neededBytes, freeBytes: free) {
            let message = shortfall.errorDescription ?? "Not enough disk space."
            states[option.id] = .failed(message)
            ErrorLog.shared.record(component: "download",
                                   message: "\(option.displayName): \(message)")
            return Task { throw shortfall }
        }
        states[option.id] = .downloading(0)
        let task = Task<Void, Error> { [weak self] in
            do {
                try await ModelDownloader.download(repo: option.id) { fraction in
                    Task { @MainActor [weak self] in
                        // Only while still downloading — a cancel may have landed.
                        if case .downloading = self?.states[option.id] ?? .notDownloaded {
                            self?.states[option.id] = .downloading(fraction)
                        }
                    }
                }
                await MainActor.run { [weak self] in
                    self?.downloadTasks[option.id] = nil
                    self?.states[option.id] = .downloaded
                }
            } catch {
                let cancelled = error is CancellationError
                    || (error as? URLError)?.code == .cancelled
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.downloadTasks[option.id] = nil
                    if ModelDownloader.isCached(repo: option.id) {
                        self.states[option.id] = .downloaded
                    } else if cancelled {
                        // Partial bytes stay on disk — surface them so the row
                        // says "Resume" with the real fraction.
                        if let fraction = ModelDownloader.partialFraction(
                            repo: option.id, expectedBytes: Int64(option.sizeGB * 1_000_000_000)) {
                            self.states[option.id] = .paused(fraction)
                        } else {
                            self.states[option.id] = .notDownloaded
                        }
                    } else {
                        let reason = Self.humanMessage(for: error)
                        self.states[option.id] = .failed(reason)
                        ErrorLog.shared.record(component: "download",
                                               message: "\(option.displayName) download failed, \(reason)",
                                               detail: String(describing: error))
                    }
                }
                throw error
            }
        }
        downloadTasks[option.id] = task
        return task
    }

    /// Raw transport errors → something the user can act on.
    static func humanMessage(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .dataNotAllowed:
                return "You appear to be offline."
            case .networkConnectionLost:
                return "The connection dropped, Resume picks up where it stopped."
            case .timedOut:
                return "The connection timed out, check your network, then Retry."
            case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost:
                return "huggingface.co can't be reached (network or DNS)."
            default:
                break
            }
        }
        if case ModelDownloader.DownloadError.badStatus(let code, _) = error {
            switch code {
            case 401, 403: return "Hugging Face refused the request (HTTP \(code))."
            case 429: return "Hugging Face is rate-limiting downloads, wait a minute, then Retry."
            case 500...599: return "Hugging Face is having trouble (HTTP \(code)), try again later."
            default: return "Download failed (HTTP \(code))."
            }
        }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteOutOfSpaceError {
            return "The disk filled up mid-download, free some space, then Resume."
        }
        return ns.localizedDescription
    }

    /// Cancel an in-flight download. The `.part` partial stays on disk, so a
    /// later download resumes instead of restarting.
    func cancelDownload(_ option: ASRModelOption) {
        downloadTasks[option.id]?.cancel()
    }

    // MARK: Selected-model load lifecycle (driven by AppDelegate)

    func markPreparing(_ option: ASRModelOption) {
        states[option.id] = .preparing
    }

    func markActive(_ option: ASRModelOption) {
        for (id, state) in states where state == .active {
            states[id] = .downloaded
        }
        states[option.id] = .active
    }

    /// The selected model failed to load (not download) — put its row back to
    /// whatever the disk says.
    func clearLoadMarker(_ option: ASRModelOption) {
        states[option.id] = ModelDownloader.isCached(repo: option.id)
            ? .downloaded : .notDownloaded
    }

    /// Delete a downloaded model from disk. Refused for the model in use —
    /// the UI requires switching first, so dictation can never lose its
    /// weights mid-flight.
    func deleteFromDisk(_ option: ASRModelOption) {
        switch state(of: option) {
        case .active, .preparing, .downloading:
            return
        default:
            break
        }
        do {
            try ModelDownloader.delete(repo: option.id)
            states[option.id] = .notDownloaded
            lastActionError = nil
        } catch {
            lastActionError = "Couldn't delete \(option.displayName), \(error.localizedDescription)"
            ErrorLog.shared.record(component: "download",
                                   message: "Model delete failed for \(option.displayName)",
                                   detail: error.localizedDescription)
            refreshFromDisk()
        }
    }
}
