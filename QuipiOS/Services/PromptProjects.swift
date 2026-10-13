import Foundation

/// Prompts that belong to projects (Q-69). A prompt's projects are tags
/// written `project:<folder>`, so they live in the prompt file on the Mac with
/// its other tags and need no wire change. A prompt with no project shows in
/// every window; one with projects shows in the prompt selector only when the
/// selected window's folder is one of them.
enum PromptProjects {
    static let tagPrefix = "project:"

    static func projects(of entry: PromptEntry) -> [String] {
        projects(inTags: entry.tags)
    }

    static func projects(inTags tags: [String]?) -> [String] {
        (tags ?? []).compactMap { tag in
            guard isProjectTag(tag) else { return nil }
            let name = String(tag.dropFirst(tagPrefix.count)).trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
    }

    /// True when `entry` should be listed for a window whose folder is
    /// `project` (nil: no window selected, or it has no folder). Folder names
    /// compare without case.
    static func belongs(_ entry: PromptEntry, to project: String?) -> Bool {
        let own = projects(of: entry)
        guard !own.isEmpty else { return true }
        guard let project = key(project) else { return false }
        return own.contains { key($0) == project }
    }

    /// `tags` with its project tags replaced by `projects`; other tags keep
    /// their order. Nil when nothing is left, so the Mac writes no tags line.
    static func tags(_ tags: [String]?, settingProjects projects: [String]) -> [String]? {
        let others = (tags ?? []).filter { !isProjectTag($0) }
        var seen = Set<String>()
        let mine = projects.compactMap { name -> String? in
            guard let clean = cleaned(name), seen.insert(clean.lowercased()).inserted else { return nil }
            return tagPrefix + clean
        }
        let out = others + mine
        return out.isEmpty ? nil : out
    }

    /// A project name the Mac can store: trimmed, with no commas (they
    /// separate tags in the prompt file) and no line breaks or other control
    /// characters (the tags are one line of the file's meta block, so a pasted
    /// line break would end it). Nil when nothing is left.
    static func cleaned(_ name: String) -> String? {
        let breaks = CharacterSet(charactersIn: ",").union(.newlines).union(.controlCharacters)
        let spaced = String(name.unicodeScalars.map { breaks.contains($0) ? " " : Character($0) })
        let clean = spaced.trimmingCharacters(in: .whitespaces)
        return clean.isEmpty ? nil : clean
    }

    private static func isProjectTag(_ tag: String) -> Bool {
        tag.lowercased().hasPrefix(tagPrefix)
    }

    private static func key(_ name: String?) -> String? {
        guard let k = name?.trimmingCharacters(in: .whitespaces).lowercased(), !k.isEmpty else { return nil }
        return k
    }
}
