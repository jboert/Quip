import Foundation

extension Notification.Name {
    /// Settings → Layouts → Apply. The object is the `SavedLayoutPreset`;
    /// MainWindow observes it, adopts the preset's mode and frames, and runs
    /// the same arrange its toolbar button runs.
    static let quipApplyLayoutPreset = Notification.Name("quip.applyLayoutPreset")
}

/// Pure edits over the `@AppStorage("savedPresets")` blob. The main window
/// writes through `adding`, the Layouts pane through `renaming`/`removing`, and
/// both read through `decode` — one shape, so a preset saved in one place is
/// the preset the other place shows.
struct LayoutPresetStore {

    /// Empty data is the `@AppStorage` default — no presets yet, not an error.
    /// Anything else that will not decode throws, so the caller can say the
    /// user's saved layouts are unreadable instead of quietly showing none.
    static func decode(_ data: Data) throws -> [SavedLayoutPreset] {
        guard !data.isEmpty else { return [] }
        return try JSONDecoder().decode([SavedLayoutPreset].self, from: data)
    }

    static func encode(_ presets: [SavedLayoutPreset]) throws -> Data {
        try JSONEncoder().encode(presets)
    }

    /// Appends `preset`, unless one with the same name (trimmed, compared
    /// case-insensitively) exists — then it replaces that entry in place and
    /// keeps its id, so saving "Work" twice updates "Work" rather than
    /// listing it twice.
    static func adding(_ preset: SavedLayoutPreset, to presets: [SavedLayoutPreset]) -> [SavedLayoutPreset] {
        let key = normalized(preset.name)
        var result = presets
        guard let index = result.firstIndex(where: { normalized($0.name) == key }) else {
            result.append(preset)
            return result
        }
        var replacement = preset
        replacement.id = result[index].id
        result[index] = replacement
        return result
    }

    static func renaming(_ id: UUID, to name: String, in presets: [SavedLayoutPreset]) -> [SavedLayoutPreset] {
        presets.map { preset in
            guard preset.id == id else { return preset }
            var renamed = preset
            renamed.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return renamed
        }
    }

    static func removing(_ id: UUID, from presets: [SavedLayoutPreset]) -> [SavedLayoutPreset] {
        presets.filter { $0.id != id }
    }

    private static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
