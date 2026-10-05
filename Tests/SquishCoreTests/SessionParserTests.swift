import Foundation
import XCTest
@testable import SquishCore

final class SessionParserTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var projectDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        projectDirectory = temporaryDirectory.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testCodexParserReadsProjectUsageAndContext() throws {
        let file = temporaryDirectory.appendingPathComponent("codex.jsonl")
        try writeJSONLines([
            [
                "timestamp": "2026-07-10T10:00:00Z",
                "type": "session_meta",
                "payload": [
                    "id": "session-1",
                    "cwd": projectDirectory.path,
                    "source": "cli",
                    "context_window": 2_000
                ]
            ],
            [
                "timestamp": "2026-07-10T10:01:00Z",
                "type": "turn_context",
                "payload": ["model": "gpt-5.4", "cwd": projectDirectory.path]
            ],
            [
                "timestamp": "2026-07-10T10:01:10Z",
                "type": "event_msg",
                "payload": ["type": "user_message", "message": "Fix the session scanner"]
            ],
            [
                "timestamp": "2026-07-10T10:02:00Z",
                "type": "event_msg",
                "payload": [
                    "type": "token_count",
                    "info": [
                        "model_context_window": 2_000,
                        "total_token_usage": [
                            "input_tokens": 1_000,
                            "cached_input_tokens": 100,
                            "output_tokens": 200
                        ],
                        "last_token_usage": ["input_tokens": 950, "output_tokens": 50]
                    ]
                ]
            ]
        ], to: file)

        let session = try XCTUnwrap(CodexSessionParser().parse(url: file, projectRoot: temporaryDirectory))
        XCTAssertEqual(session.id, "codex:session-1")
        XCTAssertEqual(session.title, "Fix the session scanner")
        XCTAssertEqual(session.model, "gpt-5.4")
        XCTAssertEqual(session.usage.inputTokens, 900)
        XCTAssertEqual(session.usage.cachedReadTokens, 100)
        XCTAssertEqual(session.usage.outputTokens, 200)
        XCTAssertEqual(session.contextTokens, 950)
        XCTAssertEqual(session.contextWindow, 2_000)
        XCTAssertEqual(
            session.lastUserMessageAt,
            ISO8601DateFormatter().date(from: "2026-07-10T10:01:10Z")
        )
    }

    func testClaudeParserSeparatesCacheWriteDurations() throws {
        let file = temporaryDirectory.appendingPathComponent("claude.jsonl")
        try writeJSONLines([
            [
                "timestamp": "2026-07-10T10:00:00Z",
                "type": "user",
                "sessionId": "session-2",
                "cwd": projectDirectory.path,
                "message": ["role": "user", "content": "Add compact alerts"]
            ],
            [
                "timestamp": "2026-07-10T10:01:00Z",
                "type": "assistant",
                "sessionId": "session-2",
                "cwd": projectDirectory.path,
                "message": [
                    "model": "claude-opus-4-8",
                    "usage": [
                        "input_tokens": 20,
                        "cache_read_input_tokens": 800,
                        "cache_creation_input_tokens": 150,
                        "output_tokens": 30,
                        "cache_creation": [
                            "ephemeral_5m_input_tokens": 100,
                            "ephemeral_1h_input_tokens": 50
                        ]
                    ]
                ]
            ]
        ], to: file)

        let session = try XCTUnwrap(ClaudeSessionParser().parse(url: file, projectRoot: temporaryDirectory))
        XCTAssertEqual(session.id, "claude:session-2")
        XCTAssertEqual(session.title, "Add compact alerts")
        XCTAssertEqual(session.usage.inputTokens, 20)
        XCTAssertEqual(session.usage.cachedReadTokens, 800)
        XCTAssertEqual(session.usage.cacheWrite5mTokens, 100)
        XCTAssertEqual(session.usage.cacheWrite1hTokens, 50)
        XCTAssertEqual(session.usage.outputTokens, 30)
        XCTAssertEqual(session.contextTokens, 1_000)
        XCTAssertEqual(
            session.lastUserMessageAt,
            ISO8601DateFormatter().date(from: "2026-07-10T10:00:00Z")
        )
    }

    func testClaudeParserIgnoresSyntheticPlaceholderModel() throws {
        let file = temporaryDirectory.appendingPathComponent("claude-synthetic.jsonl")
        let real: [String: Any] = [
            "timestamp": "2026-07-10T10:01:00Z", "type": "assistant", "sessionId": "session-s",
            "cwd": projectDirectory.path,
            "message": ["model": "claude-opus-5", "usage": ["input_tokens": 20, "output_tokens": 30]]
        ]
        let synthetic: [String: Any] = [
            "timestamp": "2026-07-10T10:02:00Z", "type": "assistant", "sessionId": "session-s",
            "cwd": projectDirectory.path,
            "message": ["model": "<synthetic>", "usage": ["input_tokens": 0, "output_tokens": 0]]
        ]
        try writeJSONLines([real, synthetic], to: file)
        let session = try XCTUnwrap(ClaudeSessionParser().parse(url: file, projectRoot: temporaryDirectory))
        XCTAssertEqual(session.model, "claude-opus-5")

        // Only placeholders: no model, no tokens, and so a known cost of nothing.
        let empty = temporaryDirectory.appendingPathComponent("claude-empty.jsonl")
        try writeJSONLines([synthetic], to: empty)
        let emptySession = try XCTUnwrap(ClaudeSessionParser().parse(url: empty, projectRoot: temporaryDirectory))
        XCTAssertEqual(emptySession.model, "Unreported model")
        XCTAssertEqual(emptySession.cost(), .zero)
    }

    func testClaudeParserSkipsInjectedCommandMessagesForTitle() throws {
        let file = temporaryDirectory.appendingPathComponent("claude-caveat.jsonl")
        try writeJSONLines([
            [
                "type": "user",
                "sessionId": "session-caveat",
                "cwd": projectDirectory.path,
                "message": [
                    "role": "user",
                    "content": "<local-command-caveat>Ignore local commands</local-command-caveat>"
                ]
            ],
            [
                "type": "user",
                "sessionId": "session-caveat",
                "cwd": projectDirectory.path,
                "message": [
                    "role": "user",
                    "content": "Fix the real session title"
                ]
            ]
        ], to: file)

        let session = try XCTUnwrap(ClaudeSessionParser().parse(url: file, projectRoot: temporaryDirectory))
        XCTAssertEqual(session.title, "Fix the real session title")
        XCTAssertFalse(session.isSubagent)
    }

    func testClaudeFableSessionUsesMillionTokenContextWindow() throws {
        let file = temporaryDirectory.appendingPathComponent("claude-fable.jsonl")
        try writeJSONLines([
            [
                "type": "user",
                "sessionId": "fable-session",
                "cwd": projectDirectory.path,
                "message": ["role": "user", "content": "Analyze the long conversation"]
            ],
            [
                "type": "assistant",
                "sessionId": "fable-session",
                "cwd": projectDirectory.path,
                "message": [
                    "model": "claude-fable-5",
                    "usage": [
                        "input_tokens": 100_000,
                        "cache_read_input_tokens": 300_000,
                        "cache_creation_input_tokens": 80_000,
                        "output_tokens": 20_000
                    ]
                ]
            ]
        ], to: file)

        let session = try XCTUnwrap(ClaudeSessionParser().parse(url: file, projectRoot: temporaryDirectory))
        XCTAssertEqual(session.contextTokens, 500_000)
        XCTAssertEqual(session.contextWindow, 1_000_000)
        XCTAssertEqual(session.contextFraction, 0.5, accuracy: 0.0001)
    }

    func testClaudeParserMarksSidechainForCostButNotCompactAlerts() throws {
        let file = temporaryDirectory.appendingPathComponent("claude-sidechain.jsonl")
        try writeJSONLines([
            [
                "type": "user",
                "sessionId": "sidechain",
                "cwd": projectDirectory.path,
                "isSidechain": true,
                "agentId": "agent-123",
                "message": ["role": "user", "content": "Investigate this in parallel"]
            ],
            [
                "type": "assistant",
                "sessionId": "sidechain",
                "cwd": projectDirectory.path,
                "isSidechain": true,
                "agentId": "agent-123",
                "message": [
                    "model": "claude-opus-4-8",
                    "usage": ["input_tokens": 100, "output_tokens": 25]
                ]
            ]
        ], to: file)

        let session = try XCTUnwrap(ClaudeSessionParser().parse(url: file, projectRoot: temporaryDirectory))
        XCTAssertEqual(session.id, "claude:subagent:agent-123")
        XCTAssertTrue(session.isSubagent)
        XCTAssertEqual(session.usage.totalTokens, 125)
    }

    func testCodexParserMarksSubagentSourceForCostButNotCompactAlerts() throws {
        let file = temporaryDirectory.appendingPathComponent("codex-subagent.jsonl")
        try writeJSONLines([
            [
                "timestamp": "2026-07-10T10:00:00Z",
                "type": "session_meta",
                "payload": [
                    "id": "codex-subagent",
                    "cwd": projectDirectory.path,
                    "source": [
                        "subagent": [
                            "thread_spawn": ["parent_thread_id": "parent-session", "depth": 1]
                        ]
                    ]
                ]
            ],
            codexTokenEvent(input: 500, cached: 100, output: 50, context: 450)
        ], to: file)

        let session = try XCTUnwrap(CodexSessionParser().parse(url: file, projectRoot: temporaryDirectory))
        XCTAssertTrue(session.isSubagent)
        XCTAssertEqual(session.usage.totalTokens, 550)
    }

    func testScannerIncludesSubagentUsageForCostAccounting() async throws {
        let sessionDirectory = projectDirectory.appendingPathComponent(".claude/session", isDirectory: true)
        let subagentDirectory = projectDirectory
            .appendingPathComponent(".claude/session/subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagentDirectory, withIntermediateDirectories: true)
        let mainFile = sessionDirectory.appendingPathComponent("main.jsonl")
        try writeJSONLines([
            [
                "type": "user",
                "sessionId": "agent-session",
                "cwd": projectDirectory.path,
                "message": ["role": "user", "content": "Coordinate the main session"]
            ]
        ], to: mainFile)
        let file = subagentDirectory.appendingPathComponent("agent-123.jsonl")
        try writeJSONLines([
            [
                "type": "assistant",
                "sessionId": "agent-session",
                "cwd": projectDirectory.path,
                "isSidechain": true,
                "agentId": "agent-123",
                "message": [
                    "model": "claude-opus-4-8",
                    "usage": ["input_tokens": 80, "output_tokens": 20]
                ]
            ]
        ], to: file)

        let sessions = await testScanner().scan(projectRoot: projectDirectory)
        let subagent = try XCTUnwrap(
            sessions.first(where: { $0.id == "claude:subagent:agent-123" })
        )
        XCTAssertTrue(subagent.isSubagent)
        XCTAssertEqual(subagent.usage.totalTokens, 100)
        XCTAssertTrue(sessions.contains { $0.id == "claude:agent-session" && !$0.isSubagent })
        XCTAssertEqual(Set(sessions.map(\.id)).count, sessions.count)
    }

    func testParserExcludesSessionOutsideSelectedFolder() throws {
        let outside = temporaryDirectory.appendingPathComponent("outside")
        let file = temporaryDirectory.appendingPathComponent("outside.jsonl")
        try writeJSONLines([
            [
                "type": "session_meta",
                "payload": ["id": "other", "cwd": outside.path]
            ]
        ], to: file)

        XCTAssertNil(try CodexSessionParser().parse(url: file, projectRoot: projectDirectory))
    }

    func testScannerFindsSessionInNestedProject() async throws {
        let nestedProject = projectDirectory.appendingPathComponent("apps/client", isDirectory: true)
        let sessionDirectory = projectDirectory.appendingPathComponent(".codex/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedProject, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let file = sessionDirectory.appendingPathComponent("nested.jsonl")
        try writeJSONLines([
            [
                "timestamp": "2026-07-10T10:00:00Z",
                "type": "session_meta",
                "payload": ["id": "nested", "cwd": nestedProject.path, "context_window": 10_000]
            ],
            [
                "timestamp": "2026-07-10T10:01:00Z",
                "type": "turn_context",
                "payload": ["model": "gpt-5.4", "cwd": nestedProject.path]
            ]
        ], to: file)

        let directlyParsed = try CodexSessionParser().parse(url: file, projectRoot: projectDirectory)
        XCTAssertEqual(directlyParsed?.id, "codex:nested")

        let sessions = await testScanner().scan(projectRoot: projectDirectory)
        XCTAssertTrue(sessions.contains(where: { $0.id == "codex:nested" }))
        XCTAssertEqual(sessions.first(where: { $0.id == "codex:nested" })?.projectPath, nestedProject.path)
    }

    func testScannerIncrementallyParsesOnlyAppendedBytes() async throws {
        let sessionDirectory = projectDirectory.appendingPathComponent(".codex/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let file = sessionDirectory.appendingPathComponent("live.jsonl")
        try writeJSONLines([
            [
                "timestamp": "2026-07-10T10:00:00Z",
                "type": "session_meta",
                "payload": ["id": "live", "cwd": projectDirectory.path, "context_window": 10_000]
            ],
            [
                "timestamp": "2026-07-10T10:01:00Z",
                "type": "turn_context",
                "payload": ["model": "gpt-5.4", "cwd": projectDirectory.path]
            ],
            codexTokenEvent(input: 1_000, cached: 400, output: 100, context: 900)
        ], to: file)

        let scanner = testScanner()
        let initial = await scanner.scan(projectRoot: projectDirectory)
        XCTAssertEqual(initial.first(where: { $0.id == "codex:live" })?.contextTokens, 900)
        let metricsBeforeAppend = scanner.metricsSnapshot()

        try appendJSONLine(
            codexTokenEvent(input: 2_000, cached: 1_000, output: 250, context: 1_800),
            to: file
        )
        let refreshed = await scanner.refresh(projectRoot: projectDirectory, changedPaths: [file])
        let live = try XCTUnwrap(refreshed.first(where: { $0.id == "codex:live" }))
        let metricsAfterAppend = scanner.metricsSnapshot()

        XCTAssertEqual(live.contextTokens, 1_800)
        XCTAssertEqual(live.usage.inputTokens, 1_000)
        XCTAssertEqual(live.usage.cachedReadTokens, 1_000)
        XCTAssertEqual(live.usage.outputTokens, 250)
        XCTAssertEqual(metricsAfterAppend.fullParses, metricsBeforeAppend.fullParses)
        XCTAssertEqual(metricsAfterAppend.incrementalParses, metricsBeforeAppend.incrementalParses + 1)
        XCTAssertEqual(metricsAfterAppend.changedFilesInspected, metricsBeforeAppend.changedFilesInspected + 1)

        _ = await scanner.discoverNewSessions(projectRoot: projectDirectory)
        XCTAssertEqual(scanner.metricsSnapshot().membershipChecks, metricsAfterAppend.membershipChecks)
    }

    func testScannerLoadsUnchangedSessionFromPersistentSummary() async throws {
        let sessionDirectory = projectDirectory.appendingPathComponent(".codex/sessions", isDirectory: true)
        let cacheDirectory = temporaryDirectory.appendingPathComponent("summary-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let file = sessionDirectory.appendingPathComponent("cached.jsonl")
        try writeJSONLines([
            [
                "timestamp": "2026-07-10T10:00:00Z",
                "type": "session_meta",
                "payload": ["id": "cached", "cwd": projectDirectory.path, "context_window": 10_000]
            ],
            [
                "timestamp": "2026-07-10T10:01:00Z",
                "type": "turn_context",
                "payload": ["model": "gpt-5.4", "cwd": projectDirectory.path]
            ],
            codexTokenEvent(input: 1_000, cached: 400, output: 100, context: 900)
        ], to: file)

        let firstScanner = SessionScanner(
            fileManager: .default,
            summaryCacheDirectory: cacheDirectory
        )
        let firstBatch = await firstScanner.scanInitialBatch(projectRoot: projectDirectory)
        XCTAssertEqual(firstBatch.sessions.first(where: { $0.id == "codex:cached" })?.contextTokens, 900)
        XCTAssertEqual(firstScanner.metricsSnapshot().fullParses, 1)
        XCTAssertEqual(firstScanner.metricsSnapshot().summaryCacheWrites, 1)

        let secondScanner = SessionScanner(
            fileManager: .default,
            summaryCacheDirectory: cacheDirectory
        )
        let secondBatch = await secondScanner.scanInitialBatch(projectRoot: projectDirectory)
        XCTAssertEqual(secondBatch.sessions.first(where: { $0.id == "codex:cached" })?.contextTokens, 900)
        XCTAssertEqual(secondScanner.metricsSnapshot().fullParses, 0)
        XCTAssertEqual(secondScanner.metricsSnapshot().summaryCacheHits, 1)
    }

    func testInitialHistoryLoadsInRecentFirstBatches() async throws {
        let sessionDirectory = projectDirectory.appendingPathComponent(".codex/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let older = sessionDirectory.appendingPathComponent("older.jsonl")
        let newer = sessionDirectory.appendingPathComponent("newer.jsonl")

        for (file, id) in [(older, "older"), (newer, "newer")] {
            try writeJSONLines([
                [
                    "timestamp": "2026-07-10T10:00:00Z",
                    "type": "session_meta",
                    "payload": ["id": id, "cwd": projectDirectory.path, "context_window": 10_000]
                ],
                [
                    "timestamp": "2026-07-10T10:01:00Z",
                    "type": "turn_context",
                    "payload": ["model": "gpt-5.4", "cwd": projectDirectory.path]
                ]
            ], to: file)
        }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: older.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: newer.path)

        let scanner = testScanner()
        let first = await scanner.scanInitialBatch(
            projectRoot: projectDirectory,
            maxFullParses: 1,
            maxCandidates: 1
        )
        XCTAssertEqual(first.sessions.map(\.id), ["codex:newer"])
        XCTAssertTrue(first.hasMoreHistory)

        let second = await scanner.loadNextHistoryBatch(
            projectRoot: projectDirectory,
            maxFullParses: 1,
            maxCandidates: 1
        )
        XCTAssertEqual(Set(second.sessions.map(\.id)), ["codex:newer", "codex:older"])
        XCTAssertFalse(second.hasMoreHistory)
    }

    private func writeJSONLines(_ objects: [[String: Any]], to url: URL) throws {
        let lines = try objects.map { object -> String in
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return try XCTUnwrap(String(data: data, encoding: .utf8))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func testScanner() -> SessionScanner {
        SessionScanner(fileManager: .default, summaryCacheDirectory: nil)
    }

    private func appendJSONLine(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Data([0x0A]))
    }

    private func codexTokenEvent(
        input: Int,
        cached: Int,
        output: Int,
        context: Int
    ) -> [String: Any] {
        [
            "timestamp": "2026-07-10T10:02:00Z",
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "info": [
                    "model_context_window": 10_000,
                    "total_token_usage": [
                        "input_tokens": input,
                        "cached_input_tokens": cached,
                        "output_tokens": output
                    ],
                    "last_token_usage": ["input_tokens": context, "output_tokens": 50]
                ]
            ]
        ]
    }
}
