import SwiftUI
import Charts

// MARK: - TrendPoint
// Shared model used by TrendChartCard and MetricChart.
// id = YYYY-MM-DD, unique per day.

struct TrendPoint: Identifiable, Equatable {
    let id: String   // YYYY-MM-DD for daily series; a timestamp for stream series
    let date: Date
    let value: Double
    /// Which unbroken run of data this point belongs to. Points in different segments are NEVER
    /// joined by a line: a stream with a two-hour hole in it used to be drawn as one long
    /// straight diagonal across the hole, which reads as "the heart rate slowly drifted" when the
    /// truth is "there is no data here". Daily series leave it at 0 and behave as before.
    var segment: Int = 0
}

extension Array where Element == TrendPoint {
    /// Splits a time-ordered stream into segments wherever the gap between two consecutive points
    /// exceeds `maxGap`, so the chart can leave holes visible instead of bridging them.
    func segmented(maxGap: TimeInterval) -> [TrendPoint] {
        guard count > 1 else { return self }
        var out: [TrendPoint] = []
        var segment = 0
        for (i, p) in enumerated() {
            if i > 0, p.date.timeIntervalSince(self[i - 1].date) > maxGap { segment += 1 }
            var copy = p
            copy.segment = segment
            out.append(copy)
        }
        return out
    }
}

// MARK: - TrendChartCard
// A titled card containing a MetricChart for a single metric.
// Header is tappable (chevron) → MetricDetailView for full history.
// Tapping a chart point → onSelectDay callback (DayDetailView sheet).

struct TrendChartCard: View {

    let kind: MetricKind
    let points: [TrendPoint]
    let latestLabel: String     // pre-formatted display string for latest value
    let onSelectDay: (String) -> Void

    @State private var selected: TrendPoint? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: WH.Spacing.sm) {

            // Header: tappable → MetricDetailView
            NavigationLink(destination: MetricDetailView(kind: kind)) {
                HStack(alignment: .lastTextBaseline) {
                    Text(kind.title.uppercased())
                        .font(WH.Font.cardTitle)
                        .foregroundStyle(WH.Color.textSecondary)
                        .tracking(1.2)
                    Spacer()
                    HStack(alignment: .lastTextBaseline, spacing: 3) {
                        Text(latestLabel)
                            .font(WH.Font.metricMedium(size: 22))
                            .foregroundStyle(kind.color)
                            .monospacedDigit()
                        Text(kind.unit)
                            .font(WH.Font.caption)
                            .foregroundStyle(WH.Color.textSecondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(WH.Color.textSecondary.opacity(0.5))
                        .padding(.leading, WH.Spacing.xs)
                }
            }
            .buttonStyle(.plain)

            // Chart (compact: no axes, with day-tap selection)
            MetricChart(
                series: points,
                kind: kind,
                showAxes: true,
                showSelection: true,
                yDomain: kind.fixedYDomain,
                selected: $selected
            )
            .frame(height: 140)
            .onChange(of: selected) { pt in
                if let pt = pt { onSelectDay(pt.id) }
            }
        }
        .padding(WH.Spacing.md)
        .background(WH.Color.surface,
                    in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))
    }
}
