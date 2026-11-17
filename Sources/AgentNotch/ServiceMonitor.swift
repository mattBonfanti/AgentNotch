import Foundation
import Network
import SwiftUI

// MARK: - Config

/// One entry of ~/Library/Application Support/AgentNotch/services.json.
/// The `type` decides which of the other fields matter; unknown fields are
/// ignored, so new check types can be added without breaking old files.
struct ServiceSpec: Codable, Hashable, Sendable {
    var name: String
    var type: String                     // http | launchd | tcp | command
    var enabled: Bool? = true

    // http
    var url: String? = nil
    var expectStatus: Int? = nil         // default 200
    var expectKey: String? = nil         // e.g. "status"
    var expectValue: String? = nil       // e.g. "ok"
    /// Accept a self-signed certificate — honoured ONLY for 127.0.0.1,
    /// localhost and ::1, never for a remote host.
    var allowInsecureLocalhost: Bool? = nil

    // launchd
    var label: String? = nil

    // tcp
    var host: String? = nil
    var port: Int? = nil

    // command (no shell: an executable and its arguments, exit 0 = ok)
    var executable: String? = nil
    var arguments: [String]? = nil

    var timeout: Double? = nil           // seconds, default 5
}

struct ServicesFile: Codable, Sendable {
    var pollInterval: Double? = 30
    var services: [ServiceSpec]

    static let defaults = ServicesFile(pollInterval: 30, services: [
        ServiceSpec(name: "Omnesis Gateway", type: "http",
                    url: "https://127.0.0.1:7600/health",
                    expectStatus: 200, expectKey: "status", expectValue: "ok",
                    allowInsecureLocalhost: true),
        ServiceSpec(name: "Omnesis Gateway (launchd)", type: "launchd",
                    label: "dev.omnesis.gateway"),
        ServiceSpec(name: "Omnesis Collector", type: "launchd",
                    label: "dev.omnesis.collector"),
    ])

    /// AGENTNOTCH_SERVICES=/path/to/file.json points at another file (tests).
    static var url: URL {
        if let p = ProcessInfo.processInfo.environment["AGENTNOTCH_SERVICES"], !p.isEmpty {
            return URL(fileURLWithPath: p.expandingTilde)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgentNotch/services.json")
    }

    /// Reads the file, writing the defaults first if it does not exist yet.
    /// A malformed file is never overwritten: the panel reports it instead.
    static func load() -> Result<ServicesFile, Error> {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            if let data = try? enc.encode(defaults) { try? data.write(to: url) }
        }
        do {
            let data = try Data(contentsOf: url)
            return .success(try JSONDecoder().decode(ServicesFile.self, from: data))
        } catch {
            return .failure(error)
        }
    }
}

// MARK: - Status

enum ServiceHealth: Int, Comparable, Sendable {
    case unknown = 0, ok = 1, degraded = 2, down = 3
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    var word: String {
        switch self {
        case .ok: return "ok"
        case .degraded: return "anomalo"
        case .down: return "giù"
        case .unknown: return "…"
        }
    }

    var color: Color {
        switch self {
        case .ok: return SessionState.working.color
        case .degraded: return SessionState.needsInput.color
        case .down: return SessionState.failed.color
        case .unknown: return Color(white: 0.48)
        }
    }
}

struct ServiceStatus: Identifiable, Equatable, Sendable {
    var id: String { name }
    let name: String
    let health: ServiceHealth
    /// Only for the tooltip and `--services`: why it is what it is.
    let detail: String
    let checkedAt: Date?
}

// MARK: - Checks (run off the main thread)

enum ServiceChecks {
    static func run(_ spec: ServiceSpec) async -> ServiceStatus {
        let (health, detail): (ServiceHealth, String)
        switch spec.type.lowercased() {
        case "http": (health, detail) = await http(spec)
        case "launchd": (health, detail) = launchd(spec)
        case "tcp": (health, detail) = await tcp(spec)
        case "command": (health, detail) = command(spec)
        default: (health, detail) = (.unknown, "tipo sconosciuto: \(spec.type)")
        }
        return ServiceStatus(name: spec.name, health: health, detail: detail, checkedAt: Date())
    }

    static func isLoopback(_ host: String?) -> Bool {
        guard let h = host?.lowercased() else { return false }
        return h == "127.0.0.1" || h == "localhost" || h == "::1" || h == "[::1]"
    }

    // http ------------------------------------------------------------------

    private final class LocalTrust: NSObject, URLSessionDelegate {
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            let space = challenge.protectionSpace
            if space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               ServiceChecks.isLoopback(space.host), let trust = space.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }
    }

    private static func http(_ spec: ServiceSpec) async -> (ServiceHealth, String) {
        guard let raw = spec.url, let url = URL(string: raw) else { return (.unknown, "url mancante") }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = spec.timeout ?? 5
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let insecure = (spec.allowInsecureLocalhost ?? false) && isLoopback(url.host)
        let session = URLSession(configuration: config,
                                 delegate: insecure ? LocalTrust() : nil, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(from: url)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let expected = spec.expectStatus ?? 200
            guard code == expected else {
                return (code >= 500 || code == 0 ? .down : .degraded, "HTTP \(code)")
            }
            if let key = spec.expectKey {
                let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let got = obj?[key].map { "\($0)" }
                if let want = spec.expectValue, got != want {
                    return (.degraded, "\(key)=\(got ?? "nil")")
                }
            }
            return (.ok, "HTTP \(code)")
        } catch {
            return (.down, (error as NSError).localizedDescription)
        }
    }

    // launchd ---------------------------------------------------------------

    private static func launchd(_ spec: ServiceSpec) -> (ServiceHealth, String) {
        guard let label = spec.label, !label.isEmpty else { return (.unknown, "label mancante") }
        let out = runProcess("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"],
                             timeout: spec.timeout ?? 5)
        guard out.status == 0 else { return (.down, "non caricato") }
        let lines = out.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let state = lines.first { $0.hasPrefix("state = ") }?.dropFirst(8)
        let pid = lines.first { $0.hasPrefix("pid = ") }?.dropFirst(6)
        if state == "running", pid != nil { return (.ok, "running") }
        let exit = lines.first { $0.hasPrefix("last exit code = ") }?.dropFirst(17)
        return (.down, "\(state.map(String.init) ?? "fermo")\(exit.map { ", exit \($0)" } ?? "")")
    }

    // tcp -------------------------------------------------------------------

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }

    private static func tcp(_ spec: ServiceSpec) async -> (ServiceHealth, String) {
        guard let host = spec.host, let port = spec.port,
              let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            return (.unknown, "host/porta mancanti")
        }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
        let queue = DispatchQueue(label: "agentnotch.tcp")
        let once = Once()
        return await withCheckedContinuation { cont in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { conn.cancel(); cont.resume(returning: (.ok, "raggiungibile")) }
                case .failed(let e), .waiting(let e):
                    if once.claim() { conn.cancel(); cont.resume(returning: (.down, "\(e)")) }
                default: break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + (spec.timeout ?? 5)) {
                if once.claim() { conn.cancel(); cont.resume(returning: (.down, "timeout")) }
            }
        }
    }

    // command ---------------------------------------------------------------

    private static func command(_ spec: ServiceSpec) -> (ServiceHealth, String) {
        guard let exe = spec.executable else { return (.unknown, "executable mancante") }
        let out = runProcess(exe, spec.arguments ?? [], timeout: spec.timeout ?? 5)
        return out.status == 0 ? (.ok, "exit 0") : (.down, "exit \(out.status)")
    }

    static func runProcess(_ path: String, _ args: [String], timeout: Double) -> (status: Int32, stdout: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "") }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func runAll(_ specs: [ServiceSpec]) async -> [ServiceStatus] {
        await withTaskGroup(of: (Int, ServiceStatus).self) { group in
            for (i, spec) in specs.enumerated() {
                group.addTask { (i, await run(spec)) }
            }
            var out: [(Int, ServiceStatus)] = []
            for await r in group { out.append(r) }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
}

// MARK: - Monitor

/// Re-reads services.json and checks every service off the main thread, at
/// the cadence the file asks for (30s by default). Like SessionStore, it only
/// touches its published state on the main thread.
final class ServiceMonitor: ObservableObject {
    @Published private(set) var statuses: [ServiceStatus] = []
    @Published private(set) var configError: String?

    private var timer: Timer?
    private var interval: Double = 30
    private var inFlight = false

    var worst: ServiceHealth { statuses.map(\.health).max() ?? .unknown }
    /// Rows the panel reserves: one for a config error, else one per service.
    var rowCount: Int { configError != nil ? 1 : min(statuses.count, ServicesSection.maxRows) }
    var problemCount: Int { statuses.filter { $0.health == .down || $0.health == .degraded }.count }

    func start() {
        guard timer == nil else { return }
        refresh()
        schedule()
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func schedule() {
        timer?.invalidate()
        let t = Timer(timeInterval: max(5, interval), repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// One pass. Never overlaps a pass still running (a slow host times out
    /// after a few seconds, but never stacks up).
    func refresh() {
        guard !inFlight else { return }
        inFlight = true
        Task.detached(priority: .utility) { [weak self] in
            let loaded = ServicesFile.load()
            var results: [ServiceStatus] = []
            var error: String?
            var wanted: Double = 30
            switch loaded {
            case .failure(let e): error = "services.json: \(e.localizedDescription)"
            case .success(let file):
                wanted = file.pollInterval ?? 30
                results = await ServiceChecks.runAll(file.services.filter { $0.enabled ?? true })
            }
            let r = results, err = error, w = wanted
            DispatchQueue.main.async { self?.publish(r, error: err, interval: w) }
        }
    }

    private func publish(_ results: [ServiceStatus], error: String?, interval wanted: Double) {
        inFlight = false
        if configError != error { configError = error }
        if error == nil, results != statuses { statuses = results }
        if wanted != interval { interval = wanted; schedule() }
    }
}

// MARK: - View

/// The services strip at the bottom of the expanded panel: a dot, a name and
/// one word per service. Everything else lives in the tooltip.
struct ServicesSection: View {
    @ObservedObject var monitor: ServiceMonitor
    static let rowHeight: CGFloat = 18
    static let headerHeight: CGFloat = 18
    static let maxRows = 6

    static func height(rows: Int) -> CGFloat {
        rows == 0 ? 0 : headerHeight + CGFloat(min(rows, maxRows)) * rowHeight + 8
    }

    private static let time: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("SERVIZI")
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .tracking(1.5)
                    .foregroundStyle(.white.opacity(0.38))
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.7)
            }
            .frame(height: Self.headerHeight)
            .padding(.horizontal, 11)

            if let err = monitor.configError {
                Text(err).font(.system(size: 10)).foregroundStyle(ServiceHealth.degraded.color)
                    .lineLimit(1).padding(.horizontal, 11).frame(height: Self.rowHeight)
            } else {
                ForEach(monitor.statuses.prefix(Self.maxRows)) { s in
                    HStack(spacing: 8) {
                        Circle().fill(s.health.color).frame(width: 7, height: 7)
                        Text(s.name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(s.health.word)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(s.health == .ok ? .white.opacity(0.45) : s.health.color)
                    }
                    .padding(.horizontal, 13)
                    .frame(height: Self.rowHeight)
                    .contentShape(Rectangle())
                    .help(s.detail + (s.checkedAt.map { "  ·  " + Self.time.string(from: $0) } ?? ""))
                }
            }
        }
        .padding(.horizontal, 7)
        .padding(.bottom, 6)
    }
}
