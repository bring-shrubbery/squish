import Foundation

public protocol SessionLogParser: Sendable {
    var provider: AgentProvider { get }
    func parse(url: URL, projectRoot: URL) throws -> CodingSession?
}

public enum SessionParsingError: Error {
    case unreadableFile
    case unsupportedFormat
}

public struct CodexSessionParser: SessionLogParser {
    public let provider = AgentProvider.codex

    public init() {}

    public func refreshing(
        _ session: CodingSession,
        withJSONLines data: Data,
        fileURL: URL
    ) -> CodingSession {
        guard !data.isEmpty else { return session }

        var title = session.title
        var projectPath = session.projectPath
        var model = session.model
        var usage = session.usage
        var contextTokens = session.contextTokens
        var contextWindow = session.contextWindow
        var updatedAt = session.updatedAt
        var lastUserMessageAt = session.lastUserMessageAt

        forEachJSONObjectLine(in: data) { object in
            guard let type = object["type"] as? String,
                  let payload = object["payload"] as? [String: Any] else { return }

            let eventDate = dateValue(object["timestamp"])
            switch type {
            case "session_meta":
                updatedAt = later(updatedAt, eventDate) ?? updatedAt
                projectPath = string(payload["cwd"]) ?? projectPath
                contextWindow = int(payload["context_window"]) ?? contextWindow

            case "turn_context":
                updatedAt = later(updatedAt, eventDate) ?? updatedAt
                model = string(payload["model"]) ?? model
                projectPath = string(payload["cwd"]) ?? projectPath

            case "event_msg":
                if payload["type"] as? String == "user_message",
                   let messageTitle = cleanTitle(string(payload["message"])) {
                    updatedAt = later(updatedAt, eventDate) ?? updatedAt
                    lastUserMessageAt = later(
                        lastUserMessageAt,
                        eventDate ?? fileDateRange(fileURL).modified
                    )
                    if title == "Codex Session" || title == "Codex session" {
                        title = messageTitle
                    }
                }
                if payload["type"] as? String == "token_count",
                   let info = payload["info"] as? [String: Any] {
                    updatedAt = later(updatedAt, eventDate) ?? updatedAt
                    if let total = info["total_token_usage"] as? [String: Any] {
                        let allInput = int(total["input_tokens"]) ?? 0
                        let cached = int(total["cached_input_tokens"]) ?? 0
                        usage = TokenUsage(
                            inputTokens: max(0, allInput - cached),
                            cachedReadTokens: cached,
                            outputTokens: int(total["output_tokens"]) ?? 0
                        )
                    }
                    if let last = info["last_token_usage"] as? [String: Any] {
                        contextTokens = int(last["input_tokens"]) ?? int(last["total_tokens"]) ?? contextTokens
                    }
                    contextWindow = int(info["model_context_window"]) ?? contextWindow
                }

            default:
                return
            }
        }

        return CodingSession(
            id: session.id,
            provider: session.provider,
            title: title,
            projectPath: projectPath,
            model: model,
            usage: usage,
            contextTokens: contextTokens,
            contextWindow: contextWindow,
            startedAt: session.startedAt,
            updatedAt: updatedAt,
            logPath: fileURL.path,
            lastUserMessageAt: lastUserMessageAt,
            isSubagent: session.isSubagent
        )
    }

    public func parse(url: URL, projectRoot: URL) throws -> CodingSession? {
        var sessionID = url.deletingPathExtension().lastPathComponent
        var cwd = ""
        var source = "Codex session"
        var model = "unknown"
        var contextWindow = 0
        var aggregate = TokenUsage()
        var contextTokens = 0
        var title: String?
        var isSubagent = false
        var startedAt: Date?
        var updatedAt: Date?
        var lastUserMessageAt: Date?

        try forEachJSONObjectLine(at: url) { object in
            guard let type = object["type"] as? String,
                  let payload = object["payload"] as? [String: Any] else { return }

            let eventDate = dateValue(object["timestamp"])
            startedAt = earlier(startedAt, eventDate)
            updatedAt = later(updatedAt, eventDate)

            switch type {
            case "session_meta":
                isSubagent = isSubagent || codexSourceIsSubagent(payload["source"])
                sessionID = string(payload["id"]) ?? string(payload["session_id"]) ?? sessionID
                cwd = string(payload["cwd"]) ?? cwd
                source = string(payload["source"]) ?? source
                contextWindow = int(payload["context_window"]) ?? contextWindow
                let metaDate = dateValue(payload["timestamp"])
                startedAt = earlier(startedAt, metaDate)
                updatedAt = later(updatedAt, metaDate)

            case "turn_context":
                model = string(payload["model"]) ?? model
                cwd = string(payload["cwd"]) ?? cwd

            case "event_msg":
                if payload["type"] as? String == "user_message",
                   let messageTitle = cleanTitle(string(payload["message"])) {
                    title = title ?? messageTitle
                    lastUserMessageAt = later(
                        lastUserMessageAt,
                        eventDate ?? fileDateRange(url).modified
                    )
                }
                if payload["type"] as? String == "token_count",
                   let info = payload["info"] as? [String: Any] {
                    if let total = info["total_token_usage"] as? [String: Any] {
                        let allInput = int(total["input_tokens"]) ?? 0
                        let cached = int(total["cached_input_tokens"]) ?? 0
                        aggregate = TokenUsage(
                            inputTokens: max(0, allInput - cached),
                            cachedReadTokens: cached,
                            outputTokens: int(total["output_tokens"]) ?? 0
                        )
                    }
                    if let last = info["last_token_usage"] as? [String: Any] {
                        contextTokens = int(last["input_tokens"]) ?? int(last["total_tokens"]) ?? contextTokens
                    }
                    contextWindow = int(info["model_context_window"]) ?? contextWindow
                }

            default:
                return
            }
        }

        guard !cwd.isEmpty, isInside(cwd, root: projectRoot.path) else { return nil }
        let fileDates = fileDateRange(url)
        let resolvedModel = model == "unknown" ? "Unreported model" : model
        let resolvedWindow = contextWindow > 0
            ? contextWindow
            : PricingCatalog.current.contextWindow(for: resolvedModel, provider: .codex)

        return CodingSession(
            id: "codex:\(sessionID)",
            provider: .codex,
            title: title ?? source.capitalized,
            projectPath: cwd,
            model: resolvedModel,
            usage: aggregate,
            contextTokens: contextTokens,
            contextWindow: resolvedWindow,
            startedAt: startedAt ?? fileDates.created,
            updatedAt: updatedAt ?? fileDates.modified,
            logPath: url.path,
            lastUserMessageAt: lastUserMessageAt,
            isSubagent: isSubagent
        )
    }
}

public struct ClaudeSessionParser: SessionLogParser {
    public let provider = AgentProvider.claude

    public init() {}

    public func refreshing(
        _ session: CodingSession,
        withJSONLines data: Data,
        fileURL: URL
    ) -> CodingSession {
        guard !data.isEmpty else { return session }

        var title = session.title
        var projectPath = session.projectPath
        var model = session.model
        var aggregate = session.usage
        var latestContextTokens = session.contextTokens
        var updatedAt = session.updatedAt
        var lastUserMessageAt = session.lastUserMessageAt

        forEachJSONObjectLine(in: data) { object in
            projectPath = string(object["cwd"]) ?? projectPath
            let eventDate = dateValue(object["timestamp"])

            guard let type = object["type"] as? String else { return }
            if type == "user" {
                updatedAt = later(updatedAt, eventDate) ?? updatedAt
                if let message = object["message"], let messageTitle = extractTitle(message) {
                    lastUserMessageAt = later(
                        lastUserMessageAt,
                        eventDate ?? fileDateRange(fileURL).modified
                    )
                    if title == "Claude Code session" { title = messageTitle }
                }
            }

            guard type == "assistant",
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { return }

            updatedAt = later(updatedAt, eventDate) ?? updatedAt
            model = string(message["model"]) ?? model
            let requestUsage = claudeTokenUsage(usage)
            aggregate = aggregate + requestUsage
            latestContextTokens = requestUsage.totalTokens
        }

        return CodingSession(
            id: session.id,
            provider: session.provider,
            title: title,
            projectPath: projectPath,
            model: model,
            usage: aggregate,
            contextTokens: latestContextTokens,
            contextWindow: PricingCatalog.current.contextWindow(
                for: model,
                provider: .claude,
                observedTokens: latestContextTokens
            ),
            startedAt: session.startedAt,
            updatedAt: updatedAt,
            logPath: fileURL.path,
            lastUserMessageAt: lastUserMessageAt,
            isSubagent: session.isSubagent
        )
    }

    public func parse(url: URL, projectRoot: URL) throws -> CodingSession? {
        var sessionID = url.deletingPathExtension().lastPathComponent
        var subagentID = url.deletingPathExtension().lastPathComponent
        var cwd = ""
        var model = "unknown"
        var aggregate = TokenUsage()
        var latestContextTokens = 0
        var title: String?
        var isSubagent = url.path.contains("/subagents/")
        var startedAt: Date?
        var updatedAt: Date?
        var lastUserMessageAt: Date?

        try forEachJSONObjectLine(at: url) { object in
            isSubagent = isSubagent || claudeRecordIsSubagent(object)
            sessionID = string(object["sessionId"]) ?? string(object["session_id"]) ?? sessionID
            subagentID = string(object["agentId"]) ?? string(object["agent_id"]) ?? subagentID
            cwd = string(object["cwd"]) ?? cwd

            let eventDate = dateValue(object["timestamp"])
            startedAt = earlier(startedAt, eventDate)
            updatedAt = later(updatedAt, eventDate)

            guard let type = object["type"] as? String else { return }
            if type == "user", let message = object["message"], let messageTitle = extractTitle(message) {
                title = title ?? messageTitle
                lastUserMessageAt = later(
                    lastUserMessageAt,
                    eventDate ?? fileDateRange(url).modified
                )
            }

            guard type == "assistant",
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { return }

            model = string(message["model"]) ?? model
            let requestUsage = claudeTokenUsage(usage)
            aggregate = aggregate + requestUsage
            latestContextTokens = requestUsage.totalTokens
        }

        guard !cwd.isEmpty, isInside(cwd, root: projectRoot.path) else { return nil }
        let fileDates = fileDateRange(url)
        let resolvedModel = model == "unknown" ? "Unreported model" : model

        let resolvedSessionID = isSubagent ? "subagent:\(subagentID)" : sessionID
        return CodingSession(
            id: "claude:\(resolvedSessionID)",
            provider: .claude,
            title: title ?? "Claude Code session",
            projectPath: cwd,
            model: resolvedModel,
            usage: aggregate,
            contextTokens: latestContextTokens,
            contextWindow: PricingCatalog.current.contextWindow(
                for: resolvedModel,
                provider: .claude,
                observedTokens: latestContextTokens
            ),
            startedAt: startedAt ?? fileDates.created,
            updatedAt: updatedAt ?? fileDates.modified,
            logPath: url.path,
            lastUserMessageAt: lastUserMessageAt,
            isSubagent: isSubagent
        )
    }
}

public struct GeminiSessionParser: SessionLogParser {
    public let provider = AgentProvider.gemini

    public init() {}

    public func parse(url: URL, projectRoot: URL) throws -> CodingSession? {
        let data = try Data(contentsOf: url)
        guard let raw = try? JSONSerialization.jsonObject(with: data) else {
            throw SessionParsingError.unsupportedFormat
        }

        let objects: [[String: Any]]
        if let object = raw as? [String: Any] {
            objects = [object]
        } else if let array = raw as? [[String: Any]] {
            objects = array
        } else {
            throw SessionParsingError.unsupportedFormat
        }

        var sessionID = url.deletingPathExtension().lastPathComponent
        var cwd = inferredGeminiProjectPath(for: url) ?? ""
        var model = "unknown"
        var title: String?
        var aggregate = TokenUsage()
        var latestContext = 0
        var startedAt: Date?
        var updatedAt: Date?
        var lastUserMessageAt: Date?

        for object in objects {
            sessionID = firstString(in: object, keys: ["sessionId", "session_id", "id"]) ?? sessionID
            cwd = firstString(in: object, keys: ["cwd", "projectPath", "project_path", "workingDirectory"]) ?? cwd
            model = firstString(in: object, keys: ["model", "modelId", "model_id"]) ?? model
            title = title ?? cleanTitle(firstString(in: object, keys: ["firstUserMessage", "title", "prompt"]))
            startedAt = earlier(startedAt, firstDate(in: object, keys: ["startTime", "createdAt", "timestamp"]))
            updatedAt = later(updatedAt, firstDate(in: object, keys: ["lastUpdated", "updatedAt", "timestamp"]))
            lastUserMessageAt = later(lastUserMessageAt, latestUserMessageDate(in: object))

            for usage in dictionaries(named: "usageMetadata", inside: object) {
                let prompt = int(usage["promptTokenCount"]) ?? int(usage["input_tokens"]) ?? 0
                let cached = int(usage["cachedContentTokenCount"]) ?? int(usage["cached_input_tokens"]) ?? 0
                let output = int(usage["candidatesTokenCount"]) ?? int(usage["output_tokens"]) ?? 0
                let item = TokenUsage(
                    inputTokens: max(0, prompt - cached),
                    cachedReadTokens: cached,
                    outputTokens: output
                )
                aggregate = aggregate + item
                latestContext = item.totalTokens
            }
        }

        guard !cwd.isEmpty, isInside(cwd, root: projectRoot.path) else { return nil }
        let fileDates = fileDateRange(url)
        let resolvedModel = model == "unknown" ? "Unreported model" : model

        return CodingSession(
            id: "gemini:\(sessionID)",
            provider: .gemini,
            title: title ?? "Gemini CLI session",
            projectPath: cwd,
            model: resolvedModel,
            usage: aggregate,
            contextTokens: latestContext,
            contextWindow: PricingCatalog.current.contextWindow(
                for: resolvedModel,
                provider: .gemini,
                observedTokens: latestContext
            ),
            startedAt: startedAt ?? fileDates.created,
            updatedAt: updatedAt ?? fileDates.modified,
            logPath: url.path,
            lastUserMessageAt: lastUserMessageAt
        )
    }
}

private let iso8601WithFractionalSeconds: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

private let iso8601Basic = ISO8601DateFormatter()

private func parseJSONObject(_ data: Data) -> [String: Any]? {
    guard !data.isEmpty,
          let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
    return object as? [String: Any]
}

private func forEachJSONObjectLine(
    at url: URL,
    body: ([String: Any]) -> Void
) throws {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    var buffer = Data()
    buffer.reserveCapacity(128 * 1024)
    while true {
        let chunk = try handle.read(upToCount: 128 * 1024) ?? Data()
        if chunk.isEmpty { break }
        buffer.append(chunk)
        consumeCompleteJSONLines(from: &buffer, body: body)
    }

    autoreleasepool {
        if let object = parseJSONObject(buffer) { body(object) }
    }
}

private func forEachJSONObjectLine(
    in data: Data,
    body: ([String: Any]) -> Void
) {
    var buffer = data
    consumeCompleteJSONLines(from: &buffer, body: body)
    autoreleasepool {
        if let object = parseJSONObject(buffer) { body(object) }
    }
}

private func consumeCompleteJSONLines(
    from buffer: inout Data,
    body: ([String: Any]) -> Void
) {
    var lineStart = buffer.startIndex
    while lineStart < buffer.endIndex,
          let newline = buffer[lineStart...].firstIndex(of: 0x0A) {
        let line = Data(buffer[lineStart..<newline])
        autoreleasepool {
            if let object = parseJSONObject(line) { body(object) }
        }
        lineStart = buffer.index(after: newline)
    }

    if lineStart > buffer.startIndex {
        buffer = Data(buffer[lineStart...])
    }
}

private func claudeTokenUsage(_ usage: [String: Any]) -> TokenUsage {
    let input = int(usage["input_tokens"]) ?? 0
    let cacheRead = int(usage["cache_read_input_tokens"]) ?? 0
    let cacheCreationTotal = int(usage["cache_creation_input_tokens"]) ?? 0
    let cacheCreation = usage["cache_creation"] as? [String: Any]
    var cache5m = int(cacheCreation?["ephemeral_5m_input_tokens"]) ?? 0
    let cache1h = int(cacheCreation?["ephemeral_1h_input_tokens"]) ?? 0
    cache5m += max(0, cacheCreationTotal - cache5m - cache1h)

    return TokenUsage(
        inputTokens: input,
        cachedReadTokens: cacheRead,
        cacheWrite5mTokens: cache5m,
        cacheWrite1hTokens: cache1h,
        outputTokens: int(usage["output_tokens"]) ?? 0
    )
}

private func string(_ value: Any?) -> String? {
    if let string = value as? String, !string.isEmpty { return string }
    return nil
}

private func int(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    if let value = value as? Double { return Int(value) }
    if let value = value as? NSNumber { return value.intValue }
    if let value = value as? String { return Int(value) }
    return nil
}

private func dateValue(_ value: Any?) -> Date? {
    if let seconds = value as? Double { return Date(timeIntervalSince1970: seconds) }
    if let seconds = value as? Int { return Date(timeIntervalSince1970: TimeInterval(seconds)) }
    guard let value = value as? String else { return nil }
    return iso8601WithFractionalSeconds.date(from: value) ?? iso8601Basic.date(from: value)
}

private func earlier(_ lhs: Date?, _ rhs: Date?) -> Date? {
    guard let rhs else { return lhs }
    guard let lhs else { return rhs }
    return min(lhs, rhs)
}

private func later(_ lhs: Date?, _ rhs: Date?) -> Date? {
    guard let rhs else { return lhs }
    guard let lhs else { return rhs }
    return max(lhs, rhs)
}

private func cleanTitle(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let title = raw
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { return nil }
    let ignoredPrefixes = [
        "<local-command-caveat>",
        "<local-command-stdout>",
        "<local-command-stderr>",
        "<command-name>",
        "<task-notification>",
        "<system-reminder>",
        "<tool-result>",
        "<tool_result>"
    ]
    let normalized = title.lowercased()
    guard !ignoredPrefixes.contains(where: { normalized.hasPrefix($0) }),
          !normalized.hasPrefix("base directory for this skill:") else { return nil }
    return String(title.prefix(72))
}

private func extractTitle(_ value: Any) -> String? {
    if let text = value as? String { return cleanTitle(text) }
    if let dictionary = value as? [String: Any] {
        if dictionary["type"] as? String == "tool_result" { return nil }
        if let text = dictionary["text"] as? String, let title = cleanTitle(text) { return title }
        if let content = dictionary["content"] { return extractTitle(content) }
        return nil
    }
    if let array = value as? [Any] {
        for item in array {
            if let title = extractTitle(item) { return title }
        }
    }
    return nil
}

func codexSourceIsSubagent(_ value: Any?) -> Bool {
    if let source = value as? String {
        let normalized = source.lowercased()
        return normalized.contains("subagent") || normalized.contains("sub-agent")
    }
    if let source = value as? [String: Any] {
        return source.keys.contains { key in
            let normalized = key.lowercased()
            return normalized == "subagent" || normalized == "sub-agent"
        }
    }
    return false
}

private func claudeRecordIsSubagent(_ object: [String: Any]) -> Bool {
    object["isSidechain"] as? Bool == true
        || string(object["agentId"]) != nil
        || string(object["agent_id"]) != nil
}

private func isInside(_ path: String, root: String) -> Bool {
    let candidate = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    let root = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
    return candidate == root || candidate.hasPrefix(root.hasSuffix("/") ? root : root + "/")
}

private func fileDateRange(_ url: URL) -> (created: Date, modified: Date) {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    let modified = attributes?[.modificationDate] as? Date ?? .distantPast
    let created = attributes?[.creationDate] as? Date ?? modified
    return (created, modified)
}

private func firstString(in object: [String: Any], keys: [String]) -> String? {
    for key in keys {
        if let value = string(object[key]) { return value }
    }
    for value in object.values {
        if let nested = value as? [String: Any], let result = firstString(in: nested, keys: keys) {
            return result
        }
    }
    return nil
}

private func firstDate(in object: [String: Any], keys: [String]) -> Date? {
    for key in keys {
        if let value = dateValue(object[key]) { return value }
    }
    return nil
}

private func latestUserMessageDate(in value: Any) -> Date? {
    if let array = value as? [Any] {
        return array.reduce(nil as Date?) { latest, item in
            later(latest, latestUserMessageDate(in: item))
        }
    }
    guard let dictionary = value as? [String: Any] else { return nil }

    var latest: Date?
    let role = (string(dictionary["role"]) ?? string(dictionary["type"]))?.lowercased()
    if role == "user" {
        let content = dictionary["content"] ?? dictionary["message"] ?? dictionary["text"]
        if let content, extractTitle(content) != nil {
            latest = firstDate(
                in: dictionary,
                keys: ["timestamp", "createdAt", "created_at", "time"]
            )
        }
    }

    for nested in dictionary.values {
        latest = later(latest, latestUserMessageDate(in: nested))
    }
    return latest
}

private func dictionaries(named key: String, inside value: Any) -> [[String: Any]] {
    var results: [[String: Any]] = []
    if let dictionary = value as? [String: Any] {
        if let match = dictionary[key] as? [String: Any] { results.append(match) }
        for nested in dictionary.values {
            results.append(contentsOf: dictionaries(named: key, inside: nested))
        }
    } else if let array = value as? [Any] {
        for nested in array {
            results.append(contentsOf: dictionaries(named: key, inside: nested))
        }
    }
    return results
}

private func inferredGeminiProjectPath(for url: URL) -> String? {
    var directory = url.deletingLastPathComponent()
    for _ in 0..<4 {
        for name in [".project_root", "project_root"] {
            let marker = directory.appendingPathComponent(name)
            if let value = try? String(contentsOf: marker, encoding: .utf8) {
                let path = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty { return path }
            }
        }
        directory.deleteLastPathComponent()
    }
    return nil
}
