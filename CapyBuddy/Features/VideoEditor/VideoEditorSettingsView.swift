import SwiftUI

@MainActor
struct VideoEditorSettingsView: View {

    @State private var openAfterRecording: Bool = VideoEditorPrefs.openAfterRecording
    @State private var exportFormat: VideoEditorPrefs.ExportFormat = VideoEditorPrefs.exportFormat
    @State private var exportQuality: VideoEditorPrefs.ExportQuality = VideoEditorPrefs.exportQuality
    @State private var revealInFinder: Bool = VideoEditorPrefs.revealInFinder

    var body: some View {
        Form {
            Section("Workflow") {
                Toggle("Open the editor after a screen recording finishes", isOn: $openAfterRecording)
                    .onChange(of: openAfterRecording) { _, new in VideoEditorPrefs.openAfterRecording = new }
                Text("When on, a finished recording opens here so you can trim or crop it before sharing.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Export") {
                Picker("Format", selection: $exportFormat) {
                    ForEach(VideoEditorPrefs.ExportFormat.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: exportFormat) { _, new in VideoEditorPrefs.exportFormat = new }

                if !exportFormat.isGIF {
                    Picker("Quality", selection: $exportQuality) {
                        ForEach(VideoEditorPrefs.ExportQuality.allCases) { Text($0.label).tag($0) }
                    }
                    .onChange(of: exportQuality) { _, new in VideoEditorPrefs.exportQuality = new }
                } else {
                    Text("GIFs are exported at up to 480 px, 12 fps.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Toggle("Reveal exported file in Finder", isOn: $revealInFinder)
                    .onChange(of: revealInFinder) { _, new in VideoEditorPrefs.revealInFinder = new }
            }

            Section {
                Text("The editor does basic, lossy edits: trim the in/out points, crop (free-drag box or a fixed aspect ratio), change playback speed, and mute the audio track. Each export re-encodes the clip.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
