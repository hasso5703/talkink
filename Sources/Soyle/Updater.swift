import AppKit
import Foundation
import Sparkle
import SoyleKit

/// Sparkle auto-updates. The feed is appcast.xml on the repo's main branch;
/// release archives are EdDSA-signed (SUPublicEDKey in Info.plist).
final class Updater: NSObject, SPUUpdaterDelegate {
    static let shared = Updater()

    private var controller: SPUStandardUpdaterController!

    /// A scheduled check found a new version — drives the prominent
    /// "Update to X, Install…" menu item. Called on the main queue.
    var onUpdateAvailable: ((String) -> Void)?

    /// Mirrors Settings → "Check for updates automatically".
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    // MARK: SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Log.update.notice("update available: \(item.displayVersionString, privacy: .public)")
        DispatchQueue.main.async { [weak self] in
            self?.onUpdateAvailable?(item.displayVersionString)
            // Menu-bar app, no Dock presence: without activation Sparkle's
            // scheduled-check alert can sit invisible behind other windows.
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Sparkle's installer agent proved unreliable at relaunching when the
    /// updated app sits at the same path as the quitting instance (verified on
    /// macOS 26 — the agent exits ~0.5s in; upstream: Sparkle #273, #1717).
    /// The host-side relaunch hook never fires either (relaunch belongs to the
    /// dead agent), so the watcher is armed at willInstallUpdate — a hook that
    /// provably fires (the install itself always succeeds). The detached helper
    /// waits for THIS process to die, then opens the updated bundle; if any
    /// Sparkle relaunch also works, the extra `open` is a no-op.
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        Log.update.notice("willInstallUpdate \(item.displayVersionString, privacy: .public) — arming relauncher")
        spawnDetachedRelauncher()
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        Log.update.notice("willRelaunchApplication, arming relauncher")
        spawnDetachedRelauncher()
    }

    private var relauncherSpawned = false

    private func spawnDetachedRelauncher() {
        guard !relauncherSpawned else { return }
        relauncherSpawned = true
        let bundlePath = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        LOG=/tmp/soyle_relauncher.log
        echo "$(date '+%H:%M:%S') armed: waiting for pid \(pid)" >> "$LOG"
        for i in $(seq 1 120); do
          if ! /bin/kill -0 \(pid) 2>/dev/null; then
            /bin/sleep 0.7
            echo "$(date '+%H:%M:%S') pid \(pid) gone, opening app" >> "$LOG"
            /usr/bin/open "\(bundlePath)" >> "$LOG" 2>&1
            exit 0
          fi
          /bin/sleep 0.5
        done
        echo "$(date '+%H:%M:%S') timeout, app never exited" >> "$LOG"
        """
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script]
        do {
            try helper.run()   // not waited on — must outlive us
        } catch {
            // The Sparkle swap still succeeds; only the relaunch is lost.
            // Recorded so the report explains "the app quit and stayed quit";
            // the post-update window-open closes the loop on manual relaunch.
            relauncherSpawned = false   // the other hook may retry
            ErrorLog.shared.record(component: "update",
                                   message: "Update installs, but the relauncher couldn't start, relaunch Talkink manually after this update",
                                   detail: error.localizedDescription)
        }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let ns = error as NSError
        Log.update.error("updater aborted: \(ns.localizedDescription, privacy: .public) (code \(ns.code))")
        // 1001 = "you're up to date" after a manual check; cancellations are
        // user choices — neither is a failure worth the journal.
        if ns.domain == "SUSparkleErrorDomain", ns.code == 1001 { return }
        if ns.localizedDescription.localizedCaseInsensitiveContains("cancel") { return }
        ErrorLog.shared.record(component: "update",
                               message: "Update aborted, \(ns.localizedDescription)",
                               detail: "\(ns.domain) code \(ns.code)")
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if let error {
            Log.update.error("update cycle ended with error: \(String(describing: error), privacy: .public)")
        }
    }
}
