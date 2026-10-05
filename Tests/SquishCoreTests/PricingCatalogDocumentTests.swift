import CryptoKit
import Foundation
import XCTest
@testable import SquishCore

final class PricingCatalogDocumentTests: XCTestCase {
    func testBundledCatalogRoundTripsThroughJSON() throws {
        let document = PricingCatalogDocument(catalog: .bundled)
        let data = try document.encoded()
        let decoded = try PricingCatalogDocument.decode(data)
        XCTAssertEqual(decoded, document)
        XCTAssertEqual(decoded.catalog, PricingCatalog.bundled)
        // Deterministic bytes: the signature made in CI stays valid for the same catalog.
        XCTAssertEqual(try decoded.encoded(), data)
    }

    func testSignatureIsCheckedBeforeTheDocumentIsTrusted() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let data = try PricingCatalogDocument(catalog: .bundled).encoded()
        let signature = try key.signature(for: data).base64EncodedString()

        let verified = try PricingCatalogSignature.verifiedDocument(
            data: data, signature: signature + "\n", publicKeyBase64: publicKey
        )
        XCTAssertEqual(verified.catalog, PricingCatalog.bundled)

        var tampered = data
        tampered.append(Data(" ".utf8))
        XCTAssertThrowsError(try PricingCatalogSignature.verifiedDocument(
            data: tampered, signature: signature, publicKeyBase64: publicKey
        )) { XCTAssertEqual($0 as? PricingCatalogDocumentError, .badSignature) }

        let otherKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        XCTAssertThrowsError(try PricingCatalogSignature.verifiedDocument(
            data: data, signature: signature, publicKeyBase64: otherKey
        ))
    }

    func testMalformedDocumentsAreRejected() throws {
        var document = PricingCatalogDocument(catalog: .bundled)
        document.formatVersion = 99
        XCTAssertThrowsError(try PricingCatalogDocument.decode(try document.encoded())) {
            XCTAssertEqual($0 as? PricingCatalogDocumentError, .unsupportedFormat)
        }

        document = PricingCatalogDocument(catalog: .bundled)
        document.prices[0].inputPerMillion = -1
        XCTAssertThrowsError(try PricingCatalogDocument.decode(try document.encoded())) {
            XCTAssertEqual($0 as? PricingCatalogDocumentError, .invalidPrice)
        }
    }

    func testCacheStoresAndReverifies() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("squish-pricing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let data = try PricingCatalogDocument(catalog: .bundled).encoded()
        let signature = try key.signature(for: data).base64EncodedString()

        let cache = PricingCatalogCache(directory: directory)
        XCTAssertNil(cache.load(publicKeyBase64: publicKey))
        try cache.save(data: data, signature: signature)
        XCTAssertEqual(cache.load(publicKeyBase64: publicKey)?.catalog, PricingCatalog.bundled)
        XCTAssertNil(cache.load(publicKeyBase64: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()))
    }

    func testActivatedCatalogBecomesCurrentUntilCleared() {
        defer { PricingCatalog.activate(nil) }
        let newer = PricingCatalog(
            effectiveDate: PricingCatalog.bundled.effectiveDate.addingTimeInterval(86_400),
            prices: [ModelPrice(provider: .codex, canonicalModel: "codex-auto-review", inputPerMillion: 1, cachedReadPerMillion: 0.1, outputPerMillion: 4, contextWindow: 400_000)]
        )
        XCTAssertNil(PricingCatalog.current.price(for: "codex-auto-review", provider: .codex))
        PricingCatalog.activate(newer)
        XCTAssertNotNil(PricingCatalog.current.price(for: "codex-auto-review", provider: .codex))
        XCTAssertEqual(PricingCatalog.current.effectiveDate, newer.effectiveDate)
        PricingCatalog.activate(nil)
        XCTAssertEqual(PricingCatalog.current, PricingCatalog.bundled)
    }
}
