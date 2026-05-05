import Foundation

/// Pure picker for "which newly-spawned window should this poller claim?"
/// (wishlist §23 race A). Extracted from `selectNewWindowAfterSpawn` so the
/// dedupe logic across overlapping rapid-fire spawns is unit-testable
/// without standing up a real WindowManager + iTerm.
///
/// Inputs are snapshots, not live references — the function mutates nothing
/// directly. Caller is expected to merge `claimed` ∪ {result.pickedId} back
/// into its claimed set after broadcasting the selection so the next poller
/// excludes it.
enum SpawnedWindowPicker {

    struct Candidate: Equatable {
        let id: String
        let isTerminal: Bool
    }

    struct Result: Equatable {
        let pickedId: String?
    }

    /// - Parameters:
    ///   - currentIds: every window id WindowManager currently knows about.
    ///   - knownIds: snapshot of ids at the moment THIS spawn fired.
    ///   - claimed: ids already claimed by a prior spawn poller in this race.
    ///   - candidates: id + isTerminal flags, used so a real terminal window
    ///                 wins over an unrelated app window that landed in the
    ///                 same refresh tick.
    /// - Returns: the id this poller should claim, or `nil` if there's
    ///   nothing un-claimed to pick yet (caller should retry).
    static func pick(currentIds: Set<String>,
                     knownIds: Set<String>,
                     claimed: Set<String>,
                     candidates: [Candidate]) -> Result {
        let newIds = currentIds
            .subtracting(knownIds)
            .subtracting(claimed)
        let candidateById = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        let terminalId = newIds.first(where: { candidateById[$0]?.isTerminal == true })
        return Result(pickedId: terminalId ?? newIds.first)
    }
}
