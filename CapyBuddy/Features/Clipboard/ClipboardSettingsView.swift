import SwiftUI
import Carbon.HIToolbox

struct ClipboardSettingsView: View {

    let feature: ClipboardFeature

    @ObservedObject private var hotkeyStore = ClipboardHotkeyStore.shared

    @AppStorage("clipboard.captureImages") private var captureImages: Bool = true
    @AppStorage("clipboard.maxItems") private var maxItems: Int = 100

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("Hotkey") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Press the shortcut anywhere to open the clipboard history panel.")
                        .foregroundStyle(.secondary)
                        .font(.callout)

                    HStack {
                        Text(hotkeyStore.current.displayString)
                            .font(.system(.body, design: .monospaced))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color(nsColor: .quaternarySystemFill))
                            )
                        Spacer()
                        Button("Reset to ⇧⌘V") {
                            hotkeyStore.update(ClipboardHotkeyStore.defaultConfig)
                        }
                    }
                }
                .padding(10)
            }

            GroupBox("History") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Maximum entries")
                        Spacer()
                        Stepper(value: $maxItems, in: 20...500, step: 20) {
                            Text("\(maxItems)")
                                .frame(minWidth: 40, alignment: .trailing)
                        }
                        .labelsHidden()
                    }
                    .onChange(of: maxItems) { _, new in
                        feature.store.maxItems = new
                    }

                    Toggle("Capture images", isOn: $captureImages)
                        .help("When off, only text is saved to history.")

                    Button("Clear unpinned history") {
                        feature.store.clearUnpinned()
                    }
                }
                .padding(10)
            }

            GroupBox("Privacy") {
                Text("CapyBuddy never captures items copied from password managers " +
                     "that mark their pasteboard data as concealed (e.g. 1Password, " +
                     "Bitwarden, Apple Keychain).")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .padding(10)
            }
        }
        .onAppear {
            feature.store.maxItems = maxItems
        }
    }
}
