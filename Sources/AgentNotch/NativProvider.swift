import Foundation

/// Reads Nativ (io.github.blaizzy.nativ), the local MLX inference app.
///
/// Two sources, because they answer different questions:
///
/// - `/metrics` over HTTP describes the **server**: is a request in flight, what
///   model is resident, how fast it is decoding, how much memory it holds. This
///   also covers requests that never touch Nativ's UI — OpenCode points at the
///   same endpoint.
/// - The chat session files describe the **app**: which conversation is running,
///   and — the signal that matters most — whether a tool call is parked at
///   `awaitingConsent`, waiting for the user to approve it.
///
/// The server alone is not enough: while Nativ waits for you to confirm a
/// command, `in_flight` is 0 and the server looks idle. What is blocked is the
/// app, not the model.
final class NativProvider {

    // MARK: - Server snapshot

    private struct Snapshot {
        var fetchedAt: Date
        var loadedModel: String?
        var toolParser: String?
        var contextLimit: Int
        var inFlight: Int
        var queueDepth: Int
        var requestsCompleted: Int
        var requestsFailed: Int
        var uptime: TimeInterval
        var lastRequestAt: Date?
        var decodeTokensPerSecond: Double
        var peakMemoryGB: Double
        var lastTotalTokens: Int
    }

    private let lock = NSLock()
    private var snapshot: Snapshot?
    private var endpoint: URL?
    private var lastDiscovery: Date = .distantPast
    private var inFlightFetch = false
    private var lastFailureCount = -1
    private var failedSince: Date?
    /// When the server first reported work in flight. `last_request_at` marks the
    /// last request to *finish*, so it would time a running generation from the
    /// wrong moment — often minutes off.
    private var busySince: Date?

    // MARK: - Chat sessions

    private struct Chat {
        var id: String
        var title: String
        var updatedAt: Date
        var model: String?
        var streaming: Bool
        /// Set when a tool call is parked waiting for the user to approve it.
        var awaitingTool: String?
        var awaitingDetail: String?
        var messageCount: Int
        var toolCount: Int
        var decodeTokensPerSecond: Double
        var peakMemoryGB: Double
        var generatedTokens: Int
    }

    private let chatDir = "~/Library/Application Support/Nativ/Chat/Sessions".expandingTilde
    private var chatCache: [String: (modified: Date, chat: Chat?)] = [:]

    // MARK: - Polling

    func poll() -> [AgentSession] {
        refreshAsync()

        lock.lock()
        let snap = snapshot
        let failedAt = failedSince
        let startedWorkAt = busySince
        lock.unlock()

        let serverUp = snap.map { Date().timeIntervalSince($0.fetchedAt) < Config.nativStaleAfter } ?? false
        let chats = loadChats()

        var sessions = chats.map { session(for: $0, snapshot: snap) }

        guard serverUp, let snap, let model = snap.loadedModel, !model.isEmpty else {
            return sessions
        }

        let busy = snap.inFlight > 0 || snap.queueDepth > 0
        let aChatIsGenerating = chats.contains { $0.streaming }

        if busy && !aChatIsGenerating {
            // The server is working but no conversation in Nativ accounts for it,
            // so the caller is someone else — OpenCode, or anything else aimed here.
            var s = serverSession(model: model, snap: snap)
            s.state = .working
            s.turnStartedAt = startedWorkAt ?? Date()
            var parts: [String] = []
            if snap.decodeTokensPerSecond > 0 {
                parts.append(String(format: "%.0f tok/s", snap.decodeTokensPerSecond))
            }
            if snap.peakMemoryGB > 0 { parts.append(String(format: "%.1f GB", snap.peakMemoryGB)) }
            if snap.queueDepth > 0 { parts.append("in coda \(snap.queueDepth)") }
            parts.append("client esterno")
            s.activity = parts.joined(separator: " · ")
            sessions.append(s)
        } else if sessions.isEmpty {
            // Nothing going on: still worth saying a model is resident, because on
            // 16 GB knowing what holds the memory is the useful fact.
            var s = serverSession(model: model, snap: snap)
            if let failedAt, Date().timeIntervalSince(failedAt) < Config.nativFailureWindow {
                s.state = .failed
                s.attention = .failed
                s.activity = "richiesta fallita"
            } else {
                s.state = .idle
                var parts = ["caricato"]
                if snap.peakMemoryGB > 0 { parts.append(String(format: "%.1f GB", snap.peakMemoryGB)) }
                if let parser = snap.toolParser, !parser.isEmpty { parts.append("tool: " + parser) }
                s.activity = parts.joined(separator: " · ")
            }
            sessions.append(s)
        }
        return sessions
    }

    private func serverSession(model: String, snap: Snapshot) -> AgentSession {
        var s = AgentSession(
            id: "nativ:server",
            kind: .nativ,
            title: "Modello locale",
            // `directory` drives the project label; for a model server the useful
            // "project" is the model itself.
            directory: model,
            branch: nil,
            model: shortModel(model),
            startedAt: Date().addingTimeInterval(-snap.uptime),
            // A live service, not a transcript: current as long as it answers.
            lastEventAt: Date(),
            turnStartedAt: snap.lastRequestAt
        )
        s.contextTokens = snap.lastTotalTokens
        s.contextWindow = snap.contextLimit
        s.totalTokens = snap.lastTotalTokens
        s.messageCount = snap.requestsCompleted
        s.activityKind = .inference
        s.isLive = true
        return s
    }

    private func session(for chat: Chat, snapshot snap: Snapshot?) -> AgentSession {
        let model = chat.model ?? snap?.loadedModel ?? ""
        var s = AgentSession(
            id: "nativ:chat:" + chat.id,
            kind: .nativ,
            title: chat.title,
            directory: model,
            branch: nil,
            model: shortModel(model),
            startedAt: chat.updatedAt,
            lastEventAt: chat.updatedAt,
            turnStartedAt: chat.updatedAt
        )
        s.messageCount = chat.messageCount
        s.toolCalls = chat.toolCount
        s.contextTokens = chat.generatedTokens
        s.totalTokens = chat.generatedTokens
        s.contextWindow = snap?.contextLimit ?? 0
        s.isLive = true

        var speed: [String] = []
        if chat.decodeTokensPerSecond > 0 {
            speed.append(String(format: "%.0f tok/s", chat.decodeTokensPerSecond))
        }
        if chat.peakMemoryGB > 0 { speed.append(String(format: "%.1f GB", chat.peakMemoryGB)) }

        if let tool = chat.awaitingTool {
            s.state = .needsInput
            // Nativ says so in the file: it is stuck until you answer.
            s.attention = .blockedOnApproval
            s.activityKind = tool == "terminal" ? .shell : .mcp
            let what = chat.awaitingDetail.map { Fmt.compact($0, max: 32) }
            s.activity = "conferma " + tool + (what.map { " · " + $0 } ?? "")
            // A pending approval must not age out of the panel: it stays true
            // until the user answers, however long that takes.
            s.lastEventAt = Date()
        } else if chat.streaming {
            s.state = .working
            s.activityKind = .inference
            s.activity = speed.isEmpty ? "genera…" : speed.joined(separator: " · ")
            s.lastEventAt = Date()
        } else {
            // A finished turn in a chat window is the app's resting state, not
            // something demanding attention — the notch stays quiet.
            s.state = .idle
            s.activityKind = .inference
            s.activity = speed.isEmpty ? nil : speed.joined(separator: " · ")
        }
        return s
    }

    /// Trims `mlx-community/Qwen3-14B-4bit` down to what fits a notch row.
    private func shortModel(_ id: String) -> String {
        id.split(separator: "/").last.map(String.init) ?? id
    }

    // MARK: - Chat parsing

    private func loadChats() -> [Chat] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: chatDir) else { return [] }
        let cutoff = Date().addingTimeInterval(-Config.recentWindow)

        var seen = Set<String>()
        var chats: [Chat] = []
        for name in names where name.hasSuffix(".json") {
            let path = chatDir + "/" + name
            let attrs = try? fm.attributesOfItem(atPath: path)
            let modified = (attrs?[.modificationDate] as? Date) ?? .distantPast
            seen.insert(path)

            let parsed: Chat?
            if let cached = chatCache[path], cached.modified == modified {
                parsed = cached.chat          // re-parsing an unchanged file is waste
            } else {
                parsed = parseChat(path: path, modified: modified)
                chatCache[path] = (modified, parsed)
            }
            // A conversation waiting for consent stays on the list no matter how
            // long it has been sitting there: that is exactly when it matters.
            if let parsed, modified > cutoff || parsed.awaitingTool != nil {
                chats.append(parsed)
            }
        }
        chatCache = chatCache.filter { seen.contains($0.key) }
        return chats.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func parseChat(path: String, modified: Date) -> Chat? {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj.str("id")
        else { return nil }

        let messages = obj.arr("messages") ?? []
        guard !messages.isEmpty else { return nil }   // an empty "New chat" says nothing

        var chat = Chat(
            id: id,
            title: Fmt.compact(obj.str("title") ?? "Chat", max: 54),
            updatedAt: TS.parse(obj.str("updatedAt")) ?? modified,
            model: nil,
            streaming: false,
            awaitingTool: nil,
            awaitingDetail: nil,
            messageCount: 0,
            toolCount: 0,
            decodeTokensPerSecond: 0,
            peakMemoryGB: 0,
            generatedTokens: 0
        )

        for message in messages {
            let role = message.str("role") ?? ""
            if let m = message.str("modelID"), !m.isEmpty { chat.model = m }
            if (message["isStreaming"] as? Bool) == true { chat.streaming = true }

            switch role {
            case "user", "assistant":
                chat.messageCount += 1
                if let metrics = message.dict("responseMetrics") {
                    chat.decodeTokensPerSecond = metrics.dbl("decodeTokensPerSecond")
                        ?? chat.decodeTokensPerSecond
                    chat.peakMemoryGB = metrics.dbl("peakMemoryGB") ?? chat.peakMemoryGB
                    chat.generatedTokens += metrics.int("generatedTokens") ?? 0
                }
            case "tool":
                chat.toolCount += 1
                // The signal the server cannot see: Nativ is holding this tool
                // call until the user presses Confirm.
                if message.str("toolStatus") == "awaitingConsent" {
                    chat.awaitingTool = message.str("toolName") ?? "tool"
                    chat.awaitingDetail = toolDetail(message)
                }
            default:
                break
            }
        }
        return chat
    }

    /// Pulls the readable part out of a pending tool call's arguments. Nativ
    /// stores them as a JSON *string*, not as a nested object.
    private func toolDetail(_ message: [String: Any]) -> String? {
        var args = message.dict("toolArguments")
        if args == nil, let raw = message.str("toolArguments"), let data = raw.data(using: .utf8) {
            args = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        guard let args else { return nil }
        for key in ["command", "path", "file_path", "query", "url", "name"] {
            if let value = args.str(key), !value.isEmpty { return value }
        }
        return nil
    }

    // MARK: - HTTP

    private func debug(_ message: String) {
        guard ProcessInfo.processInfo.environment["AGENTNOTCH_DEBUG"] != nil else { return }
        FileHandle.standardError.write("[nativ] \(message)\n".data(using: .utf8)!)
    }

    /// Never blocks the poll queue: it kicks off a request and serves whatever
    /// the previous one returned. A hung server costs a stale snapshot, not a
    /// stalled panel.
    private func refreshAsync() {
        lock.lock()
        if inFlightFetch { lock.unlock(); return }
        inFlightFetch = true
        var base = endpoint
        lock.unlock()

        if base == nil {
            base = discoverEndpoint()
            lock.lock(); endpoint = base; lock.unlock()
        }
        guard let url = base?.appendingPathComponent("metrics") else {
            lock.lock(); inFlightFetch = false; lock.unlock()
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        request.httpMethod = "GET"
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self else { return }
            defer { self.lock.lock(); self.inFlightFetch = false; self.lock.unlock() }
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self.debug("irraggiungibile: \(error.map { $0.localizedDescription } ?? "nessun dato")")
                // Wrong port, or Nativ quit and something else holds it now.
                self.lock.lock()
                self.endpoint = nil
                self.snapshot = nil
                self.lock.unlock()
                return
            }
            self.absorb(obj)
        }.resume()
    }

    private func absorb(_ obj: [String: Any]) {
        let summary = obj.dict("summary") ?? [:]
        let server = obj.dict("server") ?? [:]
        let latest = obj.dict("latest") ?? [:]

        var snap = Snapshot(
            fetchedAt: Date(),
            loadedModel: server.str("loaded_model"),
            toolParser: server.str("loaded_tool_parser"),
            contextLimit: server.int("effective_context_limit")
                ?? server.int("configured_context_limit") ?? 0,
            inFlight: summary.int("in_flight") ?? 0,
            queueDepth: server.int("request_queue_depth") ?? 0,
            requestsCompleted: summary.int("requests_completed") ?? 0,
            requestsFailed: summary.int("requests_failed") ?? 0,
            uptime: summary.dbl("uptime_s") ?? 0,
            lastRequestAt: summary.dbl("last_request_at").map { Date(timeIntervalSince1970: $0) },
            decodeTokensPerSecond: latest.dbl("decode_tok_s") ?? 0,
            peakMemoryGB: latest.dbl("peak_memory_gb") ?? 0,
            lastTotalTokens: latest.int("total_tokens") ?? 0
        )
        if snap.loadedModel == nil { snap.loadedModel = latest.str("model") }

        lock.lock()
        // Only a *new* failure is worth a red notch; a counter sitting at 3 since
        // this morning is history, not news.
        if lastFailureCount >= 0, snap.requestsFailed > lastFailureCount {
            failedSince = Date()
        }
        lastFailureCount = snap.requestsFailed
        if snap.inFlight > 0 || snap.queueDepth > 0 {
            if busySince == nil { busySince = Date() }
        } else {
            busySince = nil
        }
        snapshot = snap
        lock.unlock()
    }

    /// Finds the endpoint from the server process's own arguments, so a user who
    /// moves Nativ off port 8080 is still monitored.
    private func discoverEndpoint() -> URL? {
        // Lets you point at a Nativ running elsewhere, and makes the provider
        // testable against a captured payload:
        //   AGENTNOTCH_NATIV_URL=http://127.0.0.1:9999
        if let override = ProcessInfo.processInfo.environment["AGENTNOTCH_NATIV_URL"],
           let url = URL(string: override) {
            return url
        }
        guard Date().timeIntervalSince(lastDiscovery) > Config.nativDiscoveryInterval else {
            return URL(string: "http://127.0.0.1:8080")
        }
        lastDiscovery = Date()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Ao", "args"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return URL(string: "http://127.0.0.1:8080") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.contains("nativ_server") {
            let parts = line.split(separator: " ").map(String.init)
            var host = "127.0.0.1", port = "8080"
            for (i, part) in parts.enumerated() where i + 1 < parts.count {
                if part == "--host" { host = parts[i + 1] }
                if part == "--port" { port = parts[i + 1] }
            }
            return URL(string: "http://\(host):\(port)")
        }
        return nil
    }
}
