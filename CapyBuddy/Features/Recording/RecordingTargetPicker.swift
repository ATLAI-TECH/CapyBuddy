import AppKit
import ScreenCaptureKit
import SwiftUI

/// Two-stage selection for a recording target.
///
/// Stage 1 (`chooseMode`) — Zoom-style chooser panel with three illustrated
/// cards (Full Screen / Application / Region). Bypassable via the global
/// hotkey, which jumps straight to `.region` for the common case.
///
/// Stage 2 (`pick`) — per-mode resolver:
///   - `.fullScreen` — if there's only one display, returns it immediately;
///     otherwise shows a small floating panel listing each display.
///   - `.application` — list of running apps with visible windows, sorted
///     frontmost first. Capture is constrained to the display the app's
///     windows mostly live on.
///   - `.region` — full-screen drag overlay (one per attached display).
@MainActor
enum RecordingTargetPicker {

    static func chooseMode() async -> RecordingMode? {
        await withCheckedContinuation { cont in
            RecordingModeChooserWindow.present { mode in
                cont.resume(returning: mode)
            }
        }
    }

    static func pick(mode: RecordingMode, manager: RecordingManager) async throws -> RecordingTarget? {
        switch mode {
        case .fullScreen:
            return try await pickFullScreen()
        case .application:
            return try await pickApplication()
        case .region:
            return try await pickRegion()
        }
    }

    // MARK: - Full Screen

    private static func pickFullScreen() async throws -> RecordingTarget? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let displays = content.displays
        guard !displays.isEmpty else { return nil }
        if displays.count == 1, let only = displays.first {
            return .display(only)
        }
        let display: SCDisplay? = await withCheckedContinuation { cont in
            DisplayPickerWindow.present(displays: displays) { picked in
                cont.resume(returning: picked)
            }
        }
        return display.map { .display($0) }
    }

    // MARK: - Application

    private static func pickApplication() async throws -> RecordingTarget? {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let ourBundle = Bundle.main.bundleIdentifier ?? ""
        let windowsByApp = Dictionary(grouping: content.windows.filter { window in
            guard let app = window.owningApplication else { return false }
            if app.bundleIdentifier == ourBundle { return false }
            if let title = window.title, !title.isEmpty { return true }
            return false
        }, by: { $0.owningApplication?.bundleIdentifier ?? "" })

        // Apps that actually have user-facing windows on screen right now,
        // de-duplicated and front-to-back. SCShareableContent.applications
        // is alphabetical; window order is preserved instead.
        var seen = Set<String>()
        var apps: [SCRunningApplication] = []
        for window in content.windows {
            guard let app = window.owningApplication else { continue }
            if app.bundleIdentifier == ourBundle { continue }
            if (window.title ?? "").isEmpty { continue }
            if seen.insert(app.bundleIdentifier).inserted {
                apps.append(app)
            }
        }

        let picked: (SCRunningApplication, SCDisplay)? = await withCheckedContinuation { cont in
            ApplicationPickerWindow.present(apps: apps, displays: content.displays, windowsByApp: windowsByApp) { selection in
                cont.resume(returning: selection)
            }
        }
        guard let (app, display) = picked else { return nil }
        let appWindows = windowsByApp[app.bundleIdentifier] ?? []
        let rect = appBoundingRect(application: app, display: display, windows: appWindows)
        return .application(display: display, application: app, boundingRect: rect)
    }

    /// Union of the app's visible windows on this display, in AppKit
    /// screen-local coordinates (origin at the display's lower-left,
    /// points). Falls back to the entire display rect if nothing matches
    /// — that's just SCK's default sourceRect, no worse than what we had.
    private static func appBoundingRect(
        application: SCRunningApplication,
        display: SCDisplay,
        windows: [SCWindow]
    ) -> CGRect {
        let cgBounds = CGDisplayBounds(display.displayID)   // CG top-left
        // Union of windows in CG global top-left coords (SCWindow.frame).
        // Clip to the display so off-screen halves don't drag the rect.
        var unionCG = CGRect.null
        for win in windows {
            let clipped = win.frame.intersection(cgBounds)
            if !clipped.isNull {
                unionCG = unionCG.isNull ? clipped : unionCG.union(clipped)
            }
        }
        if unionCG.isNull {
            // No visible windows of this app on this display — record the
            // full display so the user at least gets *something*.
            return CGRect(x: 0, y: 0, width: cgBounds.width, height: cgBounds.height)
        }
        // Translate to display-local (still CG top-left).
        let localCG = CGRect(
            x: unionCG.origin.x - cgBounds.origin.x,
            y: unionCG.origin.y - cgBounds.origin.y,
            width: unionCG.width,
            height: unionCG.height
        )
        // Flip to AppKit bottom-left so it matches `.region`'s convention
        // (the engine flips both back to CG top-left for sourceRect).
        let akLocal = CGRect(
            x: localCG.origin.x,
            y: cgBounds.height - localCG.maxY,
            width: localCG.width,
            height: localCG.height
        )
        // A few pixels of padding so the recording isn't tight against
        // every shadow edge — looks nicer in the saved file.
        let pad: CGFloat = 6
        return CGRect(
            x: max(0, akLocal.origin.x - pad),
            y: max(0, akLocal.origin.y - pad),
            width: min(cgBounds.width - max(0, akLocal.origin.x - pad), akLocal.width + 2 * pad),
            height: min(cgBounds.height - max(0, akLocal.origin.y - pad), akLocal.height + 2 * pad)
        )
    }

    // MARK: - Region

    private static func pickRegion() async throws -> RecordingTarget? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let displays = content.displays
        guard !displays.isEmpty else { return nil }
        let result: (SCDisplay, NSRect)? = await withCheckedContinuation { cont in
            RegionPickerOverlay.present(displays: displays) { picked in
                cont.resume(returning: picked)
            }
        }
        guard let (display, rect) = result else { return nil }
        return .region(display: display, rect: rect)
    }
}

// MARK: - Zoom-style mode chooser

@MainActor
private final class RecordingModeChooserWindow {
    private static var current: NSPanel?

    static func present(completion: @escaping (RecordingMode?) -> Void) {
        let view = RecordingModeChooserView { mode in
            current?.orderOut(nil)
            current = nil
            completion(mode)
        }
        let host = NSHostingController(rootView: view)
        host.view.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        let panel = NSPanel(
            contentRect: host.view.frame,
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Start Recording"
        panel.titlebarAppearsTransparent = true
        panel.contentViewController = host
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        current = panel
    }
}

private struct RecordingModeChooserView: View {
    let onPick: (RecordingMode?) -> Void
    @State private var hovered: RecordingMode?

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Text("What do you want to record?")
                    .font(.title3.weight(.semibold))
                Text("Choose a capture mode to continue.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 20)
            .padding(.bottom, 18)

            HStack(spacing: 16) {
                ForEach(RecordingMode.allCases) { mode in
                    card(for: mode)
                }
            }
            .padding(.horizontal, 22)

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Cancel") { onPick(nil) }
                    .keyboardShortcut(.escape)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 18)
            .padding(.top, 16)
        }
        .frame(width: 640, height: 360)
        .background(.background)
    }

    private func card(for mode: RecordingMode) -> some View {
        Button {
            onPick(mode)
        } label: {
            VStack(spacing: 12) {
                illustration(for: mode)
                    .frame(height: 120)
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                VStack(spacing: 4) {
                    Text(mode.label)
                        .font(.headline)
                    Text(mode.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 14)
            }
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(hovered == mode
                          ? Color.accentColor.opacity(0.14)
                          : Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(hovered == mode ? Color.accentColor : Color.secondary.opacity(0.25),
                                  lineWidth: hovered == mode ? 1.8 : 0.8)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            hovered = isHovering ? mode : (hovered == mode ? nil : hovered)
        }
    }

    @ViewBuilder
    private func illustration(for mode: RecordingMode) -> some View {
        switch mode {
        case .fullScreen:  FullScreenIllustration()
        case .application: ApplicationIllustration()
        case .region:      RegionIllustration()
        }
    }
}

private struct FullScreenIllustration: View {
    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(LinearGradient(
                        colors: [.accentColor.opacity(0.30), .accentColor.opacity(0.15)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1.4)
                    )
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                // Display "stand"
                Rectangle()
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: geo.size.width * 0.30, height: 4)
                    .offset(y: geo.size.height / 2 - 4)
            }
        }
    }
}

private struct ApplicationIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                // Back window
                window(at: CGPoint(x: w * 0.30, y: h * 0.40),
                       size: CGSize(width: w * 0.55, height: h * 0.55),
                       opacity: 0.45)
                // Mid window
                window(at: CGPoint(x: w * 0.45, y: h * 0.55),
                       size: CGSize(width: w * 0.55, height: h * 0.55),
                       opacity: 0.70)
                // Front window
                window(at: CGPoint(x: w * 0.58, y: h * 0.68),
                       size: CGSize(width: w * 0.55, height: h * 0.55),
                       opacity: 1.0)
            }
        }
    }

    private func window(at center: CGPoint, size: CGSize, opacity: Double) -> some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(0.18 * opacity))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.55 * opacity), lineWidth: 1.2)
                )
            // Title-bar dots
            HStack(spacing: 3) {
                Circle().frame(width: 4, height: 4)
                Circle().frame(width: 4, height: 4)
                Circle().frame(width: 4, height: 4)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.accentColor.opacity(0.55 * opacity))
            .padding(.top, 4)
            .padding(.horizontal, 5)
        }
        .frame(width: size.width, height: size.height)
        .position(center)
    }
}

private struct RegionIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                // Faded "screen" backdrop
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.15))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                // Dashed selection rectangle
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(
                        Color.accentColor,
                        style: StrokeStyle(lineWidth: 1.8, dash: [5, 4])
                    )
                    .frame(width: w * 0.55, height: h * 0.55)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.accentColor.opacity(0.15))
                            .frame(width: w * 0.55, height: h * 0.55)
                    )
                // Handle dots at the corners
                ForEach(0..<4) { idx in
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                        .offset(
                            x: (idx % 2 == 0 ? -1 : 1) * w * 0.275,
                            y: (idx < 2 ? -1 : 1) * h * 0.275
                        )
                }
            }
        }
    }
}

// MARK: - Display picker (multi-monitor full-screen mode)

@MainActor
private final class DisplayPickerWindow {
    private static var current: NSPanel?

    static func present(displays: [SCDisplay], completion: @escaping (SCDisplay?) -> Void) {
        let view = DisplayPickerView(displays: displays) { picked in
            current?.orderOut(nil)
            current = nil
            completion(picked)
        }
        let host = NSHostingController(rootView: view)
        host.view.frame = NSRect(x: 0, y: 0, width: 420, height: 100 + CGFloat(displays.count) * 80)
        let panel = NSPanel(
            contentRect: host.view.frame,
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Choose a display to record"
        panel.contentViewController = host
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        current = panel
    }
}

private struct DisplayPickerView: View {
    let displays: [SCDisplay]
    let onPick: (SCDisplay?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose a display to record")
                .font(.headline)
            VStack(spacing: 8) {
                ForEach(Array(displays.enumerated()), id: \.offset) { index, display in
                    Button {
                        onPick(display)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: isMainDisplay(display) ? "menubar.rectangle" : "display")
                                .font(.system(size: 22))
                                .foregroundStyle(.tint)
                                .frame(width: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(labelFor(display: display, index: index))
                                    .fontWeight(.medium)
                                Text(detailFor(display: display))
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
                        .padding(10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { onPick(nil) }.keyboardShortcut(.escape)
            }
            .padding(.top, 4)
        }
        .padding(16)
    }

    private func labelFor(display: SCDisplay, index: Int) -> String {
        if isMainDisplay(display) {
            return "Main Display"
        }
        if let screen = nsScreen(for: display),
           let name = screen.localizedName as String? {
            return name
        }
        return "Display \(index + 1)"
    }

    private func detailFor(display: SCDisplay) -> String {
        let res = "\(display.width) × \(display.height)"
        var note: String?
        if let screen = nsScreen(for: display),
           let mouseScreen = screenContainingMouse(),
           screen == mouseScreen {
            note = "Cursor is here"
        }
        return note.map { "\(res) · \($0)" } ?? res
    }

    private func isMainDisplay(_ display: SCDisplay) -> Bool {
        CGMainDisplayID() == display.displayID
    }

    private func nsScreen(for display: SCDisplay) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
        }
    }

    private func screenContainingMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
    }
}

// MARK: - Application picker

@MainActor
private final class ApplicationPickerWindow {
    private static var current: NSPanel?

    static func present(apps: [SCRunningApplication],
                        displays: [SCDisplay],
                        windowsByApp: [String: [SCWindow]],
                        completion: @escaping (((SCRunningApplication, SCDisplay))?) -> Void) {
        let view = ApplicationPickerView(apps: apps, displays: displays, windowsByApp: windowsByApp) { selection in
            current?.orderOut(nil)
            current = nil
            completion(selection)
        }
        let host = NSHostingController(rootView: view)
        host.view.frame = NSRect(x: 0, y: 0, width: 600, height: 520)
        let panel = NSPanel(
            contentRect: host.view.frame,
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Choose an application to record"
        panel.contentViewController = host
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        current = panel
    }
}

private struct ApplicationPickerView: View {
    let apps: [SCRunningApplication]
    let displays: [SCDisplay]
    let windowsByApp: [String: [SCWindow]]
    let onPick: (((SCRunningApplication, SCDisplay))?) -> Void
    @State private var query: String = ""
    @State private var previews: [String: NSImage] = [:]

    private var filtered: [SCRunningApplication] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return apps }
        let q = query.lowercased()
        return apps.filter { $0.applicationName.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose an application to record")
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.top, 14)
            Text("All windows of the chosen app will be captured.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)

            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search apps…", text: $query).textFieldStyle(.plain)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
            .padding(.horizontal, 14)

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 12)], spacing: 12) {
                    ForEach(filtered, id: \.bundleIdentifier) { app in
                        Button {
                            if let display = displayFor(app: app) {
                                onPick((app, display))
                            }
                        } label: {
                            VStack(spacing: 8) {
                                preview(for: app)
                                    .frame(height: 90)
                                    .frame(maxWidth: .infinity)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .strokeBorder(Color.secondary.opacity(0.2))
                                    )
                                HStack(spacing: 6) {
                                    appIcon(for: app)
                                        .resizable()
                                        .frame(width: 18, height: 18)
                                    Text(app.applicationName)
                                        .font(.callout.weight(.medium))
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                    Text("\(windowsByApp[app.bundleIdentifier]?.count ?? 0)")
                                        .font(.caption2.monospacedDigit())
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(Color.secondary.opacity(0.18)))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.secondary.opacity(0.08))
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if filtered.isEmpty {
                        Text("No apps match.")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 20)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
            }

            HStack {
                Spacer()
                Button("Cancel") { onPick(nil) }.keyboardShortcut(.escape)
            }
            .padding(14)
        }
        .task { await loadPreviews() }
    }

    /// Pick the display that contains the largest area of this app's
    /// windows. Falls back to main display if nothing matches (rare —
    /// happens when an app's window has just minimized between our
    /// `excludingDesktopWindows(true,...)` snapshot and the user clicking).
    private func displayFor(app: SCRunningApplication) -> SCDisplay? {
        let appWindows = windowsByApp[app.bundleIdentifier] ?? []
        var bestDisplay: SCDisplay?
        var bestArea: CGFloat = 0
        for display in displays {
            let displayFrame = CGRect(x: 0, y: 0, width: CGFloat(display.width), height: CGFloat(display.height))
            // SCWindow.frame is in CG global coords (top-left); SCDisplay.frame
            // would give us the per-display CG rect via NSScreen lookup, but
            // for ranking we only need a rough overlap test. Use the matching
            // NSScreen's frame.
            guard let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
            }) else { continue }
            let cgRect = screen.frame
            let area: CGFloat = appWindows.reduce(0) { acc, window in
                let intersection = window.frame.intersection(cgRect)
                if intersection.isNull { return acc }
                return acc + intersection.width * intersection.height
            }
            if area > bestArea {
                bestArea = area
                bestDisplay = display
            }
            _ = displayFrame
        }
        return bestDisplay ?? displays.first { CGMainDisplayID() == $0.displayID } ?? displays.first
    }

    @ViewBuilder
    private func preview(for app: SCRunningApplication) -> some View {
        if let image = previews[app.bundleIdentifier] {
            Image(nsImage: image)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                LinearGradient(
                    colors: [Color.secondary.opacity(0.18), Color.secondary.opacity(0.10)],
                    startPoint: .top, endPoint: .bottom
                )
                appIcon(for: app).resizable().frame(width: 44, height: 44).opacity(0.75)
            }
        }
    }

    private func appIcon(for app: SCRunningApplication) -> Image {
        if let running = NSRunningApplication(processIdentifier: app.processID),
           let icon = running.icon {
            return Image(nsImage: icon)
        }
        return Image(systemName: "app")
    }

    private func loadPreviews() async {
        // For each app, snapshot the frontmost of its windows. Capped at
        // ~30 so the picker doesn't pause for users with 100s of windows.
        let bundles = apps.prefix(30).map { $0.bundleIdentifier }
        await withTaskGroup(of: (String, NSImage?).self) { group in
            for bundle in bundles {
                guard let topWindow = windowsByApp[bundle]?.first else { continue }
                group.addTask {
                    let img = await snapshot(of: topWindow)
                    return (bundle, img)
                }
            }
            for await (bundle, img) in group {
                if let img = img {
                    await MainActor.run { previews[bundle] = img }
                }
            }
        }
    }

    private func snapshot(of window: SCWindow) async -> NSImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let conf = SCStreamConfiguration()
        conf.width = 240
        conf.height = max(2, Int(window.frame.height * 240 / max(window.frame.width, 1)))
        conf.showsCursor = false
        do {
            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: conf)
            return NSImage(cgImage: cgImage, size: NSSize(width: conf.width, height: conf.height))
        } catch {
            return nil
        }
    }
}

// MARK: - Region picker (drag overlay)

@MainActor
private final class RegionPickerOverlay {
    private static var current: RegionPickerOverlay?

    private let displays: [SCDisplay]
    private let completion: (((SCDisplay, NSRect))?) -> Void
    private var didFinish = false

    static func present(displays: [SCDisplay], completion: @escaping (((SCDisplay, NSRect))?) -> Void) {
        let overlay = RegionPickerOverlay(displays: displays, completion: completion)
        current = overlay
        overlay.show()
    }

    private init(displays: [SCDisplay], completion: @escaping (((SCDisplay, NSRect))?) -> Void) {
        self.displays = displays
        self.completion = completion
    }

    private func show() {
        for screen in NSScreen.screens {
            let panel = RecordingRegionOverlayPanel(
                screen: screen,
                onSelect: { [weak self] globalRect in
                    self?.commit(globalRect: globalRect, screen: screen)
                },
                onCancel: { [weak self] in
                    self?.cancel()
                }
            )
            panel.makeKeyAndOrderFront(nil)
            panels.append(panel)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func commit(globalRect: NSRect, screen: NSScreen) {
        guard !didFinish else { return }
        didFinish = true
        // Find the SCDisplay matching this NSScreen by displayID.
        let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        let match = displays.first { Int($0.displayID) == screenID.map(Int.init) }
        // Convert AppKit global rect → coordinates local to that screen
        // (origin at the display's bottom-left). The engine flips Y to
        // CG top-left when building sourceRect.
        let local = NSRect(
            x: globalRect.origin.x - screen.frame.origin.x,
            y: globalRect.origin.y - screen.frame.origin.y,
            width: globalRect.width,
            height: globalRect.height
        )
        teardown()
        completion(match.map { ($0, local) })
        Self.current = nil
    }

    private func cancel() {
        guard !didFinish else { return }
        didFinish = true
        teardown()
        completion(nil)
        Self.current = nil
    }

    private func teardown() {
        for panel in panels { panel.orderOut(nil) }
        panels.removeAll()
    }

    private var panels: [RecordingRegionOverlayPanel] = []
}

// MARK: - Region overlay panel

/// Borderless screen-saver-level panel covering one display while the user
/// drags out the region to record. Independent of the screenshot overlay —
/// no annotation phase, no magnifier, no AX hit testing. Just: click-drag
/// on a dimmed backdrop, ESC to cancel, mouseUp commits the rect.
private final class RecordingRegionOverlayPanel: NSPanel {
    let owningScreen: NSScreen
    private let regionView: RegionDragView

    init(screen: NSScreen, onSelect: @escaping (NSRect) -> Void, onCancel: @escaping () -> Void) {
        self.owningScreen = screen
        self.regionView = RegionDragView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.animationBehavior = .none
        self.setFrame(screen.frame, display: false)
        self.isRestorable = false
        self.isOpaque = false
        self.backgroundColor = NSColor.black.withAlphaComponent(0.18)
        self.level = .screenSaver
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        self.hasShadow = false
        self.acceptsMouseMovedEvents = true
        self.isReleasedWhenClosed = false
        self.hidesOnDeactivate = false
        self.becomesKeyOnlyIfNeeded = false
        self.contentView = regionView
        self.initialFirstResponder = regionView

        regionView.onSelect = { [weak self] localRect in
            guard let self else { return }
            let global = NSRect(
                x: self.frame.origin.x + localRect.origin.x,
                y: self.frame.origin.y + localRect.origin.y,
                width: localRect.width,
                height: localRect.height
            )
            onSelect(global)
        }
        regionView.onCancel = onCancel
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func becomeKey() {
        super.becomeKey()
        makeFirstResponder(regionView)
    }
}

private final class RegionDragView: NSView {
    var onSelect: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?

    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?
    private let strokeLayer = CAShapeLayer()
    private let sizeLabel = CATextLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.clear.cgColor
        strokeLayer.strokeColor = NSColor.systemBlue.cgColor
        strokeLayer.fillColor = NSColor.systemBlue.withAlphaComponent(0.15).cgColor
        strokeLayer.lineWidth = 1.5
        layer?.addSublayer(strokeLayer)

        sizeLabel.fontSize = 12
        sizeLabel.foregroundColor = NSColor.white.cgColor
        sizeLabel.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        sizeLabel.alignmentMode = .center
        sizeLabel.cornerRadius = 4
        sizeLabel.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        sizeLabel.isHidden = true
        layer?.addSublayer(sizeLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentPoint = startPoint
        updateOverlay()
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        updateOverlay()
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            startPoint = nil
            currentPoint = nil
        }
        guard let rect = currentRect, rect.width >= 4, rect.height >= 4 else {
            updateOverlay()
            return
        }
        onSelect?(rect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }

    private var currentRect: NSRect? {
        guard let s = startPoint, let c = currentPoint else { return nil }
        return NSRect(
            x: min(s.x, c.x),
            y: min(s.y, c.y),
            width: abs(s.x - c.x),
            height: abs(s.y - c.y)
        )
    }

    private func updateOverlay() {
        guard let rect = currentRect else {
            strokeLayer.path = nil
            sizeLabel.isHidden = true
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strokeLayer.path = CGPath(rect: rect, transform: nil)
        sizeLabel.string = "\(Int(rect.width)) × \(Int(rect.height))"
        let labelWidth: CGFloat = 90
        let labelHeight: CGFloat = 18
        sizeLabel.frame = NSRect(
            x: rect.midX - labelWidth / 2,
            y: max(rect.maxY + 6, 8),
            width: labelWidth,
            height: labelHeight
        )
        sizeLabel.isHidden = rect.width < 8 || rect.height < 8
        CATransaction.commit()
    }
}
