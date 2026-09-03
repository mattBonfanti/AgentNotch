import SwiftUI

/// The notch silhouette: square at the screen edge, rounded at the bottom, with
/// the two outward fillets that make it read as part of the hardware.
///
/// The bottom corners use a continuous (squircle) curve rather than a circular
/// arc — that is what makes an expanded island look like iOS rather than like a
/// rounded rectangle.
struct NotchShape: Shape {
    var bottomRadius: CGFloat = 13
    var topRadius: CGFloat = 7

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(bottomRadius, topRadius) }
        set { bottomRadius = newValue.first; topRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let b = min(bottomRadius, rect.height * 0.62, rect.width / 2.6)
        let t = min(topRadius, rect.height / 3)
        // Tangent length and control-point pull that approximate Apple's
        // continuous corner: the curve starts further out and flattens later.
        let reach = b * 1.28
        let pull = b * 0.45

        var p = Path()
        p.move(to: CGPoint(x: rect.minX - t, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + t),
                       control: CGPoint(x: rect.minX, y: rect.minY))

        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - reach))
        p.addCurve(to: CGPoint(x: rect.minX + reach, y: rect.maxY),
                   control1: CGPoint(x: rect.minX, y: rect.maxY - pull),
                   control2: CGPoint(x: rect.minX + pull, y: rect.maxY))

        p.addLine(to: CGPoint(x: rect.maxX - reach, y: rect.maxY))
        p.addCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - reach),
                   control1: CGPoint(x: rect.maxX - pull, y: rect.maxY),
                   control2: CGPoint(x: rect.maxX, y: rect.maxY - pull))

        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX + t, y: rect.minY),
                       control: CGPoint(x: rect.maxX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// Real backdrop blur, so the island samples the desktop behind it instead of
/// faking translucency with a flat grey.
struct GlassBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.isEmphasized = false
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

extension AgentKind {
    var tint: Color {
        switch self {
        case .claude: return Color(red: 0.91, green: 0.51, blue: 0.36)
        case .codex: return Color(red: 0.36, green: 0.84, blue: 0.70)
        case .opencode: return Color(red: 0.58, green: 0.60, blue: 1.00)
        }
    }
}

extension SessionState {
    var color: Color {
        switch self {
        case .working: return Color(red: 0.32, green: 0.88, blue: 0.50)
        case .needsInput: return Color(red: 1.00, green: 0.74, blue: 0.22)
        case .failed: return Color(red: 1.00, green: 0.36, blue: 0.33)
        case .idle: return Color(white: 0.48)
        case .done: return Color(white: 0.58)
        }
    }

    /// Only these three are worth lighting up the bezel for.
    var deservesGlow: Bool {
        self == .working || self == .needsInput || self == .failed
    }
}

/// The hardware silhouette, as an **open** path: down the left side, around the
/// bottom, up the right side. No outward fillets — the physical cutout has none,
/// they belong to the island — and no closing segment along the screen edge,
/// which matters because `trim` distributes over path length and a closing edge
/// would waste a third of the range on something nobody can see.
struct NotchOutline: Shape {
    var bottomRadius: CGFloat = 9
    /// Zero when tracing the physical cutout, which has no fillets. When tracing
    /// the expanded island it must match `NotchShape`, or the coloured line
    /// starts below the corner and the mismatch is visible.
    var topRadius: CGFloat = 0

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(bottomRadius, topRadius) }
        set { bottomRadius = newValue.first; topRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let b = min(bottomRadius, rect.height * 0.85, rect.width / 2.2)
        let t = min(topRadius, rect.height / 3)
        let reach = b * 1.20
        let pull = b * 0.42

        var p = Path()
        if t > 0 {
            p.move(to: CGPoint(x: rect.minX - t, y: rect.minY))
            p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + t),
                           control: CGPoint(x: rect.minX, y: rect.minY))
        } else {
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        }
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - reach))
        p.addCurve(to: CGPoint(x: rect.minX + reach, y: rect.maxY),
                   control1: CGPoint(x: rect.minX, y: rect.maxY - pull),
                   control2: CGPoint(x: rect.minX + pull, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - reach, y: rect.maxY))
        p.addCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - reach),
                   control1: CGPoint(x: rect.maxX - pull, y: rect.maxY),
                   control2: CGPoint(x: rect.maxX, y: rect.maxY - pull))
        if t > 0 {
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + t))
            p.addQuadCurve(to: CGPoint(x: rect.maxX + t, y: rect.minY),
                           control: CGPoint(x: rect.maxX, y: rect.minY))
        } else {
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }
        return p
    }
}
