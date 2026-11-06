import Testing
import BuddyCore

struct BuddyEngineTests {
    @Test func noProviderTurnEndsWithNotice() {
        var engine = BuddyEngine()
        #expect(engine.handle(.pushToTalkPressed) == [.showNotch(.listening(heard: ""))])
        #expect(engine.handle(.pushToTalkReleased) == [.showNotch(.notice("No provider connected."))])
    }
    @Test func firstPermissionRequestPromptsAndRetryOpensSettings() {
        var engine = BuddyEngine()
        #expect(engine.handle(.permissionsObserved(.init(screenCapture: .notGranted))) == [])
        #expect(engine.handle(.permissionRequested(.screenCapture)) == [.requestPermission(.screenCapture)])
        #expect(engine.handle(.permissionRequested(.screenCapture)) == [.openPermissionSettings(.screenCapture)])
    }

    @Test func launchAtLoginRequiresOwnerActionAndSerializesChanges() {
        var engine = BuddyEngine()
        #expect(engine.state.loginItem == .off)
        #expect(engine.handle(.loginItemObserved(.off)) == [])
        #expect(engine.handle(.launchAtLoginRequested(true)) == [.setLaunchAtLogin(true)])
        #expect(engine.state.loginChangePending == true)
        #expect(engine.handle(.launchAtLoginRequested(false)) == [])
        #expect(engine.handle(.loginItemChangeFinished(.requiresApproval, error: nil)) == [])
        #expect(engine.state.loginChangePending == false)
        #expect(engine.state.loginItem == .requiresApproval)
        #expect(engine.handle(.launchAtLoginRequested(true)) == [.openLoginItemSettings])
        #expect(engine.handle(.launchAtLoginRequested(false)) == [.setLaunchAtLogin(false)])
    }

    @Test func interruptionClearsHeldTurnWithoutProviderNotice() {
        var engine = BuddyEngine()
        #expect(engine.handle(.pushToTalkPressed) == [.showNotch(.listening(heard: ""))])
        #expect(engine.handle(.interrupted) == [.hideBuddy, .showNotch(.idle)])
        #expect(engine.state.turn == .idle)
        #expect(engine.handle(.pushToTalkReleased) == [])
    }

    @Test func losingInputMonitoringCancelsHeldShortcut() {
        var engine = BuddyEngine()
        #expect(engine.handle(.permissionsObserved(.init(inputMonitoring: .granted))) == [])
        #expect(engine.handle(.pushToTalkPressed) == [.showNotch(.listening(heard: ""))])
        #expect(engine.handle(.permissionsObserved(.init(inputMonitoring: .notGranted))) == [.hideBuddy, .showNotch(.idle)])
        #expect(engine.state.turn == .idle)
        #expect(engine.handle(.pushToTalkReleased) == [])
    }

    @Test func duplicateShortcutEventsDoNotDuplicateTurns() {
        var engine = BuddyEngine()
        #expect(engine.handle(.pushToTalkReleased) == [])
        #expect(engine.handle(.pushToTalkPressed) == [.showNotch(.listening(heard: ""))])
        #expect(engine.handle(.pushToTalkPressed) == [])
        #expect(engine.handle(.pushToTalkReleased) == [.showNotch(.notice("No provider connected."))])
        #expect(engine.handle(.pushToTalkReleased) == [])
        #expect(engine.state.turn == .idle)
    }

    @Test func noticeExpiresWithoutClearingANewerHeldTurn() {
        var engine = BuddyEngine()
        #expect(engine.handle(.pushToTalkPressed) == [.showNotch(.listening(heard: ""))])
        #expect(engine.handle(.pushToTalkReleased) == [.showNotch(.notice("No provider connected."))])
        #expect(engine.state.notice == "No provider connected.")
        #expect(engine.handle(.pushToTalkPressed) == [.showNotch(.listening(heard: ""))])
        #expect(engine.state.notice == nil)
        #expect(engine.handle(.noticeExpired) == [])
        #expect(engine.state.turn == .held)
        #expect(engine.handle(.pushToTalkReleased) == [.showNotch(.notice("No provider connected."))])
        #expect(engine.handle(.noticeExpired) == [.hideBuddy, .showNotch(.idle)])
        #expect(engine.state.notice == nil)
        #expect(engine.handle(.noticeExpired) == [])
    }

    @Test(arguments: Permission.allCases)
    func unknownPermissionDoesNotPrompt(permission: Permission) {
        var engine = BuddyEngine()
        #expect(engine.handle(.permissionRequested(permission)) == [])
    }

    @Test(arguments: Permission.allCases)
    func grantedPermissionDoesNotPrompt(permission: Permission) {
        var engine = BuddyEngine()
        #expect(engine.handle(.permissionsObserved(.init(
            microphone: .granted, speechRecognition: .granted, screenCapture: .granted,
            accessibility: .granted, inputMonitoring: .granted
        ))) == [])
        #expect(engine.handle(.permissionRequested(permission)) == [])
        #expect(engine.state.permissions[permission] == .granted)
    }

    @Test(arguments: Permission.allCases)
    func deniedPermissionGoesStraightToSettings(permission: Permission) {
        var engine = BuddyEngine()
        #expect(engine.handle(.permissionsObserved(.init(
            microphone: .denied, speechRecognition: .denied, screenCapture: .denied,
            accessibility: .denied, inputMonitoring: .denied
        ))) == [])
        #expect(engine.handle(.permissionRequested(permission)) == [.openPermissionSettings(permission)])
    }

    @Test(arguments: Permission.allCases)
    func binaryPermissionPromptsOnlyOnce(permission: Permission) {
        var engine = BuddyEngine()
        #expect(engine.handle(.permissionsObserved(.init(
            microphone: .notGranted, speechRecognition: .notGranted, screenCapture: .notGranted,
            accessibility: .notGranted, inputMonitoring: .notGranted
        ))) == [])
        #expect(engine.handle(.permissionRequested(permission)) == [.requestPermission(permission)])
        #expect(engine.handle(.permissionRequested(permission)) == [.openPermissionSettings(permission)])
    }

    @Test func permissionPromptAttemptsAreIndependent() {
        var engine = BuddyEngine()
        #expect(engine.handle(.permissionsObserved(.init(microphone: .notDetermined, speechRecognition: .notDetermined))) == [])
        #expect(engine.handle(.permissionRequested(.microphone)) == [.requestPermission(.microphone)])
        #expect(engine.handle(.permissionRequested(.speechRecognition)) == [.requestPermission(.speechRecognition)])
        #expect(engine.handle(.permissionRequested(.microphone)) == [.openPermissionSettings(.microphone)])
    }

    @Test(arguments: [
        (Permission.microphone, "Microphone access is restricted by macOS."),
        (.speechRecognition, "Speech Recognition access is restricted by macOS."),
        (.screenCapture, "Screen Recording access is restricted by macOS."),
        (.accessibility, "Accessibility access is restricted by macOS."),
        (.inputMonitoring, "Input Monitoring access is restricted by macOS.")
    ])
    func restrictedPermissionExplainsTheRestriction(permission: Permission, message: String) {
        var engine = BuddyEngine()
        #expect(engine.handle(.permissionsObserved(.init(
            microphone: .restricted, speechRecognition: .restricted, screenCapture: .restricted,
            accessibility: .restricted, inputMonitoring: .restricted
        ))) == [])
        #expect(engine.handle(.permissionRequested(permission)) == [.showNotch(.notice(message))])
    }

    @Test func refreshedPermissionsDoNotRetainARevokedGrant() {
        var engine = BuddyEngine()
        #expect(engine.handle(.permissionsObserved(.init(screenCapture: .granted))) == [])
        #expect(engine.state.permissions.screenCapture == .granted)
        #expect(engine.handle(.permissionsObserved(.init(screenCapture: .notGranted))) == [])
        #expect(engine.state.permissions.screenCapture == .notGranted)
        #expect(engine.handle(.permissionRequested(.screenCapture)) == [.requestPermission(.screenCapture)])
    }

    @Test func loginFailureDisplaysErrorAndKeepsObservedState() {
        var engine = BuddyEngine()
        #expect(engine.handle(.launchAtLoginRequested(true)) == [.setLaunchAtLogin(true)])
        #expect(engine.handle(.loginItemChangeFinished(.off, error: "Registration failed.")) == [.showNotch(.notice("Registration failed."))])
        #expect(engine.state.loginItem == .off)
        #expect(engine.state.loginChangePending == false)
        #expect(engine.state.notice == "Registration failed.")
        #expect(engine.handle(.launchAtLoginRequested(true)) == [.setLaunchAtLogin(true)])
        #expect(engine.handle(.loginItemChangeFinished(.on, error: nil)) == [])
        #expect(engine.state.loginItem == .on)
    }

    @Test func pendingLoginApprovalCanBeCancelled() {
        var engine = BuddyEngine()
        #expect(engine.handle(.loginItemObserved(.requiresApproval)) == [])
        #expect(engine.handle(.launchAtLoginRequested(false)) == [.setLaunchAtLogin(false)])
        #expect(engine.handle(.loginItemChangeFinished(.off, error: nil)) == [])
        #expect(engine.state.loginItem == .off)
        #expect(engine.state.loginChangePending == false)
    }

    @Test func loginObservationNeverRegistersAndUnchangedToggleDoesNothing() {
        var engine = BuddyEngine()
        #expect(engine.handle(.launchAtLoginRequested(false)) == [])
        #expect(engine.handle(.loginItemObserved(.on)) == [])
        #expect(engine.handle(.launchAtLoginRequested(true)) == [])
        #expect(engine.handle(.loginItemObserved(.requiresApproval)) == [])
        #expect(engine.handle(.launchAtLoginRequested(true)) == [.openLoginItemSettings])
    }
}
