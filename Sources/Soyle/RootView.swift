import SwiftUI
import SoyleKit

/// The app's main window: the guided onboarding until it's complete, then the
/// History (transcriptions) and Settings tabs.
struct RootView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var perms: PermissionsModel
    @State private var selection = 0

    var body: some View {
        if settings.hasCompletedOnboarding {
            tabs
        } else {
            OnboardingView(settings: settings, perms: perms)
        }
    }

    private var tabs: some View {
        TabView(selection: $selection) {
            HistoryView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(0)
            SettingsView(settings: settings, perms: perms)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(1)
        }
        .frame(width: 500, height: 620)
        .onAppear {
            // Land on Settings when a model is downloading or essentials are
            // somehow missing, so the relevant controls are what the user sees.
            if !perms.essentialsGranted || ModelDownloadCenter.shared.anyDownloading { selection = 1 }
        }
        .onReceive(NotificationCenter.default.publisher(for: .soyleShowHistory)) { _ in selection = 0 }
        .onReceive(NotificationCenter.default.publisher(for: .soyleShowSettings)) { _ in selection = 1 }
    }
}
