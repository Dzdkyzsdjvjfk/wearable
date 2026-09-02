import SwiftUI

// MARK: - TrackingDiagnosticsView
//
// "Was wird getrackt?" — an honest status page answering the question the app could not answer
// before: for each signal and each metric, is it actually working, and if not, why not.
//
// It deliberately separates two different questions that are easy to confuse:
//   1. Is the RAW SIGNAL arriving from the strap? (Bluetooth offload working)
//   2. Can a METRIC be computed from it? (some cannot be, ever — see LocalMetricsEngine)
// A signal can arrive perfectly while its metric stays permanently unavailable, which is
// exactly the case for SpO2, skin temperature and respiration: the strap sends only raw ADC
// counts and the conversion to real units lives in WHOOP's cloud. Saying that plainly beats
// showing an empty field and letting the user assume something is broken.

struct TrackingDiagnosticsView: View {
    @EnvironmentObject private var metrics: MetricsRepository

    @State private var diag: TrackingDiagnostics?
    @State private var isLoading = true

    var body: some View {
        ZStack {
            WH.Color.background.ignoresSafeArea()
            if isLoading {
                loadingView
            } else if let diag {
                content(diag)
            }
        }
        .navigationTitle("Was wird getrackt?")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { await reload() }
        .refreshable { await reload() }
    }

    private func reload() async {
        isLoading = diag == nil
        diag = await metrics.diagnostics()
        isLoading = false
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: WH.Spacing.md) {
            ProgressView().tint(WH.Color.textSecondary)
            Text("Prüfe gespeicherte Daten…")
                .font(WH.Font.caption)
                .foregroundStyle(WH.Color.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Content

    private func content(_ d: TrackingDiagnostics) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WH.Spacing.lg) {

                summaryCard(d)

                section(title: "SIGNALE VOM BAND",
                        subtitle: "Kommt per Bluetooth an und liegt lokal auf dem iPhone.",
                        items: d.rawStreams)

                section(title: "BERECHNETE WERTE",
                        subtitle: "Wird auf dem iPhone aus den Signalen oben berechnet — ohne Server.",
                        items: d.metrics)

                disclaimerCard

                Spacer(minLength: WH.Spacing.xl)
            }
            .padding(WH.Spacing.md)
        }
    }

    // MARK: - Summary

    private func summaryCard(_ d: TrackingDiagnostics) -> some View {
        VStack(alignment: .leading, spacing: WH.Spacing.sm) {
            HStack {
                Text("ÜBERBLICK")
                    .font(WH.Font.cardTitle)
                    .foregroundStyle(WH.Color.textSecondary)
                    .tracking(1.2)
                Spacer()
            }

            summaryRow("Gespeicherte Messwerte",
                       d.totalStoredRows > 0 ? "\(d.totalStoredRows)" : "keine")
            summaryRow("Neuester Messwert", relativeText(d.latestSample))
            summaryRow("Ausgewertete Nächte",
                       d.nightsComputed > 0 ? "\(d.nightsComputed)" : "keine")
            summaryRow("Server konfiguriert", d.serverConfigured ? "ja" : "nein (rein lokal)")
        }
        .padding(WH.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WH.Color.surface,
                    in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(WH.Font.caption)
                .foregroundStyle(WH.Color.textSecondary)
            Spacer()
            Text(value)
                .font(.system(.footnote, design: .rounded).weight(.semibold))
                .foregroundStyle(WH.Color.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }

    private func relativeText(_ date: Date?) -> String {
        guard let date else { return "keiner" }
        let elapsed = Int(-date.timeIntervalSinceNow)
        switch elapsed {
        case ..<120:   return "gerade eben"
        case ..<3600:  return "vor \(elapsed / 60) min"
        case ..<86_400: return "vor \(elapsed / 3600) h"
        default:       return "vor \(elapsed / 86_400) Tagen"
        }
    }

    // MARK: - Sections

    private func section(title: String, subtitle: String,
                         items: [TrackingDiagnosticItem]) -> some View {
        VStack(alignment: .leading, spacing: WH.Spacing.sm) {
            Text(title)
                .font(WH.Font.cardTitle)
                .foregroundStyle(WH.Color.textSecondary)
                .tracking(1.2)
            Text(subtitle)
                .font(WH.Font.caption)
                .foregroundStyle(WH.Color.textSecondary.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    row(item)
                    if index < items.count - 1 {
                        Divider().overlay(WH.Color.separator)
                    }
                }
            }
            .background(WH.Color.surface,
                        in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))
        }
    }

    private func row(_ item: TrackingDiagnosticItem) -> some View {
        HStack(alignment: .top, spacing: WH.Spacing.sm) {
            Image(systemName: symbol(item.status))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color(item.status))
                .frame(width: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundStyle(WH.Color.textPrimary)
                Text(item.detail)
                    .font(WH.Font.caption)
                    .foregroundStyle(WH.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(WH.Spacing.md)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name), \(statusWord(item.status)). \(item.detail)")
    }

    private func symbol(_ s: TrackingDiagnosticItem.Status) -> String {
        switch s {
        case .ok:      return "checkmark.circle.fill"
        case .partial: return "exclamationmark.triangle.fill"
        case .missing: return "xmark.circle.fill"
        }
    }

    private func color(_ s: TrackingDiagnosticItem.Status) -> Color {
        switch s {
        case .ok:      return WH.Color.recoveryGreen
        case .partial: return WH.Color.recoveryYellow
        case .missing: return WH.Color.textSecondary
        }
    }

    private func statusWord(_ s: TrackingDiagnosticItem.Status) -> String {
        switch s {
        case .ok:      return "funktioniert"
        case .partial: return "eingeschränkt"
        case .missing: return "nicht verfügbar"
        }
    }

    // MARK: - Disclaimer

    private var disclaimerCard: some View {
        VStack(alignment: .leading, spacing: WH.Spacing.xs) {
            Text("WIE GENAU IST DAS?")
                .font(WH.Font.cardTitle)
                .foregroundStyle(WH.Color.textSecondary)
                .tracking(1.2)
            Text("""
                 Ruhepuls und HRV sind direkte Messgrößen aus den Herzdaten des Bands und \
                 entsprechend belastbar. Schlafdauer wird aus dem Herzfrequenzverlauf erkannt — \
                 gut für „wann und wie lange", keine Labormessung. Recovery und Strain sind \
                 eigene Schätzformeln auf Basis deiner persönlichen Vergleichswerte.

                 Das sind ausdrücklich NICHT WHOOPs Zahlen: deren Algorithmen sind nicht \
                 offengelegt, und es gibt keine Referenzwerte, gegen die sich hier prüfen ließe.
                 """)
                .font(WH.Font.caption)
                .foregroundStyle(WH.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(WH.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WH.Color.surface2,
                    in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))
    }
}

// MARK: - Preview

#Preview("Tracking-Diagnose") {
    NavigationStack {
        TrackingDiagnosticsView()
            .environmentObject(MetricsRepository(deviceId: "preview"))
    }
    .preferredColorScheme(.dark)
}

// MARK: - Settings entry point
//
// Lives here rather than in SettingsView so that file needs only a one-line change: the row and
// all its wording stay next to the screen they open.

extension SettingsView {
    /// Row that opens the tracking status page. Referenced from SettingsView's Form body.
    ///
    /// No explicit .environmentObject here on purpose: a pushed destination inherits the
    /// environment of the NavigationStack it is pushed from, and SettingsView is already
    /// given the MetricsRepository by its presenter. Passing it again would also mean
    /// reaching into SettingsView's private property, which another file cannot do.
    var diagnosticsSection: some View {
        Section {
            NavigationLink(destination: TrackingDiagnosticsView()) {
                HStack(spacing: WH.Spacing.sm) {
                    Image(systemName: "checklist")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(WH.Color.teal)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Was wird getrackt?")
                            .foregroundStyle(WH.Color.textPrimary)
                        Text("Pr\u{00FC}ft Schlaf, HRV, Ruhepuls & Co. auf Verf\u{00FC}gbarkeit")
                            .font(WH.Font.caption)
                            .foregroundStyle(WH.Color.textSecondary)
                    }
                }
            }
        } header: {
            Text("Diagnose")
        }
    }
}
