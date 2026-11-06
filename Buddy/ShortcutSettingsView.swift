import BuddyCore
import SwiftUI

struct ShortcutSettingsView: View {
    let shortcuts: Shortcuts
    let error: String?
    let choose: (ShortcutSlot, ShortcutTrigger) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Shortcuts").font(.headline)
            ForEach(ShortcutSlot.allCases, id: \.self) { slot in
                ShortcutEditor(slot: slot, saved: shortcuts[slot]) { choose(slot, $0) }
            }
            Text("Use Control, Option, Shift, Command or fn. Esc always interrupts. Changes apply immediately.")
                .font(.caption)
                .foregroundStyle(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(DS.Colors.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("shortcutError")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct ShortcutEditor: View {
    let slot: ShortcutSlot
    let saved: ShortcutTrigger
    let apply: (ShortcutTrigger) -> Void
    @State private var doubleTap = false
    @State private var held: ModifierKeys = []
    @State private var modifier = ShortcutModifier.control

    private var draft: ShortcutTrigger { doubleTap ? .doubleTap(modifier) : .held(held) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(slot.title).font(.subheadline.weight(.semibold))
            Text(saved.instruction)
                .font(.callout)
                .foregroundStyle(DS.Colors.textSecondary)
                .accessibilityIdentifier("shortcut.\(slot.rawValue).current")
            Picker("\(slot.title) trigger", selection: $doubleTap) {
                Text("Held combo").tag(false)
                Text("Double-tap").tag(true)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("shortcut.\(slot.rawValue).kind")
            if doubleTap {
                Picker("\(slot.title) modifier", selection: $modifier) {
                    ForEach(ShortcutModifier.allCases, id: \.self) { key in
                        Text(key.title).tag(key)
                    }
                }
                .accessibilityIdentifier("shortcut.\(slot.rawValue).modifier")
            } else {
                HStack(spacing: 6) {
                    ForEach(ShortcutModifier.allCases, id: \.self) { key in
                        Toggle(key.title, isOn: Binding(
                            get: { held.contains(key.keys) },
                            set: { selected in
                                if selected { held.insert(key.keys) } else { held.remove(key.keys) }
                            }
                        ))
                        .toggleStyle(.button)
                        .accessibilityLabel("\(slot.title) \(key.title)")
                        .accessibilityIdentifier("shortcut.\(slot.rawValue).\(key.rawValue)")
                    }
                }
                .controlSize(.small)
                .font(.caption)
            }
            HStack {
                if slot == .talk && doubleTap {
                    Text("Repeat the double-tap to send.")
                        .font(.caption)
                        .foregroundStyle(DS.Colors.textSecondary)
                }
                Spacer(minLength: 0)
                Button("Apply") { apply(draft) }
                    .disabled(draft == saved)
                    .accessibilityLabel("Apply \(slot.title) shortcut")
                    .accessibilityIdentifier("shortcut.\(slot.rawValue).apply")
            }
        }
        .onAppear { load(saved) }
        .onChange(of: saved) { _, value in load(value) }
    }

    private func load(_ trigger: ShortcutTrigger) {
        switch trigger {
        case .held(let keys):
            doubleTap = false
            held = keys
        case .doubleTap(let key):
            doubleTap = true
            modifier = key
        }
    }
}
