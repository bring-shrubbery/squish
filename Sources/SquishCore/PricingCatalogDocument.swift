import CryptoKit
import Foundation

/// The catalog as JSON: what the release workflow publishes next to the app and what the app
/// downloads, so new models get priced without an update. Field names are stable; add new
/// ones as optionals so older apps keep reading newer files.
public struct PricingCatalogDocument: Codable, Equatable, Sendable {
    public static let formatVersion = 1

    public struct LongContext: Codable, Equatable, Sendable {
        public var threshold: Int
        public var inputPerMillion: Double
        public var cachedReadPerMillion: Double
        public var outputPerMillion: Double
    }

    public struct Price: Codable, Equatable, Sendable {
        public var provider: AgentProvider
        public var model: String
        public var aliases: [String]?
        public var inputPerMillion: Double
        public var cachedReadPerMillion: Double
        public var cacheWrite5mPerMillion: Double?
        public var cacheWrite1hPerMillion: Double?
        public var outputPerMillion: Double
        public var contextWindow: Int
        public var longContext: LongContext?
    }

    public var formatVersion: Int
    public var effectiveDate: Date
    public var prices: [Price]

    public init(catalog: PricingCatalog) {
        formatVersion = Self.formatVersion
        effectiveDate = catalog.effectiveDate
        prices = catalog.prices.map { price in
            Price(
                provider: price.provider,
                model: price.canonicalModel,
                aliases: price.aliases.isEmpty ? nil : price.aliases,
                inputPerMillion: price.inputPerMillion,
                cachedReadPerMillion: price.cachedReadPerMillion,
                cacheWrite5mPerMillion: price.cacheWrite5mPerMillion == price.inputPerMillion ? nil : price.cacheWrite5mPerMillion,
                cacheWrite1hPerMillion: price.cacheWrite1hPerMillion == price.inputPerMillion ? nil : price.cacheWrite1hPerMillion,
                outputPerMillion: price.outputPerMillion,
                contextWindow: price.contextWindow,
                longContext: price.longContext.map {
                    LongContext(
                        threshold: $0.threshold,
                        inputPerMillion: $0.inputPerMillion,
                        cachedReadPerMillion: $0.cachedReadPerMillion,
                        outputPerMillion: $0.outputPerMillion
                    )
                }
            )
        }
    }

    public var catalog: PricingCatalog {
        PricingCatalog(
            effectiveDate: effectiveDate,
            prices: prices.map { price in
                ModelPrice(
                    provider: price.provider,
                    canonicalModel: price.model,
                    aliases: price.aliases ?? [],
                    inputPerMillion: price.inputPerMillion,
                    cachedReadPerMillion: price.cachedReadPerMillion,
                    cacheWrite5mPerMillion: price.cacheWrite5mPerMillion,
                    cacheWrite1hPerMillion: price.cacheWrite1hPerMillion,
                    outputPerMillion: price.outputPerMillion,
                    contextWindow: price.contextWindow,
                    longContext: price.longContext.map {
                        LongContextPrice(
                            threshold: $0.threshold,
                            inputPerMillion: $0.inputPerMillion,
                            cachedReadPerMillion: $0.cachedReadPerMillion,
                            outputPerMillion: $0.outputPerMillion
                        )
                    }
                )
            }
        )
    }

    /// Pretty, sorted, ISO 8601 dates: the same catalog always produces the same bytes, so a
    /// signature stays valid across builds.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> PricingCatalogDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(PricingCatalogDocument.self, from: data)
        guard document.formatVersion == formatVersion else { throw PricingCatalogDocumentError.unsupportedFormat }
        guard !document.prices.isEmpty, document.prices.allSatisfy(\.isSane) else {
            throw PricingCatalogDocumentError.invalidPrice
        }
        return document
    }
}

public enum PricingCatalogDocumentError: Error, Equatable {
    case unsupportedFormat
    case invalidPrice
    case badSignature
}

private extension PricingCatalogDocument.Price {
    var isSane: Bool {
        let rates = [inputPerMillion, cachedReadPerMillion, outputPerMillion, cacheWrite5mPerMillion ?? 0, cacheWrite1hPerMillion ?? 0]
        return !model.isEmpty && contextWindow > 0 && rates.allSatisfy { $0.isFinite && $0 >= 0 && $0 < 100_000 }
    }
}

/// Signed catalogs: the release workflow signs `pricing.json` with the same Ed25519 key that
/// signs app updates, and the app checks the signature against the public key in its
/// Info.plist (`SUPublicEDKey`) before trusting a downloaded file.
public enum PricingCatalogSignature {
    /// Decodes and verifies; `signature` is the base64 text `sign_update` prints.
    public static func verifiedDocument(
        data: Data,
        signature: String,
        publicKeyBase64: String
    ) throws -> PricingCatalogDocument {
        let trimmed = signature.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let signatureBytes = Data(base64Encoded: trimmed),
              let keyBytes = Data(base64Encoded: publicKeyBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes),
              key.isValidSignature(signatureBytes, for: data)
        else { throw PricingCatalogDocumentError.badSignature }
        return try PricingCatalogDocument.decode(data)
    }
}

/// The last verified download, kept on disk so a launch without network still prices with it.
public struct PricingCatalogCache: Sendable {
    public let directory: URL?

    public init(directory: URL?) {
        self.directory = directory
    }

    public static func defaultDirectory(fileManager: FileManager = .default) -> URL? {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Squish", isDirectory: true)
            .appendingPathComponent("pricing", isDirectory: true)
    }

    private var documentURL: URL? { directory?.appendingPathComponent("pricing.json") }
    private var signatureURL: URL? { directory?.appendingPathComponent("pricing.json.sig") }

    /// The cached catalog, re-verified against the key so a tampered cache is ignored too.
    public func load(publicKeyBase64: String) -> PricingCatalogDocument? {
        guard let documentURL, let signatureURL,
              let data = try? Data(contentsOf: documentURL),
              let signature = try? String(contentsOf: signatureURL, encoding: .utf8)
        else { return nil }
        return try? PricingCatalogSignature.verifiedDocument(data: data, signature: signature, publicKeyBase64: publicKeyBase64)
    }

    public func save(data: Data, signature: String) throws {
        guard let directory, let documentURL, let signatureURL else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: documentURL, options: .atomic)
        try signature.write(to: signatureURL, atomically: true, encoding: .utf8)
    }
}
