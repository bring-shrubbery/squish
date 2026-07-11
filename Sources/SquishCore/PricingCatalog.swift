import Foundation

public struct LongContextPrice: Equatable, Sendable {
    public let threshold: Int
    public let inputPerMillion: Double
    public let cachedReadPerMillion: Double
    public let outputPerMillion: Double

    public init(
        threshold: Int,
        inputPerMillion: Double,
        cachedReadPerMillion: Double,
        outputPerMillion: Double
    ) {
        self.threshold = threshold
        self.inputPerMillion = inputPerMillion
        self.cachedReadPerMillion = cachedReadPerMillion
        self.outputPerMillion = outputPerMillion
    }
}

public struct ModelPrice: Equatable, Sendable {
    public let provider: AgentProvider
    public let canonicalModel: String
    public let aliases: [String]
    public let inputPerMillion: Double
    public let cachedReadPerMillion: Double
    public let cacheWrite5mPerMillion: Double
    public let cacheWrite1hPerMillion: Double
    public let outputPerMillion: Double
    public let contextWindow: Int
    public let longContext: LongContextPrice?

    public init(
        provider: AgentProvider,
        canonicalModel: String,
        aliases: [String] = [],
        inputPerMillion: Double,
        cachedReadPerMillion: Double,
        cacheWrite5mPerMillion: Double? = nil,
        cacheWrite1hPerMillion: Double? = nil,
        outputPerMillion: Double,
        contextWindow: Int,
        longContext: LongContextPrice? = nil
    ) {
        self.provider = provider
        self.canonicalModel = canonicalModel
        self.aliases = aliases
        self.inputPerMillion = inputPerMillion
        self.cachedReadPerMillion = cachedReadPerMillion
        self.cacheWrite5mPerMillion = cacheWrite5mPerMillion ?? inputPerMillion
        self.cacheWrite1hPerMillion = cacheWrite1hPerMillion ?? inputPerMillion
        self.outputPerMillion = outputPerMillion
        self.contextWindow = contextWindow
        self.longContext = longContext
    }

    public func matches(_ model: String) -> Bool {
        matchSpecificity(for: model) != nil
    }

    func matchSpecificity(for model: String) -> Int? {
        let candidate = model.lowercased()
        return ([canonicalModel] + aliases)
            .filter { alias in
                candidate == alias.lowercased() || candidate.hasPrefix(alias.lowercased() + "-")
            }
            .map(\.count)
            .max()
    }

    public func cost(usage: TokenUsage, currentContextTokens: Int) -> CostBreakdown {
        let scale = 1_000_000.0
        let tier = longContext.flatMap { currentContextTokens > $0.threshold ? $0 : nil }
        let inputRate = tier?.inputPerMillion ?? inputPerMillion
        let cachedRate = tier?.cachedReadPerMillion ?? cachedReadPerMillion
        let outputRate = tier?.outputPerMillion ?? outputPerMillion

        return CostBreakdown(
            input: Double(usage.inputTokens) / scale * inputRate,
            cacheRead: Double(usage.cachedReadTokens) / scale * cachedRate,
            cacheWrite: (
                Double(usage.cacheWrite5mTokens) / scale * cacheWrite5mPerMillion
                + Double(usage.cacheWrite1hTokens) / scale * cacheWrite1hPerMillion
            ),
            output: Double(usage.outputTokens) / scale * outputRate
        )
    }
}

public struct PricingCatalog: Sendable {
    public let effectiveDate: Date
    public let prices: [ModelPrice]

    public init(effectiveDate: Date, prices: [ModelPrice]) {
        self.effectiveDate = effectiveDate
        self.prices = prices
    }

    public func price(for model: String, provider: AgentProvider) -> ModelPrice? {
        prices
            .filter { $0.provider == provider && $0.matches(model) }
            .max { lhs, rhs in
                let left = lhs.matchSpecificity(for: model) ?? 0
                let right = rhs.matchSpecificity(for: model) ?? 0
                return left < right
            }
    }

    public func contextWindow(
        for model: String,
        provider: AgentProvider,
        observedTokens: Int = 0
    ) -> Int {
        if let configured = price(for: model, provider: provider)?.contextWindow {
            return configured
        }

        switch provider {
        case .claude:
            return observedTokens > 200_000 ? 1_000_000 : 200_000
        case .codex:
            return observedTokens > 200_000 ? 400_000 : 200_000
        case .gemini:
            return 1_048_576
        }
    }

    public static let current = PricingCatalog(
        effectiveDate: ISO8601DateFormatter().date(from: "2026-07-10T00:00:00Z")!,
        prices: [
            ModelPrice(provider: .codex, canonicalModel: "gpt-5.5-pro", inputPerMillion: 30, cachedReadPerMillion: 30, outputPerMillion: 180, contextWindow: 1_050_000),
            ModelPrice(provider: .codex, canonicalModel: "gpt-5.5", inputPerMillion: 5, cachedReadPerMillion: 0.5, outputPerMillion: 30, contextWindow: 1_050_000, longContext: LongContextPrice(threshold: 272_000, inputPerMillion: 10, cachedReadPerMillion: 1, outputPerMillion: 45)),
            ModelPrice(provider: .codex, canonicalModel: "gpt-5.4-mini", inputPerMillion: 0.75, cachedReadPerMillion: 0.075, outputPerMillion: 4.5, contextWindow: 400_000),
            ModelPrice(provider: .codex, canonicalModel: "gpt-5.4", inputPerMillion: 2.5, cachedReadPerMillion: 0.25, outputPerMillion: 15, contextWindow: 1_050_000, longContext: LongContextPrice(threshold: 272_000, inputPerMillion: 5, cachedReadPerMillion: 0.5, outputPerMillion: 22.5)),
            ModelPrice(provider: .codex, canonicalModel: "gpt-5.3-codex", aliases: ["gpt-5.2"], inputPerMillion: 1.75, cachedReadPerMillion: 0.175, outputPerMillion: 14, contextWindow: 400_000),
            ModelPrice(provider: .codex, canonicalModel: "gpt-5.1-codex-mini", aliases: ["gpt-5-mini"], inputPerMillion: 0.25, cachedReadPerMillion: 0.025, outputPerMillion: 2, contextWindow: 400_000),
            ModelPrice(provider: .codex, canonicalModel: "gpt-5.1", aliases: ["gpt-5.1-codex", "gpt-5.1-codex-max", "gpt-5-codex", "gpt-5"], inputPerMillion: 1.25, cachedReadPerMillion: 0.125, outputPerMillion: 10, contextWindow: 400_000),

            ModelPrice(provider: .claude, canonicalModel: "claude-fable-5", aliases: ["claude-mythos-5"], inputPerMillion: 10, cachedReadPerMillion: 1, cacheWrite5mPerMillion: 12.5, cacheWrite1hPerMillion: 20, outputPerMillion: 50, contextWindow: 1_000_000),
            ModelPrice(provider: .claude, canonicalModel: "claude-opus-4-8", aliases: ["claude-opus-4-7", "claude-opus-4-6"], inputPerMillion: 5, cachedReadPerMillion: 0.5, cacheWrite5mPerMillion: 6.25, cacheWrite1hPerMillion: 10, outputPerMillion: 25, contextWindow: 1_000_000),
            ModelPrice(provider: .claude, canonicalModel: "claude-opus-4-5", inputPerMillion: 5, cachedReadPerMillion: 0.5, cacheWrite5mPerMillion: 6.25, cacheWrite1hPerMillion: 10, outputPerMillion: 25, contextWindow: 200_000),
            ModelPrice(provider: .claude, canonicalModel: "claude-sonnet-5", inputPerMillion: 2, cachedReadPerMillion: 0.2, cacheWrite5mPerMillion: 2.5, cacheWrite1hPerMillion: 4, outputPerMillion: 10, contextWindow: 1_000_000),
            ModelPrice(provider: .claude, canonicalModel: "claude-sonnet-4-6", inputPerMillion: 3, cachedReadPerMillion: 0.3, cacheWrite5mPerMillion: 3.75, cacheWrite1hPerMillion: 6, outputPerMillion: 15, contextWindow: 1_000_000),
            ModelPrice(provider: .claude, canonicalModel: "claude-sonnet-4-5", aliases: ["claude-sonnet-4"], inputPerMillion: 3, cachedReadPerMillion: 0.3, cacheWrite5mPerMillion: 3.75, cacheWrite1hPerMillion: 6, outputPerMillion: 15, contextWindow: 200_000),
            ModelPrice(provider: .claude, canonicalModel: "claude-haiku-4-5", inputPerMillion: 1, cachedReadPerMillion: 0.1, cacheWrite5mPerMillion: 1.25, cacheWrite1hPerMillion: 2, outputPerMillion: 5, contextWindow: 200_000),
            ModelPrice(provider: .claude, canonicalModel: "claude-3-5-haiku", inputPerMillion: 0.8, cachedReadPerMillion: 0.08, cacheWrite5mPerMillion: 1, cacheWrite1hPerMillion: 1.6, outputPerMillion: 4, contextWindow: 200_000),

            ModelPrice(provider: .gemini, canonicalModel: "gemini-2.5-pro", inputPerMillion: 1.25, cachedReadPerMillion: 0.125, outputPerMillion: 10, contextWindow: 1_048_576, longContext: LongContextPrice(threshold: 200_000, inputPerMillion: 2.5, cachedReadPerMillion: 0.25, outputPerMillion: 15)),
            ModelPrice(provider: .gemini, canonicalModel: "gemini-2.5-flash-lite", inputPerMillion: 0.1, cachedReadPerMillion: 0.01, outputPerMillion: 0.4, contextWindow: 1_048_576),
            ModelPrice(provider: .gemini, canonicalModel: "gemini-2.5-flash", inputPerMillion: 0.3, cachedReadPerMillion: 0.03, outputPerMillion: 2.5, contextWindow: 1_048_576)
        ]
    )
}
