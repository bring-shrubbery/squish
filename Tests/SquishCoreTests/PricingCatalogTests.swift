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
        let opus48 = try XCTUnwrap(PricingCatalog.current.price(for: "claude-opus-4-8", provider: .claude))
        let opus45 = try XCTUnwrap(PricingCatalog.current.price(for: "claude-opus-4-5", provider: .claude))
        let sonnet46 = try XCTUnwrap(PricingCatalog.current.price(for: "claude-sonnet-4-6", provider: .claude))

        XCTAssertEqual(opus48.contextWindow, 1_000_000)
        XCTAssertEqual(opus45.contextWindow, 200_000)
        XCTAssertEqual(sonnet46.contextWindow, 1_000_000)
    }
}
