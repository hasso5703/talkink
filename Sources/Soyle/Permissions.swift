import Foundation
import AppKit
import AVFoundation
import ApplicationServices

/// Permissions used by Talkink:
///  • Microphone — to record (required).
///  • Accessibility — lets the listen-only event tap see the push-to-talk key
///    AND lets auto-paste post ⌘V. It's a superset that covers both "listen"
///    and "post" (per Apple DTS), so it's the single key+paste permission, and
///    AXIsProcessTrustedWithOptions auto-registers the app in the Accessibility
///    list, so the user just flips the switch (no manual "+", no drag).
enum Permissions {

    // MARK: Microphone
    static var hasMicrophone: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static var microphoneDenied: Bool {
        let s = AVCaptureDevice.authorizationStatus(for: .audio)
        return s == .denied || s == .restricted
    }

    static func requestMicrophone(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    // MARK: Accessibility (the push-to-talk key tap + auto-paste)
    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// Prompt for Accessibility. AXIsProcessTrustedWithOptions both shows the
    /// system prompt and registers the app in the Accessibility list, so the
    /// user only has to flip the switch.
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private static func open(_ urlString: String) {
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }
}
