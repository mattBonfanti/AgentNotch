import Foundation

/// Reads Claude Code sessions: `~/.claude/sessions/<pid>.json` gives the live
/// processes, `~/.claude/projects/**/<sessionId>.jsonl` gives the transcript.
final class ClaudeProvider {
    private let root = "~/.claude".expandingTilde
    private let tailer = JSONLTailer()
    private var acc: [String: Accumulator] = [:]

    private struct Accumulator {
        var title: String = "Sessione"
        var directory: String = ""
        var branch: String?
        var model: String?
        var contextTokens: Int = 0
        var totalOutput: Int = 0
        var toolCalls: Int = 0
        var messages: Int = 0
        var pending: [String: String] = [:]   // tool_use id -> activity phrase
        var lastToolPhrase: String?
        var lastToolKind: ActivityKind = .none
        var pendingKind: ActivityKind = .none
        var lastStopReason: String?
        var firstEventAt: Date?
        var lastEventAt: Date = .distantPast
        var turnStartedAt: Date?
        var sawEndTurnAfterLastPrompt = false
    }

    func poll() -> [AgentSession] {
        var live: [String: (pid: pid_t, cwd: String, started: Date, name: String)] = [:]
        let sessionsDir = root + "/sessions"
        for file in (try? FileManager.default.contentsOfDirectory(atPath: sessionsDir)) ?? [] {
            guard file.hasSuffix(".json") else { continue }
            guard let data = FileManager.default.contents(atPath: sessionsDir + "/" + file),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sid = obj.str("sessionId"),
                  let pid = obj.int("pid").map({ pid_t($0) })
            else { continue }
            guard processIsAlive(pid) else { continue }
            live[sid] = (pid,
                         obj.str("cwd") ?? "",
                         TS.fromMillis(obj.int("startedAt")) ?? Date(),
                         obj.str("name") ?? "claude")
        }

        // Every transcript that is live, plus any touched recently (CLI sessions
        // and just-finished work both matter for the "ti aspetta" signal).
        var transcripts: [String: String] = [:]   // sessionId -> path
        let projects = root + "/projects"
        let cutoff = Date().addingTimeInterval(-Config.recentWindow)
        if let e = FileManager.default.enumerator(atPath: projects) {
            for case let rel as String in e {
                guard rel.hasSuffix(".jsonl") else { continue }
                let full = projects + "/" + rel
                let sid = ((rel as NSString).lastPathComponent as NSString).deletingPathExtension
                if live[sid] == nil {
                    let attrs = try? FileManager.default.attributesOfItem(atPath: full)
                    let mod = (attrs?[.modificationDate] as? Date) ?? .distantPast
                    guard mod > cutoff else { continue }
                }
                transcripts[sid] = full
            }
        }

        for (sid, path) in transcripts {
            let (objects, fresh) = tailer.newObjects(at: path)
            if fresh { acc[sid] = Accumulator() }
            guard !objects.isEmpty || acc[sid] != nil else { continue }
            var a = acc[sid] ?? Accumulator()
            for obj in objects { fold(obj, into: &a) }
            acc[sid] = a
        }
        for key in acc.keys where transcripts[key] == nil { acc[key] = nil }
        tailer.forget(paths: Set(transcripts.values))

        return acc.compactMap { sid, a in
            let l = live[sid]
            var s = AgentSession(
                id: "claude:" + sid,
                kind: .claude,
                title: a.title,
                directory: a.directory.isEmpty ? (l?.cwd ?? "") : a.directory,
                branch: a.branch,
                model: a.model,
                startedAt: a.firstEventAt ?? l?.started ?? a.lastEventAt,
                lastEventAt: a.lastEventAt,
                turnStartedAt: a.turnStartedAt
            )
            s.contextTokens = a.contextTokens
            s.contextWindow = Config.contextWindow(for: a.model)
            s.totalTokens = a.contextTokens + a.totalOutput
            s.toolCalls = a.toolCalls
            s.messageCount = a.messages
            s.pid = l?.pid
            s.isLive = l != nil
            s.activity = a.pending.values.first ?? a.lastToolPhrase
            s.activityKind = a.pending.isEmpty ? a.lastToolKind : a.pendingKind
            s.state = state(a, live: l != nil)
            if s.state == .needsInput && !a.pending.isEmpty {
                s.activity = (s.activity.map { $0 + " " } ?? "") + "· in attesa di conferma?"
            }
            return s
        }
    }

    private func state(_ a: Accumulator, live: Bool) -> SessionState {
        let quiet = Date().timeIntervalSince(a.lastEventAt)
        if !live { return quiet < Config.recentWindow ? .done : .idle }
        if !a.pending.isEmpty {
            // A tool that has not returned for a long time is almost always a
            // permission prompt sitting on screen waiting for the user.
            return quiet > Config.permissionSuspicion ? .needsInput : .working
        }
        if a.lastStopReason == "end_turn" || a.sawEndTurnAfterLastPrompt {
            return .needsInput
        }
        if quiet < Config.workingGrace { return .working }
        return .idle
    }

    private func fold(_ obj: [String: Any], into a: inout Accumulator) {
        let type = obj.str("type") ?? ""
        if let ts = TS.parse(obj.str("timestamp")) {
            if a.firstEventAt == nil { a.firstEventAt = ts }
            a.lastEventAt = max(a.lastEventAt, ts)
        }
        if let cwd = obj.str("cwd"), !cwd.isEmpty { a.directory = cwd }
        if let b = obj.str("gitBranch"), !b.isEmpty, b != "HEAD" { a.branch = b }

        switch type {
        case "custom-title":
            if let t = obj.str("customTitle"), !t.isEmpty { a.title = t }
        case "ai-title":
            if a.title == "Sessione", let t = obj.str("aiTitle"), !t.isEmpty { a.title = t }
        case "last-prompt":
            if a.title == "Sessione", let t = obj.str("lastPrompt") { a.title = Fmt.compact(t, max: 60) }
        case "queue-operation":
            if obj.str("operation") == "enqueue", let ts = TS.parse(obj.str("timestamp")) {
                a.turnStartedAt = ts
                a.sawEndTurnAfterLastPrompt = false
            }
        case "user":
            // A real prompt starts a new turn; a tool result does not.
            if obj["toolUseResult"] == nil {
                if let ts = TS.parse(obj.str("timestamp")) { a.turnStartedAt = ts }
                a.sawEndTurnAfterLastPrompt = false
                a.messages += 1
            }
            for c in contentBlocks(obj) where c.str("type") == "tool_result" {
                if let id = c.str("tool_use_id") { a.pending[id] = nil }
            }
        case "assistant":
            guard let msg = obj.dict("message") else { break }
            if let m = msg.str("model"), !m.hasPrefix("<") { a.model = m }
            if let u = msg.dict("usage") {
                let ctx = (u.int("input_tokens") ?? 0)
                    + (u.int("cache_read_input_tokens") ?? 0)
                    + (u.int("cache_creation_input_tokens") ?? 0)
                // Latest, not peak: compaction makes this fall, and a peak
                // would leave the gauge stuck at the high-water mark.
                if ctx > 0 { a.contextTokens = ctx }
                a.totalOutput += u.int("output_tokens") ?? 0
            }
            if let stop = msg.str("stop_reason") {
                a.lastStopReason = stop
                if stop == "end_turn" { a.sawEndTurnAfterLastPrompt = true }
            }
            for c in msg.arr("content") ?? [] where c.str("type") == "tool_use" {
                a.toolCalls += 1
                let name = c.str("name") ?? "tool"
                let phrase = toolPhrase(name: name, input: c.dict("input"))
                a.lastToolPhrase = phrase
                a.lastToolKind = Self.kind(forTool: name)
                a.pendingKind = a.lastToolKind
                if let id = c.str("id") { a.pending[id] = phrase }
                a.sawEndTurnAfterLastPrompt = false
            }
        default:
            break
        }
    }

    private func contentBlocks(_ obj: [String: Any]) -> [[String: Any]] {
        guard let msg = obj.dict("message") else { return [] }
        return msg.arr("content") ?? []
    }

    static func kind(forTool name: String) -> ActivityKind {
        switch name {
        case "Bash", "BashOutput", "KillShell": return .shell
        case "Read", "NotebookRead": return .read
        case "Edit", "Write", "NotebookEdit": return .edit
        case "Grep", "Glob", "ToolSearch": return .search
        case "WebFetch", "WebSearch": return .web
        case "Task", "Agent": return .subagent
        default: return name.hasPrefix("mcp__") ? .mcp : .none
        }
    }

    private func toolPhrase(name: String, input: [String: Any]?) -> String {
        let detail: String?
        switch name {
        case "Bash": detail = input?.str("command")
        case "Read", "Edit", "Write", "NotebookEdit":
            detail = input?.str("file_path").map { ($0 as NSString).lastPathComponent }
        case "Grep": detail = input?.str("pattern")
        case "Glob": detail = input?.str("pattern")
        case "Task", "Agent": detail = input?.str("description")
        case "WebFetch", "WebSearch": detail = input?.str("url") ?? input?.str("query")
        default: detail = nil
        }
        guard let d = detail, !d.isEmpty else { return name }
        return name + " · " + Fmt.compact(d, max: 38)
    }
}
