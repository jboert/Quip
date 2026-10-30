import SwiftUI
import AVFoundation

/// Notifications detail page — push toggles + Quiet Hours window. Pushed
/// behind a NavigationLink in `SettingsSheet` so the main settings list
/// stays short. Reads the same @AppStorage keys (single source of truth in
/// UserDefaults), so changes here flow back to the parent automatically.
struct NotificationsSettingsSheet: View {
    var client: WebSocketClient
    var pushRegistration: PushRegistrationService
    /// The Mac's latest snapshot, for the "pushes are off on the Mac" banner.
    var macPermissions: MacPermissionsMessage? = nil
    @AppStorage("pushPaused") private var pushPaused = false
    @AppStorage("pushBannerEnabled") private var pushBannerEnabled = true
    @AppStorage("pushSound") private var pushSound = true
    @AppStorage("pushForegroundBanner") private var pushForegroundBanner = false
    @AppStorage("pushQuietHoursEnabled") private var quietHoursEnabled = false
    @AppStorage("pushQuietHoursStart") private var quietHoursStart = 22
    @AppStorage("pushQuietHoursEnd") private var quietHoursEnd = 7
    /// (wishlist §15.) Default false → only the currently-selected
    /// window's `waiting_for_input` events push. True → every enabled
    /// window's transitions push. Synced to Mac via PushPreferencesMessage.
    @AppStorage("pushNotifyAllWindows") private var pushNotifyAllWindows = false
    /// Q-56 — the push body is the prompt's question instead of the window's
    /// name. Off by default: prompts can quote your own files.
    @AppStorage("pushShowPromptText") private var pushShowPromptText = true
    @AppStorage("liveActivitiesEnabled") private var liveActivitiesEnabled = true
    /// Q-88 US-009.
    @AppStorage(SmartLanding.enabledKey) private var smartLandingOn = true
    /// Lock-screen answers still waiting for a socket (Q-57).
    private var answerQueue: PushAnswerQueue { .shared }

    var body: some View {
        List {
            if let problem = macPermissions?.pushProblem {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Pushes are off").font(.subheadline)
                            Text("\(problem). Open Quip on the Mac → Settings → Notifications; the Mac shows what to enter.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "bell.slash.fill").foregroundStyle(.red)
                    }
                }
            }
            // MARK: Master pause + status (always visible, even when paused)
            Section {
                Toggle("Pause All", isOn: $pushPaused)
            } header: {
                Text("Push Notifications")
            } footer: {
                statusFooter
            }

            // MARK: Banner / sound / scope (only when not paused)
            if !pushPaused {
                Section {
                    Toggle("Banner", isOn: $pushBannerEnabled)
                    if pushBannerEnabled {
                        Toggle("Sound", isOn: $pushSound)
                        Toggle("Banner When App Open", isOn: $pushForegroundBanner)
                        // (wishlist §15.) Default off → only the
                        // currently-selected window's transitions push.
                        // On → every enabled window pushes (still
                        // batched into one alert via collapseId on Mac).
                        Toggle("All Windows", isOn: $pushNotifyAllWindows)
                        Toggle("Show Prompt Text", isOn: $pushShowPromptText)
                    }
                } header: {
                    Text("Banner")
                } footer: {
                    if pushBannerEnabled {
                        Text((pushNotifyAllWindows
                              ? "Pushes for any window's waiting prompt. "
                              : "Pushes only for the window you have selected. ")
                             + "A window alerts once per prompt, after it has waited 10 seconds; windows that start waiting together share one alert."
                             + (pushShowPromptText
                                ? " The alert shows the question the prompt asks and names each answer; hold it to answer."
                                : " Prompt text is off: the alert says only who is waiting."))
                    } else {
                        Text("Banner is off. Live Activities below will still update on the lock screen.")
                    }
                }

                // MARK: Answering from the alert (§15 v2 path A, Q-57)
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Long-press an alert").font(.subheadline.weight(.medium))
                            Text("Yes / No or 1–4 answer the prompt; the alert lists what each number means. Reply types an answer after Face ID. Alerts can quote option text from the terminal.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "hand.tap")
                            .foregroundStyle(.tint)
                    }
                    if !answerQueue.pending.isEmpty {
                        HStack {
                            Label {
                                Text("^[\(answerQueue.pending.count) answer](inflect: true) waiting for your Mac")
                                    .font(.subheadline)
                            } icon: {
                                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.orange)
                            }
                            Spacer()
                            Button("Discard") { answerQueue.discardAll() }
                                .buttonStyle(.borderless)
                                .font(.subheadline)
                        }
                    }
                } header: {
                    Text("Answer From the Alert")
                } footer: {
                    Text("An answer given while the app was closed is sent as soon as the Mac is reachable, for up to 10 minutes.")
                }

                // MARK: Q-88 US-009 — what the app opens on after time away
                Section {
                    Toggle("Jump to waiting windows", isOn: $smartLandingOn)
                } footer: {
                    Text("Back after two minutes or more: open on a window that is asking you something, with a Back button. Never when you tapped a notification or follow the Mac.")
                }

                // MARK: Live Activities — own section since it bypasses APNs
                Section {
                    Toggle("Live Activities", isOn: $liveActivitiesEnabled)
                } header: {
                    Text("Dynamic Island")
                } footer: {
                    Text("Driven directly by the Mac over WebSocket — works even when banners are off or paused.")
                }

                // MARK: Quiet Hours — own section, two rows max
                Section {
                    Toggle("Enable", isOn: $quietHoursEnabled)
                    if quietHoursEnabled {
                        HStack {
                            Text("From")
                            Spacer()
                            hourMenu(value: $quietHoursStart)
                            Text("to")
                                .foregroundStyle(.secondary)
                            hourMenu(value: $quietHoursEnd)
                        }
                    }
                } header: {
                    Text("Quiet Hours")
                } footer: {
                    if quietHoursEnabled {
                        Text("Banners suppressed during this window. Live Activities still update.")
                    }
                }

                // MARK: Test fire — sends a fake waiting_for_input from the
                // phone over WebSocket so the Mac fires a real APNs push back.
                // Round-trips the entire stack including action category.
                Section {
                    Button {
                        fireTestNotification()
                    } label: {
                        Label("Send Test Notification", systemImage: "paperplane")
                    }
                    .disabled(pushRegistration.deviceToken == nil)
                } footer: {
                    Text("Triggers a real push from the Mac so you can verify banner + action buttons render.")
                }
            }
        }
        .onChange(of: pushPaused) { _, _ in sendPrefs() }
        .onChange(of: pushBannerEnabled) { _, _ in sendPrefs() }
        .onChange(of: pushSound) { _, _ in sendPrefs() }
        .onChange(of: pushForegroundBanner) { _, _ in sendPrefs() }
        .onChange(of: pushNotifyAllWindows) { _, _ in sendPrefs() }
        .onChange(of: pushShowPromptText) { _, _ in sendPrefs() }
        .onChange(of: quietHoursEnabled) { _, _ in sendPrefs() }
        .onChange(of: quietHoursStart) { _, _ in sendPrefs() }
        .onChange(of: quietHoursEnd) { _, _ in sendPrefs() }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Status footer for the master section — green check or red caution
    /// based on registration state. Single source of truth for "are
    /// notifications actually wired up at all" so the user doesn't hunt
    /// across iOS Settings + Quip toggles trying to figure out why
    /// they're not getting alerts.
    @ViewBuilder
    private var statusFooter: some View {
        if let token = pushRegistration.deviceToken {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Registered · device …\(token.suffix(4))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Permission not granted. Open iOS Settings → Quip → Notifications.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Send a test push request to the Mac so it round-trips a real APNs
    /// alert back. Uses the existing `quick_action` channel with a
    /// recognizable sentinel value the Mac handler routes to
    /// `notifyWaitingForInput`. (Path keeps protocol churn minimal — see
    /// QuipMacApp's `test_push` quick_action handler.)
    private func fireTestNotification() {
        client.send(QuickActionMessage(windowId: "", action: "test_push"))
    }

    /// Compact 24-hour Menu picker. Renders the selected hour as a small pill
    /// (e.g. "10 PM") which expands to a 24-row scrollable menu on tap. Way
    /// tighter than a Stepper — fits two side-by-side on one row.
    @ViewBuilder
    private func hourMenu(value: Binding<Int>) -> some View {
        Menu(formatHour(value.wrappedValue)) {
            ForEach(0..<24, id: \.self) { h in
                Button(formatHour(h)) { value.wrappedValue = h }
            }
        }
    }

    private func formatHour(_ h: Int) -> String {
        let hh = h % 24
        let suffix = hh < 12 ? "AM" : "PM"
        let display = hh == 0 ? 12 : (hh > 12 ? hh - 12 : hh)
        return "\(display) \(suffix)"
    }

    private func sendPrefs() {
        guard let token = pushRegistration.deviceToken else { return }
        let msg = PushPreferencesMessage(
            deviceToken: token,
            paused: pushPaused,
            quietHoursStart: quietHoursEnabled ? quietHoursStart : nil,
            quietHoursEnd: quietHoursEnabled ? quietHoursEnd : nil,
            sound: pushSound,
            foregroundBanner: pushForegroundBanner,
            bannerEnabled: pushBannerEnabled,
            timeZone: TimeZone.current.identifier
        )
        client.send(msg)
    }
}
