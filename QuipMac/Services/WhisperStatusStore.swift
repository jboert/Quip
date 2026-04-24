import Foundation

/// Shared observable holder for the Mac-side Whisper recognizer state.
/// QuipMacApp mutates it during model load + on failure, SettingsView reads
/// it for the diagnostics row. Lives in its own @Observable so SwiftUI can
/// diff it cheaply via the environment without lifting SettingsView's
/// initializer surface to accept a binding.
@Observable
@MainActor
final class WhisperStatusStore {
    var state: WhisperState = .preparing
}
