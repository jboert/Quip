import SwiftUI

struct PromptGeneratorSheet: View {
    let existingIDs: Set<String>
    /// The user's most-fired prompts for the selected window's agent, best
    /// first (`PromptGenerator.topExamples`). Empty hides the section.
    let examples: [PromptEntry]
    let onUseDraft: (PromptEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var input: PromptGeneratorInput

    init(existingIDs: Set<String>, context: String?, examples: [PromptEntry],
         onUseDraft: @escaping (PromptEntry) -> Void) {
        self.existingIDs = existingIDs
        self.examples = examples
        self.onUseDraft = onUseDraft
        _input = State(initialValue: PromptGenerator.initialInput(context: context, examples: examples))
    }

    private var generatedBody: String {
        PromptGenerator.makeBody(from: input)
    }

    private var canUseDraft: Bool {
        !input.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                if !examples.isEmpty {
                    Section {
                        ForEach(examples) { entry in
                            Button {
                                input = PromptGenerator.seeded(from: entry, base: input)
                            } label: {
                                Label(entry.label, systemImage: "arrow.up.doc")
                                    .lineLimit(1)
                            }
                            .accessibilityHint("Start the draft from this prompt")
                        }
                    } header: {
                        Text("Start from a top prompt")
                    } footer: {
                        Text("The prompts you fire most here. Tap one to copy its goal, style, and target.")
                    }
                }

                Section {
                    TextField("Prompt name", text: $input.title)
                        .autocorrectionDisabled(true)
                    Picker("Target", selection: $input.targetAgent) {
                        ForEach(PromptGeneratorAgent.visibleCases) { agent in
                            Text(agent.displayName).tag(agent)
                        }
                    }
                    Picker("Style", selection: $input.outputStyle) {
                        ForEach(PromptGeneratorOutputStyle.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                } header: {
                    Text("Prompt")
                } footer: {
                    Text("Name becomes the saved prompt label. Target and style are stored as prompt metadata.")
                }

                Section {
                    TextField("What should the saved prompt make the agent do?", text: $input.goal, axis: .vertical)
                        .lineLimit(3...5)
                    TextField("Relevant project, repo, or workflow context", text: $input.context, axis: .vertical)
                        .lineLimit(3...6)
                } header: {
                    Text("Goal")
                }

                Section {
                    TextField("Constraints, tone, or must-not-do items", text: $input.constraints, axis: .vertical)
                        .lineLimit(2...5)
                    TextField("What counts as done?", text: $input.successCriteria, axis: .vertical)
                        .lineLimit(2...5)
                } header: {
                    Text("Boundaries")
                }

                Section {
                    Toggle("Ask clarifying questions first", isOn: $input.askClarifyingQuestions)
                    Toggle("Include verification", isOn: $input.includeVerification)
                    Toggle("Concise final response", isOn: $input.conciseOutput)
                } header: {
                    Text("Behavior")
                }

                Section {
                    Text(generatedBody)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                } header: {
                    HStack {
                        Text("Preview")
                        Spacer()
                        Text("\(generatedBody.utf8.count) B")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Use Draft opens the normal prompt editor, where you can revise the body before saving to the Mac.")
                }
            }
            .navigationTitle("Prompt Generator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use Draft") {
                        onUseDraft(PromptGenerator.makeEntry(from: input, existingIDs: existingIDs))
                    }
                    .disabled(!canUseDraft)
                }
            }
        }
    }
}
