import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum Palette {
    static let bg          = Color(light: NSColor.white,
                                   dark: NSColor(white: 0.12, alpha: 1))
    static let surface     = Color(light: NSColor(white: 0.97, alpha: 1),
                                   dark: NSColor(white: 0.17, alpha: 1))
    static let surfaceDeep = Color(light: NSColor(white: 0.93, alpha: 1),
                                   dark: NSColor(white: 0.22, alpha: 1))
    static let stroke      = Color(light: NSColor(white: 0.88, alpha: 1),
                                   dark: NSColor(white: 0.30, alpha: 1))
    static let primary     = Color(light: NSColor(red: 0.13, green: 0.13, blue: 0.16, alpha: 1),
                                   dark: NSColor(red: 0.92, green: 0.92, blue: 0.95, alpha: 1))
    static let muted       = Color(light: NSColor(red: 0.55, green: 0.55, blue: 0.60, alpha: 1),
                                   dark: NSColor(red: 0.62, green: 0.62, blue: 0.68, alpha: 1))
    static let accent      = Color(light: NSColor(red: 0.30, green: 0.45, blue: 0.95, alpha: 1),
                                   dark: NSColor(red: 0.45, green: 0.58, blue: 1.00, alpha: 1))
    static let warn        = Color(light: NSColor(red: 0.92, green: 0.45, blue: 0.40, alpha: 1),
                                   dark: NSColor(red: 0.98, green: 0.55, blue: 0.50, alpha: 1))
}

// MARK: - Root

struct QRCodeRootView: View {

    @State private var text: String = "https://capybuddy.atlai.co.uk"
    @State private var foreground: Color = .black
    @State private var background: Color = .white
    @State private var dotShape: QRDotShape = .square
    @State private var eyeShape: QREyeShape = .square
    @State private var errorCorrection: QRErrorCorrection = .high
    @State private var logo: NSImage? = nil
    @State private var logoScale: Double = 0.18

    @State private var rendered: NSImage? = nil
    @State private var renderError: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            previewColumn
                .frame(width: 360)
            Divider()
            controlsColumn
                .frame(maxWidth: .infinity)
        }
        .padding(24)
        .frame(minWidth: 920, idealWidth: 980, minHeight: 700, idealHeight: 740)
        .background(Palette.bg.ignoresSafeArea())
        .onAppear(perform: rerender)
        .onChange(of: text)            { _, _ in rerender() }
        .onChange(of: foreground)      { _, _ in rerender() }
        .onChange(of: background)      { _, _ in rerender() }
        .onChange(of: dotShape)        { _, _ in rerender() }
        .onChange(of: eyeShape)        { _, _ in rerender() }
        .onChange(of: errorCorrection) { _, _ in rerender() }
        .onChange(of: logoScale)       { _, _ in rerender() }
    }

    // MARK: - Preview

    private var previewColumn: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Palette.surface)
                if let rendered {
                    Image(nsImage: rendered)
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(1, contentMode: .fit)
                        .padding(12)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: renderError == nil ? "qrcode" : "exclamationmark.triangle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(renderError == nil ? Palette.muted : Palette.warn)
                        Text(renderError ?? String(localized: "Type something to encode."))
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Palette.muted)
                            .padding(.horizontal, 12)
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Palette.stroke, lineWidth: 1)
            )

            HStack(spacing: 10) {
                Button(action: copyToClipboard) {
                    Label("Copy", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(rendered == nil)

                Button(action: savePNG) {
                    Label("Save PNG…", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.accent)
                .disabled(rendered == nil)
            }
        }
    }

    // MARK: - Controls

    private var controlsColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                contentSection
                colorsSection
                shapeSection
                logoSection
                errorSection
            }
        }
    }

    private var contentSection: some View {
        section(title: String(localized: "Content")) {
            TextEditor(text: $text)
                .font(.system(size: 13, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 80, maxHeight: 120)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Palette.bg)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Palette.stroke, lineWidth: 1)
                )
            Text("\(text.count) " + String(localized: "characters"))
                .font(.caption)
                .foregroundStyle(Palette.muted)
        }
    }

    private var colorsSection: some View {
        section(title: String(localized: "Colors")) {
            HStack(spacing: 16) {
                colorRow(label: String(localized: "Foreground"), selection: $foreground)
                colorRow(label: String(localized: "Background"), selection: $background)
            }
        }
    }

    private var shapeSection: some View {
        section(title: String(localized: "Shape")) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Dots")
                        .font(.caption.bold())
                        .foregroundStyle(Palette.muted)
                    Picker("", selection: $dotShape) {
                        ForEach(QRDotShape.allCases) { s in
                            Text(s.displayName).tag(s)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Eyes")
                        .font(.caption.bold())
                        .foregroundStyle(Palette.muted)
                    Picker("", selection: $eyeShape) {
                        ForEach(QREyeShape.allCases) { s in
                            Text(s.displayName).tag(s)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
            }
        }
    }

    private var logoSection: some View {
        section(title: String(localized: "Logo")) {
            HStack(alignment: .center, spacing: 12) {
                LogoDropTarget(image: $logo, onChanged: rerender)
                    .frame(width: 80, height: 80)

                VStack(alignment: .leading, spacing: 6) {
                    if logo == nil {
                        Text("Drop or click to add a logo. PNG with transparency works best.")
                            .font(.caption)
                            .foregroundStyle(Palette.muted)
                    } else {
                        Text("Size")
                            .font(.caption.bold())
                            .foregroundStyle(Palette.muted)
                        HStack {
                            Slider(value: $logoScale, in: 0.10...0.22)
                                .tint(Palette.accent)
                            Text(String(format: "%.0f%%", logoScale * 100))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Palette.muted)
                                .frame(width: 40, alignment: .trailing)
                        }
                        Text("Adding a logo forces high error correction so scanners can recover.")
                            .font(.caption2)
                            .foregroundStyle(Palette.muted)
                        Button("Remove logo") {
                            logo = nil
                            rerender()
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .foregroundStyle(Palette.warn)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var errorSection: some View {
        section(title: String(localized: "Error correction")) {
            Picker("", selection: $errorCorrection) {
                ForEach(QRErrorCorrection.allCases) { ec in
                    Text(ec.displayName).tag(ec)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            Text("Higher correction tolerates more damage and bigger logos, but needs more modules.")
                .font(.caption)
                .foregroundStyle(Palette.muted)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.muted)
                .textCase(.uppercase)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Palette.stroke, lineWidth: 1)
        )
    }

    private func colorRow(label: String, selection: Binding<Color>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.bold())
                .foregroundStyle(Palette.muted)
            ColorPicker("", selection: selection, supportsOpacity: false)
                .labelsHidden()
        }
    }

    // MARK: - Render

    private func rerender() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            rendered = nil
            renderError = nil
            return
        }
        let opts = QRCodeOptions(
            text: trimmed,
            pixelSize: 1024,
            foreground: NSColor(foreground),
            background: NSColor(background),
            dotShape: dotShape,
            eyeShape: eyeShape,
            errorCorrection: errorCorrection,
            quietZoneModules: 2,
            logo: logo,
            logoScale: CGFloat(logoScale)
        )
        if let img = QRCodeGenerator.render(options: opts) {
            rendered = img
            renderError = nil
        } else {
            rendered = nil
            renderError = String(localized: "Couldn't encode. Try shorter text or lower correction.")
        }
    }

    // MARK: - Actions

    private func copyToClipboard() {
        guard let img = rendered, let png = pngData(for: img) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(png, forType: .png)
    }

    private func savePNG() {
        guard let img = rendered, let png = pngData(for: img) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "qrcode.png"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try png.write(to: url)
            } catch {
                let alert = NSAlert(error: error)
                alert.messageText = String(localized: "Couldn't save the QR code.")
                alert.runModal()
            }
        }
    }

    private func pngData(for image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

// MARK: - Logo drop target

private struct LogoDropTarget: View {
    @Binding var image: NSImage?
    let onChanged: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Palette.bg)
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: 1.2, dash: image == nil ? [4, 3] : [])
                )
                .foregroundStyle(hovering ? Palette.accent : Palette.stroke)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(8)
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 18))
                    Text("Drop logo")
                        .font(.system(size: 10, design: .rounded))
                }
                .foregroundStyle(Palette.muted)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture(perform: openPanel)
        .onDrop(of: [UTType.fileURL], isTargeted: $hovering) { providers in
            Task { await handleDrop(providers) }
            return true
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) async {
        for p in providers {
            let url: URL? = await withCheckedContinuation { cont in
                p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    if let u = item as? URL {
                        cont.resume(returning: u)
                    } else if let d = item as? Data,
                              let u = URL(dataRepresentation: d, relativeTo: nil) {
                        cont.resume(returning: u)
                    } else {
                        cont.resume(returning: nil)
                    }
                }
            }
            if let url, let img = NSImage(contentsOf: url) {
                await MainActor.run {
                    image = img
                    onChanged()
                }
                return
            }
        }
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image]
        // Non-blocking begin() instead of runModal() — runModal spins its
        // own event loop and steals key-window status from the host panel,
        // and on return the SwiftUI TextEditor's NSTextView sometimes fails
        // to regain first responder, which makes the text field "go dead".
        panel.begin { response in
            guard response == .OK,
                  let url = panel.url,
                  let img = NSImage(contentsOf: url) else { return }
            self.image = img
            self.onChanged()
        }
    }
}

#Preview {
    QRCodeRootView()
}
