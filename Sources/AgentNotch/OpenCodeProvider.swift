import Foundation

/// Reads OpenCode's SQLite store at `~/.local/share/opencode/opencode.db`.
final class OpenCodeProvider {
    private let db: SQLiteLite

    init() {
        var path = "~/.local/share/opencode/opencode.db".expandingTilde
        if !FileManager.default.fileExists(atPath: path) {
            let alt = "~/Library/Application Support/opencode/opencode.db".expandingTilde
            if FileManager.default.fileExists(atPath: alt) { path = alt }
        }
        db = SQLiteLite(path: path)
    }

    func poll() -> [AgentSession] {
        let cutoffMs = Int(Date().addingTimeInterval(-Config.recentWindow).timeIntervalSince1970 * 1000)
        let sessions = db.query("""
            SELECT id, title, directory, model, agent, cost,
                   tokens_input, tokens_output, tokens_reasoning, tokens_cache_read,
                   time_created, time_updated, time_archived
            FROM session
            WHERE time_updated > \(cutoffMs) AND time_archived IS NULL
            ORDER BY time_updated DESC LIMIT 12;
            """)
        guard !sessions.isEmpty else { return [] }

        return sessions.map { row in
            let sid = row.s("id") ?? UUID().uuidString
            let esc = sid.replacingOccurrences(of: "'", with: "''")

            var model = row.s("model")
            if let m = row.json("model") { model = m.str("id") ?? m.str("modelID") ?? model }

            // Latest assistant message decides whether a turn is still running.
            let recentMsgs = db.query("""
                SELECT data, time_updated FROM message
                WHERE session_id = '\(esc)' ORDER BY time_created DESC LIMIT 4;
                """)
            let lastMsg = recentMsgs.first
            // Context is what the most recent request carried, not the session-wide sum.
            let lastAssistant = recentMsgs.compactMap { $0.json("data") }
                .first {
                    $0.str("role") == "assistant"
                        && (($0.pathInt("tokens.input") ?? 0)
                            + ($0.pathInt("tokens.cache.read") ?? 0)) > 0
                }
            let msgData = lastMsg?.json("data")
            let role = msgData?.str("role") ?? ""
            let completed = msgData?.pathInt("time.completed")
            let finish = msgData?.str("finish")

            // Latest part tells us what it is doing right now.
            let lastPart = db.query("""
                SELECT data FROM part
                WHERE session_id = '\(esc)' ORDER BY time_updated DESC LIMIT 1;
                """).first?.json("data")

            let counts = db.query("""
                SELECT COUNT(*) AS n FROM message WHERE session_id = '\(esc)';
                """).first?.i("n") ?? 0
            let toolCount = db.query("""
                SELECT COUNT(*) AS n FROM part
                WHERE session_id = '\(esc)' AND json_extract(data,'$.type') = 'tool';
                """).first?.i("n") ?? 0
            let todos = db.query("""
                SELECT status, COUNT(*) AS n FROM todo
                WHERE session_id = '\(esc)' GROUP BY status;
                """)

            let updated = TS.fromMillis(row.i("time_updated")) ?? Date()
            var s = AgentSession(
                id: "opencode:" + sid,
                kind: .opencode,
                title: row.s("title").flatMap { $0.isEmpty ? nil : $0 } ?? "Sessione",
                directory: row.s("directory") ?? "",
                branch: nil,
                model: model.map { ($0 as NSString).lastPathComponent },
                startedAt: TS.fromMillis(row.i("time_created")) ?? updated,
                lastEventAt: updated,
                turnStartedAt: TS.fromMillis(msgData?.pathInt("time.created")) ?? updated
            )
            let turnContext = (lastAssistant?.pathInt("tokens.input") ?? 0)
                + (lastAssistant?.pathInt("tokens.cache.read") ?? 0)
                + (lastAssistant?.pathInt("tokens.output") ?? 0)
            // Never fall back to the lifetime sums: they are cumulative across
            // every turn and would read as a wildly overfull context.
            s.contextTokens = turnContext
            s.totalTokens = row.i("tokens_input") + row.i("tokens_cache_read")
                + row.i("tokens_output") + row.i("tokens_reasoning")
            s.contextWindow = Config.contextWindow(for: model)
            s.cost = row.d("cost")
            s.messageCount = counts
            s.toolCalls = toolCount
            s.todosTotal = todos.reduce(0) { $0 + $1.i("n") }
            s.todosDone = todos.first { $0.s("status") == "completed" }?.i("n") ?? 0
            s.activity = activity(from: lastPart)
            s.activityKind = Self.kind(fromPart: lastPart)

            let quiet = Date().timeIntervalSince(updated)
            let turnRunning = role == "assistant" && completed == nil
            if finish == "error" {
                s.state = .failed
            } else if turnRunning {
                s.state = quiet < Config.workingGrace ? .working : .idle
            } else if role == "user" {
                s.state = quiet < Config.workingGrace ? .working : .idle
            } else {
                s.state = quiet < Config.recentWindow ? .needsInput : .idle
            }
            s.isLive = quiet < Config.recentWindow
            return s
        }
    }

    static func kind(fromPart part: [String: Any]?) -> ActivityKind {
        guard let part else { return .none }
        switch part.str("type") ?? "" {
        case "step-start": return .thinking
        case "tool":
            let tool = (part.str("tool") ?? "").lowercased()
            if tool.contains("bash") || tool.contains("shell") { return .shell }
            if tool.contains("edit") || tool.contains("write") || tool.contains("patch") { return .edit }
            if tool.contains("read") { return .read }
            if tool.contains("grep") || tool.contains("glob") { return .search }
            if tool.contains("web") || tool.contains("fetch") { return .web }
            if tool.contains("task") || tool.contains("agent") { return .subagent }
            return .mcp
        default: return .none
        }
    }

    private func activity(from part: [String: Any]?) -> String? {
        guard let part else { return nil }
        switch part.str("type") ?? "" {
        case "tool":
            let tool = part.str("tool") ?? part.pathStr("state.title") ?? "tool"
            let status = part.pathStr("state.status") ?? ""
            return status == "running" ? tool + " · in corso" : tool
        case "text":
            guard let t = part.str("text"), !t.isEmpty else { return nil }
            return Fmt.compact(t, max: 44)
        case "step-start":
            return "ragiona…"
        case "step-finish":
            return nil
        default:
            return nil
        }
    }
}
