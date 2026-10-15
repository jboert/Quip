import SwiftUI

/// Search over every slash command the long-press palette lists (PRD
/// broadcast-and-search, US-105). The palette is a context menu, which can
/// hold no search field and gets hard to use past a handful of commands.
/// Tapping a row fires the command exactly as the palette does and closes
/// the sheet.
struct SlashSearchSheet: View {
    typealias Member = MainiOSView.SlashGroupMember

    let members: [Member]
    var onPick: (Member) -> Void
    /// Q-51 / US-209: what each row's hold menu and swipes need. The row
    /// state is read through closures so a pin or removal shows at once.
    var isInRow: (Member) -> Bool = { _ in false }
    var sendAction: (Member) -> QuickSend? = { _ in nil }
    var targets: () -> [SendToTargets.Target] = { [] }
    var onSendTo: (Member, _ windowID: String, QuickSend) -> Void = { _, _, _ in }
    var onTogglePin: (Member) -> Void = { _ in }
    /// Called after this sheet has started to close, since the edit form is
    /// presented by the main screen.
    var onEdit: (Member) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var sendingTo: Member?

    /// The palette offers "Search…" only when there is more than one
    /// command to choose from.
    static func offersSearch(memberCount: Int) -> Bool { memberCount > 1 }

    var body: some View {
        NavigationStack {
            List {
                let shown = QuickButtonSearch.filter(members, query: query)
                if shown.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
                Section {
                    ForEach(shown) { member in
                        row(member)
                    }
                } footer: {
                    if !shown.isEmpty {
                        Text("Hold a command for more. Swipe right to send it to another window, left to pin, remove or edit it.")
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
            .modifier(FocusSearchOnAppear())
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .navigationTitle("Slash Commands")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .sheet(item: $sendingTo) { member in
            if let action = sendAction(member) {
                SendToWindowSheet(title: member.displayName, action: action, targets: targets()) { windowID, action in
                    onSendTo(member, windowID, action)
                    // The main screen's "Sent to" note is under this sheet.
                    dismiss()
                }
            }
        }
    }

    private func row(_ member: Member) -> some View {
        let inRow = isInRow(member)
        let isCustom = member.isCustom
        return Button {
            onPick(member)
            dismiss()
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(member.displayName)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    if member.sentText != member.displayName {
                        Text(member.sentText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
                if inRow {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("In the row")
                }
            }
            .contentShape(Rectangle())
        }
        // Plain, so the row reads as text, not a blue link.
        .buttonStyle(.plain)
        .contextMenu {
            ForEach(SlashRowActions.menu(inRow: inRow, isCustom: isCustom), id: \.self) { action in
                actionButton(action, member)
            }
        }
        .swipeActions(edge: .leading) {
            ForEach(SlashRowActions.leadingSwipe, id: \.self) { action in
                actionButton(action, member)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            ForEach(SlashRowActions.trailingSwipe(inRow: inRow, isCustom: isCustom), id: \.self) { action in
                actionButton(action, member)
            }
        }
    }

    private func actionButton(_ action: SlashRowAction, _ member: Member) -> some View {
        Button(role: action == .removeFromRow ? .destructive : nil) {
            perform(action, on: member)
        } label: {
            Label(action.title, systemImage: action.systemImage)
        }
        .tint(tint(action))
        .disabled(action == .sendTo && sendAction(member) == nil)
    }

    private func tint(_ action: SlashRowAction) -> Color? {
        switch action {
        case .sendTo, .send: return .blue
        case .pinToRow: return .orange
        case .edit: return .gray
        case .removeFromRow: return nil
        }
    }

    private func perform(_ action: SlashRowAction, on member: Member) {
        switch action {
        case .send:
            onPick(member)
            dismiss()
        case .sendTo:
            sendingTo = member
        case .pinToRow, .removeFromRow:
            onTogglePin(member)
        case .edit:
            dismiss()
            onEdit(member)
        }
    }
}

/// The sheet opens only from the palette's "Search…" item, so the field takes
/// the keyboard at once; before, the first letters typed went nowhere until
/// the field was tapped. iOS 17 has no API for this and keeps the tap.
private struct FocusSearchOnAppear: ViewModifier {
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content
                .searchFocused($focused)
                .onAppear { focused = true }
        } else {
            content
        }
    }
}

extension MainiOSView.SlashGroupMember: QuipSearchable {
    var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }

    var searchFields: [QuipSearchField] {
        switch self {
        case .builtin(let button): return button.searchFields
        case .custom(let button): return button.searchFields
        }
    }

    /// What tapping the command types into the terminal.
    var sentText: String {
        switch self {
        case .builtin(let button):
            if case .sendText(let text, _) = button.action { return text.trimmingCharacters(in: .whitespaces) }
            return button.displayName
        case .custom(let button):
            return QuickButtonSearch.sentText(button.payload)
        }
    }
}
