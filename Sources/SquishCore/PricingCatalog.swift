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

    /// List prices from each provider's pricing page on 5 Oct 2026. Where a page shows a
    /// promotional rate with an end date, that rate is used and noted.
    public static let current = PricingCatalog(
        effectiveDate: ISO8601DateFormatter().date(from: "2026-10-05T00:00:00Z")!,
        prices: [
            // OpenAI. Long context is a request over 272K input tokens: 2x input and cache, 1.5x output.
            ModelPrice(provider: .codex, canonicalModel: "gpt-6-astra", inputPerMillion: 10, cachedReadPerMillion: 1, outputPerMillion: 50, contextWindow: 1_050_000, longContext: LongContextPrice(threshold: 272_000, inputPerMillion: 20, cachedReadPerMillion: 2, outputPerMillion: 75)),
            ModelPrice(provider: .codex, canonicalModel: "gpt-6.1-sol", inputPerMillion: 2, cachedReadPerMillion: 0.1, outputPerMillion: 10, contextWindow: 1_050_000, longContext: LongContextPrice(threshold: 272_000, inputPerMillion: 4, cachedReadPerMillion: 0.2, outputPerMillion: 15)),
            ModelPrice(provider: .codex, canonicalModel: "gpt-6-sol", inputPerMillion: 2, cachedReadPerMillion: 0.2, outputPerMillion: 10, contextWindow: 1_050_000, longContext: LongContextPrice(threshold: 272_000, inputPerMillion: 4, cachedReadPerMillion: 0.4, outputPerMillion: 15)),
            ModelPrice(provider: .codex, canonicalModel: "gpt-6-luna", inputPerMillion: 0.1, cachedReadPerMillion: 0.01, outputPerMillion: 0.5, contextWindow: 1_050_000, longContext: LongContextPrice(threshold: 272_000, inputPerMillion: 0.2, cachedReadPerMillion: 0.02, outputPerMillion: 0.75)),
            // Promotional rate, listed as available at least through 21 Nov 2026.
            ModelPrice(provider: .codex, canonicalModel: "gpt-5.6-sol", inputPerMillion: 4, cachedReadPerMillion: 0.4, outputPerMillion: 20, contextWindow: 1_050_000, longContext: LongContextPrice(threshold: 272_000, inputPerMillion: 8, cachedReadPerMillion: 0.8, outputPerMillion: 30)),
            ModelPrice(provider: .codex, canonicalModel: "gpt-5.6-terra", inputPerMillion: 2, cachedReadPerMillion: 0.2, outputPerMillion: 12, contextWindow: 1_050_000, longContext: LongContextPrice(threshold: 272_000, inputPerMillion: 4, cachedReadPerMillion: 0.4, outputPerMillion: 18)),
            ModelPrice(provider: .codex, canonicalModel: "gpt-5.6-luna", inputPerMillion: 0.2, cachedReadPerMillion: 0.02, outputPerMillion: 1.2, contextWindow: 1_050_000, longContext: LongContextPrice(threshold: 272_000, inputPerMillion: 0.4, cachedReadPerMillion: 0.04, outputPerMillion: 1.8)),
            ModelPrice(provider: .codex, canonicalModel: "gpt-5.5-pro", inputPerMillion: 30, cachedReadPerMillion: 30, outputPerMillion: 180, contextWindow: 1_050_000, longContext: LongContextPrice(threshold: 272_000, inputPerMillion: 60, cachedReadPerMillion: 60, outputPerMillion: 270)),
            ModelPrice(provider: .codex, canonicalModel: "gpt-5.5", inputPerMillion: 5, cachedReadPerMillion: 0.5, outputPerMillion: 30, contextWindow: 1_050_000, longContext: LongContextPrice(threshold: 272_000, inputPerMillion: 10, cachedReadPerMillion: 1, outputPerMillion: 45)),
            ModelPrice(provider: .codex, canonicalModel: "gpt-5.4-pro", inputPerMillion: 30, cachedReadPerMillion: 30, outputPerMillion: 180, contextWindow: 1_050_000, longContext: LongContextPrice(threshold: 272_000, inputPerMillion: 60, cachedReadPerMillion: 60, outputPerMillion: 270)),
            ModelPrice(provider: .codex, canonicalModel: "gpt-5.4-mini", inputPerMillion: 0.75, cachedReadPerMillion: 0.075, outputPerMillion: 4.5, contextWindow: 400_000),
            ModelPrice(provider: .codex, canonicalModel: "gpt-5.4-nano", inputPerMillion: 0.2, cachedReadPerMillion: 0.02, outputPerMillion: 1.25, contextWindow: 400_000),
            ModelPrice(provider: .codex, canonicalModel: "gpt-5.4", inputPerMillion: 2.5, cachedReadPerMillion: 0.25, outputPerMillion: 15, contextWindow: 1_050_000, longContext: LongContextPrice(threshold: 272_000, inputPerMillion: 5, cachedReadPerMillion: 0.5, outputPerMillion: 22.5)),
            ModelPrice(provider: .codex, canonicalModel: "gpt-5.3-codex", inputPerMillion: 1.75, cachedReadPerMillion: 0.175, outputPerMillion: 14, contextWindow: 400_000),
            ModelPrice(provider: .codex, canonicalModel: "gpt-5.2-pro", inputPerMillion: 21, cachedReadPerMillion: 21, outputPerMillion: 168, contextWindow: 400_000),
            ModelPrice(provider: .codex, canonicalModel: "gpt-5.2", inputPerMillion: 1.75, cachedReadPerMillion: 0.175, outputPerMillion: 14, contextWindow: 400_000),
            ModelPrice(provider: .codex, canonicalModel: "gpt-5.1-codex-mini", aliases: ["gpt-5-mini"], inputPerMillion: 0.25, cachedReadPerMillion: 0.025, outputPerMillion: 2, contextWindow: 400_000),
            ModelPrice(provider: .codex, canonicalModel: "gpt-5-pro", inputPerMillion: 15, cachedReadPerMillion: 15, outputPerMillion: 120, contextWindow: 400_000),
            ModelPrice(provider: .codex, canonicalModel: "gpt-5-nano", inputPerMillion: 0.05, cachedReadPerMillion: 0.005, outputPerMillion: 0.4, contextWindow: 400_000),
            ModelPrice(provider: .codex, canonicalModel: "gpt-5.1", aliases: ["gpt-5.1-codex", "gpt-5.1-codex-max", "gpt-5-codex", "gpt-5"], inputPerMillion: 1.25, cachedReadPerMillion: 0.125, outputPerMillion: 10, contextWindow: 400_000),

            // Anthropic. Cache reads are 10% of input, except 2.5% on Fable/Mythos 5.1 and 5% on Opus 5.5.
            ModelPrice(provider: .claude, canonicalModel: "claude-fable-5-1", aliases: ["claude-mythos-5-1"], inputPerMillion: 10, cachedReadPerMillion: 0.25, cacheWrite5mPerMillion: 12.5, cacheWrite1hPerMillion: 20, outputPerMillion: 50, contextWindow: 1_000_000),
            ModelPrice(provider: .claude, canonicalModel: "claude-fable-5", aliases: ["claude-mythos-5"], inputPerMillion: 10, cachedReadPerMillion: 1, cacheWrite5mPerMillion: 12.5, cacheWrite1hPerMillion: 20, outputPerMillion: 50, contextWindow: 1_000_000),
            ModelPrice(provider: .claude, canonicalModel: "claude-opus-5-5", inputPerMillion: 4, cachedReadPerMillion: 0.2, cacheWrite5mPerMillion: 5, cacheWrite1hPerMillion: 8, outputPerMillion: 20, contextWindow: 1_000_000),
            ModelPrice(provider: .claude, canonicalModel: "claude-opus-5", inputPerMillion: 5, cachedReadPerMillion: 0.5, cacheWrite5mPerMillion: 6.25, cacheWrite1hPerMillion: 10, outputPerMillion: 25, contextWindow: 1_000_000),
            ModelPrice(provider: .claude, canonicalModel: "claude-opus-4-8", aliases: ["claude-opus-4-7", "claude-opus-4-6"], inputPerMillion: 5, cachedReadPerMillion: 0.5, cacheWrite5mPerMillion: 6.25, cacheWrite1hPerMillion: 10, outputPerMillion: 25, contextWindow: 1_000_000),
            ModelPrice(provider: .claude, canonicalModel: "claude-opus-4-5", inputPerMillion: 5, cachedReadPerMillion: 0.5, cacheWrite5mPerMillion: 6.25, cacheWrite1hPerMillion: 10, outputPerMillion: 25, contextWindow: 200_000),
            ModelPrice(provider: .claude, canonicalModel: "claude-sonnet-5-5", inputPerMillion: 2, cachedReadPerMillion: 0.2, cacheWrite5mPerMillion: 2.5, cacheWrite1hPerMillion: 4, outputPerMillion: 10, contextWindow: 1_000_000),
            ModelPrice(provider: .claude, canonicalModel: "claude-sonnet-5", inputPerMillion: 2, cachedReadPerMillion: 0.2, cacheWrite5mPerMillion: 2.5, cacheWrite1hPerMillion: 4, outputPerMillion: 10, contextWindow: 1_000_000),
            ModelPrice(provider: .claude, canonicalModel: "claude-sonnet-4-6", inputPerMillion: 3, cachedReadPerMillion: 0.3, cacheWrite5mPerMillion: 3.75, cacheWrite1hPerMillion: 6, outputPerMillion: 15, contextWindow: 1_000_000),
            ModelPrice(provider: .claude, canonicalModel: "claude-sonnet-4-5", aliases: ["claude-sonnet-4"], inputPerMillion: 3, cachedReadPerMillion: 0.3, cacheWrite5mPerMillion: 3.75, cacheWrite1hPerMillion: 6, outputPerMillion: 15, contextWindow: 200_000),
            ModelPrice(provider: .claude, canonicalModel: "claude-haiku-4-5", inputPerMillion: 1, cachedReadPerMillion: 0.1, cacheWrite5mPerMillion: 1.25, cacheWrite1hPerMillion: 2, outputPerMillion: 5, contextWindow: 200_000),
            ModelPrice(provider: .claude, canonicalModel: "claude-3-5-haiku", inputPerMillion: 0.8, cachedReadPerMillion: 0.08, cacheWrite5mPerMillion: 1, cacheWrite1hPerMillion: 1.6, outputPerMillion: 4, contextWindow: 200_000),

            // Google. Long context is a request over 200K tokens.
            // Gemini 3.6, 3.7 and 3.8 Flash are at a promotional rate through 31 Dec 2026 ($1.50 / $0.15 / $7.50 after).
            ModelPrice(provider: .gemini, canonicalModel: "gemini-3.8-flash", inputPerMillion: 0.75, cachedReadPerMillion: 0.075, outputPerMillion: 3.75, contextWindow: 1_048_576),
            ModelPrice(provider: .gemini, canonicalModel: "gemini-3.7-flash", inputPerMillion: 0.75, cachedReadPerMillion: 0.075, outputPerMillion: 3.75, contextWindow: 1_048_576),
            ModelPrice(provider: .gemini, canonicalModel: "gemini-3.6-flash", inputPerMillion: 0.75, cachedReadPerMillion: 0.075, outputPerMillion: 3.75, contextWindow: 1_048_576),
            ModelPrice(provider: .gemini, canonicalModel: "gemini-3.5-flash-lite", inputPerMillion: 0.3, cachedReadPerMillion: 0.03, outputPerMillion: 2.5, contextWindow: 1_048_576),
            ModelPrice(provider: .gemini, canonicalModel: "gemini-3.5-flash", inputPerMillion: 1.5, cachedReadPerMillion: 0.15, outputPerMillion: 9, contextWindow: 1_048_576),
            ModelPrice(provider: .gemini, canonicalModel: "gemini-3.1-pro", aliases: ["gemini-3.1-pro-preview"], inputPerMillion: 2, cachedReadPerMillion: 0.2, outputPerMillion: 12, contextWindow: 1_048_576, longContext: LongContextPrice(threshold: 200_000, inputPerMillion: 4, cachedReadPerMillion: 0.4, outputPerMillion: 18)),
            ModelPrice(provider: .gemini, canonicalModel: "gemini-3.1-flash-lite", inputPerMillion: 0.25, cachedReadPerMillion: 0.025, outputPerMillion: 1.5, contextWindow: 1_048_576),
            ModelPrice(provider: .gemini, canonicalModel: "gemini-2.5-pro", inputPerMillion: 1.25, cachedReadPerMillion: 0.125, outputPerMillion: 10, contextWindow: 1_048_576, longContext: LongContextPrice(threshold: 200_000, inputPerMillion: 2.5, cachedReadPerMillion: 0.25, outputPerMillion: 15)),
            ModelPrice(provider: .gemini, canonicalModel: "gemini-2.5-flash-lite", inputPerMillion: 0.1, cachedReadPerMillion: 0.01, outputPerMillion: 0.4, contextWindow: 1_048_576),
            ModelPrice(provider: .gemini, canonicalModel: "gemini-2.5-flash", inputPerMillion: 0.3, cachedReadPerMillion: 0.03, outputPerMillion: 2.5, contextWindow: 1_048_576)
        ]
    )
}
