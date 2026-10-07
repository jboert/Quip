import AppKit

/// Runs the app's start-up work once the app has finished launching AND the
/// app has handed over that work, in whichever order the two happen.
///
/// Services used to start from a window's `onAppear`. A relaunch that restores
/// no windows (the user had closed the main window and kept Quip in the menu
/// bar) never fired it: nothing listened on 8765 and Whisper never loaded until
/// a second `open` created a window. The app delegate's launch callback fires
/// with or without a window, so it is the trigger now; the `onAppear` calls
/// stay as a fallback, and the start-up work guards against running twice.
@MainActor
final class LaunchHook {
    private var action: (() -> Void)?
    private var launched = false

    /// Hand over the start-up work. Runs it at once if launch already finished.
    func register(_ action: @escaping () -> Void) {
        self.action = action
        if launched { action() }
    }

    /// Called from `applicationDidFinishLaunching`.
    func finishLaunching() {
        launched = true
        action?()
    }
}

/// Owns the launch callback for `QuipMacApp` (see `LaunchHook`).
@MainActor
final class QuipAppDelegate: NSObject, NSApplicationDelegate {
    static let launchHook = LaunchHook()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.launchHook.finishLaunching()
    }
}
