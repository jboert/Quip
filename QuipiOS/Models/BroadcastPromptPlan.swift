import Foundation

/// Pure selection and validation rules for the phone's broadcast-prompt sheet.
/// Wire sends stay in `MainiOSView`; this type keeps the view honest and testable.
enum BroadcastPromptPlan {
    static func eligibleWindows(_ windows: [WindowState]) -> [WindowState] {
        windows.filter(\.isTerminal)
    }

    static func initialSelection(windows: [WindowState]) -> Set<String> {
        Set(eligibleWindows(windows).map(\.id))
    }

    static func reconciledSelection(_ selectedIDs: Set<String>,
                                    windows: [WindowState]) -> Set<String> {
        selectedIDs.intersection(eligibleWindows(windows).map(\.id))
    }

    static func normalizedText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func targetIDs(windows: [WindowState],
                          selectedIDs: Set<String>) -> [String] {
        eligibleWindows(windows).compactMap { window in
            selectedIDs.contains(window.id) ? window.id : nil
        }
    }

    static func failedSelection(requestedIDs: [String],
                                queuedIDs: Set<String>) -> Set<String> {
        Set(requestedIDs).subtracting(queuedIDs)
    }

    static func canOpen(windows: [WindowState], isConnected: Bool) -> Bool {
        isConnected && !eligibleWindows(windows).isEmpty
    }

    static func canSend(text: String,
                        windows: [WindowState],
                        selectedIDs: Set<String>,
                        isConnected: Bool) -> Bool {
        isConnected
            && !normalizedText(text).isEmpty
            && !targetIDs(windows: windows, selectedIDs: selectedIDs).isEmpty
    }
}
