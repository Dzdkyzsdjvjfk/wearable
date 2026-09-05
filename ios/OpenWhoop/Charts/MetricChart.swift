import SwiftUI
import Charts

// MARK: - MetricChart
// Unified, reusable chart component used by TrendChartCard (compact) and MetricDetailView (full).
// iOS 16-safe: uses .chartOverlay + GeometryReader for tap selection.
// Overflow fix: .clipped() + .chartPlotStyle(.clipped()) + padded y-scale.

struct MetricChart: View {

    let series: [TrendPoint]
    let kind: MetricKind
    var showAxes: Bool = true
    var showSelection: Bool = false
    var yDomain: ClosedRange<Double>? = nil
    @Binding var selected: TrendPoint?

    // MARK: - Body

    var body: some View {
        if series.count < 2 {
            emptyChart
        } else {
            chartBody
        }
    }

    // MARK: - Empty state

    private var emptyChart: some View {
        HStack {
            Spacer()
            VStack(spacing: WH.Spacing.xs) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(WH.Color.textSecondary.opacity(0.5))
                Text("Not enough data")
                    .font(WH.Font.caption)
                    .foregroundStyle(WH.Color.textSecondary)
            }
            Spacer()
        }
        .frame(height: showAxes ? 200 : 100)
    }

    // MARK: - Effective y-domain with padding

    private var effectiveDomain: ClosedRange<Double> {
        let base = yDomain ?? kind.fixedYDomain
        let vals = series.map(\.value)
        let minVal = vals.min() ?? 0
        let maxVal = vals.max() ?? 1

        let lo: Double
        let hi: Double
        if let b = base {
            lo = b.lowerBound
            hi = b.upperBound
        } else {
            let pad = max((maxVal - minVal) * 0.13, 1.0)
            lo = max(0, minVal - pad)
            hi = maxVal + pad
        }
        return lo...hi
    }

    // MARK: - Main chart

    @ViewBuilder
    private var chartBody: some View {
        let dom = effectiveDomain
        let color = kind.color

        Chart {
            // Recovery zone bands (drawn first, behind the data)
            if kind.hasRecoveryBands {
                recoveryBands(dom: dom)
            }

            // Data marks
            switch kind.markType {
            case .line:
                lineMarks(color: color)
            case .bar:
                barMarks(color: color)
            }

            // Selection highlight
            if showSelection, let sel = selected {
                PointMark(
                    x: .value("Date", sel.date),
                    y: .value(kind.title, sel.value)
                )
                .foregroundStyle(color)
                .symbolSize(100)
                .annotation(position: .top, alignment: .center, spacing: 4) {
                    selectionCallout(point: sel)
                }
            }
        }
        .chartYScale(domain: dom)
        .chartXAxis { xAxisContent }
        .chartYAxis { yAxisContent }
        .chartPlotStyle { plot in
            plot
                .background(WH.Color.surface2)
                .clipped()
        }
        .clipped()
        // iOS-16 tap detection
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        guard showSelection else { return }
                        handleTap(location: location, proxy: proxy, geometry: geo)
                    }
            }
        }
    }

    // MARK: - Recovery zone bands

    @ChartContentBuilder
    private func recoveryBands(dom: ClosedRange<Double>) -> some ChartContent {
        // Green zone: 67–100
        RectangleMark(
            xStart: .value("s", series.first!.date),
            xEnd:   .value("e", series.last!.date),
            yStart: .value("lo", min(67.0, dom.upperBound)),
            yEnd:   .value("hi", dom.upperBound)
        )
        .foregroundStyle(WH.Color.recoveryGreen.opacity(0.07))

        // Yellow zone: 34–67
        RectangleMark(
            xStart: .value("s", series.first!.date),
            xEnd:   .value("e", series.last!.date),
            yStart: .value("lo", min(34.0, dom.upperBound)),
            yEnd:   .value("hi", min(67.0, dom.upperBound))
        )
        .foregroundStyle(WH.Color.recoveryYellow.opacity(0.07))

        // Red zone: 0–34
        RectangleMark(
            xStart: .value("s", series.first!.date),
            xEnd:   .value("e", series.last!.date),
            yStart: .value("lo", dom.lowerBound),
            yEnd:   .value("hi", min(34.0, dom.upperBound))
        )
        .foregroundStyle(WH.Color.recoveryRed.opacity(0.07))
    }

    // MARK: - Line marks

    @ChartContentBuilder
    private func lineMarks(color: Color) -> some ChartContent {
        // Faint gradient area
        ForEach(series) { pt in
            AreaMark(
                x: .value("Date", pt.date),
                y: .value(kind.title, pt.value),
                series: .value("Segment", pt.segment)
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [color.opacity(0.28), color.opacity(0.0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .interpolationMethod(.catmullRom)
        }
        // Line
        // series: — points from different segments are never connected, so a gap in the data
        // stays a gap instead of being drawn as a long straight line across it.
        ForEach(series) { pt in
            LineMark(
                x: .value("Date", pt.date),
                y: .value(kind.title, pt.value),
                series: .value("Segment", pt.segment)
            )
            .foregroundStyle(color)
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .interpolationMethod(.catmullRom)
        }
    }

    // MARK: - Bar marks

    @ChartContentBuilder
    private func barMarks(color: Color) -> some ChartContent {
        // Constrain bar width based on point count to prevent overflow
        let barWidth: MarkDimension = barWidthForCount(series.count)
        ForEach(series) { pt in
            BarMark(
                x: .value("Date", pt.date),
                y: .value(kind.title, pt.value),
                width: barWidth
            )
            .foregroundStyle(color.opacity(0.85))
            .cornerRadius(3)
        }
    }

    private func barWidthForCount(_ count: Int) -> MarkDimension {
        // Keep bars narrow enough to never bleed: cap at ~12pt max
        switch count {
        case ..<8:  return .fixed(14)
        case ..<15: return .fixed(10)
        case ..<31: return .fixed(7)
        case ..<91: return .fixed(4)
        default:    return .fixed(3)
        }
    }

    // MARK: - Adaptive x-axis helpers

    /// Number of calendar days the series spans (first point to last point).
    private var seriesSpanDays: Int {
        guard let first = series.first?.date, let last = series.last?.date else { return 0 }
        return max(1, Int(last.timeIntervalSince(first) / 86_400) + 1)
    }

    /// Desired tick count chosen so that no two ticks land on the same calendar day.
    /// With N days of data the axis will place at most N ticks; we also cap at 5
    /// to keep labels readable on narrow screens.
    private var xAxisDesiredCount: Int {
        let days = seriesSpanDays
        // Never request more ticks than we have unique days.
        return min(5, max(2, days))
    }

    /// Format: "MMM" (e.g. "May") for spans > 30 days; "M/d" otherwise.
    private func xAxisDateLabel(_ date: Date) -> String {
        seriesSpanDays > 30 ? Self.monthFmt.string(from: date) : Self.shortFmt.string(from: date)
    }

    // MARK: - Axis content

    @AxisContentBuilder
    private var xAxisContent: some AxisContent {
        if showAxes {
            AxisMarks(values: .automatic(desiredCount: xAxisDesiredCount)) { value in
                AxisGridLine()
                    .foregroundStyle(WH.Color.separator.opacity(0.5))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(xAxisDateLabel(date))
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .foregroundStyle(WH.Color.textSecondary)
                    }
                }
            }
        } else {
            AxisMarks { _ in }   // hide in compact mode
        }
    }

    @AxisContentBuilder
    private var yAxisContent: some AxisContent {
        if showAxes {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                    .foregroundStyle(WH.Color.separator)
                AxisValueLabel {
                    if let d = value.as(Double.self) {
                        Text(kind.formatShort(d))
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .foregroundStyle(WH.Color.textSecondary)
                    }
                }
            }
        } else {
            AxisMarks(position: .leading) { _ in }
        }
    }

    // MARK: - Selection callout

    private func selectionCallout(point: TrendPoint) -> some View {
        VStack(spacing: 2) {
            Text(kind.format(point.value))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(WH.Color.textPrimary)
            Text(mediumDateLabel(point.date))
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(WH.Color.textSecondary)
        }
        .padding(.horizontal, WH.Spacing.sm)
        .padding(.vertical, WH.Spacing.xs)
        .background(WH.Color.surface2,
                    in: RoundedRectangle(cornerRadius: WH.Radius.chip, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: WH.Radius.chip, style: .continuous)
                .stroke(WH.Color.separator, lineWidth: 0.5)
        )
    }

    // MARK: - Tap handling (iOS 16)

    private func handleTap(location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard !series.isEmpty else { return }
        let origin = geometry[proxy.plotAreaFrame].origin
        let x = location.x - origin.x

        if let tappedDate: Date = proxy.value(atX: x) {
            selected = series.min(by: {
                abs($0.date.timeIntervalSince(tappedDate)) < abs($1.date.timeIntervalSince(tappedDate))
            })
        } else {
            // Fallback: fractional position
            let fraction = max(0, min(1, location.x / geometry.size.width))
            let idx = min(series.count - 1, Int((fraction * Double(series.count - 1)).rounded()))
            selected = series[idx]
        }
    }

    // MARK: - Date formatting helpers

    private static let shortFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "M/d"; return f
    }()
    private static let medFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f
    }()
    private static let monthFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM"; return f
    }()

    private func shortDateLabel(_ date: Date) -> String { Self.shortFmt.string(from: date) }
    private func mediumDateLabel(_ date: Date) -> String { Self.medFmt.string(from: date) }
}
