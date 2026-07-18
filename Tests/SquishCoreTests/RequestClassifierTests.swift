import Foundation
import XCTest
@testable import SquishCore

final class RequestClassifierTests: XCTestCase {
    func testBashIsPermissionWithCommandSummary() {
        let c = RequestClassifier.classify(toolName: "Bash", toolInput: ["command": "rm -rf build/"])
        XCTAssertEqual(c.kind, .permission)
        XCTAssertEqual(c.summary, "rm -rf build/")
        XCTAssertNil(c.options)
    }

    func testWriteUsesFilePath() {
        let c = RequestClassifier.classify(toolName: "Write", toolInput: ["file_path": "/etc/hosts", "content": "x"])
        XCTAssertEqual(c.kind, .permission)
        XCTAssertEqual(c.summary, "/etc/hosts")
    }

    func testAskUserQuestionIsQuestionWithOptions() {
        let input: [String: Any] = ["questions": [[
            "header": "Live demo",
            "question": "How do you want to see the notch?",
            "multiSelect": false,
            "options": [
                ["label": "I'll drive it myself", "description": "..."],
                ["label": "Demo it for me", "description": "..."]
            ]
        ]]]
        let c = RequestClassifier.classify(toolName: "AskUserQuestion", toolInput: input)
        XCTAssertEqual(c.kind, .question)
        XCTAssertEqual(c.summary, "How do you want to see the notch?")
        XCTAssertEqual(c.options, ["I'll drive it myself", "Demo it for me"])
    }

    func testMultipleQuestionsAnnotatesCount() {
        let input: [String: Any] = ["questions": [
            ["question": "First?", "options": [["label": "A"]]],
            ["question": "Second?", "options": [["label": "B"]]]
        ]]
        let c = RequestClassifier.classify(toolName: "AskUserQuestion", toolInput: input)
        XCTAssertEqual(c.kind, .question)
        XCTAssertEqual(c.summary, "First? (+1 more)")
        XCTAssertEqual(c.options, ["A"])
    }

    func testAskUserQuestionFallbackWhenMalformed() {
        let c = RequestClassifier.classify(toolName: "AskUserQuestion", toolInput: [:])
        XCTAssertEqual(c.kind, .question)
        XCTAssertEqual(c.summary, "Question")
        XCTAssertNil(c.options)
    }
}
