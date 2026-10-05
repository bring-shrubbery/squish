import Foundation
import XCTest
@testable import SquishCore

final class CodexConfigTests: XCTestCase {
    func testAddsAFeaturesTableToAConfigWithout() {
        let config = "model = \"gpt-6-astra\"\n"
        XCTAssertEqual(CodexConfig.enablingHooks(in: config), "model = \"gpt-6-astra\"\n\n[features]\nhooks = true\n")
        XCTAssertEqual(CodexConfig.enablingHooks(in: ""), "[features]\nhooks = true\n")
    }

    func testSetsTheKeyInsideAnExistingFeaturesTable() {
        let config = "model = \"x\"\n\n[features]\nweb_search = true\nhooks = false # off\n\n[mcp_servers.pencil]\ncommand = \"p\"\n"
        let result = CodexConfig.enablingHooks(in: config)
        XCTAssertEqual(result, "model = \"x\"\n\n[features]\nweb_search = true\nhooks = true\n\n[mcp_servers.pencil]\ncommand = \"p\"\n")
        XCTAssertTrue(CodexConfig.hooksEnabled(in: result!))

        let withoutKey = "[features]\nweb_search = true\n\n[other]\nhooks = false\n"
        XCTAssertEqual(CodexConfig.enablingHooks(in: withoutKey), "[features]\nhooks = true\nweb_search = true\n\n[other]\nhooks = false\n")
    }

    func testDottedKeyAndInlineTable() {
        XCTAssertEqual(CodexConfig.enablingHooks(in: "features.hooks = false\n"), "features.hooks = true\n")
        XCTAssertNil(CodexConfig.enablingHooks(in: "features = { web_search = true }\n"))
        XCTAssertTrue(CodexConfig.hooksEnabled(in: "features = { hooks = true }\n"))
    }

    func testAlreadyEnabledIsUntouched() {
        let config = "[features]\nhooks = true\n"
        XCTAssertEqual(CodexConfig.enablingHooks(in: config), config)
        XCTAssertFalse(CodexConfig.hooksEnabled(in: "[features]\nhooks = false\n"))
        XCTAssertFalse(CodexConfig.hooksEnabled(in: "[other]\nhooks = true\n"))
    }
}
