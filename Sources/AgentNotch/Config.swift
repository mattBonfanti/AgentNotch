import Foundation

enum Config {
    /// A session quiet for longer than this drops off the notch entirely.
    static let recentWindow: TimeInterval = {
        if let raw = ProcessInfo.processInfo.environment["AGENTNOTCH_WINDOW_MIN"],
           let m = Double(raw), m > 0 { return m * 60 }
        return 20 * 60
    }()
    /// After the last event, how long we still call a session "al lavoro".
    static let workingGrace: TimeInterval = 90
    /// A tool call outstanding this long *might* be a permission prompt. Measured
    /// against real transcripts, 35s was far too eager: ordinary builds and test
    /// runs sat at 37–122s and every one of them was mistaken for a prompt. It is
    /// now a slow visual hint only — it never makes a sound.
    static let permissionSuspicion: TimeInterval = 180
    /// A turn shorter than this finished while you were almost certainly still
    /// watching, so its completion is not worth an interruption.
    static let minWorkBeforeAlert: TimeInterval = 45
    /// One announcement per session per this interval, whatever happens.
    static let alertCooldown: TimeInterval = 180
    /// And a floor between any two announcements, so three agents finishing at
    /// once cannot machine-gun you.
    static let alertSpacing: TimeInterval = 12
    /// Nativ answers over HTTP, so "reachable" replaces "recently written to".
    /// Past this, the last snapshot is treated as dead rather than current.
    static let nativStaleAfter: TimeInterval = 8
    /// How long a newly failed request keeps the indicator red.
    static let nativFailureWindow: TimeInterval = 20
    /// Re-reading the process table to find the port is only worth doing when
    /// the endpoint stops answering.
    static let nativDiscoveryInterval: TimeInterval = 10

    /// Poll cadence for all providers.
    static let pollInterval: TimeInterval = 1.0
    /// How long the halo breathes after an agent asks for attention. It then
    /// settles to a static glow: a pulse that never stops becomes wallpaper,
    /// and it keeps the display link spinning for as long as you ignore it.
    static let pulseDuration: TimeInterval = 20
    /// How long an alert holds the notch open before it collapses again.
    static let alertDuration: TimeInterval = 4.5

    /// Only Codex writes its context window to disk. Guessing it for the others
    /// produced false "contesto pieno" alarms — a Claude Code session was sitting
    /// at 226k against an assumed 200k ceiling — so an unknown window means no
    /// gauge at all, just the raw token count.
    /// Add an entry here only when you know the real number for a model.
    static let knownWindows: [String: Int] = [:]

    static func contextWindow(for model: String?) -> Int {
        guard let m = model?.lowercased() else { return 0 }
        for (key, value) in knownWindows where m.contains(key) { return value }
        return 0
    }

    /// The cutout's bounding box is exact (the public aux-area maths agrees to
    /// the point with AppKit's private `_notchFrame`), but nothing exposes the
    /// curvature of its corners, so this is matched by eye and left adjustable
    /// at runtime — no rebuild needed:
    ///   defaults write local.agentnotch notchCornerRadius -float 8
    static var notchCornerRadius: CGFloat {
        let v = UserDefaults.standard.double(forKey: "notchCornerRadius")
        return v > 0 ? CGFloat(v) : 10
    }

    /// Thickness of the line that traces the notch. Tunable at runtime:
    ///   defaults write local.agentnotch notchLineWidth -float 3
    static var notchLineWidth: CGFloat {
        let v = UserDefaults.standard.double(forKey: "notchLineWidth")
        return v > 0 ? CGFloat(v) : 2.4
    }

    /// How the notch reports at a glance when nothing is hovered.
    enum IndicatorStyle: String {
        case line     // a coloured line tracing the cutout, occupying no space
        case island   // a small island beside the notch: dots left, symbol right
    }

    // Persisted preferences
    private static let d = UserDefaults.standard
    static var soundOnAlert: Bool {
        get { d.object(forKey: "soundOnAlert") as? Bool ?? true }
        set { d.set(newValue, forKey: "soundOnAlert") }
    }
    static var autoExpandOnAlert: Bool {
        get { d.object(forKey: "autoExpandOnAlert") as? Bool ?? true }
        set { d.set(newValue, forKey: "autoExpandOnAlert") }
    }
    static var indicatorStyle: IndicatorStyle {
        get { IndicatorStyle(rawValue: d.string(forKey: "indicatorStyle") ?? "") ?? .line }
        set { d.set(newValue.rawValue, forKey: "indicatorStyle") }
    }

    /// One coloured arc per working agent, instead of a single outline tinted
    /// by the most urgent state.
    static var glowPerAgent: Bool {
        get { d.object(forKey: "glowPerAgent") as? Bool ?? true }
        set { d.set(newValue, forKey: "glowPerAgent") }
    }
    /// Stay silent about an agent whose own app is in front of you: you are
    /// already looking at it.
    static var quietWhenFrontmost: Bool {
        get { d.object(forKey: "quietWhenFrontmost") as? Bool ?? true }
        set { d.set(newValue, forKey: "quietWhenFrontmost") }
    }
    static var showWhenIdle: Bool {
        get { d.object(forKey: "showWhenIdle") as? Bool ?? false }
        set { d.set(newValue, forKey: "showWhenIdle") }
    }
}
