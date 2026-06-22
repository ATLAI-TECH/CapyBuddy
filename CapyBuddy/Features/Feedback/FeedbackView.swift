import AppKit
import SwiftUI

/// Settings → Feedback. Submits straight to the CapyBuddy issue Worker
/// (Cloudflare Worker, source in CapyBuddyTools/worker/src/index.js) which
/// holds the GitHub PAT server-side and creates a public GitHub issue.
///
/// Why a Worker and not URL-prefill any more: the user shouldn't need a
/// GitHub account to file a bug. Why not embed the PAT in the app: anyone
/// can unzip the .app and extract it, then spam the issue tracker.
struct FeedbackView: View {

    enum IssueKind: String, CaseIterable, Identifiable {
        case bug, feature, question
        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .bug: return "Bug report"
            case .feature: return "Feature request"
            case .question: return "Question"
            }
        }

        var titlePlaceholder: String {
            switch self {
            case .bug: return "e.g. Screenshot tool crashes on dual monitors"
            case .feature: return "e.g. Add scrolling capture mode"
            case .question: return "e.g. How do I rebind Space Shortcut?"
            }
        }

        var descriptionPlaceholder: String {
            switch self {
            case .bug: return "Describe what happened and what you expected."
            case .feature: return "Describe the feature and why it would be useful."
            case .question: return "Provide context so we can help you."
            }
        }

        var showsSteps: Bool { self == .bug }
        var showsEnvironment: Bool { self == .bug || self == .question }
    }

    enum SubmitState: Equatable {
        case idle
        case submitting
        case succeeded(url: String, number: Int)
        case failed(String)
    }

    /// Cloudflare Worker that creates the GitHub issue. Public URL — fine
    /// to ship in source. The PAT lives only in the Worker's secrets.
    private static let workerURL = URL(string: "https://capybuddy-issues.haopeng-yu.workers.dev")!

    private static let titleLimit = 200
    private static let descriptionLimit = 5000
    private static let stepsLimit = 2000
    private static let environmentLimit = 200
    private static let contactLimit = 200

    @State private var kind: IssueKind = .bug
    @State private var title: String = ""
    @State private var descriptionText: String = ""
    @State private var steps: String = ""
    @State private var environment: String = ""
    @State private var contact: String = ""
    @State private var submitState: SubmitState = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            switch submitState {
            case .succeeded(let url, let number):
                successCard(url: url, number: number)
            default:
                form
            }

            footerNote

            Spacer()
        }
        .onAppear {
            // Pre-fill environment with diagnostics so the user doesn't have
            // to type their macOS / Mac model from scratch. They can still
            // edit it before submitting.
            if environment.isEmpty {
                environment = Self.environmentDiagnostics()
            }
        }
    }

    // MARK: - Subviews

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Send feedback")
                .font(.title2).bold()
            Text("Found a bug? Want a new tool inside CapyBuddy? Submit it here — your report goes straight to our issue tracker. No GitHub account needed.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var form: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Type", selection: $kind) {
                    ForEach(IssueKind.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(submitState == .submitting)

                labeledField("Title", hint: "A short summary") {
                    TextField(kind.titlePlaceholder, text: $title)
                        .textFieldStyle(.roundedBorder)
                        .disabled(submitState == .submitting)
                }
                charCounter(current: title.count, max: Self.titleLimit)

                labeledField("Description", hint: "Required") {
                    TextEditor(text: $descriptionText)
                        .font(.system(size: 13))
                        .frame(minHeight: 120)
                        .padding(6)
                        .background(editorBackground)
                        .overlay(editorBorder)
                        .disabled(submitState == .submitting)
                        .overlay(alignment: .topLeading) {
                            if descriptionText.isEmpty {
                                Text(kind.descriptionPlaceholder)
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 14)
                                    .padding(.leading, 12)
                                    .allowsHitTesting(false)
                            }
                        }
                }
                charCounter(current: descriptionText.count, max: Self.descriptionLimit)

                if kind.showsSteps {
                    labeledField("Steps to reproduce", hint: "Optional but helpful") {
                        TextEditor(text: $steps)
                            .font(.system(size: 13))
                            .frame(minHeight: 70)
                            .padding(6)
                            .background(editorBackground)
                            .overlay(editorBorder)
                            .disabled(submitState == .submitting)
                    }
                }

                if kind.showsEnvironment {
                    labeledField("Environment", hint: "Auto-filled — edit if needed") {
                        TextField("macOS version, CapyBuddy version, Mac model", text: $environment)
                            .textFieldStyle(.roundedBorder)
                            .disabled(submitState == .submitting)
                    }
                }

                labeledField("Contact email", hint: "Optional — only if you want a follow-up") {
                    TextField("you@example.com", text: $contact)
                        .textFieldStyle(.roundedBorder)
                        .disabled(submitState == .submitting)
                }

                submitRow
            }
            .padding(12)
        }
    }

    private func successCard(url: String, number: Int) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Thanks! Issue #\(number) submitted.")
                        .font(.headline)
                    Text("Your report has been posted to GitHub.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                if let issueURL = URL(string: url) {
                    Button {
                        NSWorkspace.shared.open(issueURL)
                    } label: {
                        Label("View on GitHub", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button("Submit another") { resetForm() }
                Spacer()
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.green.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.green.opacity(0.25), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var submitRow: some View {
        HStack(spacing: 10) {
            Button {
                Task { await submit() }
            } label: {
                HStack(spacing: 6) {
                    if submitState == .submitting {
                        ProgressView().controlSize(.small)
                    }
                    Text(submitState == .submitting ? "Submitting…" : "Submit")
                }
                .frame(minWidth: 90)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSubmit)

            if case .failed(let message) = submitState {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()
        }
    }

    private var footerNote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("How this works")
                .font(.caption).bold()
                .foregroundStyle(.secondary)
            Text("Your report is sent to our Cloudflare Worker, which creates a public issue at github.com/ATLAI-TECH/CapyBuddyTools. Don't include private info you wouldn't want public.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .quaternarySystemFill))
        )
    }

    private func labeledField<Content: View>(
        _ label: String,
        hint: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(label).font(.caption).bold().foregroundStyle(.secondary)
                Text(hint).font(.caption2).foregroundStyle(.tertiary)
            }
            content()
        }
    }

    private func charCounter(current: Int, max: Int) -> some View {
        HStack {
            Spacer()
            Text("\(current)/\(max)")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(current > max ? AnyShapeStyle(Color.red) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
        }
    }

    private var editorBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(nsColor: .textBackgroundColor))
    }

    private var editorBorder: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
    }

    // MARK: - Actions

    private var canSubmit: Bool {
        guard submitState != .submitting else { return false }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDesc = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !trimmedDesc.isEmpty else { return false }
        guard trimmedTitle.count <= Self.titleLimit,
              trimmedDesc.count <= Self.descriptionLimit,
              steps.count <= Self.stepsLimit,
              environment.count <= Self.environmentLimit,
              contact.count <= Self.contactLimit else { return false }
        return true
    }

    private func resetForm() {
        title = ""
        descriptionText = ""
        steps = ""
        environment = Self.environmentDiagnostics()
        contact = ""
        submitState = .idle
    }

    @MainActor
    private func submit() async {
        submitState = .submitting

        var payload: [String: String] = [
            "kind": kind.rawValue,
            "title": title.trimmingCharacters(in: .whitespacesAndNewlines),
            "description": descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        let trimmedSteps = steps.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEnv = environment.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContact = contact.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind.showsSteps, !trimmedSteps.isEmpty { payload["steps"] = trimmedSteps }
        if kind.showsEnvironment, !trimmedEnv.isEmpty { payload["environment"] = trimmedEnv }
        if !trimmedContact.isEmpty { payload["contact"] = trimmedContact }

        guard let bodyData = try? JSONSerialization.data(withJSONObject: payload) else {
            submitState = .failed("Couldn't encode the request. Please try again.")
            return
        }

        var request = URLRequest(url: Self.workerURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("CapyBuddy-macOS-app", forHTTPHeaderField: "User-Agent")
        request.httpBody = bodyData
        request.timeoutInterval = 25

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

            guard let http = response as? HTTPURLResponse else {
                submitState = .failed("No response from server.")
                return
            }

            if (200..<300).contains(http.statusCode), json["success"] as? Bool == true {
                let url = json["issue_url"] as? String ?? "https://github.com/ATLAI-TECH/CapyBuddyTools/issues"
                let number = json["issue_number"] as? Int ?? 0
                submitState = .succeeded(url: url, number: number)
            } else {
                let message = (json["error"] as? String) ?? "Server returned status \(http.statusCode)."
                submitState = .failed(message)
            }
        } catch {
            submitState = .failed("Network error: \(error.localizedDescription)")
        }
    }

    // MARK: - Diagnostics

    /// "macOS 14.5.0 · CapyBuddy v1.0 (12) · Mac15,9 (Apple Silicon)"
    private static func environmentDiagnostics() -> String {
        let info = ProcessInfo.processInfo
        let v = info.operatingSystemVersion
        let osString = "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"

        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let appString = "CapyBuddy v\(short) (\(build))"

        let arch: String
        #if arch(arm64)
        arch = "Apple Silicon"
        #elseif arch(x86_64)
        arch = "Intel"
        #else
        arch = "Unknown arch"
        #endif

        return "\(osString) · \(appString) · \(hardwareModel()) (\(arch))"
    }

    /// Reads `hw.model` from sysctl, e.g. "Mac15,9". Falls back to "unknown"
    /// if the call fails.
    private static func hardwareModel() -> String {
        var size: size_t = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }
}
