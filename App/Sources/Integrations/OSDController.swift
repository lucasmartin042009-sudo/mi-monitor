// OSD maison : un seul panneau flottant non activant, réutilisé à chaque touche,
// placé sur l'écran visé (celui du contrôleur passé à show) selon AppSettings.osdStyle (capsule en haut ou en bas ;
// « Aucun » par défaut, l'encoche étant laissée à Canopy), en fondu (0,2 s),
// masqué 1,5 s après la dernière mise à jour.
// Le panneau est entièrement transparent : seul le verre de la capsule (glassEffect) est visible.

import AppKit
import SwiftUI

final class OSDController {
    private unowned let model: AppModel
    private let state = OSDState()
    private var panel: OSDPanel?
    private var hideTask: Task<Void, Never>?
    /// Vrai entre show() et le début du fondu de sortie.
    private var isShown = false
    /// Incrémenté à chaque affichage : un fondu de sortie périmé ne doit pas masquer un nouvel OSD.
    private var generation = 0

    /// Durées du fondu et de l'affichage.
    static let fadeDuration: TimeInterval = 0.2
    static let displayDuration: Duration = .milliseconds(1500)
    /// Marge transparente autour du contenu pour que l'ombre ne soit pas rognée.
    static let shadowMargin: CGFloat = 40

    init(model: AppModel) { self.model = model }

    /// Affiche l'OSD (selon AppSettings.osdStyle) sur l'écran du contrôleur donné.
    func show(_ control: Control, on display: DisplayController) {
        let style = model.settings.osdStyle
        guard style != .none else { hide(animated: false); return }
        guard let screen = model.displays.screen(for: display) ?? NSScreen.main else { return }

        state.control = control
        state.display = display
        state.steps = max(1, model.settings.keyboardSteps)
        state.style = style

        let panel = self.panel ?? makePanel()
        let content = Self.contentFrame(style: style, screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
        let frame = content.insetBy(dx: -Self.shadowMargin, dy: -Self.shadowMargin)
        if panel.frame != frame { panel.setFrame(frame, display: false) }

        generation += 1
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        isShown = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.fadeDuration
            panel.animator().alphaValue = 1
        }
        scheduleHide()
    }

    /// Masque l'OSD (en fondu ou immédiatement).
    func hide(animated: Bool = true) {
        hideTask?.cancel()
        hideTask = nil
        guard let panel, panel.isVisible else { isShown = false; return }
        isShown = false
        guard animated else { panel.alphaValue = 0; panel.orderOut(nil); return }
        let gen = generation
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.fadeDuration
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // Un show() survenu pendant le fondu garde le panneau à l'écran.
                guard let self, gen == self.generation, !self.isShown else { return }
                self.panel?.orderOut(nil)
            }
        })
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.displayDuration)
            guard !Task.isCancelled else { return }
            self?.hide(animated: true)
        }
    }

    private func makePanel() -> OSDPanel {
        let panel = OSDPanel(contentRect: NSRect(x: 0, y: 0, width: 464, height: 142),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        // Au-dessus des apps en plein écran et des menus.
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Pas de NSVisualEffectView ni d'ombre de fenêtre : le verre SwiftUI fait tout.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        let host = NSHostingView(rootView: OSDView(state: state))
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        return panel
    }

    // MARK: - Placement (pur, testable)

    /// Cadre du contenu (sans la marge d'ombre) en coordonnées d'écran globales.
    static func contentFrame(style: OSDStyle, screenFrame: CGRect, visibleFrame: CGRect) -> CGRect {
        let size = OSDCapsule.size
        let x = (screenFrame.midX - size.width / 2).rounded()
        let y: CGFloat
        switch style {
        case .capsuleTop, .none:
            // Juste sous la barre des menus (24 pt supposés si elle est masquée automatiquement).
            let menuBar = screenFrame.maxY - visibleFrame.maxY
            let top = menuBar > 1 ? menuBar : 24
            y = screenFrame.maxY - top - 10 - size.height
        case .capsuleBottom:
            // ~120 pt du bas, au-dessus du Dock s'il est en bas.
            y = max(screenFrame.minY + 120, visibleFrame.minY + 20)
        }
        return CGRect(origin: CGPoint(x: x, y: y.rounded()), size: size)
    }
}

/// Panneau qui ne prend jamais le focus.
final class OSDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
