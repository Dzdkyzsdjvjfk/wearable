import SwiftUI

// MARK: - StressExplainerView
// In-app disclosure sheet for the live Stress tile on the Today screen. Explains what's being
// shown and — matching this project's honesty-first stance on metric accuracy — what it is NOT.
// iOS 16 safe.

struct StressExplainerView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                WH.Color.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: WH.Spacing.lg) {
                        section(
                            title: "What this is",
                            body: "A live autonomic-stress estimate computed on your phone from the real-time R-R (heartbeat-to-heartbeat) intervals your strap streams over Bluetooth — the Baevsky Stress Index, a published heart-rate-variability formula from 1997. Lower means calmer, higher means more sympathetic (\"fight or flight\") activity."
                        )
                        section(
                            title: "How the history works",
                            body: "The formula needs a window of real beats, nothing more — so the same calculation runs over the R-R intervals already stored on your phone, in 5-to-30-minute bins, giving you the last 6 hours, 24 hours or 7 days. That includes stretches when the strap was recording without your phone nearby, because those beats arrive later with the strap's own history. A gap in the chart means too few beats in that window to compute anything honest — never \"calm\"."
                        )
                        section(
                            title: "What it is NOT",
                            body: "This is not a WHOOP metric. WHOOP's own stress score, if it has one, uses a different, undisclosed algorithm, and this formula has never been validated against it. Like every metric in this app, there is no WHOOP data to check it against, so treat the number as a rough, qualitative trend — \"calmer than a minute ago\" — not a clinical or precise reading."
                        )
                        Spacer(minLength: WH.Spacing.xl)
                    }
                    .padding(WH.Spacing.md)
                }
            }
            .navigationTitle("About Stress")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func section(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: WH.Spacing.xs) {
            Text(title)
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(WH.Color.textPrimary)
            Text(body)
                .font(.system(.subheadline, design: .default))
                .foregroundStyle(WH.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Preview

#Preview("Stress Explainer") {
    StressExplainerView()
}
