import Foundation

enum AICommitMessageReasoningEffort: String, CaseIterable, Identifiable, Sendable {
    case low
    case medium
    case high
    case xhigh
    case max
    case ultra

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra High"
        case .max: "Maximum"
        case .ultra: "Ultra"
        }
    }
}

enum AICommitMessageProvider: String, CaseIterable, Identifiable, Sendable {
    case codex
    case claude

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        }
    }

    var serviceName: String {
        switch self {
        case .codex: "OpenAI"
        case .claude: "Anthropic"
        }
    }

    var executableName: String { rawValue }

    /// The model family used when none is chosen. A commit subject needs
    /// little reasoning, so the default is each vendor's fast family.
    var automaticModelFamily: String {
        switch self {
        case .codex: "GPT Luna"
        case .claude: "Sonnet"
        }
    }

    var automaticModelName: String { "Latest \(automaticModelFamily)" }

    /// Picks the automatic model. Codex lists models in its own priority
    /// order, newest first within a family, so the first Luna is the latest.
    /// Claude Code resolves the `sonnet` alias to the newest Sonnet itself.
    func automaticModel(in models: [AICommitMessageModel]) -> String? {
        switch self {
        case .codex: (models.first { $0.id.hasSuffix("-luna") } ?? models.first)?.id
        case .claude: "sonnet"
        }
    }

    /// The model Kvist stored as the default before it resolved the latest
    /// Luna model. Loading treats it as automatic.
    var legacyDefaultModel: String? {
        switch self {
        case .codex: "gpt-6-luna"
        case .claude: nil
        }
    }

    var suggestedModels: [AICommitMessageModel] {
        switch self {
        case .codex:
            []
        case .claude:
            [
                AICommitMessageModel(id: "sonnet", name: "Sonnet (latest)"),
                AICommitMessageModel(id: "opus", name: "Opus (latest)"),
                AICommitMessageModel(id: "haiku", name: "Haiku (latest)")
            ]
        }
    }

    var defaultCommandTemplate: String {
        switch self {
        case .codex:
            return "{executable} exec --model {model} --config model_reasoning_effort={reasoning-effort} --ephemeral --sandbox read-only --color never --cd {repository} --output-schema {schema} --output-last-message {output} -"
        case .claude:
            return "{executable} --print --model {model} --effort high --permission-mode plan --tools '' --no-session-persistence --output-format json --json-schema {schema-json}"
        }
    }

    var legacyDefaultCommandTemplate: String? {
        switch self {
        case .codex:
            "{executable} exec --model {model} --config 'model_reasoning_effort=\"xhigh\"' --ephemeral --sandbox read-only --color never --cd {repository} --output-schema {schema} --output-last-message {output} -"
        case .claude:
            nil
        }
    }

    var modelSourceDescription: String {
        switch self {
        case .codex:
            "The menu lists models from the installed Codex CLI."
        case .claude:
            "The menu lists Claude Code aliases. Full model IDs also work."
        }
    }
}

struct AICommitMessageModel: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let supportedReasoningEfforts: [AICommitMessageReasoningEffort]
    let defaultReasoningEffort: AICommitMessageReasoningEffort?

    init(
        id: String,
        name: String,
        supportedReasoningEfforts: [AICommitMessageReasoningEffort] = [],
        defaultReasoningEffort: AICommitMessageReasoningEffort? = nil
    ) {
        self.id = id
        self.name = name
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.defaultReasoningEffort = defaultReasoningEffort
    }
}

struct AICommitMessageConfiguration: Equatable, Sendable {
    let provider: AICommitMessageProvider
    /// `nil` selects the provider's automatic model when generating.
    let model: String?
    let reasoningEffort: AICommitMessageReasoningEffort?
    let commandTemplate: String

    init(
        provider: AICommitMessageProvider,
        model: String? = nil,
        reasoningEffort: AICommitMessageReasoningEffort? = nil,
        commandTemplate: String
    ) {
        self.provider = provider
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.commandTemplate = commandTemplate
    }

    static func load(defaults: UserDefaults = .standard) -> Self {
        let provider = AICommitMessageProvider(
            rawValue: defaults.string(forKey: AICommitMessagePreferences.providerKey) ?? ""
        ) ?? .codex
        let model = defaults.string(forKey: AICommitMessagePreferences.modelKey(for: provider))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let command = defaults.string(
            forKey: AICommitMessagePreferences.commandTemplateKey(for: provider)
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        let reasoningEffort = provider == .codex
            ? AICommitMessageReasoningEffort(
                rawValue: defaults.string(
                    forKey: AICommitMessagePreferences.codexReasoningEffortKey
                ) ?? ""
            ) ?? .low
            : nil
        let storedCommand = command.flatMap { $0.isEmpty ? nil : $0 }
        let normalizedCommand = storedCommand == provider.legacyDefaultCommandTemplate
            ? provider.defaultCommandTemplate
            : storedCommand

        return Self(
            provider: provider,
            model: model.flatMap {
                $0.isEmpty || $0 == provider.legacyDefaultModel ? nil : $0
            },
            reasoningEffort: reasoningEffort,
            commandTemplate: normalizedCommand
                ?? provider.defaultCommandTemplate
        )
    }
}

enum AICommitMessagePreferences {
    static let providerKey = "aiCommitMessageProvider"
    static let codexModelKey = "aiCommitMessageCodexModel"
    static let claudeModelKey = "aiCommitMessageClaudeModel"
    static let codexReasoningEffortKey = "aiCommitMessageCodexReasoningEffort"
    static let codexCommandTemplateKey = "aiCommitMessageCodexCommandTemplate"
    static let claudeCommandTemplateKey = "aiCommitMessageClaudeCommandTemplate"

    static func modelKey(for provider: AICommitMessageProvider) -> String {
        switch provider {
        case .codex: codexModelKey
        case .claude: claudeModelKey
        }
    }

    static func commandTemplateKey(for provider: AICommitMessageProvider) -> String {
        switch provider {
        case .codex: codexCommandTemplateKey
        case .claude: claudeCommandTemplateKey
        }
    }
}
