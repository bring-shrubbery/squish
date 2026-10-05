import Foundation
import SquishCore

/// Keeps the pricing catalog current without an app update: at launch and every few hours it
/// downloads the catalog the latest release published, checks its signature against the
/// update key in Info.plist, and activates it when it is newer than the one in use. The last
/// good download is cached, so an offline launch still has it.
@MainActor
final class PricingUpdater {
    struct Status: Equatable {
        /// The catalog in use.
        var effectiveDate: Date
        /// Where it came from.
        var source: Source
        var lastCheck: Date?

        enum Source: Equatable {
            case bundled
            case downloaded
        }
    }

    private(set) var status: Status
    /// Called after a newer catalog has been activated, so the ledger can be re-priced.
    var onCatalogChange: (() -> Void)?

    private let documentURL: URL
    private let signatureURL: URL
    private let publicKey: String?
    private let cache: PricingCatalogCache
    private var timer: Timer?
    private var checkTask: Task<Void, Never>?

    static let checkInterval: TimeInterval = 6 * 60 * 60

    init(
        documentURL: URL = URL(string: "https://squish.quassum.com/pricing.json")!,
        signatureURL: URL = URL(string: "https://squish.quassum.com/pricing.json.sig")!,
        publicKey: String? = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
        cache: PricingCatalogCache = PricingCatalogCache(directory: PricingCatalogCache.defaultDirectory())
    ) {
        #if DEBUG
        // For trying the download against a local server with a test key.
        let environment = ProcessInfo.processInfo.environment
        if let base = environment["SQUISH_PRICING_URL"].flatMap(URL.init(string:)) {
            self.documentURL = base
            self.signatureURL = URL(string: base.absoluteString + ".sig")!
        } else {
            self.documentURL = documentURL
            self.signatureURL = signatureURL
        }
        self.publicKey = environment["SQUISH_PRICING_KEY"] ?? publicKey
        #else
        self.documentURL = documentURL
        self.signatureURL = signatureURL
        self.publicKey = publicKey
        #endif
        self.cache = cache
        status = Status(effectiveDate: PricingCatalog.bundled.effectiveDate, source: .bundled, lastCheck: nil)
    }

    /// Activates the cached download if it is newer than the bundled catalog, then starts
    /// checking for newer ones. Without a public key (`swift run`) nothing is downloaded.
    func start() {
        guard let publicKey else { return }
        if let cached = cache.load(publicKeyBase64: publicKey) {
            activateIfNewer(cached.catalog, source: .downloaded)
        }
        check()
        let timer = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func check() {
        guard let publicKey, checkTask == nil else { return }
        let documentURL = documentURL
        let signatureURL = signatureURL
        checkTask = Task { [weak self] in
            defer { Task { @MainActor [weak self] in self?.checkTask = nil } }
            guard let download = await Self.download(documentURL: documentURL, signatureURL: signatureURL) else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                status.lastCheck = Date()
                guard let document = try? PricingCatalogSignature.verifiedDocument(
                    data: download.data, signature: download.signature, publicKeyBase64: publicKey
                ) else { return }
                if activateIfNewer(document.catalog, source: .downloaded) {
                    try? cache.save(data: download.data, signature: download.signature)
                }
            }
        }
    }

    @discardableResult
    private func activateIfNewer(_ catalog: PricingCatalog, source: Status.Source) -> Bool {
        guard catalog.effectiveDate > PricingCatalog.current.effectiveDate else { return false }
        PricingCatalog.activate(catalog)
        status.effectiveDate = catalog.effectiveDate
        status.source = source
        onCatalogChange?()
        return true
    }

    private static func download(documentURL: URL, signatureURL: URL) async -> (data: Data, signature: String)? {
        var request = URLRequest(url: documentURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("Squish", forHTTPHeaderField: "User-Agent")
        var signatureRequest = URLRequest(url: signatureURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        signatureRequest.setValue("Squish", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              data.count < 2_000_000,
              let (signatureData, signatureResponse) = try? await URLSession.shared.data(for: signatureRequest),
              (signatureResponse as? HTTPURLResponse)?.statusCode == 200,
              let signature = String(data: signatureData, encoding: .utf8)
        else { return nil }
        return (data, signature)
    }
}
