import SwiftUI

struct SystemMonitorSettingsView: View {

    let feature: SystemMonitorFeature

    @AppStorage("systemMonitor.refreshInterval") private var refreshInterval: Double = 1.0
    @AppStorage("systemMonitor.showCPU") private var showCPU: Bool = true
    @AppStorage("systemMonitor.showMEM") private var showMEM: Bool = true
    @AppStorage(SystemMonitorPrefs.displayFormatKey) private var displayFormatRaw: String = MenuBarDisplayFormat.labeled.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("Display") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Show CPU", isOn: $showCPU)
                        .onChange(of: showCPU) { _, _ in feature.update() }
                    Toggle("Show Memory", isOn: $showMEM)
                        .onChange(of: showMEM) { _, _ in feature.update() }

                    Picker("Format", selection: $displayFormatRaw) {
                        ForEach(MenuBarDisplayFormat.allCases) { fmt in
                            Text(fmt.displayName).tag(fmt.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 360)
                    .onChange(of: displayFormatRaw) { _, _ in feature.update() }

                    Picker("Refresh interval", selection: $refreshInterval) {
                        Text("1 second").tag(1.0)
                        Text("2 seconds").tag(2.0)
                        Text("5 seconds").tag(5.0)
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220)
                    .onChange(of: refreshInterval) { _, _ in feature.restartTimer() }
                }
                .padding(10)
            }

            GroupBox("Notes") {
                Text("System Monitor lives in its own menu-bar slot showing the " +
                     "current CPU and memory usage. Click for a detailed breakdown.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .padding(10)
            }
        }
    }
}
