// NotificationsTab.swift
// QuipMac — Settings window pane (split out of SettingsView.swift)

import SwiftUI
import Darwin
import AppKit

// MARK: - Notifications Tab

/// Collects the APNs auth-key configuration (.p8 file, Key ID, Team ID,
/// Bundle ID) + a Test Push button. The .p8 goes into the Keychain via
/// APNsKeyStore; the three ID fields sit in the Keychain via
/// APNsMetadataStore. No pushes fire from here — the only send is Test
/// Push, which loops registered devices and reports per-device
/// success/failure inline.
struct NotificationsTab: View {
    @Environment(PushNotificationService.self) private var pushService

    // GH #22 — moved from @AppStorage("apnsKeyId" / "apnsTeamId" / "apnsBundleId")
    // to APNsMetadataStore (Keychain). View holds @State copies for SwiftUI's
    // two-way TextField binding; each is seeded once from the store in .task
    // (the first read performs the one-shot migration from UserDefaults if
    // needed), and .onChange writes back. A @State initial value is evaluated
    // on every init of this struct, so seeding there hit the Keychain each
    // time the parent re-rendered. importKey() also writes the store directly
    // when it auto-syncs the Key ID. The bundleId default flows through the
    // store (com.quip.QuipiOS).
    @State private var keyId: String = ""
    @State private var teamId: String = ""
    @State private var bundleId: String = ""
    /// What the store holds for each field, as last seeded or written. The
    /// getters resolve defaults (signing team, the key's own kid, the default
    /// bundle), so .onChange must not write a seeded value back — that would
    /// pin a default into the Keychain the user never typed.
    @State private var stored = (keyId: "", teamId: "", bundleId: "")
    @State private var seeded = false

    @State private var hasKey: Bool = false
    @State private var importStatus: String?
    @State private var testStatus: [String] = []
    @State private var isSending: Bool = false
    @State private var showForgetAllConfirm: Bool = false

    /// All four pieces APNs needs before any push (test or production) can
    /// fire: the .p8 key in the Keychain plus non-empty Key ID, Team ID, and
    /// Bundle ID. Mirrors the Send Test Push button's enable condition.
    private var isConfigured: Bool {
        hasKey && !keyId.isEmpty && !teamId.isEmpty && !bundleId.isEmpty
    }

    private var readinessSubline: AttributedString {
        if isConfigured {
            let n = pushService.devices.count
            return n == 0
                ? AttributedString("Ready · no iPhones registered yet")
                : AttributedString(localized: "Ready · ^[\(n) device](inflect: true) registered")
        }
        let missing = PushNotificationService.missingAPNsSetup(hasKey: hasKey, keyId: keyId,
                                                               teamId: teamId, bundleId: bundleId)
        return AttributedString("Missing " + missing.joined(separator: ", "))
    }

    /// Focal point of the Notifications pane — the one thing it answers: will
    /// a push actually fire? A status glyph + headline + a subline that names
    /// what's still missing. Consistent with the Connection pane's
    /// connectionHero (tinted circle glyph + title3 headline + callout subline).
    @ViewBuilder
    private var notificationsHero: some View {
        let configured = isConfigured
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill((configured ? Color.green : Color.red).opacity(0.15))
                    .frame(width: 46, height: 46)
                Image(systemName: configured ? "bell.badge.fill" : "bell.slash.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(configured ? .green : .red)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(configured ? "Push configured" : "Push not configured")
                    .font(.title3.weight(.semibold))
                Text(readinessSubline)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    var body: some View {
        Form {
            Section {
                notificationsHero
            }

            Section("APNs Auth Key") {
                LabeledContent("Auth key") {
                    HStack(spacing: 8) {
                        StatusDot(kind: hasKey ? .ok : .bad,
                                  text: hasKey ? "Stored in Keychain" : "Not set")
                        Spacer()
                        Button(hasKey ? "Replace .p8…" : "Import .p8…") { importKey() }
                        if hasKey {
                            Button("Clear") { clearKey() }
                        }
                    }
                }
                if let importStatus {
                    Text(importStatus)
                        .font(.caption)
                        .foregroundStyle(importStatus.hasPrefix("Error") ? .red : .secondary)
                }
                TextField("Key ID", text: $keyId)
                    .onChange(of: keyId) { _, new in
                        guard new != stored.keyId else { return }
                        APNsMetadataStore.keyId = new
                        stored.keyId = new
                    }
                TextField("Team ID", text: $teamId)
                    .onChange(of: teamId) { _, new in
                        guard new != stored.teamId else { return }
                        APNsMetadataStore.teamId = new
                        stored.teamId = new
                    }
                TextField("Bundle ID", text: $bundleId)
                    .onChange(of: bundleId) { _, new in
                        guard new != stored.bundleId else { return }
                        APNsMetadataStore.bundleId = new
                        stored.bundleId = new
                    }
            }

            Section("Registered Devices (\(pushService.devices.count))") {
                if pushService.devices.isEmpty {
                    Text("No iPhones have registered yet. Open Quip on the phone and connect.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(pushService.devices, id: \.token) { device in
                        HStack(spacing: 8) {
                            Image(systemName: "iphone")
                                .foregroundStyle(.secondary)
                            Text(device.token.prefix(12) + "…")
                                .font(.system(.caption, design: .monospaced))
                            Spacer()
                            Text(device.environment)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button(role: .destructive) {
                        showForgetAllConfirm = true
                    } label: {
                        Label("Forget All Devices", systemImage: "trash")
                    }
                    .confirmationDialog(
                        "Forget all \(pushService.devices.count) registered devices?",
                        isPresented: $showForgetAllConfirm,
                        titleVisibility: .visible
                    ) {
                        Button("Forget All", role: .destructive) {
                            pushService.removeAllDevices()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Clears stale tokens left by app reinstalls. Each phone re-registers a fresh token the next time it connects.")
                    }
                }
            }

            Section("Send Test Push") {
                HStack {
                    Button {
                        Task { await sendTestPush() }
                    } label: {
                        Label("Send Test Push", systemImage: "paperplane")
                    }
                    .disabled(isSending || !hasKey || keyId.isEmpty || teamId.isEmpty || bundleId.isEmpty || pushService.devices.isEmpty)
                    if isSending { ProgressView().scaleEffect(0.7) }
                }
                ForEach(testStatus, id: \.self) { line in
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(line.hasPrefix("✓") ? Color.secondary : Color.red)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            guard !seeded else { return }
            seeded = true
            stored = (APNsMetadataStore.keyId, APNsMetadataStore.teamId, APNsMetadataStore.bundleId)
            keyId = stored.keyId
            teamId = stored.teamId
            bundleId = stored.bundleId
            hasKey = APNsKeyStore.hasKey
        }
    }

    private func importKey() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Import"
        panel.message = "Select your APNs .p8 auth key"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = try Data(contentsOf: url)
                // The kid rides on the key item so a lost metadata item cannot
                // lose it: Apple's filename, else the Key ID already entered.
                let fileKeyId = APNsMetadataStore.keyId(fromFilename: url.lastPathComponent)
                if APNsKeyStore.set(data, keyId: fileKeyId ?? keyId) {
                    hasKey = true
                    var status = "Imported \(url.lastPathComponent)"
                    // The Key ID can't be derived from the key bytes, so a
                    // mismatched kid silently passes import and only fails at
                    // send time with `InvalidProviderToken`. Apple's filename
                    // (`AuthKey_<KEYID>.p8`) carries the kid — sync it to the
                    // stored key so the two can't drift apart.
                    if let fileKeyId {
                        if fileKeyId != keyId {
                            let old = keyId
                            // Write the store directly, not just @State: production
                            // push paths (PushNotificationService) read
                            // APNsMetadataStore.keyId from Keychain, so persistence
                            // must not hinge on the Key ID TextField's deferred
                            // .onChange firing on a later SwiftUI render.
                            APNsMetadataStore.keyId = fileKeyId
                            stored.keyId = fileKeyId
                            keyId = fileKeyId
                            status += old.isEmpty
                                ? " · Key ID set to \(fileKeyId)"
                                : " · Key ID \(old)→\(fileKeyId) to match the file"
                        }
                    } else if !keyId.isEmpty {
                        // Filename carries no Key ID (renamed/duplicated file,
                        // e.g. "AuthKey_… 2.p8" or "prod-key.p8") and a kid is
                        // already set — it may now name the WRONG key. The kid
                        // isn't recoverable from the key bytes, so warn instead
                        // of letting the stale kid reach APNs as a silent
                        // InvalidProviderToken at send time.
                        status += " · ⚠︎ couldn't read Key ID from filename — verify Key ID “\(keyId)” matches this key"
                    }
                    importStatus = status
                    // New key → cached APNsClient's parsed private key
                    // is stale. Drop it so the next send re-reads.
                    pushService.invalidateClient()
                } else {
                    importStatus = "Error: could not save to Keychain"
                }
            } catch {
                importStatus = "Error: \(error.localizedDescription)"
            }
        }
    }

    private func clearKey() {
        if APNsKeyStore.clear() {
            hasKey = false
            importStatus = "Key cleared"
        }
    }

    private func sendTestPush() async {
        testStatus = []
        isSending = true
        defer { isSending = false }

        let hostName = Host.current().localizedName ?? "Mac"
        let payload: [String: Any] = [
            "aps": [
                "alert": ["title": "Quip", "body": "Test push from \(hostName)"],
                "sound": "default"
            ],
            "quip_event": "test_push"
        ]
        let devicesSnapshot = pushService.devices
        let client: APNsClient
        do {
            client = try pushService.cachedClient(keyId: keyId, teamId: teamId, bundleId: bundleId)
        } catch {
            testStatus.append("Error creating client: \(error)")
            return
        }
        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            testStatus.append("Error: could not encode payload")
            return
        }
        for device in devicesSnapshot {
            do {
                try await client.send(payloadData: body, toDevice: device)
                testStatus.append("✓ \(device.token.prefix(8))… sent")
            } catch APNsError.unregistered {
                testStatus.append("⚠ \(device.token.prefix(8))… dropped (unregistered)")
                pushService.removeDevice(token: device.token)
            } catch {
                testStatus.append("✗ \(device.token.prefix(8))… \(error)")
            }
        }
    }
}
