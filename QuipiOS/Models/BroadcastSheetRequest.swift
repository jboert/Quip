import Foundation

/// What the Broadcast sheet opens with: the draft, the library prompt it came
/// from (US-107), and which terminals start selected. `selection` nil selects
/// every terminal; a retry (US-111) passes only the ones that did not confirm.
struct BroadcastSheetRequest: Identifiable {
    let id = UUID()
    var draft: String
    var source: BroadcastSource?
    var selection: Set<String>?
}
