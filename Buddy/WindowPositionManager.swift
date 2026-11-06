enum PermissionRequestPresentationDestination: Equatable {
    case alreadyGranted, systemPrompt, systemSettings
}

enum WindowPositionManager {
    static func permissionRequestPresentationDestination(
        hasPermissionNow: Bool,
        hasAttemptedSystemPrompt: Bool
    ) -> PermissionRequestPresentationDestination {
        if hasPermissionNow { return .alreadyGranted }
        return hasAttemptedSystemPrompt ? .systemSettings : .systemPrompt
    }

    static func shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
        hasScreenRecordingPermissionNow: Bool,
        hasPreviouslyConfirmedScreenRecordingPermission: Bool
    ) -> Bool {
        hasScreenRecordingPermissionNow || hasPreviouslyConfirmedScreenRecordingPermission
    }
}
