// « Mode noir » : rend un écran externe entièrement noir SANS l'éteindre.
//
// Pourquoi pas la veille DDC (0xD6) : sur le Mi Monitor, elle coupe aussi la charge USB-C du Mac
// et le DDC (essai du 17 nov., cf. DisplayQuirks). Ici l'écran reste allumé — charge et DDC intacts —
// avec le rétroéclairage au minimum (luminosité 0) et une fenêtre noire posée au-dessus de tout,
// barre des menus comprise. Limite : le rétroéclairage reste faiblement allumé (léger halo dans le noir).
//
// Sortie : clic sur l'écran noir, raccourci global ⌃⌥⌘N, ou bouton « Mode noir » du panneau.
// La luminosité d'avant est rétablie en sortant.

import AppKit
import Observation

@Observable
final class BlackoutController {
    @ObservationIgnored private unowned let model: AppModel
    /// Écrans actuellement en mode noir (identifiants des contrôleurs).
    private(set) var activeIDs: Set<String> = []
    @ObservationIgnored private var windows: [String: NSWindow] = [:]
    /// Luminosité à rétablir en sortant du mode noir.
    @ObservationIgnored private var savedBrightness: [String: Int] = [:]
    @ObservationIgnored private var screenObserver: NSObjectProtocol?

    init(model: AppModel) {
        self.model = model
        // Écran débranché ou résolution changée : on recale ou on retire les fenêtres noires.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refitWindows() }
        }
    }

    func isActive(_ display: DisplayController) -> Bool { activeIDs.contains(display.id) }

    func toggle(_ display: DisplayController) {
        isActive(display) ? disable(display) : enable(display)
    }

    /// Écran visé par le raccourci : l'écran externe sous le pointeur s'il y en a un, sinon l'écran sélectionné.
    func toggleForShortcut() {
        // Un écran déjà noir sous le pointeur ou ailleurs : le raccourci rallume tout (sortie toujours possible).
        if !activeIDs.isEmpty { disableAll(); return }
        if let display = model.displays.controllerUnderMouse() ?? model.displays.selected { enable(display) }
    }

    func enable(_ display: DisplayController) {
        guard !isActive(display), let screen = model.displays.screen(for: display) else { return }
        let window = makeWindow(on: screen) { [weak self, weak display] in
            guard let self, let display else { return }
            self.disable(display)
        }
        windows[display.id] = window
        activeIDs.insert(display.id)
        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.25; window.animator().alphaValue = 1 }

        // Rétroéclairage au minimum (l'écran reste allumé : charge USB-C et DDC intacts).
        // On relit d'abord la vraie luminosité : elle a pu changer via les boutons de l'écran,
        // et c'est elle qu'il faudra rétablir en sortant (constaté à l'essai du 17 nov.).
        guard display.connection.isUsable else { return }
        Task { [weak self, weak display] in
            guard let display else { return }
            await display.refresh()
            guard let self, self.isActive(display), display.connection.isUsable else { return }
            self.savedBrightness[display.id] = display.brightness
            display.set(.brightness, percent: 0)
        }
    }

    func disable(_ display: DisplayController) {
        guard isActive(display) else { return }
        activeIDs.remove(display.id)
        if let window = windows.removeValue(forKey: display.id) {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; window.animator().alphaValue = 0 },
                                                completionHandler: { window.orderOut(nil) })
        }
        if let level = savedBrightness.removeValue(forKey: display.id), display.connection.isUsable {
            display.set(.brightness, percent: level)
        }
    }

    func disableAll() {
        for id in activeIDs {
            if let display = model.displays.controller(id: id) { disable(display) } else { removeWindow(id) }
        }
    }

    // MARK: - Fenêtres

    private func makeWindow(on screen: NSScreen, onClick: @escaping () -> Void) -> NSWindow {
        let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        // Au-dessus de tout : barre des menus, Dock, et aussi les notifications (vues par-dessus
        // le niveau .screenSaver à l'essai du 17 nov.) → niveau « bouclier » du système.
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.contentView = BlackoutView(onClick: onClick)
        window.setFrame(screen.frame, display: false)
        window.setAccessibilityLabel("Mode noir : cliquez pour rallumer")
        return window
    }

    private func removeWindow(_ id: String) {
        windows.removeValue(forKey: id)?.orderOut(nil)
        activeIDs.remove(id)
        savedBrightness.removeValue(forKey: id)
    }

    private func refitWindows() {
        for id in activeIDs {
            guard let display = model.displays.controller(id: id), let screen = model.displays.screen(for: display) else {
                removeWindow(id)   // écran disparu : plus rien à masquer
                continue
            }
            windows[id]?.setFrame(screen.frame, display: true)
        }
    }
}

/// Vue noire : un clic n'importe où rallume l'écran.
private final class BlackoutView: NSView {
    private let onClick: () -> Void

    init(onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("non utilisé") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick() }
}
