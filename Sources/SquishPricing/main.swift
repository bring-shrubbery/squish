import Foundation
import SquishCore

// squish-pricing: prints the bundled pricing catalog as the JSON the app downloads.
//
// The release workflow runs it, signs the output with the update key and publishes
// pricing.json and pricing.json.sig next to the app, so every installed copy, updated or
// not, prices the models this build knows about.

do {
    let data = try PricingCatalogDocument(catalog: .bundled).encoded()
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("squish-pricing: \(error)\n".utf8))
    exit(1)
}
