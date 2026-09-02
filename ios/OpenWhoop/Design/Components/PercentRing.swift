import SwiftUI

// MARK: - PercentRing
// Generic circular progress ring for a 0–100 (or custom-max) value, used for the three Today
// hero rings (Sleep / Recovery / Strain). RecoveryRing delegates to this for backward
// compatibility with its existing call sites; TodayView uses it directly so all three rings
// share one visual language.
//
// Accessibility: the ring's diameter is fixed (it's a circle, it can't reflow like text), so the
// center numeral scales by a bounded multiplier at larger Dynamic Type sizes instead of 1:1 —
// see WH.Font.numeralScale(for:). VoiceOver gets a single combined "Sleep, 76 percent"-style
// label instead of reading the numeral and caption as two separate elements.

struct PercentRing: View {

    /// Value to render as the ring's arc, on a 0...maxValue scale.
    var value: Double
    var maxValue: Double = 100
    var size: CGFloat = 108
    var strokeWidth: CGFloat = 10
    var color: Color
    /// Caption under the center number, e.g. "RECOVERY".
    var label: String
    /// Overrides the center number (default: rounded integer of `value`). Use for e.g. a "—"
    /// pending state without needing a separate view.
    var displayText: String? = nil
    var showGlow: Bool = true
    /// Extra context appended to the VoiceOver label after the percentage, e.g. "efficiency" or
    /// "14.2 of 21". Purely spoken — not shown visually (see the caption Text in TodayView).
    var accessibilityDetail: String? = nil

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var clamped: Double { min(maxValue, max(0, value)) }
    private var progress: Double { maxValue > 0 ? clamped / maxValue : 0 }
    private var numeralSize: CGFloat {
        size * 0.32 * WH.Font.numeralScale(for: dynamicTypeSize)
    }

    var body: some View {
        ZStack {
            // --- Track (faint ring) ---
            Circle()
                .stroke(WH.Color.ringTrack, lineWidth: strokeWidth)

            // --- Filled arc ---
            Circle()
                .trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.6), value: progress)

            // --- Glow effect (subtle) ---
            if showGlow {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(color.opacity(0.25),
                            style: StrokeStyle(lineWidth: strokeWidth + 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .blur(radius: 5)
                    .animation(.easeInOut(duration: 0.6), value: progress)
            }

            // --- Center content ---
            VStack(spacing: 2) {
                Text(displayText ?? "\(Int(clamped.rounded()))")
                    .font(WH.Font.metricHero(size: numeralSize))
                    .foregroundStyle(WH.Color.textPrimary)
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)

                Text(label)
                    .font(WH.Font.cardTitle)
                    .foregroundStyle(WH.Color.textSecondary)
                    .tracking(1.2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 4)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let base = "\(label.capitalized), \(Int(clamped.rounded())) percent"
        guard let accessibilityDetail else { return base }
        return "\(base), \(accessibilityDetail)"
    }
}

// MARK: - PendingPercentRing
// Placeholder ring shown while a value hasn't loaded yet — same frame as PercentRing so layout
// doesn't jump once real data arrives.

struct PendingPercentRing: View {
    var size: CGFloat = 108
    var strokeWidth: CGFloat = 10
    var label: String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var numeralSize: CGFloat {
        size * 0.32 * WH.Font.numeralScale(for: dynamicTypeSize)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(WH.Color.ringTrack, lineWidth: strokeWidth)

            VStack(spacing: 2) {
                Text("—")
                    .font(WH.Font.metricHero(size: numeralSize))
                    .foregroundStyle(WH.Color.textSecondary)
                Text(label)
                    .font(WH.Font.cardTitle)
                    .foregroundStyle(WH.Color.textSecondary)
                    .tracking(1.2)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label.capitalized), not available yet")
    }
}

// MARK: - Preview

#Preview("Percent Rings") {
    HStack(spacing: WH.Spacing.lg) {
        PercentRing(value: 76, color: WH.Color.sleepPurple, label: "SLEEP")
        PercentRing(value: 82, color: WH.Color.recoveryColor(forPercent: 82), label: "RECOVERY")
        PercentRing(value: 68, color: WH.Color.strainBlue, label: "STRAIN")
        PendingPercentRing(label: "SLEEP")
    }
    .padding(WH.Spacing.xl)
    .background(WH.Color.background)
}
