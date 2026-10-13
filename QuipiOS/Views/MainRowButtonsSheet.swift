import SwiftUI
import AVFoundation

/// Quick Buttons detail page — lives behind a NavigationLink in SettingsSheet
/// instead of inlining the ~18-chip grid on the main Settings page. Keeps the
/// top-level Settings list scannable without losing the density the chip grid
/// provides here.
/// Settings sheet for toggling each button in the main control row.
/// PTT mic stays mandatory (core function); everything else can be hidden
/// to keep the row from overflowing on smaller phones or to reduce
/// per-thumb visual noise. @AppStorage-backed so toggles persist.
struct MainRowButtonsSheet: View {
    @AppStorage("mainRow.cycleLeft") private var cycleLeft: Bool = true
    @AppStorage("mainRow.cycleRight") private var cycleRight: Bool = true
    @AppStorage("mainRow.spawn") private var spawn: Bool = true
    @AppStorage("mainRow.arrange") private var arrange: Bool = true
    @AppStorage("mainRow.photo") private var photo: Bool = true
    @AppStorage("mainRow.prompts") private var prompts: Bool = false
    @AppStorage("mainRow.keyboard") private var keyboard: Bool = true
    @AppStorage("mainRow.return") private var pressReturn: Bool = true
    @AppStorage("mainRow.broadcast") private var broadcast: Bool = true
    @AppStorage("mainRow.broadcastBar") private var broadcastBar: Bool = false

    var body: some View {
        List {
            Section {
                Toggle(isOn: $cycleLeft) { Label("Previous Window", systemImage: "chevron.left") }
                Toggle(isOn: $cycleRight) { Label("Next Window", systemImage: "chevron.right") }
                Toggle(isOn: $spawn) { Label("Spawn New Window", systemImage: "plus") }
                Toggle(isOn: $arrange) { Label("Arrange Layout", systemImage: "rectangle.3.group") }
                Toggle(isOn: $photo) { Label("Attach Image", systemImage: "photo") }
                Toggle(isOn: $prompts) { Label("Prompts", systemImage: "doc.text.magnifyingglass") }
                Toggle(isOn: $keyboard) { Label("Keyboard Toggle", systemImage: "keyboard") }
                Toggle(isOn: $pressReturn) { Label("Press Return", systemImage: "return") }
                Toggle(isOn: $broadcast) { Label("Broadcast (beside the mic)", systemImage: "dot.radiowaves.left.and.right") }
                Toggle(isOn: $broadcastBar) { Label("Broadcast Bar (own row)", systemImage: "rectangle.and.text.magnifyingglass") }
            } footer: {
                Text("PTT mic always shows. Hide buttons you don't use to keep the row uncluttered. Long-press the Arrange button to realign auto-layout. Broadcast lives beside the mic; the bar is the same action as a full-width row, off unless you want it. Broadcast can also be a Quick Button.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Main Row Buttons")
        .navigationBarTitleDisplayMode(.inline)
    }
}
