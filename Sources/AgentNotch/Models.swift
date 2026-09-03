import Foundation

enum AgentKind: String, CaseIterable, Codable {
    case claude
    case codex
    case opencode

    var label: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        }
    }

    /// Short tag drawn inside the compact pill.
    var tag: String {
        switch self {
        case .claude: return "CC"
        case .codex: return "CX"
        case .opencode: return "OC"
        }
    }

    /// Bundle identifiers we try, in order, when the user clicks a row.
    var hostBundleIDs: [String] {
        switch self {
        case .claude: return ["com.anthropic.claudefordesktop", "com.anthropic.claude"]
        case .codex: return ["com.openai.codex", "com.openai.chat"]
        case .opencode: return ["ai.opencode.desktop", "dev.opencode.desktop"]
        }
    }
}

/// Ordered by how loudly it deserves the user's attention.
enum SessionState: Int, Comparable, Codable {
    case done = 0
    case idle = 1
    case working = 2
    case needsInput = 3
    case failed = 4

    static func < (a: SessionState, b: SessionState) -> Bool { a.rawValue < b.rawValue }

    var shortLabel: String {
        switch self {
        case .done: return "fatto"
        case .idle: return "in pausa"
        case .working: return "al lavoro"
        case .needsInput: return "ti aspetta"
        case .failed: return "errore"
        }
    }

    var symbol: String {
        switch self {
        case .done: return "checkmark.circle.fill"
        case .idle: return "pause.circle.fill"
        case .working: return "circle.hexagongrid.circle"
        case .needsInput: return "hand.raised.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
}

/// What the agent is doing right now, as a symbol the eye can decode without
/// reading. Set by each provider from its own event vocabulary.
enum ActivityKind: String, Equatable {
    case shell, read, edit, search, web, subagent, mcp, thinking, file, none

    var symbol: String {
        switch self {
        case .shell: return "terminal.fill"
        case .read: return "doc.text.fill"
        case .edit: return "pencil.line"
        case .search: return "magnifyingglass"
        case .web: return "globe"
        case .subagent: return "person.2.fill"
        case .mcp: return "puzzlepiece.extension.fill"
        case .thinking: return "sparkles"
        case .file: return "doc.on.doc.fill"
        case .none: return "circle.dashed"
        }
    }
}

struct AgentSession: Identifiable, Equatable {
    var id: String
    var kind: AgentKind
    var title: String
    var directory: String
    var branch: String?
    var model: String?
    var state: SessionState = .idle
    /// Human phrase for what is happening right now ("Bash · swift build").
    var activity: String?
    var activityKind: ActivityKind = .none
    var startedAt: Date
    var lastEventAt: Date
    /// When the current turn began — drives the elapsed timer.
    var turnStartedAt: Date?
    var contextTokens: Int = 0
    var contextWindow: Int = 0
    var totalTokens: Int = 0
    var cost: Double = 0
    var toolCalls: Int = 0
    var messageCount: Int = 0
    var todosDone: Int = 0
    var todosTotal: Int = 0
    /// When the session last changed state — drives how long the halo pulses.
    var stateSince: Date = .distantPast
    var pid: pid_t?
    var isLive: Bool = true
    /// Percentage of the plan's rate limit consumed, when the agent reports it.
    var rateLimitPercent: Double?

    var project: String {
        let base = (directory as NSString).lastPathComponent
        if base.isEmpty || base == "/" { return "/" }
        return base
    }

    var contextPercent: Double {
        guard contextWindow > 0 else { return 0 }
        return min(1.0, Double(contextTokens) / Double(contextWindow))
    }

    var elapsed: TimeInterval {
        Date().timeIntervalSince(turnStartedAt ?? lastEventAt)
    }

    var quietFor: TimeInterval { Date().timeIntervalSince(lastEventAt) }

    /// Breathe only while the news is fresh, then hold a steady glow.
    var wantsPulse: Bool {
        guard state == .needsInput || state == .failed else { return false }
        return Date().timeIntervalSince(stateSince) < Config.pulseDuration
    }
}

// MARK: - Formatting

enum Fmt {
    static func duration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }

    static func shortDuration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if s < 3600 { return String(format: "%d:%02d", s / 60, s % 60) }
        return String(format: "%dh%02d", s / 3600, (s % 3600) / 60)
    }

    static func tokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fk", Double(n) / 1_000) }
        return "\(n)"
    }

    static func cost(_ c: Double) -> String {
        c >= 1 ? String(format: "$%.2f", c) : String(format: "%.0f¢", c * 100)
    }

    /// Collapses a shell command or long tool argument into one readable line.
    static func compact(_ s: String, max: Int = 46) -> String {
        var t = s.replacingOccurrences(of: "\n", with: " ")
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespaces)
        if t.count <= max { return t }
        return String(t.prefix(max - 1)) + "…"
    }
}

// MARK: - Small helpers

func processIsAlive(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
}

extension String {
    var expandingTilde: String { (self as NSString).expandingTildeInPath }
}
