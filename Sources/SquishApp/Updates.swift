import Foundation
import Sparkle

/// In-app updates through Sparkle. The feed (`SUFeedURL`) and the public EdDSA key
/// (`SUPublicEDKey`) live in Support/Info.plist; docs/release.md explains the flow.
@MainActor
final class Updates: ObservableObject {
    /// False while a check or an install is under way; the menu item is disabled then.
    @Published private(set) var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController
    private var observation: NSKeyValueObservation?

    /// `swift run` launches a bare executable with no Info.plist, so there is no feed to read;
    /// starting the updater there would put up Sparkle's error alert.
    private static var isPackagedApp: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: Self.isPackagedApp,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        canCheckForUpdates = Self.isPackagedApp && controller.updater.canCheckForUpdates
        // Sparkle drives its updater on the main thread, so the change lands on the main actor.
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
            MainActor.assumeIsolated {
                self?.canCheckForUpdates = Self.isPackagedApp && (change.newValue ?? false)
            }
        }
    }

    /// Check for Updates…: Sparkle reports the outcome itself, including "You're up to date".
    func check() {
        controller.checkForUpdates(nil)
    }
}
