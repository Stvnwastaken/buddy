import BuddyCore
import SwiftUI

/// The owner's choices for agent runs started from now on: the CLI they run on and how they are approved.
struct AgentRunsView: View {
    let choice: ProviderChoice
    let mode: ApprovalMode
    let chooseProvider: (ProviderChoice) -> Void
    let chooseMode: (ApprovalMode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Agent runs").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Provider").accessibilityHidden(true)
                    Picker("Provider", selection: Binding(get: { choice }, set: chooseProvider)) {
                        ForEach(ProviderChoice.allCases, id: \.self) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier("runProvider")
                }
                GridRow {
                    Text("Approvals").accessibilityHidden(true)
                    Picker("Approvals", selection: Binding(get: { mode }, set: chooseMode)) {
                        Text("Auto").tag(ApprovalMode.auto)
                        Text("Approve only").tag(ApprovalMode.approveOnly)
                        Text("YOLO").tag(ApprovalMode.yolo)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier("approvalMode")
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                note(providerNote)
                note(approvalNote, color: mode == .yolo ? DS.Colors.danger : DS.Colors.textSecondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private var approvalNote: String {
        switch mode {
        case .auto: "They do safe steps on their own, skip ones they can do another way, and ask you about the rest."
        case .approveOnly: "They ask you on their card before every command and file change."
        case .yolo: "They do anything without asking, including deleting files, sending and network commands."
        }
    }

    private var providerNote: String {
        switch choice {
        case .auto: "New runs use your direct sign-ins, routed by headroom. At a usage limit they continue on the other provider with their saved progress."
        case .claude: "New runs stay on your direct Claude CLI sign-in on Opus, including at a usage limit."
        case .codex: "New runs stay on Codex's app server with your ChatGPT sign-in, including at a usage limit, without your Codex settings."
        }
    }

    private func note(_ text: String, color: Color = DS.Colors.textSecondary) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
