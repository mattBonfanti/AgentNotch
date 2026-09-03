import AppKit
import SwiftUI
import Combine

/// Owns the floating panel that sits on the notch, decides when it opens and
/// closes, and keeps click-through correct so the menu bar stays usable.
final class NotchController {
    private let store: SessionStore
    private let vm = NotchViewModel()
    private var panel: NSPanel?
    private var hoverTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var screen: NSScreen?
    private var alertHold: Date?
    private var lastTickAt: Date = .distantPast
    private var hideWork: DispatchWorkItem?

    init(store: SessionStore) {
        self.store = store
    }

    func start() {
        rebuild()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.rebuild() }

        store.$alert
            .receive(on: RunLoop.main)
            .sink { [weak self] alert in
                guard let self else { return }
                self.alertHold = alert == nil ? nil : Date()
                self.refreshMode()
            }
            .store(in: &cancellables)

        store.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshMode() }
            .store(in: &cancellables)

        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.refreshMode() }
        RunLoop.main.add(t, forMode: .common)
        hoverTimer = t
    }

    // MARK: - Panel

    private func rebuild() {
        let target = pickScreen()
        screen = target
        vm.geometry = Self.geometry(for: target)

        let size = panelSize()
        let frame = NSRect(
            x: target.frame.midX - size.width / 2,
            y: target.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )

        if let panel {
            panel.setFrame(frame, display: true)
            // A resolution or display change can drop the panel out of the
            // current space; re-asserting it is cheap and avoids a silent
            // disappearance that `isVisible` would not report.
            panel.orderFrontRegardless()
            return
        }

        let p = NSPanel(contentRect: frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = NSWindow.Level(Int(CGWindowLevelForKey(.statusWindow)) + 2)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isMovableByWindowBackground = false
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.ignoresMouseEvents = true

        let host = NSHostingView(rootView: NotchView(store: store, vm: vm))
        host.frame = NSRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        p.orderFrontRegardless()
        panel = p
    }

    /// The window never resizes — it stays big enough for the largest island
    /// plus room for the halo to bleed, and the view draws whatever fits.
    private func panelSize() -> CGSize {
        let g = vm.geometry
        let widest = max(NotchView.size(mode: .expanded, geometry: g, rows: 4).width,
                         NotchView.size(mode: .alert, geometry: g, rows: 1).width)
        let tallest = NotchView.size(mode: .expanded, geometry: g, rows: 4).height
        return CGSize(width: widest + 80, height: tallest + 40)
    }

    private func pickScreen() -> NSScreen {
        if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        return NSScreen.main ?? NSScreen.screens.first!
    }

    static func geometry(for screen: NSScreen) -> NotchGeometry {
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let width = right.minX - left.maxX
            let height = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : left.height
            if width > 40 {
                return NotchGeometry(notchWidth: width, notchHeight: max(height, 26),
                                     hasHardwareNotch: true)
            }
        }
        return NotchGeometry(notchWidth: 180,
                             notchHeight: max(NSStatusBar.system.thickness, 24),
                             hasHardwareNotch: false)
    }

    // MARK: - Mode

    /// Rect the visible shape occupies on screen, in global coordinates.
    private func shapeRect(for mode: NotchMode) -> NSRect {
        guard let screen else { return .zero }
        let size = NotchView.size(mode: mode, geometry: vm.geometry, rows: store.sessions.count)
        return NSRect(x: screen.frame.midX - size.width / 2,
                      y: screen.frame.maxY - size.height,
                      width: size.width,
                      height: size.height)
    }

    private var baseMode: NotchMode {
        let resting: NotchMode = Config.indicatorStyle == .island ? .compact : .glow
        if store.activeCount > 0 || store.waitingCount > 0 { return resting }
        if Config.showWhenIdle && store.hasAnything { return resting }
        return .hidden
    }

    private func refreshMode() {
        guard let panel else { return }
        // AGENTNOTCH_FORCE_MODE=alert|expanded|glow pins the panel open so the
        // states can be looked at without waiting for one to happen.
        if let forced = ProcessInfo.processInfo.environment["AGENTNOTCH_FORCE_MODE"] {
            let mode: NotchMode = forced == "alert" ? .alert
                : forced == "expanded" ? .expanded
                : forced == "compact" ? .compact
                : forced == "glow" ? .glow : .hidden
            if vm.mode != mode { vm.mode = mode }
            if !panel.isVisible { panel.orderFrontRegardless() }
            if Date().timeIntervalSince(lastTickAt) >= 1 { lastTickAt = Date(); vm.tick &+= 1 }
            return
        }
        let mouse = NSEvent.mouseLocation
        var next: NotchMode

        if vm.mode == .expanded {
            // Generous exit zone so small jitters don't slam it shut.
            next = shapeRect(for: .expanded).insetBy(dx: -10, dy: -10).contains(mouse)
                ? .expanded : baseMode
        } else {
            // With the pills gone the target is the notch itself, so give it a
            // few forgiving pixels on every side.
            let hoverZone = shapeRect(for: baseMode == .compact ? .compact : .glow)
                .insetBy(dx: -8, dy: -8)
            if hoverZone.contains(mouse) {
                next = .expanded
            } else if store.alert != nil, Config.autoExpandOnAlert {
                next = .alert
            } else {
                next = baseMode
            }
        }

        if next != vm.mode { vm.mode = next }

        // A hidden panel should cost nothing, so order it out instead of
        // leaving a transparent view attached to the display link. Hiding waits
        // for the collapse animation; showing is immediate.
        let shouldBeVisible = next != .hidden
        if shouldBeVisible {
            hideWork?.cancel()
            hideWork = nil
            if !panel.isVisible { panel.orderFrontRegardless() }
        } else if panel.isVisible, hideWork == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.vm.mode == .hidden else { return }
                self.panel?.orderOut(nil)
                self.hideWork = nil
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        }

        if ProcessInfo.processInfo.environment["AGENTNOTCH_DEBUG"] != nil,
           Date().timeIntervalSince(lastTickAt) >= 1 {
            let size = NotchView.size(mode: vm.mode, geometry: vm.geometry,
                                      rows: store.sessions.count)
            let r = shapeRect(for: vm.mode)
            FileHandle.standardError.write(
                "modo \(vm.mode) | notch \(vm.geometry.notchWidth)x\(vm.geometry.notchHeight) | forma \(size) | rect \(r) | finestra \(panel.frame)\n"
                    .data(using: .utf8)!)
        }

        // Drive the elapsed timers only while something is on screen.
        if vm.mode == .alert || vm.mode == .expanded,
           Date().timeIntervalSince(lastTickAt) >= 1 {
            lastTickAt = Date()
            vm.tick &+= 1
        }
        // Only swallow clicks while the panel is actually under the pointer.
        let interactive = next == .expanded && shapeRect(for: .expanded).contains(mouse)
        if panel.ignoresMouseEvents == interactive { panel.ignoresMouseEvents = !interactive }
    }

    func peek() {
        vm.mode = .expanded
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.refreshMode() }
    }
}
