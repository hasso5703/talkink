#if SOYLE_DEVTOOLS
import AppKit
import SwiftUI
import SoyleKit

/// Dev-only: render every onboarding step to a PNG offscreen, so the wizard's
/// look can be reviewed without a live run or real system permission prompts.
/// Usage: Soyle --onboarding-shots [OUTDIR]
enum OnboardingShots {
    static func run(outDir: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let settings = SettingsStore.shared
        let perms = PermissionsModel()
        OnboardingProbe.shared.lastHeard = "hello world, testing Talkink"   // fills the "try it" card

        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let size = NSSize(width: 500, height: 620)

        for step in OnboardingStep.allCases {
            let host = NSHostingView(rootView: OnboardingView(settings: settings, perms: perms, initialStep: step))
            host.frame = NSRect(origin: .zero, size: size)
            let win = NSWindow(contentRect: NSRect(x: -9000, y: -9000, width: size.width, height: size.height),
                               styleMask: [.borderless], backing: .buffered, defer: false)
            win.isOpaque = true
            win.backgroundColor = .windowBackgroundColor
            win.contentView = host
            win.orderFront(nil)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))   // let SwiftUI settle/animate one frame

            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: "\(outDir)/\(step.rawValue)_\(step).png"))
                }
            }
            win.orderOut(nil)
            FileHandle.standardError.write(Data("rendered step \(step.rawValue) (\(step))\n".utf8))
        }
        FileHandle.standardError.write(Data("written to \(outDir)\n".utf8))
        exit(0)
    }
}
#endif
