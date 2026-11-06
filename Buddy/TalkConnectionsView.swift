import BuddyCore
import SwiftUI

struct TalkConnectionsView: View {
    @ObservedObject var connections: TalkConnections
    let usage: UsageSnapshots
    /// The provider the next turn goes to unless Auto moves it.
    let active: Provider

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            // A window that resets while the panel is open shows as unused within a minute.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        rowLabel("Provider")
                        providerPicker
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .accessibilityIdentifier("talkProvider")
                    }
                    if !connections.selection.useProxy {
                        ForEach(Provider.allCases, id: \.self) { provider in
                            headroomRow(provider, at: context.date)
                        }
                    }
                    GridRow {
                        rowLabel("Use CLIProxy")
                        Toggle("Use CLIProxy", isOn: Binding(
                            get: { connections.selection.useProxy },
                            set: { enabled in
                                connections.useProxy(enabled)
                                if enabled { Task { await connections.refresh() } }
                            }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                        .accessibilityIdentifier("useCLIProxy")
                    }
                    if connections.selection.useProxy {
                        GridRow {
                            rowLabel("Account")
                            accountPicker
                        }
                        GridRow {
                            rowLabel("Model")
                            modelPicker
                        }
                    }
                }
                .buttonSizing(.flexible)
            }
            notes
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 12))
        .disabled(connections.busy)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Talk with").font(.headline)
            Spacer()
            if connections.busy { ProgressView().controlSize(.small) }
            if connections.selection.useProxy {
                Button("Refresh") { Task { await connections.refresh() } }
                    .controlSize(.small)
                    .help("Reload accounts and models from CLIProxy")
                    .accessibilityIdentifier("refreshAccounts")
            }
        }
        .frame(minHeight: 22)
    }

    /// Through CLIProxy the owner picks the provider the hub serves. With direct sign-ins Auto can route between them.
    @ViewBuilder private var providerPicker: some View {
        if connections.selection.useProxy {
            Picker("Provider", selection: Binding(get: { connections.selection.provider }, set: connections.chooseProvider)) {
                ForEach(Provider.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        } else {
            Picker("Provider", selection: Binding(get: { connections.selection.choice }, set: connections.choose)) {
                ForEach(ProviderChoice.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        }
    }

    private func headroomRow(_ provider: Provider, at now: Date) -> some View {
        let headroom = usage[provider]?.headroom(at: now)
        return GridRow {
            rowLabel(provider.title)
            HStack(spacing: 8) {
                ProgressView(value: headroom ?? 0)
                    .tint(headroom.map { $0 > 0 ? DS.Colors.success : DS.Colors.danger } ?? DS.Colors.textSecondary)
                    .opacity(headroom == nil ? 0.4 : 1)
                Text(headroom.map { "\(Int(($0 * 100).rounded()))% left" } ?? "Unknown")
                    .monospacedDigit()
                    .frame(width: 64, alignment: .trailing)
                Text(provider == active ? "Active" : "")
                    .foregroundStyle(DS.Colors.accentText)
                    .frame(width: 44, alignment: .leading)
            }
            .font(.caption)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(provider.title) headroom")
        .accessibilityValue((headroom.map { "\(Int(($0 * 100).rounded())) percent left" } ?? "unknown") + (provider == active ? ", active" : ""))
        .accessibilityIdentifier("headroom-\(provider.rawValue)")
    }

    private var accountPicker: some View {
        Picker("Account", selection: Binding(
            get: { connections.selection.accountID },
            set: { id in Task { await connections.chooseAccount(id) } }
        )) {
            Text("Automatic (CLIProxy)").tag("")
            if !connections.providerAccounts.isEmpty { Divider() }
            ForEach(connections.providerAccounts) { account in
                Text(account.title + (account.disabled ? " (disabled)" : ""))
                    .tag(account.id)
                    .disabled(account.disabled)
            }
            if !connections.selection.accountID.isEmpty && connections.selectedAccount == nil {
                Text("Selected account unavailable").tag(connections.selection.accountID)
            }
        }
        .labelsHidden()
        .accessibilityIdentifier("talkAccount")
    }

    private var modelPicker: some View {
        Picker("Model", selection: Binding(
            get: { connections.selection.model }, set: connections.chooseModel
        )) {
            ForEach(connections.models, id: \.self) { Text($0).tag($0) }
            if !connections.models.contains(connections.selection.model) {
                Text(connections.selection.model.isEmpty ? "Choose a model" : connections.selection.model + " (unavailable)")
                    .tag(connections.selection.model)
            }
        }
        .labelsHidden()
        .accessibilityIdentifier("talkModel")
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 6) {
            if connections.selection.useProxy {
                if let status = connections.selectedAccount?.statusText {
                    note(status, color: DS.Colors.textPrimary)
                }
                if let error = connections.error {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill").accessibilityHidden(true)
                        Text(error)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("proxyError")
                    }
                    .font(.caption)
                    .foregroundStyle(DS.Colors.danger)
                }
                note("Automatic lets CLIProxy choose an account. A specific account stays selected until you change it.")
            } else {
                note("Auto sends each turn to the provider with more headroom, and moves only when the other leads by \(Int(ProviderRouter.margin * 100)) points or the current one hits its limit. Claude uses your Claude CLI sign-in, and Codex its app server with your ChatGPT sign-in.")
            }
        }
    }

    private func rowLabel(_ title: String) -> some View {
        Text(title).accessibilityHidden(true)
    }

    private func note(_ text: String, color: Color = DS.Colors.textSecondary) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
