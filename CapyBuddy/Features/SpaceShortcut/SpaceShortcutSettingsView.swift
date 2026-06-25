import SwiftUI
import AppKit
import Carbon.HIToolbox
import UniformTypeIdentifiers

struct SpaceShortcutSettingsView: View {

    @ObservedObject var store: BindingStore
    @ObservedObject private var stats = SpaceShortcutStats.shared
    var isTapActive: () -> Bool
    var restartTap: () -> Bool

    @State private var draft: Draft? = nil
    @State private var keyMonitor: Any? = nil
    @State private var isCapturingKey: Bool = false
    @State private var statusMessage: String? = nil
    @State private var accessibilityGranted: Bool = PermissionChecker.isAccessibilityGranted()
    @State private var tapActive: Bool = false

    private struct Draft: Equatable {
        var keyCode: UInt16? = nil
        var app: AppBinding? = nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !accessibilityGranted {
                permissionBanner
            } else if !tapActive {
                tapInactiveBanner
            }

            bindingsTab
        }
        .onAppear {
            accessibilityGranted = PermissionChecker.isAccessibilityGranted()
            tapActive = isTapActive()
            if accessibilityGranted && !tapActive {
                tapActive = restartTap()
            }
        }
        .onDisappear {
            cancelDraft()
        }
    }

    private var bindingsTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(triggerHintText)
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Button {
                    startNewBinding()
                } label: {
                    Label("Add Binding…", systemImage: "plus")
                }
                .disabled(draft != nil)
                Spacer()
                if draft == nil, let msg = statusMessage {
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                } else if stats.totalLaunches > 0 {
                    Text("\(stats.totalLaunches) total launches")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Reset") { stats.reset() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }

            if let draft = draft {
                draftRow(draft)
            }

            Divider()

            if store.sortedBindings.isEmpty {
                ContentUnavailableView(
                    "No bindings yet",
                    systemImage: "keyboard",
                    description: Text("Add a key → app binding to get started.")
                )
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                Table(store.sortedBindings) {
                    TableColumn("Key") { (row: BindingStore.Row) in
                        Text(KeyCombo.keyName(forKeyCode: row.keyCode))
                            .font(.system(.body, design: .monospaced))
                    }
                    .width(80)

                    TableColumn("Application") { (row: BindingStore.Row) in
                        HStack(spacing: 8) {
                            if let icon = appIcon(forPath: row.binding.bundlePath) {
                                Image(nsImage: icon)
                                    .resizable()
                                    .frame(width: 18, height: 18)
                            }
                            Text(row.binding.displayName)
                        }
                    }

                    TableColumn("Launches") { (row: BindingStore.Row) in
                        Text("\(stats.count(for: row.binding))")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .width(70)

                    TableColumn("") { (row: BindingStore.Row) in
                        Button(role: .destructive) {
                            store.removeBinding(forKeyCode: row.keyCode)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    .width(40)
                }
                .frame(minHeight: 200)
            }
        }
    }

    private var triggerHintText: LocalizedStringKey {
        "Tap **Space** for a normal space. Hold ~200ms and the chord HUD appears - then press a bound key to launch its app. (Note: macOS blocks this trigger in password fields.)"
    }

    private var tapInactiveBanner: some View {
        let trusted = PermissionChecker.isAccessibilityGranted(prompt: false)
        let bundlePath = Bundle.main.bundlePath
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Listener not running").bold()
                Text("The keyboard event tap isn't active. macOS reports this process as **\(trusted ? "trusted" : "NOT trusted")** for Accessibility. If the entry in System Settings refers to a stale build path, remove it and re-add the binary below, then click Restart.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(bundlePath)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Open Accessibility Settings") {
                        PermissionChecker.openAccessibilitySettings()
                    }
                    Button("Reveal Binary in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: bundlePath)])
                    }
                    Button("Restart Listener") {
                        tapActive = restartTap()
                    }
                }
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Draft row

    @ViewBuilder
    private func draftRow(_ draft: Draft) -> some View {
        HStack(spacing: 12) {
            keySlot(draft: draft)
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            appSlot(draft: draft)
            Spacer()
            Button("Cancel") { cancelDraft() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.4))
        )
    }

    @ViewBuilder
    private func keySlot(draft: Draft) -> some View {
        Button {
            startKeyCapture()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "keyboard")
                if isCapturingKey {
                    Text("Press a key…").italic().foregroundStyle(.tint)
                } else if let keyCode = draft.keyCode {
                    Text(KeyCombo.keyName(forKeyCode: keyCode))
                        .font(.system(.body, design: .monospaced))
                } else {
                    Text("Set Key…").foregroundStyle(.tint)
                }
            }
            .frame(minWidth: 110, alignment: .leading)
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    private func appSlot(draft: Draft) -> some View {
        Button {
            pickAppForDraft()
        } label: {
            HStack(spacing: 6) {
                if let app = draft.app, let icon = appIcon(forPath: app.bundlePath) {
                    Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                } else {
                    Image(systemName: "app.dashed")
                }
                if let app = draft.app {
                    Text(app.displayName)
                } else {
                    Text("Choose App…").foregroundStyle(.tint)
                }
            }
            .frame(minWidth: 160, alignment: .leading)
        }
        .buttonStyle(.bordered)
    }

    private var permissionBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 4) {
                Text("Accessibility permission required").bold()
                Text("Space Shortcut needs Accessibility permission to detect Space chords. Open System Settings, then return here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Open System Settings") {
                        PermissionChecker.openAccessibilitySettings()
                    }
                    Button("Recheck") {
                        accessibilityGranted = PermissionChecker.isAccessibilityGranted()
                        if accessibilityGranted {
                            tapActive = restartTap()
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func appIcon(forPath path: String) -> NSImage? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return NSWorkspace.shared.icon(forFile: path)
    }

    // MARK: - Draft flow

    private func startNewBinding() {
        statusMessage = nil
        draft = Draft()
    }

    private func cancelDraft() {
        stopKeyCapture()
        draft = nil
    }

    private func pickAppForDraft() {
        // Pause key capture while the open panel is up so it doesn't eat panel keystrokes.
        stopKeyCapture()
        guard let app = pickApp() else { return }
        guard var current = draft else { return }
        current.app = app
        draft = current
        commitIfReady()
    }

    private func pickApp() -> AppBinding? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.title = "Select an Application"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let displayName = (try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName)
            ?? url.deletingPathExtension().lastPathComponent
        return AppBinding(bundlePath: url.path, displayName: displayName)
    }

    private func startKeyCapture() {
        stopKeyCapture()
        isCapturingKey = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = event.keyCode
            DispatchQueue.main.async {
                if Int(keyCode) == kVK_Escape {
                    stopKeyCapture()
                    return
                }
                guard var current = draft else {
                    stopKeyCapture()
                    return
                }
                current.keyCode = keyCode
                draft = current
                stopKeyCapture()
                commitIfReady()
            }
            return nil  // swallow this keystroke so it doesn't go anywhere else
        }
    }

    private func stopKeyCapture() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        isCapturingKey = false
    }

    private func commitIfReady() {
        guard let d = draft, let keyCode = d.keyCode, let app = d.app else { return }
        store.setBinding(app, forKeyCode: keyCode)
        statusMessage = "Bound \(KeyCombo.keyName(forKeyCode: keyCode)) → \(app.displayName)"
        draft = nil
    }
}
