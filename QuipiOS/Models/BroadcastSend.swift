import Foundation

/// One tap on Send, as the Broadcast sheet hands it to the main screen.
struct BroadcastSend {
    /// The draft as sent, kept so a retry can reopen the sheet with it.
    let text: String
    let source: BroadcastSource?
    let route: BroadcastRoute
    let targetIDs: [String]
    let pressReturn: Bool
}
