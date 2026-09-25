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

    /// What a confirmed import will actually add. Built before anything is
    /// sent, so the sheet and the apply step agree on the same numbers.
    struct ImportPlan {
        /// Prompts to put, already carrying their final non-colliding ids.
        let prompts: [PromptEntry]
        /// Buttons to append, already re-minted.
        let buttons: [CustomButton]
        let alreadyInstalledPrompts: Int
        let alreadyInstalledButtons: Int

        var isEmpty: Bool { prompts.isEmpty && buttons.isEmpty }
    }

    /// Plan an import against what is already installed (Q-27b).
    ///
    /// Importing the same pack twice used to add a suffixed copy of every
    /// prompt and a fresh copy of every button. Now an item whose visible
    /// content is already installed is skipped: a prompt matches on label AND
    /// body (ignoring id, because an earlier import may have suffixed it), a
    /// button on label, icon and payload. Anything else is added exactly as
    /// before — a prompt whose id is taken by DIFFERENT content still gets a
    /// suffixed id rather than overwriting the user's copy.
    static func importPlan(for pack: SharedPromptPack,
                           existingPrompts: [PromptEntry],
                           existingButtons: [CustomButton]) -> ImportPlan {
        var takenIDs = Set(existingPrompts.map(\.id))
        var installedPrompts = Set(existingPrompts.map { PromptContent($0) })
        var prompts: [PromptEntry] = []
        var skippedPrompts = 0
        for p in pack.prompts {
            guard installedPrompts.insert(PromptContent(p)).inserted else {
                skippedPrompts += 1
                continue
            }
            let id = uniquePromptID(desired: p.id, existing: takenIDs)
            takenIDs.insert(id)
            prompts.append(PromptEntry(id: id, label: p.label, body: p.body, tags: p.tags,
                                       targetAgent: p.targetAgent, description: p.description))
        }

        var installedButtons = Set(existingButtons.map { ButtonContent($0) })
        var buttons: [CustomButton] = []
        var skippedButtons = 0
        for b in pack.buttons {
            guard installedButtons.insert(ButtonContent(b)).inserted else {
                skippedButtons += 1
                continue
            }
            buttons.append(reminted(b))
        }

        return ImportPlan(prompts: prompts, buttons: buttons,
                          alreadyInstalledPrompts: skippedPrompts,
                          alreadyInstalledButtons: skippedButtons)
    }

    private struct PromptContent: Hashable {
        let label: String
        let body: String
        init(_ p: PromptEntry) { label = p.label; body = p.body }
    }

    private struct ButtonContent: Hashable {
        let label: String
        let systemImage: String?
        let payload: CustomPayload
        init(_ b: CustomButton) { label = b.label; systemImage = b.systemImage; payload = b.payload }
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
