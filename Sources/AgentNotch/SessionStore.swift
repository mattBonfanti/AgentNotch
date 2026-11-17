import Foundation
import AppKit
import Combine

/// Polls all three providers on a background queue and publishes a single,
/// priority-sorted list of what the agents are doing.
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    /// The session the collapsed pill talks about.
    @Published private(set) var headline: AgentSession?
    /// Set briefly when a session flips to "ti aspetta" / "errore".
    @Published var alert: AgentSession?

    private let claude = ClaudeProvider()
    private let codex = CodexProvider()
    private let opencode = OpenCodeProvider()
    private let nativ = NativProvider()
    private let queue = DispatchQueue(label: "agentnotch.poll", qos: .utility)
    private var timer: Timer?
    private var previousStates: [String: SessionState] = [:]
    private var stateSince: [String: Date] = [:]
    private var alertClear: DispatchWorkItem?
    private var lastAlertAt: [String: Date] = [:]
    private var lastAnyAlertAt: Date = .distantPast
    private var tickCount = 0
    private var hasPolled = false

    var activeCount: Int { sessions.filter { $0.state == .working }.count }
    var waitingCount: Int { sessions.filter { $0.state == .needsInput || $0.state == .failed }.count }
    var hasAnything: Bool { !sessions.isEmpty }

    func start() {
        tick()
        let t = Timer(timeInterval: Config.pollInterval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        // Nothing is running: a slower cadence is plenty and keeps the app
        // near-invisible in Activity Monitor.
        tickCount += 1
        // The backoff must never swallow the first poll, or the panel stays
        // blind for the first seconds after launch.
        if hasPolled, activeCount == 0, tickCount % 3 != 0 { return }
        queue.async { [weak self] in
            guard let self else { return }
            var all = self.claude.poll() + self.codex.poll()
                + self.opencode.poll() + self.nativ.poll()
            all = all.filter { $0.isLive || $0.quietFor < Config.recentWindow }
            all.sort { a, b in
                if a.state != b.state { return a.state > b.state }
                return a.lastEventAt > b.lastEventAt
            }
            DispatchQueue.main.async { self.publish(all) }
        }
    }

    private func publish(_ incoming: [AgentSession]) {
        var incoming = incoming
        var newlyWaiting: AgentSession?
        let now = Date()
        for i in incoming.indices {
            if previousStates[incoming[i].id] != incoming[i].state {
                stateSince[incoming[i].id] = now
            }
            incoming[i].stateSince = stateSince[incoming[i].id] ?? now
        }
        for s in incoming {
            let before = previousStates[s.id]
            // Fire on any transition into a "needs you" state — but never on the
            // first sighting of a session, or launching would set off every alert.
            let becameWaiting = (s.state == .needsInput || s.state == .failed)
                && before != nil && before != s.state
            if becameWaiting, newlyWaiting == nil { newlyWaiting = s }
            previousStates[s.id] = s.state
        }
        let liveIDs = Set(incoming.map(\.id))
        previousStates = previousStates.filter { liveIDs.contains($0.key) }
        stateSince = stateSince.filter { liveIDs.contains($0.key) }
        lastAlertAt = lastAlertAt.filter { liveIDs.contains($0.key) }

        // Assigning an identical array would still fire objectWillChange and
        // redraw the whole panel every second for no reason.
        hasPolled = true
        if incoming != sessions { sessions = incoming }
        if incoming.first != headline { headline = incoming.first }

        if let n = newlyWaiting, shouldAnnounce(n) { raiseAlert(for: n) }
    }

    /// An agent finishing a turn is not the same as an agent needing you, and
    /// treating them alike meant a sound on every single turn — measured at ~24
    /// interruptions in one working session. This decides what actually earns one.
    private func shouldAnnounce(_ session: AgentSession) -> Bool {
        switch session.attention {
        case .none, .inferred:
            // Shown on the notch, never announced: it may simply be wrong.
            return false
        case .turnFinished:
            // A turn that lasted seconds ended while you were still watching it.
            if session.elapsed < Config.minWorkBeforeAlert { return false }
        case .blockedOnApproval, .failed:
            break   // genuinely stuck or broken: always worth a word
        }

        // You are already looking at the app that wants you.
        if Config.quietWhenFrontmost,
           let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           session.kind.hostBundleIDs.contains(front) {
            return false
        }

        let now = Date()
        if now.timeIntervalSince(lastAnyAlertAt) < Config.alertSpacing { return false }
        if let last = lastAlertAt[session.id],
           now.timeIntervalSince(last) < Config.alertCooldown { return false }
        lastAlertAt[session.id] = now
        lastAnyAlertAt = now
        return true
    }

    private func raiseAlert(for session: AgentSession) {
        alert = session
        if Config.soundOnAlert {
            NSSound(named: session.state == .failed ? "Basso" : "Blow")?.play()
        }
        alertClear?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.alert = nil }
        alertClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Config.alertDuration, execute: work)
    }

    /// Bring the app that owns a session to the front.
    func focus(_ session: AgentSession) {
        for id in session.kind.hostBundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: cfg)
                return
            }
        }
        revealDirectory(session)
    }

    func revealDirectory(_ session: AgentSession) {
        guard !session.directory.isEmpty else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.directory)
    }
}
