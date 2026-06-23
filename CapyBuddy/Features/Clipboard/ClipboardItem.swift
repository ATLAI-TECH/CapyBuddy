import Foundation

struct ClipboardItem: Identifiable, Codable, Equatable {

    enum Kind: Codable, Equatable {
        case text(String)
        case image(URL)
        case files([URL])
    }

    let id: UUID
    let kind: Kind
    let preview: String
    let timestamp: Date
    let sourceBundleID: String?
    var pinned: Bool

    init(
        id: UUID = UUID(),
        kind: Kind,
        timestamp: Date = Date(),
        sourceBundleID: String? = nil,
        pinned: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.preview = Self.makePreview(from: kind)
        self.timestamp = timestamp
        self.sourceBundleID = sourceBundleID
        self.pinned = pinned
    }

    /// Two items are considered the "same paste" if their content matches —
    /// id/timestamp/pin status are ignored. Used for dedup-on-insert.
    static func sameContent(_ a: ClipboardItem, _ b: ClipboardItem) -> Bool {
        a.kind == b.kind
    }

    static func makePreview(from kind: Kind) -> String {
        switch kind {
        case .text(let s):
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? s : trimmed
        case .image(let url):
            return "[Image] \(url.lastPathComponent)"
        case .files(let urls):
            if urls.count == 1 {
                return "[File] \(urls[0].lastPathComponent)"
            }
            return "[\(urls.count) files] \(urls.first?.lastPathComponent ?? "")"
        }
    }
}
