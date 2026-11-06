import AppKit
import ApplicationServices
import AVFoundation
import BuddyCore
import Speech

@MainActor
struct PermissionAdapter {
    func snapshot() -> PermissionSnapshot {
        PermissionSnapshot(
            microphone: microphoneStatus,
            speechRecognition: speechStatus,
            screenCapture: CGPreflightScreenCaptureAccess() ? .granted : .notGranted,
            accessibility: AXIsProcessTrusted() ? .granted : .notGranted,
            inputMonitoring: CGPreflightListenEventAccess() ? .granted : .notGranted
        )
    }

    func request(_ permission: Permission) async {
        switch permission {
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .speechRecognition:
            _ = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        case .screenCapture:
            _ = CGRequestScreenCaptureAccess()
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .inputMonitoring:
            _ = CGRequestListenEventAccess()
        }
    }

    func openSettings(for permission: Permission) {
        let pane: String
        switch permission {
        case .microphone: pane = "Privacy_Microphone"
        case .speechRecognition: pane = "Privacy_SpeechRecognition"
        case .screenCapture: pane = "Privacy_ScreenCapture"
        case .accessibility: pane = "Privacy_Accessibility"
        case .inputMonitoring: pane = "Privacy_ListenEvent"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    private var microphoneStatus: PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .unknown
        }
    }

    private var speechStatus: PermissionStatus {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .unknown
        }
    }
}
