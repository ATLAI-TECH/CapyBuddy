import SwiftUI

struct CaffeineSettingsView: View {

    let feature: CaffeineFeature

    @AppStorage("caffeine.defaultDuration") private var defaultDuration: Double = 0
    @AppStorage("caffeine.activateOnLaunch") private var activateOnLaunch: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("Behavior") {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Default duration", selection: $defaultDuration) {
                        Text("15 minutes").tag(15.0 * 60)
                        Text("30 minutes").tag(30.0 * 60)
                        Text("1 hour").tag(60.0 * 60)
                        Text("2 hours").tag(2.0 * 60 * 60)
                        Text("Indefinitely").tag(0.0)
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 260)

                    Toggle("Activate when CapyBuddy launches", isOn: $activateOnLaunch)
                }
                .padding(10)
            }

            GroupBox("How it works") {
                Text("Keep Awake stops both your Mac and its display from going to sleep " +
                     "while it’s active. Pick a duration from the menu-bar dropdown, or " +
                     "leave it on indefinitely.")
                    .foregroundStyle(.secondary)
                    .padding(10)
            }
        }
    }
}
