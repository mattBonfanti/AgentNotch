import SwiftUI
import AppKit

enum NotchMode: Equatable {
    case hidden      // nothing running: the notch is just a notch
    case glow        // a coloured line on the bezel, occupying no space
    case compact     // a small island beside the notch: dots left, symbol right
    case alert       // an agent handed control back: the island opens briefly
    case expanded    // full list, on hover
}

struct NotchGeometry {
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var hasHardwareNotch: Bool

    static let fallback = NotchGeometry(notchWidth: 180, notchHeight: 26, hasHardwareNotch: false)
}

final class NotchViewModel: ObservableObject {
    @Published var mode: NotchMode = .hidden
    @Published var geometry: NotchGeometry = .fallback
    /// Bumped once a second while visible, so elapsed timers advance.
    @Published var tick: Int = 0
}

struct NotchView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var vm: NotchViewModel

    static let expandedWidth: CGFloat = 462
    static let rowHeight: CGFloat = 50
    static let compactSide: CGFloat = 62
    static let alertExtraWidth: CGFloat = 300
    static let alertExtraHeight: CGFloat = 36

    private var notchW: CGFloat { max(vm.geometry.notchWidth, 8) }
    private var notchH: CGFloat { max(vm.geometry.notchHeight, 26) }

    private var visibleSessions: [AgentSession] { Array(store.sessions.prefix(4)) }
    private var alertSession: AgentSession? { store.alert ?? store.headline }

    static func size(mode: NotchMode, geometry: NotchGeometry, rows: Int) -> CGSize {
        let w = max(geometry.notchWidth, 8)
        let h = max(geometry.notchHeight, 26)
        switch mode {
        case .hidden, .glow:
            return CGSize(width: w, height: h)
        case .compact:
            return CGSize(width: w + compactSide * 2, height: h)
        case .alert:
            return CGSize(width: w + alertExtraWidth, height: h + alertExtraHeight)
        case .expanded:
            let body = CGFloat(max(min(rows, 4), 1)) * rowHeight + 14
            return CGSize(width: expandedWidth, height: h + body)
        }
    }

    private var currentSize: CGSize {
        Self.size(mode: vm.mode, geometry: vm.geometry, rows: visibleSessions.count)
    }

    private var isIsland: Bool {
        vm.mode == .compact || vm.mode == .alert || vm.mode == .expanded
    }
    private var bottomRadius: CGFloat { vm.mode == .expanded ? 26 : (vm.mode == .alert ? 20 : 13) }
    private var topRadius: CGFloat { vm.mode == .expanded ? 11 : 7 }

    private var shape: NotchShape {
        NotchShape(bottomRadius: bottomRadius, topRadius: topRadius)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
            notchLine
            if isIsland { island }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.40, dampingFraction: 0.74), value: vm.mode)
        .animation(.spring(response: 0.40, dampingFraction: 0.74), value: visibleSessions.count)
    }

    // MARK: - Halo

    /// Agents worth signalling, in a stable order so an arc or a dot does not
    /// change colour when an unrelated session appears.
    private var signallingSessions: [AgentSession] {
        store.sessions
            .filter { $0.state.deservesGlow }
            .sorted { ($0.kind.rawValue, $0.id) < ($1.kind.rawValue, $1.id) }
            .prefix(4)
            .map { $0 }
    }

    /// In glow mode the halo traces the physical cutout; once the island is
    /// open it traces the island instead, so the two read as one object.
    private var lineRadius: CGFloat {
        isIsland ? bottomRadius : Config.notchCornerRadius
    }

    /// Everything the halo needs, and nothing that changes by the second. The
    /// working session updates its tokens and elapsed time constantly; without
    /// this the nine blurred strokes were being re-rasterised on every tick.
    private var lineSpec: NotchLineSpec {
        var arcs: [NotchLineSpec.Arc] = []
        let sessions = signallingSessions
        if Config.glowPerAgent, !sessions.isEmpty {
            let n = sessions.count
            let span = 1.0 / CGFloat(n)
            let gap: CGFloat = n > 1 ? 0.022 : 0
            for (index, session) in sessions.enumerated() {
                arcs.append(.init(
                    id: session.id,
                    from: CGFloat(index) * span + gap,
                    to: CGFloat(index + 1) * span - gap,
                    color: session.state == .working ? session.kind.tint : session.state.color,
                    pulsing: session.wantsPulse
                ))
            }
        } else if let worst = sessions.map(\.state).max() {
            arcs.append(.init(id: "all", from: 0, to: 1, color: worst.color,
                              pulsing: sessions.contains { $0.wantsPulse }))
        }
        return NotchLineSpec(arcs: arcs, size: currentSize,
                             radius: lineRadius, topRadius: isIsland ? topRadius : 0)
    }

    @ViewBuilder
    private var notchLine: some View {
        // The line and the compact island are alternatives, never both.
        if Config.indicatorStyle == .line, vm.mode != .hidden, !lineSpec.arcs.isEmpty {
            NotchLineView(spec: lineSpec).equatable()
        }
    }

    // MARK: - Island

    private var island: some View {
        content
            .frame(width: currentSize.width, height: currentSize.height, alignment: .top)
            .background(glass)
            .clipShape(shape)
            .overlay(
                // Glass edge on the sides and bottom only. The closed shape put a
                // hairline along the screen edge and around the top fillets, which
                // read as a stray grey line rather than as light on glass.
                NotchOutline(bottomRadius: bottomRadius, topRadius: topRadius).stroke(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0), location: 0),
                            .init(color: .white.opacity(0.05), location: 0.35),
                            .init(color: .white.opacity(0.13), location: 1)
                        ],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 0.8
                )
            )
            .shadow(color: .black.opacity(0.55), radius: 24, y: 10)
    }

    /// Opaque black where it meets the notch — so it reads as the hardware —
    /// turning to glass as it drapes down over the desktop.
    private var glass: some View {
        let fade = min(0.95, max(0.05, notchH / currentSize.height))
        return ZStack {
            // The compact island sits entirely in the menu bar strip and has to
            // read as hardware, so it stays solid black — no backdrop sampling.
            if vm.mode != .compact { GlassBackdrop() }
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: fade),
                    .init(color: .black.opacity(vm.mode == .expanded ? 0.80
                                                : vm.mode == .alert ? 0.92 : 1.0), location: 1)
                ],
                startPoint: .top, endPoint: .bottom
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        switch vm.mode {
        case .hidden, .glow:
            Color.clear
        case .compact:
            compactContent
                .transition(.opacity)
        case .alert:
            alertContent
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
        case .expanded:
            expanded
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
        }
    }

    // MARK: - Compact island

    /// The session the right-hand symbol speaks for: the most urgent one.
    private var leadSession: AgentSession? {
        signallingSessions.max { $0.state < $1.state } ?? store.headline
    }

    private var compactContent: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                ForEach(signallingSessions.prefix(3)) { session in
                    StatusPip(color: session.state == .working
                              ? session.kind.tint : session.state.color,
                              pulsing: session.wantsPulse)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 14)
            .frame(width: Self.compactSide, alignment: .leading)

            Spacer(minLength: 0).frame(width: notchW)

            HStack(spacing: 4) {
                Spacer(minLength: 0)
                if let lead = leadSession {
                    if signallingSessions.count > 1 {
                        Text("\(signallingSessions.count)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    Image(systemName: lead.state == .working
                          ? lead.activityKind.symbol : lead.state.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(lead.state == .working
                                         ? lead.kind.tint : lead.state.color)
                }
            }
            .padding(.trailing, 14)
            .frame(width: Self.compactSide, alignment: .trailing)
        }
        .frame(height: notchH)
    }

    // MARK: - Alert

    @ViewBuilder
    private var alertContent: some View {
        if let s = alertSession {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    HStack(spacing: 8) {
                        IconBadge(session: s, size: 22, corner: 7, iconSize: 11)
                        Text(s.kind.label)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 14)
                    .frame(width: (currentSize.width - notchW) / 2, alignment: .leading)

                    Spacer(minLength: 0).frame(width: notchW)

                    HStack(spacing: 5) {
                        Spacer(minLength: 0)
                        Image(systemName: s.state.symbol)
                            .font(.system(size: 10, weight: .bold))
                        Text(s.state.shortLabel)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(s.state.color)
                    .padding(.trailing, 14)
                    .frame(width: (currentSize.width - notchW) / 2, alignment: .trailing)
                }
                .frame(height: notchH)

                HStack(spacing: 6) {
                    Text(s.title)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                    Text("·").foregroundStyle(.white.opacity(0.3))
                    Text(s.project)
                        .font(.system(size: 11))
                        .foregroundStyle(s.kind.tint)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .frame(height: Self.alertExtraHeight, alignment: .center)
            }
        }
    }

    // MARK: - Expanded

    private var expanded: some View {
        VStack(spacing: 0) {
            header
            if visibleSessions.isEmpty {
                Text("Nessuna sessione attiva")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 2) {
                    ForEach(visibleSessions) { session in
                        SessionRow(session: session)
                            .frame(height: Self.rowHeight - 2)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if NSEvent.modifierFlags.contains(.option) {
                                    store.revealDirectory(session)
                                } else {
                                    store.focus(session)
                                }
                            }
                    }
                }
                .padding(.horizontal, 7)
                .padding(.bottom, 7)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("AGENTI")
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .tracking(1.5)
                    .foregroundStyle(.white.opacity(0.38))
                Spacer(minLength: 0)
            }
            .padding(.leading, 18)
            .frame(width: (Self.expandedWidth - notchW) / 2, alignment: .leading)

            Spacer(minLength: 0).frame(width: notchW)

            HStack(spacing: 6) {
                Spacer(minLength: 0)
                if store.activeCount > 0 {
                    CountChip(symbol: SessionState.working.symbol,
                              text: "\(store.activeCount)",
                              color: SessionState.working.color)
                }
                if store.waitingCount > 0 {
                    CountChip(symbol: SessionState.needsInput.symbol,
                              text: "\(store.waitingCount)",
                              color: SessionState.needsInput.color)
                }
            }
            .padding(.trailing, 16)
            .frame(width: (Self.expandedWidth - notchW) / 2, alignment: .trailing)
        }
        .frame(height: notchH)
    }
}

// MARK: - Pieces

struct CountChip: View {
    let symbol: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 8.5, weight: .bold))
            Text(text).font(.system(size: 10, weight: .bold, design: .rounded))
        }
        .foregroundStyle(color)
        .fixedSize()
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(
            Capsule().fill(color.opacity(0.16))
                .overlay(Capsule().stroke(color.opacity(0.22), lineWidth: 0.6))
        )
    }
}

/// The glyph that carries the meaning: what the agent is doing while it works,
/// what it needs from you when it stops.
struct IconBadge: View {
    let session: AgentSession
    var size: CGFloat = 32
    var corner: CGFloat = 9
    var iconSize: CGFloat = 13

    private var symbol: String {
        session.state == .working ? session.activityKind.symbol : session.state.symbol
    }
    private var tint: Color {
        session.state == .working ? session.kind.tint : session.state.color
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(tint.opacity(0.17))
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .stroke(tint.opacity(0.28), lineWidth: 0.7)
            Image(systemName: symbol)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
    }
}

struct SessionRow: View {
    let session: AgentSession
    // macOS 26 / SDK 27 turned SwiftUI's `@State` into a macro backed by the
    // `SwiftUIMacros` plugin, which ships only with Xcode — this project builds
    // with the Command Line Tools alone, so the attribute cannot expand here.
    // The underlying @propertyWrapper struct is still there, so this is exactly
    // what the macro would have generated.
    private var _hovering = State(wrappedValue: false)
    private var hovering: Bool {
        get { _hovering.wrappedValue }
        nonmutating set { _hovering.wrappedValue = newValue }
    }

    var body: some View {
        HStack(spacing: 11) {
            IconBadge(session: session)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(session.kind.tag)
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                        .foregroundStyle(session.kind.tint)
                    Text(session.project)
                        .foregroundStyle(.white.opacity(0.6))
                    if let b = session.branch {
                        Text("⑂ " + b).foregroundStyle(.white.opacity(0.32))
                    }
                    if let a = session.activity {
                        Text("· " + a).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                    }
                }
                .font(.system(size: 10))
                .lineLimit(1)
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: session.state.symbol)
                        .font(.system(size: 9, weight: .bold))
                    Text(session.state == .working
                         ? Fmt.shortDuration(session.elapsed)
                         : session.state.shortLabel)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                .foregroundStyle(session.state.color)

                HStack(spacing: 5) {
                    if session.todosTotal > 0 {
                        Text("\(session.todosDone)/\(session.todosTotal)")
                    }
                    if session.cost > 0 {
                        Text(Fmt.cost(session.cost))
                    }
                    // No gauge without a real denominator — see Config.knownWindows.
                    if session.contextWindow > 0 {
                        ContextGauge(percent: session.contextPercent)
                    }
                    if let rate = session.rateLimitPercent, rate >= 50 {
                        Text("piano \(Int(rate))%")
                            .foregroundStyle(rate >= 85
                                             ? SessionState.failed.color
                                             : SessionState.needsInput.color)
                    }
                    Text(Fmt.tokens(session.contextTokens))
                }
                .font(.system(size: 9, design: .rounded))
                .foregroundStyle(.white.opacity(0.42))
            }
        }
        .padding(.horizontal, 11)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.09 : 0))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(hovering ? 0.10 : 0), lineWidth: 0.7)
                )
        )
        .onHover { hovering = $0 }
        .help((session.directory.isEmpty ? session.title : session.directory)
              + "\n" + (session.model ?? "")
              + "  ·  click: apri l'app  ·  ⌥click: apri la cartella")
    }
}

/// Thin bar showing how full the context window is.
struct ContextGauge: View {
    let percent: Double
    private var color: Color {
        if percent > 0.9 { return SessionState.failed.color }
        if percent > 0.7 { return SessionState.needsInput.color }
        return Color.white.opacity(0.5)
    }
    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.16))
            Capsule().fill(color).frame(width: max(2, 26 * percent))
        }
        .frame(width: 26, height: 3)
    }
}


struct NotchLineSpec: Equatable {
    struct Arc: Equatable {
        let id: String
        let from: CGFloat
        let to: CGFloat
        let color: Color
        let pulsing: Bool
    }
    let arcs: [Arc]
    let size: CGSize
    let radius: CGFloat
    let topRadius: CGFloat
}

/// Isolated from the rest of the panel: SwiftUI skips this whole subtree while
/// the spec is unchanged, so per-second session updates cost nothing here.
struct NotchLineView: View, Equatable {
    let spec: NotchLineSpec

    static func == (a: NotchLineView, b: NotchLineView) -> Bool { a.spec == b.spec }

    var body: some View {
        ZStack {
            ForEach(spec.arcs, id: \.id) { arc in
                NotchLineSegment(from: arc.from, to: arc.to, color: arc.color,
                                 pulsing: arc.pulsing,
                                 radius: spec.radius, topRadius: spec.topRadius)
            }
        }
        .frame(width: spec.size.width, height: spec.size.height)
        .allowsHitTesting(false)
    }
}

/// One coloured segment of the bezel. Static while an agent works — this sits
/// in peripheral vision all day — and breathing when it wants you, because
/// motion is what the eye actually catches, far more than hue.
struct NotchLineSegment: View {
    let from: CGFloat
    let to: CGFloat
    let color: Color
    let pulsing: Bool
    let radius: CGFloat
    var topRadius: CGFloat = 0

    var body: some View {
        // Two distinct view types, not one view with a flag: a repeatForever
        // animation cannot be called off by reassigning the property it drives,
        // so the only reliable way to stop breathing is to tear the breathing
        // view down. Leaving it running kept the display link spinning at ~2%
        // CPU for as long as a session sat waiting.
        if pulsing {
            BreathingLine(from: from, to: to, color: color,
                          radius: radius, topRadius: topRadius)
        } else {
            NotchOutline(bottomRadius: radius, topRadius: topRadius)
                .trim(from: max(0, from), to: min(1, to))
                .stroke(color, style: StrokeStyle(lineWidth: Config.notchLineWidth,
                                                  lineCap: .round))
        }
    }
}

private struct BreathingLine: View {
    let from: CGFloat
    let to: CGFloat
    let color: Color
    let radius: CGFloat
    var topRadius: CGFloat = 0

    // macOS 26 / SDK 27 turned SwiftUI's `@State` into a macro backed by the
    // `SwiftUIMacros` plugin, which ships only with Xcode — this project builds
    // with the Command Line Tools alone, so the attribute cannot expand here.
    // The underlying @propertyWrapper struct is still there, so this is exactly
    // what the macro would have generated.
    private var _breathe = State(wrappedValue: false)
    private var breathe: Bool {
        get { _breathe.wrappedValue }
        nonmutating set { _breathe.wrappedValue = newValue }
    }

    var body: some View {
        NotchOutline(bottomRadius: radius, topRadius: topRadius)
            .trim(from: max(0, from), to: min(1, to))
            .stroke(color, style: StrokeStyle(lineWidth: Config.notchLineWidth,
                                              lineCap: .round))
            .opacity(breathe ? 1.0 : 0.28)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    breathe = true
                }
            }
    }
}




/// A single agent's dot in the compact island. Split in two like the line, so a
/// repeating animation is destroyed with its view instead of running forever.
struct StatusPip: View {
    let color: Color
    let pulsing: Bool

    var body: some View {
        if pulsing {
            BreathingPip(color: color)
        } else {
            Circle().fill(color).frame(width: 7, height: 7)
        }
    }
}

private struct BreathingPip: View {
    let color: Color
    // macOS 26 / SDK 27 turned SwiftUI's `@State` into a macro backed by the
    // `SwiftUIMacros` plugin, which ships only with Xcode — this project builds
    // with the Command Line Tools alone, so the attribute cannot expand here.
    // The underlying @propertyWrapper struct is still there, so this is exactly
    // what the macro would have generated.
    private var _breathe = State(wrappedValue: false)
    private var breathe: Bool {
        get { _breathe.wrappedValue }
        nonmutating set { _breathe.wrappedValue = newValue }
    }

    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
            .opacity(breathe ? 1.0 : 0.28)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    breathe = true
                }
            }
    }
}
