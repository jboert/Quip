import Foundation

/// A shareable bundle of prompts and custom "hot buttons" (§6.1). Reuses the
/// existing `PromptEntry` and `CustomButton` types verbatim — it does not
/// redefine them. iOS-only and **never sent over the wire**: it's a file
/// artifact (`.quippack`, JSON). On import the phone fans prompts out to the
/// Mac via `PutPromptMessage` and applies buttons locally.
struct SharedPromptPack: Codable {
    /// Bump only on a breaking format change. Import rejects packs newer than
    /// the running app understands.
    static let currentSchema = 1
    static let fileExtension = "quippack"
    static let uti = "com.fintechadventures.quip.pack"

    let schema: Int
    let name: String?
    let createdAt: Date?
    let prompts: [PromptEntry]
    let buttons: [CustomButton]

    init(name: String? = nil,
         prompts: [PromptEntry] = [],
         buttons: [CustomButton] = [],
         createdAt: Date? = Date(),
         schema: Int = SharedPromptPack.currentSchema) {
        self.schema = schema
        self.name = name
        self.createdAt = createdAt
        self.prompts = prompts
        self.buttons = buttons
    }

    var isEmpty: Bool { prompts.isEmpty && buttons.isEmpty }

    enum PackError: Error, Equatable {
        case unsupportedSchema(Int)
        case empty
    }

    func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(self)
    }

    /// Decode + validate. Throws `unsupportedSchema` for packs from a newer
    /// Quip; the caller surfaces that to the user rather than partial-applying.
    static func decode(_ data: Data) throws -> SharedPromptPack {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let pack = try dec.decode(SharedPromptPack.self, from: data)
        guard pack.schema <= currentSchema else {
            throw PackError.unsupportedSchema(pack.schema)
        }
        return pack
    }

    /// Pick a non-colliding prompt id for import: returns `desired` if free,
    /// else suffixes `-2`, `-3`, … (non-destructive default; the import UI can
    /// still offer explicit overwrite). (§6.1)
    static func uniquePromptID(desired: String, existing: Set<String>) -> String {
        guard existing.contains(desired) else { return desired }
        var n = 2
        while existing.contains("\(desired)-\(n)") { n += 1 }
        return "\(desired)-\(n)"
    }

    /// Re-mint a button's id so an imported button never collides with an
    /// existing local one. (§6.1)
    static func reminted(_ button: CustomButton) -> CustomButton {
        CustomButton(id: UUID(), label: button.label,
                     systemImage: button.systemImage, payload: button.payload)
    }

    /// Stage the pack as a temp `.quippack` file for `UIActivityViewController`.
    func writeToTemp(filename: String) throws -> URL {
        let base = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = base.isEmpty ? "quip-pack"
            : base.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(safe)
            .appendingPathExtension(Self.fileExtension)
        try encoded().write(to: url)
        return url
    }
}
