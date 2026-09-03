import Foundation

/// Reads Codex rollout transcripts under `~/.codex/sessions/YYYY/MM/DD/`.
final class CodexProvider {
    private let root = "~/.codex".expandingTilde
    private let tailer = JSONLTailer()
    private var acc: [String: Accumulator] = [:]

    private struct Accumulator {
        var title: String = "Sessione"
        var directory: String = ""
        var model: String?
        var totalTokens: Int = 0
        var contextTokens: Int = 0
        var contextWindow: Int = 0
        var toolCalls: Int = 0
        var messages: Int = 0
        var lastActivity: String?
        var lastKind: ActivityKind = .none
        var firstEventAt: Date?
        var lastEventAt: Date = .distantPast
        var turnStartedAt: Date?
        var turnOpen = false
        var failed = false
        var rateLimitPercent: Double?
        var pendingCalls: Set<String> = []
    }

    func poll() -> [AgentSession] {
        var names: [String: String] = [:]
        if let data = FileManager.default.contents(atPath: root + "/session_index.jsonl"),
           let text = String(data: data, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                guard let d = line.data(using: .utf8),
                      let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let id = o.str("id") else { continue }
                if let n = o.str("thread_name"), !n.isEmpty { names[id] = n }
            }
        }

        // Rollouts live in YYYY/MM/DD folders — only look at the days that
        // could still hold a live session instead of walking the whole archive.
        var files: [String: String] = [:]   // sessionId -> path
        let cutoff = Date().addingTimeInterval(-Config.recentWindow)
        let fm = FileManager.default
        let cal = Calendar.current
        let df = DateFormatter()
        df.dateFormat = "yyyy/MM/dd"
        var days: Set<String> = []
        for offset in 0...1 {
            if let d = cal.date(byAdding: .day, value: -offset, to: Date()) {
                days.insert(df.string(from: d))
            }
        }
        for day in days {
            let dir = root + "/sessions/" + day
            for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
                guard name.hasSuffix(".jsonl"), name.hasPrefix("rollout-") else { continue }
                let full = dir + "/" + name
                let attrs = try? fm.attributesOfItem(atPath: full)
                let mod = (attrs?[.modificationDate] as? Date) ?? .distantPast
                guard mod > cutoff else { continue }
                let base = (name as NSString).deletingPathExtension
                let sid = String(base.suffix(36))   // rollout-<iso>-<uuid>
                files[sid] = full
            }
        }

        for (sid, path) in files {
            let (objects, fresh) = tailer.newObjects(at: path)
            if fresh { acc[sid] = Accumulator() }
            var a = acc[sid] ?? Accumulator()
            for obj in objects { fold(obj, into: &a) }
            if let n = names[sid] { a.title = n }
            acc[sid] = a
        }
        for key in acc.keys where files[key] == nil { acc[key] = nil }
        tailer.forget(paths: Set(files.values))

        return acc.map { sid, a in
            var s = AgentSession(
                id: "codex:" + sid,
                kind: .codex,
                title: a.title,
                directory: a.directory,
                branch: nil,
                model: a.model,
                startedAt: a.firstEventAt ?? a.lastEventAt,
                lastEventAt: a.lastEventAt,
                turnStartedAt: a.turnStartedAt
            )
            s.contextTokens = a.contextTokens > 0 ? a.contextTokens : a.totalTokens
            s.contextWindow = a.contextWindow > 0 ? a.contextWindow : Config.contextWindow(for: a.model)
            s.totalTokens = a.totalTokens
            s.toolCalls = a.toolCalls
            s.messageCount = a.messages
            s.activity = a.lastActivity
            s.activityKind = a.lastKind
            s.rateLimitPercent = a.rateLimitPercent
            let quiet = Date().timeIntervalSince(a.lastEventAt)
            if a.failed {
                s.state = .failed
            } else if a.turnOpen {
                s.state = quiet < Config.workingGrace ? .working : .idle
            } else {
                s.state = quiet < Config.recentWindow ? .needsInput : .idle
            }
            s.isLive = quiet < Config.recentWindow
            return s
        }
    }

    private func fold(_ obj: [String: Any], into a: inout Accumulator) {
        let type = obj.str("type") ?? ""
        if let ts = TS.parse(obj.str("timestamp")) {
            if a.firstEventAt == nil { a.firstEventAt = ts }
            a.lastEventAt = max(a.lastEventAt, ts)
        }
        guard let payload = obj.dict("payload") else { return }

        switch type {
        case "session_meta":
            if let cwd = payload.str("cwd") { a.directory = cwd }
        case "turn_context":
            if let cwd = payload.str("cwd") { a.directory = cwd }
            if let m = payload.str("model") { a.model = m }
        case "world_state":
            if let m = payload.pathStr("state.collaboration_mode.model") { a.model = m }
        case "event_msg":
            foldEvent(payload, into: &a)
        case "response_item":
            foldItem(payload, into: &a)
        default:
            break
        }
    }

    private func foldEvent(_ p: [String: Any], into a: inout Accumulator) {
        switch p.str("type") ?? "" {
        case "task_started":
            a.turnOpen = true
            a.failed = false
            if let started = p.int("started_at") {
                a.turnStartedAt = Date(timeIntervalSince1970: Double(started))
            } else {
                a.turnStartedAt = a.lastEventAt
            }
            if let w = p.int("model_context_window") { a.contextWindow = w }
        case "task_complete", "turn_complete", "turn_completed", "task_finished":
            a.turnOpen = false
            a.pendingCalls.removeAll()
        case "turn_aborted", "task_aborted":
            a.turnOpen = false
        case "error", "stream_error", "turn_failed":
            a.failed = true
            a.turnOpen = false
            a.lastActivity = Fmt.compact(p.str("message") ?? "errore", max: 44)
        case "token_count":
            if let t = p.pathInt("info.total_token_usage.total_tokens") { a.totalTokens = t }
            // The last request's input is what actually occupies the context window;
            // total_token_usage is the running sum over the whole session.
            if let c = p.pathInt("info.last_token_usage.total_tokens") { a.contextTokens = c }
            if let w = p.pathInt("info.model_context_window") { a.contextWindow = w }
            if let pct = p.pathDbl("rate_limits.primary.used_percent") { a.rateLimitPercent = pct }
        case "item_completed", "item_started":
            if let item = p.dict("item") { foldTimelineItem(item, into: &a) }
        case "agent_message":
            a.messages += 1
        default:
            break
        }
    }

    private func foldTimelineItem(_ item: [String: Any], into a: inout Accumulator) {
        switch item.str("type") ?? "" {
        case "UserMessage":
            a.messages += 1
            a.turnStartedAt = a.lastEventAt
            if a.title == "Sessione", let texts = item.arr("content") {
                if let t = texts.compactMap({ $0.str("text") }).first {
                    a.title = Fmt.compact(t, max: 60)
                }
            }
        case "AgentMessage", "AssistantMessage":
            a.messages += 1
        case "CommandExecution", "LocalShellCall", "Exec":
            a.toolCalls += 1
            let cmd = item.str("command") ?? item.pathStr("action.command") ?? "exec"
            a.lastActivity = "exec · " + Fmt.compact(cmd, max: 38)
            a.lastKind = .shell
        case "FileChange", "PatchApply":
            a.toolCalls += 1
            a.lastActivity = "modifica file"
            a.lastKind = .edit
        case "WebSearch":
            a.toolCalls += 1
            a.lastActivity = "ricerca web"
            a.lastKind = .web
        case "McpToolCall":
            a.toolCalls += 1
            a.lastActivity = "mcp · " + Fmt.compact(item.str("tool") ?? "tool", max: 30)
            a.lastKind = .mcp
        case "Reasoning":
            a.lastActivity = "ragiona…"
            a.lastKind = .thinking
        default:
            break
        }
    }

    private func foldItem(_ p: [String: Any], into a: inout Accumulator) {
        switch p.str("type") ?? "" {
        case "custom_tool_call", "function_call", "local_shell_call":
            a.toolCalls += 1
            if let id = p.str("call_id") { a.pendingCalls.insert(id) }
            let name = p.str("name") ?? "tool"
            a.lastKind = name == "exec" ? .shell : .mcp
            if let raw = p.str("input"), let cmd = extractCommand(raw) {
                a.lastActivity = name + " · " + Fmt.compact(cmd, max: 36)
            } else {
                a.lastActivity = name
            }
        case "custom_tool_call_output", "function_call_output":
            if let id = p.str("call_id") { a.pendingCalls.remove(id) }
        case "reasoning":
            if let summary = (p["summary"] as? [[String: Any]])?.compactMap({ $0.str("text") }).last {
                a.lastActivity = Fmt.compact(summary.replacingOccurrences(of: "*", with: ""), max: 42)
                a.lastKind = .thinking
            }
        case "message":
            if p.str("role") == "assistant" { a.messages += 1 }
        default:
            break
        }
    }

    /// Codex wraps shell work in a JS snippet; pull the readable command out.
    private func extractCommand(_ raw: String) -> String? {
        guard let r = raw.range(of: "\"cmd\":\"") else { return nil }
        let rest = raw[r.upperBound...]
        guard let end = rest.range(of: "\",\"") ?? rest.range(of: "\"}") else {
            return String(rest.prefix(60))
        }
        return String(rest[..<end.lowerBound])
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}
