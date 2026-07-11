import Foundation

public enum AgentProvider: String, Codable, CaseIterable, Sendable {
    case codex
    case claude
    case gemini

    public var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        case .gemini: "Gemini CLI"
        }
    }
}

public struct TokenUsage: Codable, Equatable, Sendable {
    public var inputTokens: Int
    public var cachedReadTokens: Int
    public var cacheWrite5mTokens: Int
    public var cacheWrite1hTokens: Int
    public var outputTokens: Int

    public init(
        inputTokens: Int = 0,
        cachedReadTokens: Int = 0,
        cacheWrite5mTokens: Int = 0,
        cacheWrite1hTokens: Int = 0,
        outputTokens: Int = 0
    ) {
        self.inputTokens = max(0, inputTokens)
        self.cachedReadTokens = max(0, cachedReadTokens)
        self.cacheWrite5mTokens = max(0, cacheWrite5mTokens)
        self.cacheWrite1hTokens = max(0, cacheWrite1hTokens)
        self.outputTokens = max(0, outputTokens)
    }

    public var totalInputTokens: Int {
        inputTokens + cachedReadTokens + cacheWrite5mTokens + cacheWrite1hTokens
    }

    public var totalTokens: Int {
        totalInputTokens + outputTokens
    }

    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            cachedReadTokens: lhs.cachedReadTokens + rhs.cachedReadTokens,
            cacheWrite5mTokens: lhs.cacheWrite5mTokens + rhs.cacheWrite5mTokens,
            cacheWrite1hTokens: lhs.cacheWrite1hTokens + rhs.cacheWrite1hTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens
        )
    }
}

public struct CostBreakdown: Codable, Equatable, Sendable {
    public let input: Double
    public let cacheRead: Double
    public let cacheWrite: Double
    public let output: Double

    public init(input: Double, cacheRead: Double, cacheWrite: Double, output: Double) {
        self.input = input
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.output = output
    }

    public var total: Double { input + cacheRead + cacheWrite + output }

    public static let zero = CostBreakdown(input: 0, cacheRead: 0, cacheWrite: 0, output: 0)

    public static func + (lhs: CostBreakdown, rhs: CostBreakdown) -> CostBreakdown {
        CostBreakdown(
            input: lhs.input + rhs.input,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
            output: lhs.output + rhs.output
        )
    }

    public static func - (lhs: CostBreakdown, rhs: CostBreakdown) -> CostBreakdown {
        CostBreakdown(
            input: lhs.input - rhs.input,
            cacheRead: lhs.cacheRead - rhs.cacheRead,
            cacheWrite: lhs.cacheWrite - rhs.cacheWrite,
            output: lhs.output - rhs.output
        )
    }
}

public struct CodingSession: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let provider: AgentProvider
    public let title: String
    public let projectPath: String
    public let model: String
    public let usage: TokenUsage
    public let contextTokens: Int
    public let contextWindow: Int
    public let startedAt: Date
    public let updatedAt: Date
    public let logPath: String
    public let lastUserMessageAt: Date?
    private let subagentFlag: Bool?

    public var isSubagent: Bool { subagentFlag == true }

    public init(
        id: String,
        provider: AgentProvider,
        title: String,
        projectPath: String,
        model: String,
        usage: TokenUsage,
        contextTokens: Int,
        contextWindow: Int,
        startedAt: Date,
        updatedAt: Date,
        logPath: String,
        lastUserMessageAt: Date? = nil,
        isSubagent: Bool = false
    ) {
        self.id = id
        self.provider = provider
        self.title = title
        self.projectPath = projectPath
        self.model = model
        self.usage = usage
        self.contextTokens = max(0, contextTokens)
        self.contextWindow = max(1, contextWindow)
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.logPath = logPath
        self.lastUserMessageAt = lastUserMessageAt
        self.subagentFlag = isSubagent
    }

    public var contextFraction: Double {
        min(Double(contextTokens) / Double(contextWindow), 1)
    }

    public var projectName: String {
        URL(fileURLWithPath: projectPath).lastPathComponent
    }

    public func cost(using catalog: PricingCatalog = .current) -> CostBreakdown? {
        catalog.price(for: model, provider: provider)?.cost(
            usage: usage,
            currentContextTokens: contextTokens
        )
    }
}

public enum CompactAlertPolicy {
    public static func shouldNotify(
        previous: CodingSession?,
        current: CodingSession,
        threshold: Double,
        isArmed: Bool,
        hasAlerted: Bool,
        monitoringIsEstablished: Bool,
        now: Date = Date()
    ) -> Bool {
        guard monitoringIsEstablished,
              !current.isSubagent,
              current.contextFraction >= threshold,
              let currentMessageDate = current.lastUserMessageAt else { return false }

        if let previousMessageDate = previous?.lastUserMessageAt,
           currentMessageDate <= previousMessageDate {
            return false
        }

        let messageAge = now.timeIntervalSince(currentMessageDate)
        guard messageAge >= -5, messageAge < 120 else { return false }
        return isArmed || !hasAlerted
    }
}
