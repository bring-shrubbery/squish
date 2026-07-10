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

    public func parse(url: URL, projectRoot: URL) throws -> CodingSession? {
        let contents = try String(contentsOf: url, encoding: .utf8)
        var sessionID = url.deletingPathExtension().lastPathComponent
        var cwd = ""
        var source = "Codex session"
        var model = "unknown"
        var contextWindow = 0
        var aggregate = TokenUsage()
        var contextTokens = 0
        var title: String?
        var startedAt: Date?
        var updatedAt: Date?

        for line in contents.split(whereSeparator: \.isNewline) {
            guard let object = parseJSONObject(String(line)),
                  let type = object["type"] as? String,
                  let payload = object["payload"] as? [String: Any] else { continue }

            let eventDate = dateValue(object["timestamp"])
            startedAt = earlier(startedAt, eventDate)
            updatedAt = later(updatedAt, eventDate)

            switch type {
            case "session_meta":
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
                if payload["type"] as? String == "user_message", title == nil {
                    title = cleanTitle(string(payload["message"]))
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
                continue
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
            logPath: url.path
        )
    }
}

public struct ClaudeSessionParser: SessionLogParser {
    public let provider = AgentProvider.claude

    public init() {}

    public func parse(url: URL, projectRoot: URL) throws -> CodingSession? {
        let contents = try String(contentsOf: url, encoding: .utf8)
        var sessionID = url.deletingPathExtension().lastPathComponent
        var cwd = ""
        var model = "unknown"
        var aggregate = TokenUsage()
        var latestContextTokens = 0
        var title: String?
        var startedAt: Date?
        var updatedAt: Date?

        for line in contents.split(whereSeparator: \.isNewline) {
            guard let object = parseJSONObject(String(line)) else { continue }
            sessionID = string(object["sessionId"]) ?? string(object["session_id"]) ?? sessionID
            cwd = string(object["cwd"]) ?? cwd

            let eventDate = dateValue(object["timestamp"])
            startedAt = earlier(startedAt, eventDate)
            updatedAt = later(updatedAt, eventDate)

            guard let type = object["type"] as? String else { continue }
            if type == "user", title == nil, let message = object["message"] {
                title = cleanTitle(extractText(message))
            }

            guard type == "assistant",
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }

            model = string(message["model"]) ?? model
            let input = int(usage["input_tokens"]) ?? 0
            let cacheRead = int(usage["cache_read_input_tokens"]) ?? 0
            let cacheCreationTotal = int(usage["cache_creation_input_tokens"]) ?? 0
            let cacheCreation = usage["cache_creation"] as? [String: Any]
            var cache5m = int(cacheCreation?["ephemeral_5m_input_tokens"]) ?? 0
            let cache1h = int(cacheCreation?["ephemeral_1h_input_tokens"]) ?? 0
            cache5m += max(0, cacheCreationTotal - cache5m - cache1h)
            let output = int(usage["output_tokens"]) ?? 0

            let requestUsage = TokenUsage(
                inputTokens: input,
                cachedReadTokens: cacheRead,
                cacheWrite5mTokens: cache5m,
                cacheWrite1hTokens: cache1h,
                outputTokens: output
            )
            aggregate = aggregate + requestUsage
            latestContextTokens = requestUsage.totalTokens
        }

        guard !cwd.isEmpty, isInside(cwd, root: projectRoot.path) else { return nil }
        let fileDates = fileDateRange(url)
        let resolvedModel = model == "unknown" ? "Unreported model" : model

        return CodingSession(
            id: "claude:\(sessionID)",
            provider: .claude,
            title: title ?? "Claude Code session",
            projectPath: cwd,
            model: resolvedModel,
            usage: aggregate,
            contextTokens: latestContextTokens,
            contextWindow: PricingCatalog.current.contextWindow(for: resolvedModel, provider: .claude),
            startedAt: startedAt ?? fileDates.created,
            updatedAt: updatedAt ?? fileDates.modified,
            logPath: url.path
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

        for object in objects {
            sessionID = firstString(in: object, keys: ["sessionId", "session_id", "id"]) ?? sessionID
            cwd = firstString(in: object, keys: ["cwd", "projectPath", "project_path", "workingDirectory"]) ?? cwd
            model = firstString(in: object, keys: ["model", "modelId", "model_id"]) ?? model
            title = title ?? cleanTitle(firstString(in: object, keys: ["firstUserMessage", "title", "prompt"]))
            startedAt = earlier(startedAt, firstDate(in: object, keys: ["startTime", "createdAt", "timestamp"]))
            updatedAt = later(updatedAt, firstDate(in: object, keys: ["lastUpdated", "updatedAt", "timestamp"]))

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
            contextWindow: PricingCatalog.current.contextWindow(for: resolvedModel, provider: .gemini),
            startedAt: startedAt ?? fileDates.created,
            updatedAt: updatedAt ?? fileDates.modified,
            logPath: url.path
        )
    }
}

private func parseJSONObject(_ line: String) -> [String: Any]? {
    guard let data = line.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
    return object as? [String: Any]
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
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return withFraction.date(from: value) ?? ISO8601DateFormatter().date(from: value)
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
    return String(title.prefix(72))
}

private func extractText(_ value: Any) -> String? {
    if let text = value as? String { return text }
    if let dictionary = value as? [String: Any] {
        if let content = dictionary["content"] { return extractText(content) }
        if let text = dictionary["text"] as? String { return text }
    }
    if let array = value as? [Any] {
        return array.compactMap(extractText).first
    }
    return nil
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
