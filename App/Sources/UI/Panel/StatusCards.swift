// Cartes d'état du panneau (planche 2) :
//  • « Le Mi Monitor ne répond pas » (nom de l'écran affiché) avec la liste de diagnostic et Réessayer ;
//  • cartes compactes « Débranché · en attente » (Réessayer) et « En veille » (Réveiller) ;
//  • « Aucun écran détecté ».
// Cartes en Liquid Glass (panelModule), boutons en verre natif (.glass / .glassProminent).

import SwiftUI

// MARK: - Écran qui ne répond pas

struct UnresponsiveCard: View {
    @Environment(AppModel.self) private var model
    let display: DisplayController
    /// Raison technique remontée par le cœur (description de l'erreur DDC).
    let reason: String

    @State private var isRetrying = false
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("\(display.nameWithArticle(capitalized: true)) ne répond pas")
                    .font(.system(size: 13, weight: .semibold))
            }
            .accessibilityElement(children: .combine)

            Text("Branché, mais sans réponse DDC/CI. Vérifiez que DDC/CI est activé dans le menu de l'écran.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Diagnostic : ce qui marche encore, ce qui échoue.
            VStack(alignment: .leading, spacing: 5) {
                if display.displayID != nil {
                    DiagnosticLine(ok: true, title: "Écran détecté par macOS", detail: display.title(for: display.input))
                } else {
                    DiagnosticLine(ok: false, title: "Écran non vu par macOS", detail: nil)
                }
                // L'opération réellement en cause (lecture, écriture du son, d'un gain…).
                DiagnosticLine(ok: false, title: display.failedOperation ?? "Lecture luminosité (0x10)",
                               detail: Self.shortReason(reason))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.vertical, 2)

            if showsDetails {
                Text(reason)
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }

            HStack(spacing: 8) {
                Button {
                    retry()
                } label: {
                    HStack(spacing: 6) {
                        if isRetrying {
                            ProgressView().controlSize(.mini).environment(\.colorScheme, .dark)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text("Réessayer")
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(isRetrying)

                Button("Diagnostic…") {
                    withAnimation(.snappy) { showsDetails.toggle() }
                }
                .buttonStyle(.glass)
                .accessibilityHint("Affiche le message d'erreur complet")
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(.horizontal, 14)
        .padding(.top, 13)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelModule()
    }

    /// Relance la détection (macOS a pu recréer le service DDC après un réveil) :
    /// le rattachement relit ensuite toutes les valeurs.
    private func retry() {
        isRetrying = true
        Task {
            await model.displays.rescanNow()
            isRetrying = false
        }
    }

    /// Résumé lisible de l'erreur DDC (voir DDCError dans DDCKit).
    /// Après les réessais, DDCKit emballe la dernière erreur dans « pas de réponse valide (…) » :
    /// on teste donc d'abord la cause interne (refus du pilote) avant le cas générique.
    static func shortReason(_ reason: String) -> String {
        if reason.contains("refusée") { return "refusée par le pilote" }
        if reason.contains("pas de réponse") { return "délai dépassé" }
        return "échec"
    }
}

private struct DiagnosticLine: View {
    let ok: Bool
    let title: String
    let detail: String?

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? Color.green : Color.orange)
                .font(.system(size: 12))
            Text(title)
            if let detail {
                Text("· \(detail)").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(ok ? "Correct" : "Problème") : \(title)\(detail.map { ", \($0)" } ?? "")")
    }
}

// MARK: - Cartes compactes

/// Panneau réduit quand l'écran est débranché ou en veille (planche 2, scène 7).
struct CompactStatusCard: View {
    enum Kind { case disconnected, asleep }

    @Environment(AppModel.self) private var model
    let display: DisplayController
    let kind: Kind

    @State private var isWaking = false
    /// Le dernier réveil n'a pas abouti (l'écran reste « En veille »).
    @State private var wakeFailed = false

    var body: some View {
        StatusCardLayout(
            symbol: kind == .asleep ? "moon.fill" : "display",
            title: display.displayName,
            dotColor: kind == .asleep ? .orange : Color.secondary.opacity(0.6),
            subtitle: kind == .asleep ? (wakeFailed ? "En veille · réveil sans réponse" : "En veille")
                                      : "Débranché · en attente"
        ) {
            switch kind {
            case .disconnected:
                Button {
                    model.displays.scheduleRescan(after: .zero)
                } label: {
                    Label("Réessayer", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            case .asleep:
                Button {
                    wake()
                } label: {
                    HStack(spacing: 6) {
                        if isWaking {
                            ProgressView().controlSize(.mini).environment(\.colorScheme, .dark)
                        } else {
                            Image(systemName: "power")
                        }
                        Text("Réveiller")
                    }
                }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
                .disabled(isWaking)
            }
        }
    }

    private func wake() {
        isWaking = true
        Task {
            // L'écran en veille a pu disparaître puis revenir côté macOS : on rafraîchit
            // d'abord son accès DDC (sans relecture), puis on envoie le réveil.
            await model.displays.rescanNow()
            wakeFailed = !(await display.setPower(on: true))
            isWaking = false
        }
    }
}

/// Aucun écran externe trouvé (ou première détection encore en cours).
struct NoDisplayCard: View {
    @Environment(AppModel.self) private var model
    let hasScanned: Bool

    var body: some View {
        if hasScanned {
            StatusCardLayout(symbol: "display.trianglebadge.exclamationmark",
                             title: "Aucun écran détecté",
                             dotColor: Color.secondary.opacity(0.6),
                             subtitle: "Branchez le Mi Monitor en USB-C") {
                Button {
                    model.displays.scheduleRescan(after: .zero)
                } label: {
                    Label("Réessayer", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Recherche de l'écran…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .panelModule()
        }
    }
}

/// Mise en page commune des cartes compactes : pastille sur remplissage système, titre, état,
/// bouton à droite.
private struct StatusCardLayout<Trailing: View>: View {
    let symbol: String
    let title: String
    let dotColor: Color
    let subtitle: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            IconBadge(symbol: symbol, background: nil, foreground: .primary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    StatusDot(color: dotColor)
                    Text(subtitle)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 6)
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .panelModule(cornerRadius: 18)
    }
}
