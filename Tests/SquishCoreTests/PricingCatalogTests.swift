import XCTest
@testable import SquishCore

final class PricingCatalogTests: XCTestCase {
    func testCodexCachedTokenPricing() throws {
        let price = try XCTUnwrap(PricingCatalog.current.price(for: "gpt-5.4", provider: .codex))
        let cost = price.cost(
            usage: TokenUsage(inputTokens: 900_000, cachedReadTokens: 100_000, outputTokens: 20_000),
            currentContextTokens: 100_000
        )

        XCTAssertEqual(cost.input, 2.25, accuracy: 0.0001)
        XCTAssertEqual(cost.cacheRead, 0.025, accuracy: 0.0001)
        XCTAssertEqual(cost.output, 0.3, accuracy: 0.0001)
        XCTAssertEqual(cost.total, 2.575, accuracy: 0.0001)
    }

    func testLongContextPricingTier() throws {
        let price = try XCTUnwrap(PricingCatalog.current.price(for: "gemini-2.5-pro", provider: .gemini))
        let usage = TokenUsage(inputTokens: 1_000_000, outputTokens: 100_000)

        XCTAssertEqual(price.cost(usage: usage, currentContextTokens: 150_000).total, 2.25, accuracy: 0.0001)
        XCTAssertEqual(price.cost(usage: usage, currentContextTokens: 250_000).total, 4.0, accuracy: 0.0001)
    }

    func testSpecificAliasWinsOverBroadAlias() throws {
        let price = try XCTUnwrap(PricingCatalog.current.price(for: "gpt-5.1-codex-mini", provider: .codex))
        XCTAssertEqual(price.canonicalModel, "gpt-5.1-codex-mini")

        let gpt54 = try XCTUnwrap(PricingCatalog.current.price(for: "gpt-5.4", provider: .codex))
        XCTAssertEqual(gpt54.canonicalModel, "gpt-5.4")
    }

    func testCurrentClaudeContextWindows() throws {
        let fable5 = try XCTUnwrap(PricingCatalog.current.price(for: "claude-fable-5", provider: .claude))
        let mythos5 = try XCTUnwrap(PricingCatalog.current.price(for: "claude-mythos-5", provider: .claude))
        let opus48 = try XCTUnwrap(PricingCatalog.current.price(for: "claude-opus-4-8", provider: .claude))
        let opus45 = try XCTUnwrap(PricingCatalog.current.price(for: "claude-opus-4-5", provider: .claude))
        let sonnet46 = try XCTUnwrap(PricingCatalog.current.price(for: "claude-sonnet-4-6", provider: .claude))

        XCTAssertEqual(fable5.contextWindow, 1_000_000)
        XCTAssertEqual(mythos5.contextWindow, 1_000_000)
        XCTAssertEqual(opus48.contextWindow, 1_000_000)
        XCTAssertEqual(opus45.contextWindow, 200_000)
        XCTAssertEqual(sonnet46.contextWindow, 1_000_000)
    }

    func testFablePricingAndUnknownClaudeWindowInference() throws {
        let fable = try XCTUnwrap(PricingCatalog.current.price(for: "claude-fable-5", provider: .claude))
        let cost = fable.cost(
            usage: TokenUsage(
                inputTokens: 1_000_000,
                cachedReadTokens: 1_000_000,
                cacheWrite5mTokens: 1_000_000,
                cacheWrite1hTokens: 1_000_000,
                outputTokens: 1_000_000
            ),
            currentContextTokens: 500_000
        )

        XCTAssertEqual(cost.input, 10, accuracy: 0.0001)
        XCTAssertEqual(cost.cacheRead, 1, accuracy: 0.0001)
        XCTAssertEqual(cost.cacheWrite, 32.5, accuracy: 0.0001)
        XCTAssertEqual(cost.output, 50, accuracy: 0.0001)
        XCTAssertEqual(
            PricingCatalog.current.contextWindow(
                for: "claude-future-model",
                provider: .claude,
                observedTokens: 400_000
            ),
            1_000_000
        )
    }
}
