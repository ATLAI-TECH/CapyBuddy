import AppKit
import AVKit
import SwiftUI
import UniformTypeIdentifiers

/// The Video Editor window contents — a player on top, a trim timeline, and
/// a row of basic edit controls (crop, speed, mute) plus Export.
/// Intentionally minimal: anything fancier belongs in a future pass.
struct VideoEditorView: View {

    @ObservedObject var model: VideoEditorModel

    var body: some View {
        VStack(spacing: 0) {
            playerArea
            Divider()
            if model.hasVideo {
                controls
                    .padding(16)
            } else {
                emptyState
            }
        }
        .frame(minWidth: 660, minHeight: 480)
    }

    // MARK: Player

    @ViewBuilder
    private var playerArea: some View {
        ZStack {
            Color.black
            if model.hasVideo {
                ZStack {
                    PlayerView(player: model.player)
                    if let cropRect = model.activeCropRect {
                        if model.cropPreset.isCustom {
                            CropBoxOverlay(rect: $model.customCrop, interactive: true)
                        } else {
                            CropBoxOverlay(rect: .constant(cropRect), interactive: false)
                        }
                    }
                }
                .aspectRatio(model.displayAspect, contentMode: .fit)
                .padding(6)
            }
            if model.isLoading {
                ProgressView().controlSize(.large).tint(.white)
            }
            if let error = model.loadError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.yellow)
                    Text(error)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            }
        }
        .frame(minHeight: 280)
        .layoutPriority(1)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "film")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Open a video to start editing")
                .foregroundStyle(.secondary)
            Button("Open Video…") {
                if let url = VideoEditorOpenPanel.chooseURL() { model.load(url: url) }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(40)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            trimSection
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                Picker("Crop", selection: $model.cropPreset) {
                    ForEach(CropPreset.allCases) { Text($0.label).tag($0) }
                }
                .frame(maxWidth: 230)

                Picker("Speed", selection: $model.speed) {
                    ForEach(PlaybackSpeed.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()

                Toggle("Mute audio", isOn: $model.muteAudio)
                Spacer()
            }
            if model.cropPreset.isCustom {
                Text("Drag the box — or its corners — on the video above to set the crop region.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Text(exportSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.isExporting {
                    ProgressView(value: model.exportProgress)
                        .frame(width: 120)
                    Text("\(Int((model.exportProgress * 100).rounded()))%")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                Button {
                    model.export()
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(model.isExporting || model.isLoading || !model.hasVideo)
            }
        }
    }

    private var trimSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Trim", systemImage: "scissors").font(.headline)
                Spacer()
                Text("\(timeString(model.trimStart)) – \(timeString(model.trimEnd))  ·  \(timeString(model.trimmedDuration))")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            RangeSlider(
                low: $model.trimStart,
                high: $model.trimEnd,
                bounds: 0...max(model.duration, 0.001),
                onScrub: { model.seek(to: $0) }
            )
            .frame(height: 28)
            HStack(spacing: 8) {
                Button { model.setStartToPlayhead() } label: {
                    Label("Set start to playhead", systemImage: "arrow.left.to.line")
                }
                Button { model.setEndToPlayhead() } label: {
                    Label("Set end to playhead", systemImage: "arrow.right.to.line")
                }
                Button { model.resetTrim() } label: {
                    Label("Reset", systemImage: "arrow.uturn.backward")
                }
                Spacer()
                Button { model.togglePlayPause() } label: {
                    Image(systemName: "playpause.fill")
                }
                Button { model.previewSelection() } label: {
                    Label("Preview selection", systemImage: "play.rectangle")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var exportSummary: String {
        let fmt = VideoEditorPrefs.exportFormat
        if fmt.isGIF { return String(localized: "Will export an animated GIF.") }
        return String(localized: "Will export \(fmt.label) at \(VideoEditorPrefs.exportQuality.label).")
    }

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        let frac = Int((seconds - Double(total)).magnitude * 100)
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d.%02d", m, s, frac)
    }
}

// MARK: - AVPlayerView bridge

private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = true
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}

// MARK: - Free-drag crop box

/// Overlay that draws (and, when `interactive`, lets you drag) a crop
/// rectangle on top of the video. `rect` is normalized to `[0, 1]` with a
/// top-left origin, matching the video's pixel space — the overlay is
/// placed inside an aspect-fitted frame so 1 overlay point ↔ a fixed
/// fraction of the frame regardless of window size.
struct CropBoxOverlay: View {
    @Binding var rect: CGRect
    var interactive: Bool

    private enum Corner { case topLeft, topRight, bottomLeft, bottomRight }

    @State private var startRect: CGRect?
    private let handleSize: CGFloat = 12
    private let hitSize: CGFloat = 28
    private let minNorm: CGFloat = 0.06

    var body: some View {
        GeometryReader { geo in
            content(in: geo.size)
        }
    }

    private func content(in size: CGSize) -> some View {
        let f = CGRect(x: rect.minX * size.width, y: rect.minY * size.height,
                       width: rect.width * size.width, height: rect.height * size.height)
        return ZStack(alignment: .topLeading) {
            Path { p in
                p.addRect(CGRect(origin: .zero, size: size))
                p.addRect(f)
            }
            .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            Rectangle()
                .strokeBorder(Color.white, lineWidth: 1.5)
                .frame(width: max(f.width, 1), height: max(f.height, 1))
                .offset(x: f.minX, y: f.minY)
                .allowsHitTesting(false)

            if interactive {
                Color.white.opacity(0.001)
                    .frame(width: max(f.width, 1), height: max(f.height, 1))
                    .offset(x: f.minX, y: f.minY)
                    .gesture(bodyDrag(size: size))

                handle.position(x: f.minX, y: f.minY).gesture(cornerDrag(.topLeft, size: size))
                handle.position(x: f.maxX, y: f.minY).gesture(cornerDrag(.topRight, size: size))
                handle.position(x: f.minX, y: f.maxY).gesture(cornerDrag(.bottomLeft, size: size))
                handle.position(x: f.maxX, y: f.maxY).gesture(cornerDrag(.bottomRight, size: size))
            }
        }
    }

    private var handle: some View {
        Color.clear
            .frame(width: hitSize, height: hitSize)
            .contentShape(Rectangle())
            .overlay(
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().stroke(Color.black.opacity(0.4), lineWidth: 0.5))
                    .frame(width: handleSize, height: handleSize)
                    .shadow(radius: 1)
            )
    }

    private func bodyDrag(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                let base = startRect ?? rect
                if startRect == nil { startRect = base }
                var r = base
                r.origin.x = min(max(0, base.minX + v.translation.width / max(size.width, 1)), 1 - base.width)
                r.origin.y = min(max(0, base.minY + v.translation.height / max(size.height, 1)), 1 - base.height)
                rect = r
            }
            .onEnded { _ in startRect = nil }
    }

    private func cornerDrag(_ corner: Corner, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                let base = startRect ?? rect
                if startRect == nil { startRect = base }
                let dx = v.translation.width / max(size.width, 1)
                let dy = v.translation.height / max(size.height, 1)
                var x0 = base.minX, y0 = base.minY, x1 = base.maxX, y1 = base.maxY
                switch corner {
                case .topLeft:     x0 = base.minX + dx; y0 = base.minY + dy
                case .topRight:    x1 = base.maxX + dx; y0 = base.minY + dy
                case .bottomLeft:  x0 = base.minX + dx; y1 = base.maxY + dy
                case .bottomRight: x1 = base.maxX + dx; y1 = base.maxY + dy
                }
                x0 = min(max(0, x0), x1 - minNorm)
                y0 = min(max(0, y0), y1 - minNorm)
                x1 = max(min(1, x1), x0 + minNorm)
                y1 = max(min(1, y1), y0 + minNorm)
                rect = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
            }
            .onEnded { _ in startRect = nil }
    }
}

// MARK: - Dual-handle range slider

/// A compact two-thumb slider for picking a sub-range. Dragging a thumb
/// also scrubs the player (`onScrub`) so the user sees the frame they're
/// landing on.
struct RangeSlider: View {
    @Binding var low: Double
    @Binding var high: Double
    let bounds: ClosedRange<Double>
    var onScrub: (Double) -> Void = { _ in }

    private let thumb: CGFloat = 14
    private let minGap: Double = 0.2

    var body: some View {
        GeometryReader { geo in
            track(in: geo.size)
        }
    }

    private func span() -> Double { max(bounds.upperBound - bounds.lowerBound, 0.0001) }
    private func usable(_ width: CGFloat) -> CGFloat { max(width - thumb, 1) }

    private func x(_ v: Double, width: CGFloat) -> CGFloat {
        CGFloat((v - bounds.lowerBound) / span()) * usable(width) + thumb / 2
    }

    private func value(at px: CGFloat, width: CGFloat) -> Double {
        let frac = Double(max(0, min(usable(width), px - thumb / 2)) / usable(width))
        return bounds.lowerBound + frac * span()
    }

    private func track(in size: CGSize) -> some View {
        let w = size.width
        let xLow = x(low, width: w)
        let xHigh = x(high, width: w)
        return ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.secondary.opacity(0.25))
                .frame(height: 5)
            Capsule()
                .fill(Color.accentColor.opacity(0.7))
                .frame(width: max(xHigh - xLow, 1), height: 5)
                .offset(x: xLow - thumb / 2)

            thumbView
                .position(x: xLow, y: size.height / 2)
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    let v = min(value(at: g.location.x, width: w), high - minGap)
                    low = max(bounds.lowerBound, v)
                    onScrub(low)
                })
            thumbView
                .position(x: xHigh, y: size.height / 2)
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    let v = max(value(at: g.location.x, width: w), low + minGap)
                    high = min(bounds.upperBound, v)
                    onScrub(high)
                })
        }
    }

    private var thumbView: some View {
        Circle()
            .fill(Color.white)
            .frame(width: thumb, height: thumb)
            .shadow(radius: 1, y: 0.5)
            .overlay(Circle().stroke(Color.secondary.opacity(0.5), lineWidth: 0.5))
    }
}

// MARK: - Open panel helper

enum VideoEditorOpenPanel {
    @MainActor
    static func chooseURL() -> URL? {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Open Video")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        return panel.runModal() == .OK ? panel.url : nil
    }
}
