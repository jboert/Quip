import Foundation

/// One QA-mode pair: a `target` window (Simulator now, browser-on-localhost
/// later) and a `terminal` window. IDs are opaque `WindowState.id` strings
/// the Mac assigns. Stored per-backend in `@AppStorage` so reconnects /
/// app relaunches restore the pair when both windows still exist.
struct QAPair: Codable, Equatable, Sendable {
    let targetId: String
    let terminalId: String
}
