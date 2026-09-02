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
                            title: "Why it only works live",
                            body: "It needs a steady stream of real beats to compute, so it only updates while your strap is connected and streaming, and it resets when you disconnect. There's no history or daily average — that's by design, not a bug."
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
