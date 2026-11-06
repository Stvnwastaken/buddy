import BuddyCore
import ServiceManagement
import SwiftUI

struct CompanionPanelView: View {
    @ObservedObject var manager: CompanionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "cursorarrow.rays")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.blue)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Buddy").font(.title2.weight(.semibold))
                    Text("Your buddy, on your Mac.")
                        .font(.callout)
                        .foregroundStyle(DS.Colors.textSecondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Ask Buddy")
                    .font(.headline)
                Text("To ask about your screen, \(manager.state.shortcuts[.talk].instruction). \(talkEnding) Or \(manager.state.shortcuts[.textBox].instruction) to type a question.")
                    .font(.callout)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Start with “agent” to hand Buddy a task to do in the background.")
                    .font(.callout)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Spoken replies", isOn: Binding(
                    get: { manager.state.spokenReplies },
                    set: { manager.send(.spokenRepliesChanged($0)) }
                ))
                .toggleStyle(.switch)
                .accessibilityIdentifier("spokenReplies")
                Text("Turn off speech to read Buddy's answer and keep its pointing. Press Esc or ask another question to dismiss the written answer.")
                    .font(.caption)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Pen sounds", isOn: Binding(
                    get: { manager.state.penSounds },
                    set: { manager.send(.penSoundsChanged($0)) }
                ))
                .toggleStyle(.switch)
                .accessibilityIdentifier("penSounds")
                Text("Play a quiet paper scratch as Buddy draws. This is separate from spoken replies.")
                    .font(.caption)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let reply = manager.state.history.conversations.last?.turns.last?.reply, !reply.isEmpty {
                    DisclosureGroup("Latest answer") {
                        ScrollView {
                            Text(reply)
                                .font(.callout)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("latestAnswerText")
                        }
                        .frame(maxHeight: 240)
                    }
                    .accessibilityIdentifier("latestAnswer")
                }
                speechModelStatus
                if manager.state.spokenReplies { neuralVoiceStatus }
                if let notice = manager.state.notice {
                    Text(notice)
                        .font(.callout.weight(.medium))
                        .accessibilityIdentifier("turnNotice")
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 12))

            voiceSettings

            ShortcutSettingsView(shortcuts: manager.state.shortcuts, error: manager.state.shortcutError) {
                manager.send(.shortcutChosen($0, $1))
            }

            TalkConnectionsView(connections: manager.connections, usage: manager.state.usage, active: manager.state.provider)

            AgentRunsView(
                choice: manager.state.runProviderChoice,
                mode: manager.state.approvalMode,
                chooseProvider: { manager.send(.runProviderChosen($0)) },
                chooseMode: { manager.send(.approvalModeChosen($0)) }
            )

            VStack(alignment: .leading, spacing: 14) {
                Text("Permissions").font(.headline)
                ForEach(Permission.allCases, id: \.self) { permission in
                    permissionRow(permission)
                }
                Text("Grant access here when you are ready. Buddy checks the current macOS settings.")
                    .font(.caption)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().overlay(DS.Colors.textSecondary.opacity(0.25))

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("History").font(.headline)
                    Spacer()
                    Button("Clear history", role: .destructive) { manager.send(.clearHistoryRequested) }
                        .controlSize(.small)
                        .disabled(manager.state.historyClearPending || (manager.state.history.conversations.isEmpty && manager.state.historyError == nil))
                        .accessibilityIdentifier("clearHistory")
                }
                Text("Conversation history and summaries stay on this Mac as text. Agent runs keep their screen captures in each run folder.")
                    .font(.caption)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = manager.state.historyError {
                    Text(error)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("historyError")
                } else if manager.state.historyCleared {
                    Text("History cleared.")
                        .font(.caption)
                        .foregroundStyle(DS.Colors.success)
                        .accessibilityIdentifier("historyCleared")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Profile").font(.headline)
                    Spacer()
                    Button("Clear profile", role: .destructive) { manager.send(.clearProfileRequested) }
                        .controlSize(.small)
                        .disabled(manager.state.profileClearPending || (manager.state.profile.notes.isEmpty && manager.state.profileError == nil))
                        .accessibilityIdentifier("clearProfile")
                }
                if manager.state.profile.notes.isEmpty {
                    Text("Say “remember…” and Buddy notes it here. Say “forget…” to take a note out.")
                        .font(.callout)
                        .foregroundStyle(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("profileEmpty")
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(manager.state.profile.notes.enumerated()), id: \.offset) { _, note in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("•")
                                    .foregroundStyle(DS.Colors.textSecondary)
                                    .accessibilityHidden(true)
                                Text(note)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.callout)
                        }
                    }
                    .textSelection(.enabled)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("profileNotes")
                }
                Text("Buddy reads these notes with every question. They stay on this Mac.")
                    .font(.caption)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = manager.state.profileError {
                    Text(error)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("profileError")
                } else if manager.state.profileCleared {
                    Text("Profile cleared.")
                        .font(.caption)
                        .foregroundStyle(DS.Colors.success)
                        .accessibilityIdentifier("profileCleared")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Launch at login", isOn: Binding(
                    get: { manager.state.loginItem == .on || manager.state.loginItem == .requiresApproval },
                    set: { manager.send(.launchAtLoginRequested($0)) }
                ))
                .toggleStyle(.switch)
                .disabled(manager.state.loginChangePending)
                .accessibilityIdentifier("launchAtLogin")
                if manager.state.loginChangePending {
                    Text("Updating login settings…").font(.caption)
                } else if manager.state.loginItem == .requiresApproval {
                    HStack {
                        Text("Waiting for approval in System Settings.")
                            .font(.caption)
                            .foregroundStyle(DS.Colors.textSecondary)
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                            .controlSize(.small)
                    }
                } else if manager.state.loginItem == .unavailable {
                    Text("macOS has not found Buddy's login service yet.")
                        .font(.caption)
                        .foregroundStyle(DS.Colors.textSecondary)
                }
            }

            HStack {
                Text("Buddy \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                    .font(.caption)
                    .foregroundStyle(DS.Colors.textSecondary)
                Spacer()
                Button("Quit Buddy") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.callout)
            }
        }
        .padding(22)
        .frame(width: 380)
        .foregroundStyle(DS.Colors.textPrimary)
        .background(DS.Colors.background)
        .preferredColorScheme(.dark)
        .tint(DS.Colors.accentText)
        .onAppear { manager.refreshSystemState() }
    }

    private var talkEnding: String {
        switch manager.state.shortcuts[.talk] {
        case .held: "Release to send."
        case .doubleTap: "Repeat the double-tap to send."
        }
    }

    @ViewBuilder private var speechModelStatus: some View {
        switch manager.speechModel {
        case .checking, .ready:
            EmptyView()
        case .installing(let fraction):
            VStack(alignment: .leading, spacing: 6) {
                Text("Installing the on-device speech model…")
                    .font(.caption)
                    .foregroundStyle(DS.Colors.textSecondary)
                // macOS 26 often reports nothing until the download finishes, so zero shows as indeterminate.
                Group {
                    if fraction > 0 {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                    }
                }
                .progressViewStyle(.linear)
                .accessibilityLabel("On-device speech model")
            }
            .accessibilityIdentifier("speechModel")
        case .unavailable(let reason):
            Text("\(reason) Buddy listens with Apple Speech instead.")
                .font(.caption)
                .foregroundStyle(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("speechModel")
        }
    }

    var voiceSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Voice and speed").font(.headline)
            ForEach(manager.state.availableVoices, id: \.self) { voice in
                HStack {
                    Button {
                        manager.send(.speechSettingsChanged(SpeechSettings(voice: voice, speed: manager.state.speechSettings.speed)))
                    } label: {
                        Label(voice.title, systemImage: manager.state.speechSettings.voice == voice ? "largecircle.fill.circle" : "circle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(manager.state.speechSettings.voice == voice ? .isSelected : [])
                    Button {
                        manager.send(.voicePreviewRequested(voice))
                    } label: { Image(systemName: "play.fill") }
                    .accessibilityLabel("Preview \(voice.title)")
                    .disabled(voice != .apple && manager.state.neuralVoice != .ready)
                }
            }
            if !manager.state.availableVoices.contains(manager.state.speechSettings.voice) {
                Text("Saved voice \(manager.state.speechSettings.voice.title) is unavailable. Using Apple until it is ready.")
                    .font(.caption)
                    .foregroundStyle(DS.Colors.textSecondary)
            }
            if let error = manager.voicePreviewError { Text(error).font(.caption) }
            Text("Speed · \(manager.state.speechSettings.speed.formatted(.number.precision(.fractionLength(2))))×")
            Slider(value: Binding(
                get: { manager.state.speechSettings.speed },
                set: { manager.send(.speechSettingsChanged(SpeechSettings(voice: manager.state.speechSettings.voice, speed: $0))) }
            ), in: 0.5...2, step: 0.05)
            .accessibilityLabel("Speech speed")
            Text("Changes apply to the next line. Previews are generated on your Mac. Only installed Kokoro voices are listed; unavailable voices use Apple.")
                .font(.caption)
                .foregroundStyle(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var neuralVoiceStatus: some View {
        switch manager.state.neuralVoice {
        case .loading, .ready:
            EmptyView()
        case .notInstalled:
            VStack(alignment: .leading, spacing: 6) {
                Text("The neural voice isn't installed, so Buddy speaks with the Apple voice. To add it, run this in the Buddy repo, then reopen Buddy:")
                    .font(.caption)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: "swift run --package-path BuddyVoice install-voice")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            .accessibilityIdentifier("neuralVoice")
        case .failed(let reason):
            Text("The neural voice couldn't load, so Buddy speaks with the Apple voice. \(reason)")
                .font(.caption)
                .foregroundStyle(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("neuralVoice")
        }
    }

    private func permissionRow(_ permission: Permission) -> some View {
        let status = manager.state.permissions[permission]
        return HStack(spacing: 10) {
            Image(systemName: status == .granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(status == .granted ? DS.Colors.success : DS.Colors.textSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title).font(.callout.weight(.medium))
                Text(status.label)
                    .font(.caption)
                    .foregroundStyle(DS.Colors.textSecondary)
            }
            Spacer(minLength: 4)
            if status != .granted {
                Button(status == .denied ? "Open Settings" : "Grant Access") {
                    manager.refreshSystemState()
                    manager.send(.permissionRequested(permission))
                }
                .controlSize(.small)
                .disabled(status == .unknown || status == .restricted || manager.permissionInFlight != nil)
                .accessibilityLabel("\(status == .denied ? "Open Settings for" : "Grant") \(permission.title)")
                .accessibilityIdentifier("permission-\(permission.rawValue)")
            }
        }
    }
}

private extension PermissionStatus {
    var label: String {
        switch self {
        case .unknown: "Checking…"
        case .notDetermined: "Not requested"
        case .notGranted: "Not granted"
        case .denied: "Denied in System Settings"
        case .restricted: "Restricted by macOS"
        case .granted: "Granted"
        }
    }
}
