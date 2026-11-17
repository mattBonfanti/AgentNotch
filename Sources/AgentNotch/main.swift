import AppKit
import SwiftUI

if CommandLine.arguments.contains("--diag") {
    for (i, sc) in NSScreen.screens.enumerated() {
        let g = NotchController.geometry(for: sc)
        print("schermo \(i): frame \(sc.frame)  safeAreaTop \(sc.safeAreaInsets.top)")
        print("   auxLeft \(sc.auxiliaryTopLeftArea.map { "\($0)" } ?? "nil")")
        print("   auxRight \(sc.auxiliaryTopRightArea.map { "\($0)" } ?? "nil")")
        print("   notch rilevato: \(g.hasHardwareNotch)  larghezza \(g.notchWidth)  altezza \(g.notchHeight)")
    }
    print("menu bar thickness: \(NSStatusBar.system.thickness)")
    exit(0)
}

/// `AgentNotch --dump` prints one snapshot of what the providers see and exits.
/// Useful for checking the parsers without the panel in the way.
if CommandLine.arguments.contains("--dump") {
    let store = SessionStore()
    store.start()
    // Big transcripts take a moment on the first pass, and providers that talk
    // over HTTP answer on a later tick — so always give everyone a settling
    // period rather than printing whatever the first pass happened to have.
    let settle = Date().addingTimeInterval(3)
    let deadline = Date().addingTimeInterval(8)
    while (store.sessions.isEmpty && Date() < deadline) || Date() < settle {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }
    let sessions = store.sessions
    print("Sessioni trovate: \(sessions.count)   al lavoro: \(store.activeCount)   in attesa: \(store.waitingCount)")
    for s in sessions {
        print("""
        \n[\(s.kind.tag)] \(s.title)
          stato      \(s.state.shortLabel)\(s.isLive ? " (live)" : "")  pid \(s.pid.map(String.init) ?? "-")
          progetto   \(s.project)  \(s.branch.map { "⑂ " + $0 } ?? "")  \(s.directory)
          modello    \(s.model ?? "?")
          attivita   \(s.activity ?? "-")
          contesto   \(Fmt.tokens(s.contextTokens))/\(Fmt.tokens(s.contextWindow)) (\(Int(s.contextPercent * 100))%)  tool \(s.toolCalls)  msg \(s.messageCount)
          tempi      turno \(Fmt.duration(s.elapsed))  silenzio \(Fmt.duration(s.quietFor))
          extra      costo \(Fmt.cost(s.cost))  todo \(s.todosDone)/\(s.todosTotal)  rate \(s.rateLimitPercent.map { String(format: "%.0f%%", $0) } ?? "-")
        """)
    }
    exit(0)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SessionStore()
    private var controller: NotchController?
    private var statusItem: NSStatusItem?
    private var styleItems: [NSMenuItem] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let c = NotchController(store: store)
        controller = c
        c.start()
        store.start()
        installStatusItem()
    }

    /// Prefers the outline mark as a template image, so macOS recolours it for
    /// the light and dark menu bar and for the highlighted state. Falls back to
    /// the colour icon, then to a system symbol — running the bare binary during
    /// development has no Resources folder at all.
    private static func statusIcon() -> NSImage? {
        if let url = Bundle.main.url(forResource: "StatusIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 19, height: 19)
            image.isTemplate = true
            return image
        }
        if let url = Bundle.main.url(forResource: "MenuIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = false   // it is a colour mark, not a glyph
            return image
        }
        let fallback = NSImage(systemSymbolName: "rectangle.topthird.inset.filled",
                               accessibilityDescription: "AgentNotch")
        fallback?.isTemplate = true
        return fallback
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.statusIcon()

        let menu = NSMenu()
        menu.addItem(withTitle: "Mostra pannello", action: #selector(peek), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())

        let header = NSMenuItem(title: "Indicatore", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for (title, style) in [("Linea attorno al notch", "line"),
                               ("Isola compatta", "island")] {
            let item = NSMenuItem(title: "  " + title, action: #selector(setStyle(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = style
            item.state = Config.indicatorStyle.rawValue == style ? .on : .off
            menu.addItem(item)
            styleItems.append(item)
        }

        menu.addItem(.separator())
        for (title, key) in [("Suono quando un agente ti aspetta", "soundOnAlert"),
                             ("Avviso sul notch", "autoExpandOnAlert"),
                             ("Zitto se l'app è in primo piano", "quietWhenFrontmost"),
                             ("Linea divisa per agente", "glowPerAgent"),
                             ("Mostra anche sessioni ferme", "showWhenIdle")] {
            let mi = NSMenuItem(title: title, action: #selector(toggle(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = key
            mi.state = UserDefaults.standard.object(forKey: key) as? Bool ?? (key != "showWhenIdle")
                ? .on : .off
            menu.addItem(mi)
        }
        let login = NSMenuItem(title: "Avvia al login", action: #selector(toggleLogin(_:)),
                               keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Esci da AgentNotch", action: #selector(quit), keyEquivalent: "q")
            .target = self
        item.menu = menu
        statusItem = item
    }

    @objc private func peek() { controller?.peek() }

    @objc private func toggle(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        let current = UserDefaults.standard.object(forKey: key) as? Bool ?? (key != "showWhenIdle")
        UserDefaults.standard.set(!current, forKey: key)
        sender.state = !current ? .on : .off
    }

    @objc private func setStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let style = Config.IndicatorStyle(rawValue: raw) else { return }
        Config.indicatorStyle = style
        for item in styleItems {
            item.state = (item.representedObject as? String) == raw ? .on : .off
        }
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        let now = !LoginItem.isEnabled
        LoginItem.setEnabled(now)
        sender.state = now ? .on : .off
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
