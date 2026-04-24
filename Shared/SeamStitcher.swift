import Foundation

/// Joins two consecutive recognizer outputs, stripping any repeated
/// trailing-old / leading-new word overlap.
enum SeamStitcher {
    /// Maximum number of trailing/leading tokens to inspect.
    static let maxOverlap = 3

    static func stitch(old: String, new: String) -> String {
        let oldTrimmed = old.trimmingCharacters(in: .whitespaces)
        let newTrimmed = new.trimmingCharacters(in: .whitespaces)
        if oldTrimmed.isEmpty { return newTrimmed }
        if newTrimmed.isEmpty { return oldTrimmed }

        let oldTokens = oldTrimmed.split(separator: " ").map(String.init)
        let newTokens = newTrimmed.split(separator: " ").map(String.init)

        let bound = min(maxOverlap, oldTokens.count, newTokens.count)
        var overlap = 0
        for k in stride(from: bound, through: 1, by: -1) {
            let oldSuffix = oldTokens.suffix(k).map { $0.lowercased() }
            let newPrefix = newTokens.prefix(k).map { $0.lowercased() }
            if oldSuffix == newPrefix {
                overlap = k
                break
            }
        }

        let keptNew = newTokens.dropFirst(overlap)
        if keptNew.isEmpty { return oldTrimmed }
        return oldTrimmed + " " + keptNew.joined(separator: " ")
    }
}
