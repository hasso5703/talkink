import Foundation
import Combine

/// Live-updating permission status for the settings/onboarding window.
/// Polls every second — but only while the window is visible.
final class PermissionsModel: ObservableObject {
    @Published var microphone = false
    @Published var accessibility = false      // the push-to-talk key tap + auto-paste

    private var timer: Timer?

    init() {
        refresh()
    }

    deinit { timer?.invalidate() }

    /// Poll so the UI reflects grants made in System Settings. Scoped to window
    /// visibility — no point burning a 1 Hz timer forever in a menu-bar app.
    func startPolling() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let mic = Permissions.hasMicrophone
        let ax = Permissions.hasAccessibility
        if mic != microphone { microphone = mic }
        if ax != accessibility { accessibility = ax }
    }

    /// Essentials needed for push-to-talk to work at all.
    var essentialsGranted: Bool { microphone && accessibility }
}
