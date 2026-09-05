import SwiftUI
import Charts

// MARK: - StressDetailView
//
// What the Stress tile opens into: the stress history the tile itself can't show.
//
// Before this screen the tile was live-only — a single number that existed while the strap was
// connected and vanished on disconnect, with the explainer sheet openly calling the absence of
// history "by design". It isn't necessary: every beat is already stored, so the index can be
// recomputed per time-bin for any past window (see StressHistory.swift). This view does that for
// the last 6 / 24 hours or 7 days, with the live reading kept on top for "right now".
//
// iOS 16-safe: Charts API only, no iOS 17-only modifiers.

struct StressDetailView: View {
    @EnvironmentObject private var metrics: MetricsRepository
    @EnvironmentObject private var live: LiveViewModel

    // MARK: - Range

    enum Range: String, CaseIterable, Identifiable {
        case h6 = "6 h"
        case h24 = "24 h"
        case d7 = "7 d"

        var id: String { rawValue }
        var seconds: Int {
            switch self {
            case .h6:  return 6 * 3600
            case .h24: return 24 * 3600
            case .d7:  return 7 * 86_400
            }
        }
        /// Wider bins over longer ranges so a week doesn't become 2000 unreadable points.
        var binSeconds: Int {
            switch self {
            case .h6:  return 300      // 5 min
            case .h24: return 600      // 10 min
            case .d7:  return 1800     // 30 min
            }
        }
    }

    @State private var range: Range = .h24
    @State private var points: [StressPoint] = []
    @State private var isLoading = true
    @State private var selected: StressPoint?
    @State private var showExplainer = false

    // MARK: - Body

    var body: some View {
        ZStack {
            WH.Color.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: WH.Spacing.lg) {
                    liveHeader
                    rangePicker
                    chartCard
                    summaryCard
                    bandLegend
                    footnote
                }
                .padding(WH.Spacing.md)
            }
        }
        .navigationTitle("Stress")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showExplainer = true } label: { Image(systemName: "info.circle") }
                    .accessibilityLabel("About the stress index")
            }
        }
        .sheet(isPresented: $showExplainer) { StressExplainerView() }
        .preferredColorScheme(.dark)
        .task(id: range) { await reload() }
        .refreshable { await reload() }
    }

    // MARK: - Live "right now" header

    private var liveHeader: some View {
        let idx = live.stressIndex
        let band = idx.map(BaevskyStress.band(for:))
        return VStack(alignment: .leading, spacing: WH.Spacing.xs) {
            Text("RIGHT NOW")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .tracking(1.0)
                .foregroundStyle(WH.Color.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: WH.Spacing.sm) {
                Text(idx.map { String(format: "%.0f", $0) } ?? "—")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(color(for: band))
                    .monospacedDigit()
                Text(band?.label ?? (live.state.connected ? "Collecting beats…" : "Strap not connected"))
                    .font(WH.Font.caption)
                    .foregroundStyle(WH.Color.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Range picker

    private var rangePicker: some View {
        Picker("Range", selection: $range) {
            ForEach(Range.allCases) { r in Text(r.rawValue).tag(r) }
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Chart

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: WH.Spacing.sm) {
            HStack {
                Text(selected == nil ? "Verlauf" : selectedLabel)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(WH.Color.textPrimary)
                Spacer()
                if isLoading { ProgressView().tint(WH.Color.textSecondary).scaleEffect(0.7) }
            }
            if points.count < 2 {
                emptyChart
            } else {
                chart
            }
        }
        .padding(WH.Spacing.md)
        .background(WH.Color.surface,
                    in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))
    }

    private var selectedLabel: String {
        guard let s = selected else { return "" }
        let f = DateFormatter()
        f.dateFormat = range == .d7 ? "EEE HH:mm" : "HH:mm"
        return "\(f.string(from: s.date)) · \(Int(s.index.rounded())) · \(s.band.label)"
    }

    private var chart: some View {
        let smooth = StressHistory.smoothed(points)
        let maxY = max(600, (points.map(\.index).max() ?? 100) * 1.1)
        return Chart {
            // Band backgrounds make "calm / elevated / high" readable without a legend lookup.
            RectangleMark(yStart: .value("", 0), yEnd: .value("", 150))
                .foregroundStyle(WH.Color.recoveryGreen.opacity(0.07))
            RectangleMark(yStart: .value("", 150), yEnd: .value("", 500))
                .foregroundStyle(WH.Color.recoveryYellow.opacity(0.07))
            RectangleMark(yStart: .value("", 500), yEnd: .value("", maxY))
                .foregroundStyle(WH.Color.recoveryRed.opacity(0.07))

            ForEach(smooth) { p in
                AreaMark(x: .value("Time", p.date), y: .value("Stress", min(p.index, maxY)))
                    .foregroundStyle(.linearGradient(colors: [WH.Color.teal.opacity(0.35),
                                                              WH.Color.teal.opacity(0.02)],
                                                     startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.catmullRom)
                LineMark(x: .value("Time", p.date), y: .value("Stress", min(p.index, maxY)))
                    .foregroundStyle(WH.Color.teal)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .interpolationMethod(.catmullRom)
            }

            if let s = selected {
                RuleMark(x: .value("Time", s.date))
                    .foregroundStyle(WH.Color.textSecondary.opacity(0.5))
                PointMark(x: .value("Time", s.date), y: .value("Stress", min(s.index, maxY)))
                    .foregroundStyle(color(for: s.band))
                    .symbolSize(70)
            }
        }
        .chartYScale(domain: 0...maxY)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 150, 500]) { value in
                AxisGridLine().foregroundStyle(WH.Color.separator)
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text("\(Int(v))").font(.system(size: 10)).foregroundStyle(WH.Color.textSecondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(WH.Color.separator.opacity(0.5))
                AxisValueLabel(format: range == .d7
                               ? Date.FormatStyle().weekday(.abbreviated)
                               : Date.FormatStyle().hour().minute())
                    .foregroundStyle(WH.Color.textSecondary)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { drag in select(at: drag.location, proxy: proxy, geo: geo) }
                        .onEnded { _ in })
            }
        }
        .frame(height: 220)
    }

    /// iOS 16-safe hit testing: `plotAreaFrame` (not the iOS 17-only `plotFrame`), same approach
    /// MetricChart already uses.
    private func select(at location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) {
        guard !points.isEmpty else { return }
        let x = location.x - geo[proxy.plotAreaFrame].origin.x
        if let date: Date = proxy.value(atX: x) {
            selected = points.min(by: {
                abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
            })
        }
    }

    private var emptyChart: some View {
        VStack(spacing: WH.Spacing.xs) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(WH.Color.textSecondary.opacity(0.5))
            Text(isLoading ? "Wird berechnet…" : "Zu wenige R-R-Intervalle in diesem Zeitraum")
                .font(WH.Font.caption)
                .foregroundStyle(WH.Color.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 220)
    }

    // MARK: - Summary

    @ViewBuilder
    private var summaryCard: some View {
        if let s = StressHistory.summary(points, binSeconds: range.binSeconds) {
            VStack(alignment: .leading, spacing: WH.Spacing.sm) {
                HStack(spacing: WH.Spacing.lg) {
                    stat("Ø", String(format: "%.0f", s.average))
                    stat("Peak", String(format: "%.0f", s.peak))
                    stat("Erfasst", "\(s.coveredMinutes / 60) h \(s.coveredMinutes % 60) min")
                }
                shareBar(s)
            }
            .padding(WH.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WH.Color.surface,
                        in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .tracking(0.5)
                .foregroundStyle(WH.Color.textSecondary)
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(WH.Color.textPrimary)
                .monospacedDigit()
        }
    }

    /// Proportion of the window spent calm / elevated / high, as one stacked bar.
    private func shareBar(_ s: StressSummary) -> some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                segment(width: geo.size.width * CGFloat(s.calmShare), color: WH.Color.recoveryGreen)
                segment(width: geo.size.width * CGFloat(s.elevatedShare), color: WH.Color.recoveryYellow)
                segment(width: geo.size.width * CGFloat(s.highShare), color: WH.Color.recoveryRed)
            }
        }
        .frame(height: 8)
        .accessibilityLabel(String(format: "Calm %.0f percent, elevated %.0f percent, high %.0f percent",
                                   s.calmShare * 100, s.elevatedShare * 100, s.highShare * 100))
    }

    @ViewBuilder
    private func segment(width: CGFloat, color: Color) -> some View {
        if width > 0.5 {
            RoundedRectangle(cornerRadius: 4).fill(color).frame(width: width)
        }
    }

    // MARK: - Legend + footnote

    private var bandLegend: some View {
        HStack(spacing: WH.Spacing.md) {
            legendDot(WH.Color.recoveryGreen, "Ruhig  < 150")
            legendDot(WH.Color.recoveryYellow, "Erhöht  150–500")
            legendDot(WH.Color.recoveryRed, "Hoch  > 500")
        }
        .font(.system(size: 11))
        .foregroundStyle(WH.Color.textSecondary)
    }

    private func legendDot(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
        }
    }

    private var footnote: some View {
        Text("Rückwirkend aus den gespeicherten R-R-Intervallen berechnet — auch für Zeiten, in denen das Handy nicht verbunden war. Lücken bedeuten: zu wenige Herzschläge in diesem Fenster, nicht „ruhig\". Eigene Schätzung nach der Baevsky-Formel, kein WHOOP-Wert.")
            .font(.system(size: 11))
            .foregroundStyle(WH.Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Data

    private func reload() async {
        isLoading = true
        selected = nil
        let now = Int(Date().timeIntervalSince1970)
        points = await metrics.stressSeries(fromEpoch: now - range.seconds,
                                            toEpoch: now,
                                            binSeconds: range.binSeconds)
        isLoading = false
    }

    private func color(for band: BaevskyStress.Band?) -> Color {
        switch band {
        case .calm:     return WH.Color.recoveryGreen
        case .elevated: return WH.Color.recoveryYellow
        case .high:     return WH.Color.recoveryRed
        case nil:       return WH.Color.textSecondary
        }
    }
}
