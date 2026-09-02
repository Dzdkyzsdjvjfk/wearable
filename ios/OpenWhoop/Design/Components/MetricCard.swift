import SwiftUI

// MARK: - MetricCard
// Dark rounded card displaying a titled metric.
// Flexible: title + big value + optional unit + optional accessory view.
// Used for Recovery %, Strain, Sleep hours, HRV, RHR, SpO2, etc.

struct MetricCard<Accessory: View>: View {

    var title: String
    var value: String
    var unit: String?
    var accentColor: Color = WH.Color.textPrimary
    var accessory: (() -> Accessory)?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var valueSize: CGFloat { 28 * WH.Font.numeralScale(for: dynamicTypeSize) }

    var body: some View {
        VStack(alignment: .leading, spacing: WH.Spacing.sm) {

            // --- Header row ---
            HStack {
                Text(title.uppercased())
                    .font(WH.Font.cardTitle)
                    .foregroundStyle(WH.Color.textSecondary)
                    .tracking(1.2)
                Spacer()
            }

            // --- Value + unit ---
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(value)
                    .font(WH.Font.metricMedium(size: valueSize))
                    .foregroundStyle(accentColor)
                    .monospacedDigit()

                if let unit {
                    Text(unit)
                        .font(WH.Font.unit)
                        .foregroundStyle(WH.Color.textSecondary)
                }

                Spacer(minLength: 0)
            }

            // --- Optional accessory (e.g. sparkline, dot, badge) ---
            if let accessory {
                accessory()
            }
        }
        .padding(WH.Spacing.md)
        .background(WH.Color.surface, in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))
        // Default combined VoiceOver reading ("HRV, 62 ms") for every call site. A caller that
        // wants a more specific phrase (e.g. including a live status) can still override with its
        // own .accessibilityLabel(...) on top of this view — an explicit label always wins.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)\(unit.map { ", \(value) \($0)" } ?? ", \(value)")")
    }
}

// Convenience init without accessory
extension MetricCard where Accessory == EmptyView {
    init(title: String, value: String, unit: String? = nil, accentColor: Color = WH.Color.textPrimary) {
        self.title = title
        self.value = value
        self.unit = unit
        self.accentColor = accentColor
        self.accessory = nil
    }
}

// MARK: - Preview

#Preview("Metric Cards") {
    VStack(spacing: WH.Spacing.sm) {
        MetricCard(title: "Strain", value: "14.2", accentColor: WH.Color.strainBlue)
        MetricCard(title: "Sleep", value: "7h 23m", accentColor: WH.Color.textPrimary)
        MetricCard(title: "HRV", value: "62", unit: "ms", accentColor: WH.Color.recoveryGreen)
        MetricCard(title: "Resting HR", value: "48", unit: "bpm")
        MetricCard(title: "SpO2", value: "97", unit: "%")
    }
    .padding(WH.Spacing.md)
    .background(WH.Color.background)
}
