import SwiftUI

/// Search over every slash command the long-press palette lists (PRD
/// broadcast-and-search, US-105). The palette is a context menu, which can
/// hold no search field and gets hard to use past a handful of commands.
/// Tapping a row fires the command exactly as the palette does and closes
/// the sheet.
struct SlashSearchSheet: View {
    let members: [MainiOSView.SlashGroupMember]
    var onPick: (MainiOSView.SlashGroupMember) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    /// The palette offers "Search…" only when there is more than one
    /// command to choose from.
    static func offersSearch(memberCount: Int) -> Bool { memberCount > 1 }

    var body: some View {
        NavigationStack {
            List {
                let shown = QuickButtonSearch.filter(members, query: query)
                if shown.isEmpty {
                    Text("No slash commands match \"\(query)\".")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                ForEach(shown) { member in
                    Button {
                        onPick(member)
                        dismiss()
                    } label: {
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
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
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
    }
}

extension MainiOSView.SlashGroupMember: QuipSearchable {
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
