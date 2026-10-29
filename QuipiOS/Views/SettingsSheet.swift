import SwiftUI
import AVFoundation

struct SettingsSheet: View {
    @Binding var enabledQuickButtonsRaw: String
    var client: WebSocketClient
    var pushRegistration: PushRegistrationService
    var macPermissions: MacPermissionsMessage?
    /// Resolver for the host's currently-selected window. Closure (not a
    /// stored value) so the Prompts sheet always fires into the *current*
    /// window even when the user changes selection after Settings opens.
    /// (§B4 wrong-window paste bug — by-value capture froze whatever id
    /// was active at sheet open.)
    var windowIdProvider: () -> String? = { nil }
    /// The selected window's agent as a prompt-ranking context, resolved
    /// late for the same reason as `windowIdProvider`. Seeds the generator.
    var promptContextProvider: () -> String? = { nil }
    /// The selected window's folder, resolved late (Q-69).
    var projectProvider: () -> String? = { nil }
    /// The current windows, for Send to… in the Prompts hub (US-209).
    var windowsProvider: () -> [WindowState] = { [] }
    @AppStorage("tintContentBorder") private var tintContentBorder = true
    /// Same key the PTT path reads in QuipApp; @AppStorage keeps the two in
    /// step without threading a binding through the settings hierarchy.
    @AppStorage("dictation.autoSend") private var settingsDictationAutoSend = false
    @AppStorage("urlTrayEnabled") private var urlTrayEnabled = true
    @AppStorage("urlTrayLimit") private var urlTrayLimit = 10
    @AppStorage("contentRenderMode") private var contentRenderModeRaw: String = ContentRenderMode.auto.rawValue
    /// Manual override for system color scheme. Bound to the Settings →
    /// Appearance picker; QuipApp's root view reads the same key and
    /// applies `.preferredColorScheme(...)` accordingly.
    @AppStorage("appearance.mode") private var appearanceModeRaw: String = "auto"
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
    @AppStorage("pushShowPromptText") private var pushShowPromptText = true
    // Device-local only — Live Activities don't flow through the Mac's
    // APNs prefs, so no sendPrefs() wiring. The main app reads this
    // @AppStorage key too and gates its liveActivity.startOrUpdate calls.
    @AppStorage("liveActivitiesEnabled") private var liveActivitiesEnabled = true
    @Environment(\.dismiss) private var dismiss
    /// Briefly flips to true after the user taps the Version row — drives
    /// the inline "Copied" confirmation; auto-resets after 1.5s so the row
    /// reverts to the version string.
    @State private var versionCopied = false
    /// Same flip for the Mac build row (Q-86).
    @State private var macBuildCopied = false

    /// "1.5.7 (a8f2308, 2026-10-08 08:30)": the version with the commit and
    /// build time stamped by tools/stamp-build-info.sh, so an install can be
    /// told from the last one. Read once per launch.
    static let appVersionDisplay: String = BuildInfo.display(BuildInfo.current)

    var body: some View {
        NavigationStack {
            List {
                // Mac Status — compact in the common all-granted case (single
                // green row), expands to the three-row detail only when
                // something's wrong or we're still waiting for the Mac to
                // report in. Saves two rows and a paragraph of footer copy
                // for the 99% of sessions where everything's fine.
                macPermsSection

                // Q-87: hidden until the Mac says it supports the switch.
                if client.claudePreviewsState != nil {
                    claudePreviewsSection
                }

                // Appearance — common visual preferences stay inline so the
                // user can tune the main screen without drilling through
                // another detail page.
                Section {
                    Picker("Theme", selection: $appearanceModeRaw) {
                        Text("Auto").tag("auto")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .pickerStyle(.segmented)
                    Toggle("Tint content panel border", isOn: $tintContentBorder)
                    HStack {
                        Toggle("URL tray", isOn: $urlTrayEnabled)
                        if urlTrayEnabled {
                            Stepper("\(urlTrayLimit)",
                                    value: $urlTrayLimit, in: 1...50)
                                .fixedSize()
                                .foregroundStyle(.secondary)
                        }
                    }
                    Picker("Content mode", selection: $contentRenderModeRaw) {
                        ForEach(ContentRenderMode.allCases) { mode in
                            Text(mode.label).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("Auto content mode uses images when available and falls back to text.")
                }

                // Prompts — Mac-managed library of paste-and-run prompts,
                // including the local prompt generator entry point.
                // Input — the prompt library plus the customizable button
                // rows, all "what you send and how" under one header (folded
                // the former standalone Prompts section in here).
                Section {
                    NavigationLink {
                        PromptLibrarySheet(client: client, windowIdProvider: windowIdProvider,
                                           promptContextProvider: promptContextProvider,
                                           projectProvider: projectProvider,
                                           windowsProvider: windowsProvider)
                    } label: {
                        settingsLinkRow(
                            title: "Prompts",
                            subtitle: "Library, generator, paste-and-submit",
                            systemImage: "wand.and.stars",
                            tint: .purple,
                            trailing: "\(client.promptLibrary.count) on Mac"
                        )
                    }
                    NavigationLink {
                        QuickButtonsSheet(enabledQuickButtonsRaw: $enabledQuickButtonsRaw, client: client)
                    } label: {
                        settingsLinkRow(
                            title: "Quick Buttons",
                            subtitle: "Customize the command row",
                            systemImage: "keyboard",
                            tint: .blue,
                            trailing: quickButtonsSummary
                        )
                    }
                    NavigationLink {
                        MainRowButtonsSheet()
                    } label: {
                        settingsLinkRow(
                            title: "Main Row Buttons",
                            subtitle: "Choose the large bottom controls",
                            systemImage: "rectangle.bottomthird.inset.filled",
                            tint: .teal
                        )
                    }
                    Toggle("Auto-send dictation", isOn: $settingsDictationAutoSend)
                } header: {
                    Text("Input")
                } footer: {
                    Text("Presses Return as soon as you stop speaking. Off leaves the transcript in the prompt so you can read it back first.")
                }

                Section {
                    NavigationLink {
                        NotificationsSettingsSheet(client: client, pushRegistration: pushRegistration,
                                                   macPermissions: macPermissions)
                    } label: {
                        settingsLinkRow(
                            title: "Notifications",
                            subtitle: notificationsDetail,
                            systemImage: "bell.badge",
                            tint: .orange,
                            trailing: notificationsSummary
                        )
                    }
                } header: {
                    Text("Notifications")
                }

                // Quip Labs — opt-in beta features, all off by default. (§0)
                LabsSection()

                // Diagnostics — pinned at the bottom of Settings since it's
                // a triage tool, not part of the day-to-day. Surfaces the
                // in-memory connection event ring buffer + auto-fetched
                // Mac log tail (since commit d8f1503).
                Section {
                    NavigationLink {
                        ConnectionDiagnosticsSheet(client: client)
                    } label: {
                        settingsLinkRow(
                            title: "Connection",
                            subtitle: "Recent reconnect and Mac log events",
                            systemImage: "network",
                            tint: .indigo,
                            trailing: "\(client.recentConnectionEvents.count) events"
                        )
                    }
                    NavigationLink {
                        LatencyDiagnosticsSheet(client: client)
                    } label: {
                        settingsLinkRow(
                            title: "Latency",
                            subtitle: "Round-trip timing by send path",
                            systemImage: "speedometer",
                            tint: .gray
                        ) {
                            LatencySummary.from(samples: client.latencySamples)
                                .badgeView()
                        }
                    }
                    // Version row, folded in from the old standalone About
                    // section to save a row — it's reference info, same as
                    // the rest of Diagnostics.
                    Button {
                        UIPasteboard.general.string = "Quip iOS \(Self.appVersionDisplay)"
                        versionCopied = true
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            await MainActor.run { versionCopied = false }
                        }
                    } label: {
                        settingsLinkRow(
                            title: "Version",
                            systemImage: "info.circle",
                            tint: .gray
                        ) {
                            if versionCopied {
                                Text("Copied")
                                    .foregroundStyle(.secondary)
                                    .transition(.opacity)
                            } else {
                                Text(Self.appVersionDisplay)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Tap to copy version to clipboard")
                } header: {
                    Text("Diagnostics")
                }
            }
            .listStyle(.insetGrouped)
            .environment(\.defaultMinListRowHeight, 0)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// Mac Permissions top section. Three states, rendered at very different
    /// densities so the common case (everything green) doesn't eat rows:
    ///   - Waiting for Mac to report → placeholder row + footer
    ///   - All three granted → single "Mac permissions OK" row, no footer
    ///   - Any missing → full expanded detail + footer prompting user to tap
    /// The "tap a red row to open System Settings" pattern depends on the
    /// detail rows being visible, which is why we only expand when needed.
    @ViewBuilder
    /// Q-87: the phone's copy of the Mac's "Show Claude's previews on phone"
    /// switch. The Mac does the work (adds/removes its Claude Code hook) and
    /// answers with the new state, which is what this row shows.
    private var claudePreviewsSection: some View {
        let state = client.claudePreviewsState ?? "off"
        return Section {
            Toggle(isOn: Binding(
                get: { state == "on" || state == "stale" },
                set: { client.send(SetClaudePreviewsMessage(enabled: $0)) }
            )) {
                HStack(spacing: 10) {
                    settingsIcon("photo.on.rectangle", tint: .purple)
                    Text("Show Claude's previews")
                }
            }
            .disabled(state == "remote" || state == "unreadable")
        } header: {
            Text("Claude Previews")
        } footer: {
            switch state {
            case "remote":
                Text("Available when connected over your home network or Tailscale.")
            case "unreadable":
                Text("Claude's settings file on the Mac isn't valid JSON, so Quip won't change it.")
            case "stale":
                Text("Claude is set up to use an older copy of Quip. Turn this off and on to repair it.")
            default:
                Text("When Claude opens an image or PDF on the Mac, it shows on that terminal here. Only files Claude opens are sent — never Preview windows you open yourself.")
            }
        }
    }

    private var macPermsSection: some View {
        Section {
            if let perms = macPermissions {
                let allGranted = perms.accessibility && perms.appleEvents && perms.screenRecording
                if allGranted {
                    HStack(spacing: 10) {
                        settingsIcon("checkmark", tint: .green)
                        Text("Mac permissions")
                        Spacer()
                        Text("Granted")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    macPermRow(name: "Accessibility",
                               icon: "accessibility",
                               granted: perms.accessibility,
                               pane: .accessibility)
                    macPermRow(name: "Automation (iTerm)",
                               icon: "terminal",
                               granted: perms.appleEvents,
                               pane: .automation)
                    macPermRow(name: "Screen Recording",
                               icon: "rectangle.dashed",
                               granted: perms.screenRecording,
                               pane: .screenRecording)
                }
                // Push set-up lives on the Mac; without this row the phone
                // only ever showed "notifications: On" while every push was
                // skipped on the Mac for a missing Key ID (2026-10-08).
                if let problem = perms.pushProblem {
                    HStack(spacing: 10) {
                        settingsIcon("bell.slash", tint: .red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Push on Mac")
                            Text("\(problem). Quip on the Mac → Settings → Notifications.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            } else {
                HStack(spacing: 10) {
                    settingsIcon("hourglass", tint: .gray)
                    Text("Waiting for Mac…")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            // Q-86: which Mac build this phone talks to, rendered by the same
            // BuildInfo.shortDisplay as the Version row below. Absent from a
            // Mac that predates mac_build.
            if let macBuild = client.macBuild {
                let display = BuildInfo.shortDisplay(macBuild.stamp)
                Button {
                    UIPasteboard.general.string = "Quip Mac \(display)"
                    macBuildCopied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        await MainActor.run { macBuildCopied = false }
                    }
                } label: {
                    settingsLinkRow(title: "Mac build", systemImage: "desktopcomputer", tint: .gray) {
                        if macBuildCopied {
                            Text("Copied")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .transition(.opacity)
                        } else {
                            Text(display)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    // A plain button hit-tests only its content; without
                    // this the gap between label and value is dead.
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Mac Permissions")
        } footer: {
            if let perms = macPermissions,
               !(perms.accessibility && perms.appleEvents && perms.screenRecording) {
                Text("Tap a red row — Mac will pop the right System Settings pane open.")
            } else if macPermissions == nil {
                Text("If this never updates, the Mac may be on an older build that doesn't broadcast permission status.")
            }
        }
    }

    /// Single Mac-permission row. Green check when granted; red cross when not,
    /// and tapping a denied row asks the Mac to open the matching System Settings
    /// pane via `OpenMacSettingsPaneMessage`. Granted rows aren't tappable —
    /// nothing useful happens there and we don't want to bounce the Mac into
    /// Settings on accidental taps.
    @ViewBuilder
    private func macPermRow(name: String, icon: String, granted: Bool, pane: MacSettingsPane) -> some View {
        let row = HStack(spacing: 10) {
            // Status-tinted chip matches the icon-chip system used by every
            // other row, and the green/red fill reads the grant state at a
            // glance — the section's whole job.
            settingsIcon(icon, tint: granted ? .green : .red)
            Text(name)
            Spacer()
            if granted {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.green)
            } else {
                Text("Fix")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.red)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        if granted {
            row
        } else {
            Button { client.send(OpenMacSettingsPaneMessage(pane: pane)) } label: { row }
                .buttonStyle(.plain)
        }
    }

    private func settingsLinkRow(title: String,
                                 subtitle: String? = nil,
                                 systemImage: String,
                                 tint: Color,
                                 trailing: String? = nil) -> some View {
        HStack(spacing: 10) {
            settingsIcon(systemImage, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if let trailing {
                Text(trailing)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .monospacedDigit()
            }
        }
    }

    /// Trailing-view overload of `settingsLinkRow`. Same icon-chip chrome as the
    /// `String?` variant above, but the row can supply an arbitrary trailing view
    /// (a tinted badge, a swappable "Copied" label) instead of plain secondary
    /// text. Swift picks this overload when the call uses a trailing closure and
    /// the String? one when `trailing:` is a String, so existing callers are
    /// untouched.
    private func settingsLinkRow<Trailing: View>(title: String,
                                                 subtitle: String? = nil,
                                                 systemImage: String,
                                                 tint: Color,
                                                 @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            settingsIcon(systemImage, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            trailing()
        }
    }

    private func settingsIcon(_ systemImage: String, tint: Color) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 28, height: 28)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    /// Send the current settings state to the Mac so it can honor them
    /// at push-send time. Fires on every toggle change and from onAppear.
    /// No-op when we don't yet have a device token (nothing to key on
    /// from the Mac's perspective).
    fileprivate func sendPrefs() {
        guard let token = pushRegistration.deviceToken else { return }
        let msg = PushPreferencesMessage(
            deviceToken: token,
            paused: pushPaused,
            quietHoursStart: quietHoursEnabled ? quietHoursStart : nil,
            quietHoursEnd: quietHoursEnabled ? quietHoursEnd : nil,
            sound: pushSound,
            foregroundBanner: pushForegroundBanner,
            bannerEnabled: pushBannerEnabled,
            timeZone: TimeZone.current.identifier,
            notifyAllWindows: pushNotifyAllWindows,
            showPromptText: pushShowPromptText
        )
        client.send(msg)
    }

    /// 13 → "1 PM", 0 → "12 AM", 22 → "10 PM". Plain string for Steppers.
    fileprivate func formatHour(_ h: Int) -> String {
        let hh = h % 24
        let suffix = hh < 12 ? "AM" : "PM"
        let display = hh == 0 ? 12 : (hh > 12 ? hh - 12 : hh)
        return "\(display) \(suffix)"
    }

    /// One-line state summary shown next to the Notifications NavigationLink
    /// on the main Settings page. Priority: Paused beats everything; then a
    /// quiet-now flag; otherwise just "On" or "Banner off". Kept short so it
    /// doesn't fight the disclosure chevron for row space.
    fileprivate var notificationsSummary: String {
        if macPermissions?.pushConfigured == false { return "Mac not set up" }
        if pushPaused { return "Paused" }
        if !pushBannerEnabled { return "Banner off" }
        if quietHoursEnabled {
            return "Quiet \(formatHour(quietHoursStart))–\(formatHour(quietHoursEnd))"
        }
        return "On"
    }

    fileprivate var notificationsDetail: String {
        if let problem = macPermissions?.pushProblem { return problem }
        if pushPaused { return "Push alerts are paused" }
        if quietHoursEnabled {
            return "Quiet hours \(formatHour(quietHoursStart))-\(formatHour(quietHoursEnd))"
        }
        if pushForegroundBanner {
            return "Foreground banners enabled"
        }
        return pushSound ? "Sound and banners enabled" : "Silent banners enabled"
    }

    /// Compact summary shown next to the Quick Buttons NavigationLink. Slot
    /// count covers built-ins + customs + spacers, which is the size of the
    /// rendered row — what the user actually cares about.
    fileprivate var quickButtonsSummary: String {
        let slots = QuickSlotStore.decode(
            UserDefaults.standard.string(forKey: "quickSlotsJSON") ?? ""
        )
        let count = slots.count
        return "\(count) item\(count == 1 ? "" : "s")"
    }

}
