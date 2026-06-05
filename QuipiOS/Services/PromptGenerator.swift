import Foundation

enum PromptGeneratorAgent: String, CaseIterable, Identifiable {
    case any
    case claude
    case codex
    case cursor
    case grok

    var id: String { rawValue }

    static let visibleCases: [PromptGeneratorAgent] = [.any, .claude, .codex, .grok]

    var displayName: String {
        switch self {
        case .any: return "Any agent"
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .grok: return "Grok"
        }
    }

    var metadataValue: String? {
        switch self {
        case .any: return "any"
        case .claude, .codex, .cursor, .grok: return rawValue
        }
    }
}

enum PromptGeneratorOutputStyle: String, CaseIterable, Identifiable {
    case implementation
    case codeReview
    case debug
    case planning
    case writing
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .implementation: return "Implementation"
        case .codeReview: return "Code review"
        case .debug: return "Debugging"
        case .planning: return "Planning"
        case .writing: return "Writing"
        case .custom: return "Custom"
        }
    }

    var instruction: String {
        switch self {
        case .implementation:
            return "Implement the requested change, keep edits scoped, and verify the touched behavior."
        case .codeReview:
            return "Review for bugs, regressions, missing tests, and user-visible risks. Put findings first."
        case .debug:
            return "Trace the failure from observed symptom to root cause, then apply the smallest reliable fix."
        case .planning:
            return "Create a concrete execution plan with dependencies, risks, and verification steps."
        case .writing:
            return "Draft clear copy that matches the product voice and avoids unnecessary explanation."
        case .custom:
            return "Follow the goal and constraints exactly."
        }
    }
}

struct PromptGeneratorInput: Equatable {
    var title: String
    var targetAgent: PromptGeneratorAgent
    var outputStyle: PromptGeneratorOutputStyle
    var goal: String
    var context: String
    var constraints: String
    var successCriteria: String
    var askClarifyingQuestions: Bool
    var includeVerification: Bool
    var conciseOutput: Bool

    static let empty = PromptGeneratorInput(
        title: "",
        targetAgent: .any,
        outputStyle: .implementation,
        goal: "",
        context: "",
        constraints: "",
        successCriteria: "",
        askClarifyingQuestions: false,
        includeVerification: true,
        conciseOutput: true
    )
}

enum PromptGenerator {
    static func makeEntry(from input: PromptGeneratorInput, existingIDs: Set<String>) -> PromptEntry {
        let title = cleanLine(input.title).isEmpty ? cleanLine(input.goal) : cleanLine(input.title)
        let label = title.isEmpty ? "Generated Prompt" : title
        let id = uniqueID(base: label, existingIDs: existingIDs)
        return PromptEntry(
            id: id,
            label: label,
            body: makeBody(from: input),
            tags: ["generated", input.outputStyle.rawValue],
            targetAgent: input.targetAgent.metadataValue,
            description: cleanLine(input.goal).isEmpty ? nil : cleanLine(input.goal)
        )
    }

    static func makeBody(from input: PromptGeneratorInput) -> String {
        let agent = input.targetAgent.displayName
        let goal = cleanBlock(input.goal)
        let context = cleanBlock(input.context)
        let constraints = cleanBlock(input.constraints)
        let successCriteria = cleanBlock(input.successCriteria)

        var lines: [String] = [
            "You are \(agent) working inside Quip.",
            "",
            "Goal:",
            goal.isEmpty ? "- Complete the requested task." : "- \(goal)",
            "",
            "Mode:",
            "- \(input.outputStyle.instruction)"
        ]

        if !context.isEmpty {
            lines += [
                "",
                "Context:",
                context
            ]
        }

        var instructionLines: [String] = []
        if input.askClarifyingQuestions {
            instructionLines.append("Ask concise clarifying questions before acting if required details are missing.")
        } else {
            instructionLines.append("Make reasonable assumptions when safe and state them briefly.")
        }
        if input.includeVerification {
            instructionLines.append("Verify the result with the narrowest meaningful test, build, or manual check.")
        }
        if input.conciseOutput {
            instructionLines.append("Keep the final response concise and focused on what changed, verification, and remaining risk.")
        }
        if !constraints.isEmpty {
            instructionLines.append("Respect these constraints: \(constraints)")
        }

        lines += [
            "",
            "Instructions:"
        ]
        lines += instructionLines.map { "- \($0)" }

        if !successCriteria.isEmpty {
            lines += [
                "",
                "Done when:",
                successCriteria
            ]
        }

        return lines.joined(separator: "\n")
    }

    static func uniqueID(base: String, existingIDs: Set<String>) -> String {
        let sanitized = sanitizedID(base)
        let root = sanitized.isEmpty ? "generated-prompt" : sanitized
        guard existingIDs.contains(root) else { return root }

        var index = 2
        while existingIDs.contains("\(root)-\(index)") {
            index += 1
        }
        return "\(root)-\(index)"
    }

    static func sanitizedID(_ value: String) -> String {
        let lower = value.lowercased()
        var scalars: [UnicodeScalar] = []
        var previousWasSeparator = false

        for scalar in lower.unicodeScalars {
            let value = scalar.value
            let isDigit = value >= 48 && value <= 57
            let isLetter = value >= 97 && value <= 122
            let isAllowed = isDigit || isLetter || scalar == "_"

            if isAllowed {
                scalars.append(scalar)
                previousWasSeparator = false
            } else if !previousWasSeparator {
                scalars.append("-")
                previousWasSeparator = true
            }
        }

        let raw = String(String.UnicodeScalarView(scalars))
        return raw.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
    }

    private static func cleanLine(_ value: String) -> String {
        cleanBlock(value).replacingOccurrences(of: "\n", with: " ")
    }

    private static func cleanBlock(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
