import SwiftUI
import AVFoundation

/// Apple-toolbar-style editor for the quick-button row. Slots render in
/// user-controlled order; the "Add" toolbar menu inserts built-ins,
/// custom buttons, or fixed-width spacers. Drag to reorder; swipe to
/// delete. The legacy CSV `enabledQuickButtons` is kept in sync on every
/// edit so a downgrade-and-restart still reads a sensible row.
struct QuickButtonsSheet: View {
    @Binding var enabledQuickButtonsRaw: String
    /// Optional — when present, the "+" menu can offer Mac-managed
    /// prompts as keyboard slots. Older callers that don't pass a
    /// client still get the legacy menu (no Prompt section). (§B3)
    var client: WebSocketClient?
    @AppStorage("quickSlotsJSON") private var quickSlotsJSON: String = ""
    @AppStorage("customButtonsJSON") private var customButtonsJSON: String = "[]"
    @AppStorage(KeyColors.storageKey) private var quickSlotColorsJSON: String = "{}"
    /// Q-50, US-206: icons and colors from each button's words; off is the
    /// plain row from before.
    @AppStorage(KeyPillSpec.autoStyleKey) private var autoKeyStyle: Bool = true
    /// The row entry whose color sheet is open.
    @State private var coloringSlot: QuickSlot?
    @Environment(\.colorScheme) private var colorScheme
    private var colors: QuipColors { QuipColors(scheme: colorScheme) }

    private var slotColors: [String: String] { KeyColors.decode(quickSlotColorsJSON) }

    @State private var editingCustomID: UUID?
    /// Q-67: a built-in from Row Order open in the edit form, as a custom copy.
    @State private var editingBuiltin: QuickButton?
    @State private var addingCustom: Bool = false
    @State private var showPromptPicker: Bool = false
    /// Drives the sheet-based add picker. Replaces the prior toolbar Menu,
    /// which became unscrollable once the slash list grew past ~6 items
    /// (iOS Menu has a fixed render window and clips long labels mid-word).
    @State private var showAddSheet: Bool = false
    @State private var addSheetQuery: String = ""
    /// Search over Row Order and Custom Buttons (US-103). While it holds a
    /// query, drag-to-reorder is off: moving rows of a filtered list is
    /// ambiguous.
    @State private var editorQuery: String = ""
    // The Add Prompt picker ranks, hides and searches like the Prompts hub
    // (US-104), from the same stores.
    @State private var promptPickerQuery: String = ""
    @State private var showHiddenInPromptPicker: Bool = false
    @State private var promptPickerCache = PromptSearchCache()
    @AppStorage("hiddenPromptIDsJSON") private var hiddenPromptIDsJSON: String = "[]"
    @AppStorage("promptUsageJSON") private var promptUsageJSON: String = "{}"
    @AppStorage("promptUsageMRUJSON") private var promptUsageMRUJSON: String = "{}"
    @AppStorage(LabsFlags.promptPackSharing) private var labsPromptPacks = false
    @State private var shareItem: PackShareItem?
    @State private var exportError: String?

    // Cached snapshots of the @AppStorage-backed JSON. Computed-property
    // versions re-decoded on EVERY body evaluation, and any observable
    // (`client.promptLibrary` broadcasts, other @AppStorage changes) was
    // enough to re-decode the entire slot list mid-scroll. List layout
    // shudders during a re-decode and the scroll position resets to the
    // top — that's the "scrolling to pick custom buttons is buggy and
    // often goes back to the top" symptom. Caching here means decode
    // runs only on .onAppear and on the specific .onChange(of:) hooks
    // below; routine SwiftUI body re-evals are now cheap and don't
    // disturb List scroll state.
    @State private var slots: [QuickSlot] = []
    @State private var customs: [CustomButton] = []
    @State private var customsByID: [UUID: CustomButton] = [:]
    /// Snapshot of the prompt catalog labels at sheet open / on
    /// observable change. slotRow used to read `client.promptLibrary`
    /// directly which made the row re-render every time the Mac
    /// broadcast its catalog (every reconnect / FS change). Local
    /// snapshot breaks that observation chain.
    @State private var promptLabelByID: [String: String] = [:]
    @State private var promptByteSizeByID: [String: Int] = [:]

    private var isFilteringEditor: Bool { !QuipSearch.tokens(editorQuery).isEmpty }

    /// Row Order slots matching the editor search, best match first; every
    /// slot in row order without a query.
    private var visibleSlots: [QuickSlot] {
        guard isFilteringEditor else { return slots }
        let rows = slots.map { QuickButtonSearch.row($0, customs: customsByID, promptLabels: promptLabelByID) }
        return QuickButtonSearch.filter(rows, query: editorQuery).map(\.slot)
    }

    private var visibleCustoms: [CustomButton] {
        QuickButtonSearch.filter(customs, query: editorQuery)
    }

    /// Swipe-to-remove on the possibly filtered Row Order list: the offsets
    /// index `visibleSlots`, so remove by slot id.
    private func deleteVisibleSlots(at offsets: IndexSet) {
        let shown = visibleSlots
        let removed = Set(offsets.map { shown[$0].id })
        persistSlots(slots.filter { !removed.contains($0.id) })
    }

    private func deleteVisibleCustoms(at offsets: IndexSet) {
        let shown = visibleCustoms
        let removedIDs = Set(offsets.map { shown[$0].id })
        deleteCustomDefs(at: IndexSet(customs.indices.filter { removedIDs.contains(customs[$0].id) }))
    }

    /// Set of built-in QuickButton rawValues already placed in the slot
    /// list — used to disable duplicate adds in the "+" menu so the user
    /// can't end up with two `Esc` pills by accident.
    private var placedBuiltins: Set<String> {
        Set(slots.compactMap { slot -> String? in
            if case .builtin(let b) = slot { return b.rawValue }
            return nil
        })
    }

    var body: some View {
        List {
            // Live preview — shows the actual rendered row exactly as it
            // will appear above the keyboard, on the same dark surface.
            // Updates immediately on any reorder / add / delete because
            // it reads the same @AppStorage the keyboard does.
            Section {
                rowPreview
                    .listRowInsets(EdgeInsets(top: 8, leading: 6, bottom: 8, trailing: 6))
                    .listRowBackground(Color.clear)
                Toggle("Automatic button style", isOn: $autoKeyStyle)
            } header: {
                Text("Preview")
            } footer: {
                Text(autoKeyStyle
                     ? "Each button gets an icon and color from its words: green go, red stop, orange build or interrupt, blue plan, teal review or test. Purple is only for prompts. A color you pick always wins."
                     : "Plain buttons, as before. A color you pick still shows.")
            }

            Section {
                if slots.isEmpty {
                    Text("No buttons yet. Tap + → “Custom Button” to make your own, or pick a built-in.")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 13))
                } else if isFilteringEditor && visibleSlots.isEmpty {
                    Text("No buttons in the row match \"\(editorQuery)\".")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 13))
                } else {
                    ForEach(visibleSlots) { slot in
                        HStack(spacing: 8) {
                            // Q-67: tap a button to edit it. Tap gesture, not
                            // Button, so the List keeps scroll and drag (see
                            // the Custom Buttons rows below).
                            slotRow(slot)
                                .contentShape(Rectangle())
                                .onTapGesture { editRowSlot(slot) }
                            slotColorButton(slot)
                        }
                    }
                    .onMove(perform: isFilteringEditor ? nil : moveSlots)
                    .onDelete(perform: deleteVisibleSlots)
                }
            } header: {
                HStack {
                    Text("Row Order")
                    Spacer()
                    Text(isFilteringEditor ? "\(visibleSlots.count) of \(slots.count)" : "\(slots.count)")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            } footer: {
                Text(isFilteringEditor
                     ? "Clear the search to reorder. Tap a button to edit it. Swipe to remove. Tap the dot to color a button."
                     : "Tap a button to edit it; editing a built-in makes it your own custom button. Drag the handle to reorder. Swipe to remove. Tap the dot to color a button. Spacers add fixed gaps between buttons. On the keyboard itself, hold any button for more: send it to another window, edit, color, add a spacer, remove.")
            }

            if !visibleCustoms.isEmpty {
                Section {
                    ForEach(visibleCustoms) { c in
                        // HStack + .contentShape + .onTapGesture instead of
                        // Button { } .buttonStyle(.plain) — the Button form
                        // eats scroll gestures inside a List, making the
                        // section feel sticky and occasionally opening the
                        // edit sheet when the user is mid-scroll. The tap-
                        // gesture form lets List own the scroll and only
                        // fires on a clean tap, restoring smooth scrolling
                        // and reliable .onDelete swipes.
                        HStack {
                            customPillPreview(c, tint: slotColors[QuickSlot.custom(c.id).id])
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.label).foregroundStyle(.primary)
                                Text(payloadSummary(c.payload))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { editingCustomID = c.id }
                    }
                    .onDelete(perform: deleteVisibleCustoms)
                } header: {
                    HStack {
                        Text("Custom Buttons")
                        Spacer()
                        Text(isFilteringEditor ? "\(visibleCustoms.count) of \(customs.count)" : "\(customs.count)")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                } footer: {
                    Text("Tap to edit. Deleting here removes it from the row too.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $editorQuery, placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: "Search buttons")
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled(true)
        .navigationTitle("Quick Buttons")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
            ToolbarItem(placement: .topBarTrailing) {
                addMenu
            }
            // §6.1 — export custom buttons as a shareable .quippack (Labs).
            if labsPromptPacks && !customs.isEmpty {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        let pack = SharedPromptPack(name: "Quip Buttons", prompts: [], buttons: customs)
                        do {
                            shareItem = PackShareItem(url: try pack.writeToTemp(filename: "quip-buttons"))
                        } catch {
                            // Staging the .quippack to the temp dir can fail on a
                            // full disk. `try?` made the Share button a no-op —
                            // the user taps it and nothing happens, forever.
                            print("[Quip][Packs] export buttons FAILED err=\(error)")
                            exportError = "Couldn't stage the button pack for sharing. \(error.localizedDescription)"
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share buttons")
                }
            }
        }
        .sheet(item: $shareItem) { item in
            DiagnosticsShareSheet(items: [item.url])
        }
        .alert("Couldn't share buttons", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        .onAppear { refreshSnapshots() }
        .onChange(of: quickSlotsJSON) { _, _ in refreshSlotsSnapshot() }
        .onChange(of: customButtonsJSON) { _, _ in refreshCustomsSnapshot() }
        .onChange(of: client?.promptLibrary.count ?? 0) { _, _ in refreshPromptSnapshot() }
        .sheet(isPresented: $addingCustom) {
            CustomButtonForm(
                initial: nil,
                onSave: { newButton in
                    var defs = customs
                    defs.append(newButton)
                    customButtonsJSON = CustomButtonStore.encode(defs)
                    var s = slots
                    s.append(.custom(newButton.id))
                    persistSlots(s)
                }
            )
        }
        .sheet(item: Binding(
            get: { editingCustomID.flatMap { customsByID[$0] } },
            set: { editingCustomID = $0?.id }
        )) { existing in
            CustomButtonForm(
                initial: existing,
                tint: slotColors[QuickSlot.custom(existing.id).id],
                onSave: { updated in
                    var defs = customs
                    if let idx = defs.firstIndex(where: { $0.id == updated.id }) {
                        defs[idx] = updated
                    }
                    customButtonsJSON = CustomButtonStore.encode(defs)
                }
            )
        }
        .sheet(item: $editingBuiltin) { builtin in
            if let copy = QuickButtonEdit.customCopy(of: builtin) {
                CustomButtonForm(initial: copy, tint: slotColors[QuickSlot.builtin(builtin).id]) { edited in
                    let r = QuickButtonEdit.save(edited, over: .builtin(builtin), slots: slots,
                                                 defs: customs, colors: slotColors)
                    customButtonsJSON = CustomButtonStore.encode(r.defs)
                    persistSlots(r.slots)
                    quickSlotColorsJSON = KeyColors.encode(r.colors)
                }
            }
        }
        .sheet(isPresented: $showPromptPicker) {
            promptPickerSheet
        }
        .sheet(item: $coloringSlot) { slot in
            ColorChoiceSheet(
                title: slotTitle(slot),
                current: slotColors[slot.id],
                resetLabel: KeyPillSpec.colorResetLabel(automatic: pillSpec(slot, userColor: nil), auto: autoKeyStyle)
            ) { hex in
                quickSlotColorsJSON = KeyColors.encode(KeyColors.setting(hex, for: slot.id, in: slotColors))
            }
        }
        .sheet(isPresented: $showAddSheet) {
            addSheet
        }
    }

    /// Lists the Mac's prompts the way the Prompts hub does (US-104): most
    /// used first, hidden prompts in a collapsed section, and the same
    /// search. Tap = add as a .prompt slot at the end of the row.
    /// Already-placed prompts are disabled so the user can't accidentally
    /// double-add. (§B3)
    private var promptPickerSheet: some View {
        NavigationStack {
            List {
                if let cl = client {
                    let placed = Set(slots.compactMap { slot -> String? in
                        if case .prompt(let pid) = slot { return pid }
                        return nil
                    })
                    let hub = PromptHub.sections(
                        cl.promptLibrary,
                        hiddenJSON: hiddenPromptIDsJSON,
                        store: PromptRanker.load(usageJSON: promptUsageJSON, legacyMRUJSON: promptUsageMRUJSON),
                        context: nil,
                        query: promptPickerQuery,
                        at: Date(),
                        cache: promptPickerCache
                    )
                    if hub.visible.isEmpty && hub.hidden.isEmpty && !cl.promptLibrary.isEmpty {
                        Text("No prompts match \"\(promptPickerQuery)\".")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    if !hub.visible.isEmpty {
                        Section(promptPickerQuery.isEmpty ? "Most used first" : "Best match first") {
                            ForEach(hub.visible) { entry in
                                promptPickerRow(entry, placed: placed.contains(entry.id), note: hub.notes[entry.id])
                            }
                        }
                    }
                    if !hub.hidden.isEmpty {
                        let expanded = showHiddenInPromptPicker || !promptPickerQuery.isEmpty
                        Section {
                            if expanded {
                                ForEach(hub.hidden) { entry in
                                    promptPickerRow(entry, placed: placed.contains(entry.id), note: hub.notes[entry.id])
                                }
                            }
                        } header: {
                            Button {
                                showHiddenInPromptPicker.toggle()
                            } label: {
                                Label("Hidden (\(hub.hidden.count))",
                                      systemImage: expanded ? "chevron.down" : "chevron.right")
                            }
                            .font(.caption)
                        }
                    }
                }
            }
            .searchable(text: $promptPickerQuery, placement: .navigationBarDrawer(displayMode: .always))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .navigationTitle("Add Prompt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showPromptPicker = false }
                }
            }
        }
    }

    private func promptPickerRow(_ entry: PromptEntry, placed: Bool, note: PromptHub.MatchNote?) -> some View {
        Button {
            addPromptSlot(entry.id)
            showPromptPicker = false
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.label)
                        .foregroundStyle(.primary)
                    Text(note?.excerpt ?? entry.bodyPreview)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let closeMatch = note?.closeMatch {
                        Text(closeMatch)
                            .font(.system(size: 10))
                            .foregroundStyle(.tint)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if placed {
                    Text("Added")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .disabled(placed)
    }

    private func addPromptSlot(_ promptID: String) {
        var s = slots
        s.append(.prompt(promptID: promptID))
        persistSlots(s)
    }

    /// The dot that opens a button's color sheet. Shows the button's color,
    /// or a palette outline when it has none. Spacers have nothing to color.
    @ViewBuilder
    private func slotColorButton(_ slot: QuickSlot) -> some View {
        if case .spacer = slot {
            EmptyView()
        } else {
            Button {
                coloringSlot = slot
            } label: {
                if let hex = slotColors[slot.id] {
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 22, height: 22)
                } else {
                    Image(systemName: "paintpalette")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                }
            }
            // Borderless: a plain Button in a List row would take taps
            // anywhere on the row.
            .buttonStyle(.borderless)
            .accessibilityLabel("Color for \(slotTitle(slot))")
        }
    }

    private func slotTitle(_ slot: QuickSlot) -> String {
        switch slot {
        case .builtin(let b): return b.displayName
        case .custom(let id): return customsByID[id]?.label ?? "Custom button"
        case .prompt(let pid): return promptLabelByID[pid] ?? pid
        case .promptsPicker: return "Prompts"
        case .spacer: return "Spacer"
        }
    }

    /// Q-67: what tapping a Row Order entry opens. Prompts are edited in the
    /// Prompts hub, and spacers and Broadcast have nothing to edit.
    private func editRowSlot(_ slot: QuickSlot) {
        switch slot {
        case .builtin(let b) where QuickButtonEdit.customCopy(of: b) != nil: editingBuiltin = b
        case .custom(let id) where customsByID[id] != nil: editingCustomID = id
        default: break
        }
    }

    @ViewBuilder
    private func slotRow(_ slot: QuickSlot) -> some View {
        switch slot {
        case .builtin(let b):
            HStack(spacing: 12) {
                builtinPillPreview(b, tint: slotColors[slot.id])
                VStack(alignment: .leading, spacing: 2) {
                    Text(b.displayName)
                    Text("Built-in")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
        case .custom(let id):
            if let def = customsByID[id] {
                HStack(spacing: 12) {
                    customPillPreview(def, tint: slotColors[slot.id])
                    VStack(alignment: .leading, spacing: 2) {
                        Text(def.label)
                        Text("Custom · \(payloadSummary(def.payload))")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "questionmark.square.dashed")
                        .frame(width: 36, height: 28)
                        .foregroundStyle(.tertiary)
                    Text("Custom (deleted)").foregroundStyle(.secondary)
                    Spacer()
                }
            }
        case .spacer:
            HStack(spacing: 12) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 36, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        Image(systemName: "arrow.left.and.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    )
                Text("Spacer")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        case .prompt(let pid):
            let label = promptLabelByID[pid]
            let bytes = promptByteSizeByID[pid]
            HStack(spacing: 12) {
                Rectangle()
                    .fill(Color.purple.opacity(0.25))
                    .frame(width: 36, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        Image(systemName: autoKeyStyle ? KeyStyles.prompt(label: label ?? pid).symbol : "doc.text")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.purple)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(label ?? pid)
                    Text(label == nil ? "Prompt (Mac unreachable)" : "Prompt · \(bytes ?? 0)B")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
            }
        case .promptsPicker:
            HStack(spacing: 12) {
                Rectangle()
                    .fill(Color.purple.opacity(0.25))
                    .frame(width: 36, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.purple)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("Prompts")
                    Text("Picker · ranked by use")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
            }
        }
    }

    /// Live preview of the actual quick-button row, rendered on the dark
    /// keyboard surface so users see exactly what they'll get without
    /// dismissing the editor. Horizontally scrolls when the row gets long.
    @ViewBuilder
    private var rowPreview: some View {
        let items = previewRowItems
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                if items.isEmpty {
                    Text("Empty — add a button below")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, 12)
                } else {
                    ForEach(items, id: \.0) { _, view in
                        view
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .background(Color.black.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Build the preview items as `(id, AnyView)` pairs so SwiftUI's
    /// ForEach has stable identity even though the items are a mix of
    /// builtin pills, custom pills, and spacers. Mirrors the same render
    /// logic as the live keyboard row, minus the disable-when-disconnected
    /// styling (the editor doesn't need to grey out its preview).
    private var previewRowItems: [(String, AnyView)] {
        var result: [(String, AnyView)] = []
        let tints = slotColors
        for slot in slots {
            switch slot {
            case .builtin(let b):
                result.append((slot.id, AnyView(builtinPillPreview(b, tint: tints[slot.id]))))
            case .custom(let id):
                if let def = customsByID[id] {
                    result.append((slot.id, AnyView(customPillPreview(def, tint: tints[slot.id]))))
                }
            case .spacer:
                result.append((slot.id, AnyView(
                    Color.clear.frame(width: 12, height: 1)
                )))
            case .prompt(let pid):
                let label = promptLabelByID[pid] ?? pid
                result.append((slot.id, AnyView(promptPillPreview(label: label, tint: tints[slot.id]))))
            case .promptsPicker:
                result.append((slot.id, AnyView(promptsPickerPillPreview(tint: tints[slot.id]))))
            }
        }
        return result
    }

    /// The same pill the keyboard row draws for `slot` (US-204), so the
    /// editor shows each button exactly as the row will.
    private func pillSpec(_ slot: QuickSlot, userColor: String?) -> KeyPillSpec? {
        KeyPillSpec.slot(slot, auto: autoKeyStyle, userColor: userColor, customs: customsByID,
                         promptLabel: { promptLabelByID[$0] ?? $0 }, symbolExists: KeySymbol.exists)
    }

    /// Editor-only mock of the Prompts-picker pill so the preview row
    /// renders correctly when the user has the picker slot configured.
    private func promptsPickerPillPreview(tint: String? = nil) -> some View {
        KeyPill(spec: .promptsPicker(userColor: tint))
    }

    /// Editor-only mock of the prompt pill — the live keyboard renderer's
    /// `KeyPill`, as in `promptQuickButton`. (§B3)
    private func promptPillPreview(label: String, tint: String? = nil) -> some View {
        KeyPill(spec: .prompt(label: label, auto: autoKeyStyle, userColor: tint))
    }

    /// Pill mock that matches the keyboard's `quickActionButton` chrome.
    /// Intentionally non-interactive in the editor — just a visual proxy.
    private func builtinPillPreview(_ b: QuickButton, tint: String? = nil) -> some View {
        KeyPill(spec: .builtin(b, auto: autoKeyStyle, userColor: tint), minHeight: 28)
    }

    private func customPillPreview(_ c: CustomButton, tint: String? = nil) -> some View {
        KeyPill(spec: .custom(c, auto: autoKeyStyle, userColor: tint, symbolExists: KeySymbol.exists), minHeight: 28)
    }

    /// "+" toolbar button — opens the sheet-based add picker. The previous
    /// inline `Menu` rendered a fixed-height list that clipped long slash
    /// names mid-word and offered awkward scroll once the list passed ~6
    /// items. A bottom sheet gives proper scroll, two-line rows, and a
    /// search bar.
    @ViewBuilder
    private var addMenu: some View {
        Button {
            addSheetQuery = ""
            showAddSheet = true
        } label: {
            Image(systemName: "plus")
        }
    }

    /// Sheet-based add picker that replaced the toolbar Menu. Sectioned,
    /// scrollable, searchable. Filters across all categories at once when
    /// the user types in the search bar.
    private var addSheet: some View {
        NavigationStack {
            List {
                let topItems = filteredAddItems
                if !topItems.isEmpty {
                    Section {
                        ForEach(topItems, id: \.self) { item in addItemRow(item) }
                    } footer: {
                        if topItems.contains(.customButton) {
                            Text("“Custom Button” makes your own slash, text, or keystroke key with a live preview.")
                        }
                    }
                }

                let slashMatches = filteredBuiltins(category: .slash)
                if !slashMatches.isEmpty {
                    Section("Slash") {
                        ForEach(slashMatches) { btn in addSheetRow(btn) }
                    }
                }
                let answerMatches = filteredBuiltins(category: .answer)
                if !answerMatches.isEmpty {
                    Section("Answers") {
                        ForEach(answerMatches) { btn in addSheetRow(btn) }
                    }
                }
                let keystrokeMatches = filteredBuiltins(category: .keystroke)
                if !keystrokeMatches.isEmpty {
                    Section("Keystrokes") {
                        ForEach(keystrokeMatches) { btn in addSheetRow(btn) }
                    }
                }
                let appMatches = filteredBuiltins(category: .app)
                if !appMatches.isEmpty {
                    Section("Quip") {
                        ForEach(appMatches) { btn in addSheetRow(btn) }
                    }
                }
                if topItems.isEmpty && slashMatches.isEmpty && answerMatches.isEmpty && keystrokeMatches.isEmpty
                    && appMatches.isEmpty {
                    Section {
                        Text("No buttons match \"\(addSheetQuery)\".")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Add Button")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $addSheetQuery, placement: .navigationBarDrawer(displayMode: .always))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showAddSheet = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// Built-ins of one category for the add sheet, matched by the search
    /// engine (US-103) on the short label (`/ship`), the full name
    /// (`/commit-commands:commit-push-pr`), the id and what the button
    /// sends, so "escape" finds Esc. Best match first while searching.
    private func filteredBuiltins(category: QuickButton.Category) -> [QuickButton] {
        QuickButtonSearch.filter(QuickButton.allCases.filter { $0.category == category }, query: addSheetQuery)
    }

    /// The entries above the built-ins, filtered by the same search. "One
    /// prompt…" is offered only once the Mac has sent its prompts.
    private var filteredAddItems: [QuickButtonSearch.AddItem] {
        var items: [QuickButtonSearch.AddItem] = [.customButton, .spacer]
        if !promptLabelByID.isEmpty { items.append(.onePrompt) }
        items.append(.promptsPicker)
        return QuickButtonSearch.filter(items, query: addSheetQuery)
    }

    @ViewBuilder
    private func addItemRow(_ item: QuickButtonSearch.AddItem) -> some View {
        switch item {
        case .customButton:
            Button {
                showAddSheet = false
                addingCustom = true
            } label: {
                Label("Custom Button…", systemImage: "plus.square.dashed")
            }
        case .spacer:
            Button {
                addSpacer()
                showAddSheet = false
            } label: {
                Label("Spacer", systemImage: "arrow.left.and.right")
            }
        case .onePrompt:
            Button {
                showAddSheet = false
                promptPickerQuery = ""
                showPromptPicker = true
            } label: {
                Label("One prompt as its own button…", systemImage: "doc.text")
            }
        case .promptsPicker:
            let pickerPlaced = slots.contains(where: {
                if case .promptsPicker = $0 { return true } else { return false }
            })
            Button {
                addPromptsPicker()
                showAddSheet = false
            } label: {
                Label("Prompts button (opens all prompts)" + (pickerPlaced ? " · added" : ""),
                      systemImage: "doc.text.magnifyingglass")
            }
            .disabled(pickerPlaced)
        }
    }

    /// Single row in the add sheet — uses the SHORT label as primary, with
    /// the full displayName as a secondary line so users can see e.g.
    /// `/ship` is `/commit-commands:commit-push-pr` without the long name
    /// wrapping mid-word like the prior Menu did.
    @ViewBuilder
    private func addSheetRow(_ btn: QuickButton) -> some View {
        let placed = placedBuiltins.contains(btn.rawValue)
        Button {
            addBuiltin(btn)
            showAddSheet = false
        } label: {
            HStack(spacing: 10) {
                if autoKeyStyle {
                    let style = KeyStyles.builtin(btn)
                    Image(systemName: style.symbol)
                        .frame(width: 22)
                        .foregroundStyle(style.hue.iconColor)
                } else if let sym = btn.systemImage {
                    Image(systemName: sym)
                        .frame(width: 22)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(btn.label.isEmpty ? btn.displayName : btn.label)
                            .font(.body.weight(.medium))
                        if placed {
                            Text("· added")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if btn.label != btn.displayName, !btn.label.isEmpty {
                        Text(btn.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
            }
        }
        .disabled(placed)
    }

    private func addPromptsPicker() {
        var s = slots
        s.append(.promptsPicker)
        persistSlots(s)
    }

    /// Re-read every cached snapshot from its source. Called on the
    /// view's first .onAppear so the editor opens with fresh data.
    private func refreshSnapshots() {
        refreshSlotsSnapshot()
        refreshCustomsSnapshot()
        refreshPromptSnapshot()
    }

    private func refreshSlotsSnapshot() {
        slots = QuickSlotStore.decode(quickSlotsJSON)
    }

    private func refreshCustomsSnapshot() {
        let decoded = CustomButtonStore.decode(customButtonsJSON)
        customs = decoded
        customsByID = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
    }

    private func refreshPromptSnapshot() {
        let entries = client?.promptLibrary ?? []
        promptLabelByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.label) })
        promptByteSizeByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.bodyBytes) })
    }

    @ViewBuilder
    private func builtinAddRow(_ btn: QuickButton) -> some View {
        let placed = placedBuiltins.contains(btn.rawValue)
        Button {
            addBuiltin(btn)
        } label: {
            if let sym = btn.systemImage {
                Label(btn.displayName + (placed ? " · added" : ""), systemImage: sym)
            } else {
                Text(btn.displayName + (placed ? " · added" : ""))
            }
        }
        .disabled(placed)
    }

    private func payloadSummary(_ p: CustomPayload) -> String {
        switch p {
        case .slash(let t, let a): return "\(t)\(a ? " ⏎" : "")"
        case .rawText(let t, let a): return "\"\(t)\"\(a ? " ⏎" : "")"
        case .keystroke(let action): return action
        }
    }

    private func moveSlots(from source: IndexSet, to destination: Int) {
        var s = slots
        s.move(fromOffsets: source, toOffset: destination)
        persistSlots(s)
    }

    private func deleteSlots(at offsets: IndexSet) {
        var s = slots
        s.remove(atOffsets: offsets)
        persistSlots(s)
    }

    private func deleteCustomDefs(at offsets: IndexSet) {
        var defs = customs
        let removedIds = offsets.map { defs[$0].id }
        defs.remove(atOffsets: offsets)
        customButtonsJSON = CustomButtonStore.encode(defs)
        // Cascade-remove any slots referencing the deleted custom IDs so
        // the row doesn't render orphan "Custom (deleted)" pills.
        let removedSet = Set(removedIds)
        let pruned = slots.filter { slot in
            if case .custom(let id) = slot { return !removedSet.contains(id) }
            return true
        }
        if pruned.count != slots.count {
            persistSlots(pruned)
        }
    }

    private func addBuiltin(_ btn: QuickButton) {
        var s = slots
        s.append(.builtin(btn))
        persistSlots(s)
    }

    private func addSpacer() {
        var s = slots
        s.append(.spacer(UUID()))
        persistSlots(s)
    }

    /// Persist the slot list and keep the legacy CSV in sync. The CSV is no
    /// longer the source of truth, but PreferencesSyncService still mirrors
    /// it to the Mac for older clients and a downgrade safety net.
    private func persistSlots(_ s: [QuickSlot]) {
        quickSlotsJSON = QuickSlotStore.encode(s)
        let builtins = s.compactMap { slot -> QuickButton? in
            if case .builtin(let b) = slot { return b }
            return nil
        }
        enabledQuickButtonsRaw = QuickButton.encode(builtins)
    }
}
