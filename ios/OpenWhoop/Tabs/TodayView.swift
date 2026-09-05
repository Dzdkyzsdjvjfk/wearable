import SwiftUI
import UniformTypeIdentifiers

// MARK: - TodayView
// The command-centre "Today" tab. Renders server-cached recovery/strain/sleep/HRV/RHR metrics
// pulled from MetricsRepository, plus live BLE readings (HR chart, Stress) from LiveViewModel.
//
// Layout: three percentage hero rings (Sleep / Recovery / Strain) → detailed sleep card →
// a user-reorderable row of tiles (HRV / Resting HR / Stress) → a live heart-rate chart →
// strap status + sync footer.
//
// Tapping a metric → MetricDetailView (full history, range selector). The Stress tile opens
// StressDetailView, which recomputes the stress index per time-bin from the stored R-R intervals
// — so it has a real 6 h / 24 h / 7 d history, and the tile itself falls back to the most recent
// stored reading (with its age) whenever the strap isn't connected.

struct TodayView: View {
    @EnvironmentObject private var metrics: MetricsRepository
    @EnvironmentObject private var live: LiveViewModel
    @EnvironmentObject private var journal: JournalStore

    // Reorderable HRV / RHR / Stress row
    @State private var tileOrder: [TodayTileKind] = TileOrderStore.load()
    @State private var draggedTile: TodayTileKind?

    // Live HR chart selection (tap-to-highlight, like the Trends HR card)
    @State private var hrChartSelected: TrendPoint?

    @State private var showJournal = false

    /// Most recent stress reading recomputed from STORED R-R intervals, so the tile still shows a
    /// real value (with its age) when the strap isn't currently connected — it used to fall back
    /// to a dash the moment the live stream stopped.
    @State private var recentStress: StressPoint?

    /// Stored heart-rate samples backing the chart below the tiles (see hrChartSeries).
    @State private var storedHR: [TrendPoint] = []

    var body: some View {
        NavigationStack {
            ZStack {
                WH.Color.background.ignoresSafeArea()

                Group {
                    if metrics.isRefreshing && metrics.today == nil && metrics.lastNight == nil {
                        loadingView
                    } else {
                        scrollContent
                    }
                }
            }
            // Hide the system nav bar on the root so the custom ScreenHeader sits tight
            // below the status bar/Dynamic Island. Pushed detail views manage their own bars.
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .task { await metrics.refresh(); await loadRecentStress(); await loadStoredHR() }
        .refreshable { await metrics.refresh(); await loadRecentStress(); await loadStoredHR() }
        // A completed strap sync writes new rows; recompute and reload right away so the screen
        // reflects the data the moment it lands instead of on the next manual pull-to-refresh.
        .onChange(of: live.lastSyncedAt) { _ in
            Task { await metrics.refresh(); await loadRecentStress(); await loadStoredHR() }
        }
        // Reconnecting empties the live buffer, so pull the stored curve back in immediately
        // instead of leaving the chart blank until enough new readings have arrived.
        .onChange(of: live.connected) { _ in
            Task { await loadStoredHR(); await loadRecentStress() }
        }
        .sheet(isPresented: $showJournal) {
            JournalEntryView(day: JournalStore.dayString(), dayLabel: "Today", journal: journal)
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: WH.Spacing.md) {
            ProgressView()
                .tint(WH.Color.textSecondary)
            Text("Loading metrics…")
                .font(WH.Font.caption)
                .foregroundStyle(WH.Color.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Main scroll content

    private var scrollContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WH.Spacing.lg) {

                // Custom tight header (replaces the hidden system large-title nav bar)
                ScreenHeader("Today")

                // Three hero rings: Sleep / Recovery / Strain, each as a percentage
                heroRingsRow

                // Sleep card → sleep duration history
                NavigationLink(destination: MetricDetailView(kind: .sleepDuration)) {
                    sleepCard
                }
                .buttonStyle(.plain)

                // HRV + Resting HR + Stress — user can drag to reorder; order is persisted
                reorderableTileRow

                // Daily journal (custom tags + note) — local-only, no backend
                journalCard

                // Live heart-rate chart (BLE stream, not server-backed — updates in real time)
                hrChartCard

                if let err = metrics.lastError {
                    errorBanner(err)
                }

                if metrics.today == nil && metrics.lastNight == nil && !metrics.isRefreshing {
                    emptyState
                }

                strapNote
                syncFooter

                Spacer(minLength: WH.Spacing.xl)
            }
            .padding(WH.Spacing.md)
        }
        .background(WH.Color.background)
    }

    // MARK: - Hero rings (Sleep / Recovery / Strain, all as percentages)

    private var heroRingsRow: some View {
        HStack(spacing: WH.Spacing.md) {
            ringSlot(value: sleepPercent,
                     color: WH.Color.sleepPurple,
                     label: "SLEEP",
                     destination: .sleepDuration,
                     accessibilityDetail: "sleep efficiency")

            ringSlot(value: recoveryPercent,
                     color: recoveryPercent.map(WH.Color.recoveryColor(forPercent:)) ?? WH.Color.textSecondary,
                     label: "RECOVERY",
                     destination: .recovery)

            ringSlot(value: strainPercent,
                     color: WH.Color.strainBlue,
                     label: "STRAIN",
                     destination: .strain,
                     caption: strainCaption,
                     accessibilityDetail: strainCaption.map { "\($0) day strain" })
        }
        .padding(.top, WH.Spacing.sm)
    }

    /// Sleep efficiency as a percent — the one sleep number that's a percentage natively.
    private var sleepPercent: Double? {
        if let e = metrics.today?.efficiency, e > 0 { return e * 100 }
        if let e = metrics.lastNight?.efficiency, e > 0 { return e * 100 }
        return nil
    }

    private var recoveryPercent: Double? {
        metrics.today?.recovery.map { $0 * 100 }
    }

    /// Strain isn't naturally a percentage — WHOOP's own scale is 0–21, not linear/perceptual —
    /// so this ring is `strain / 21 * 100` purely so it visually matches the other two rings, as
    /// requested. The real 0–21 value is shown as a caption under the ring so it isn't lost.
    private var strainPercent: Double? {
        metrics.today?.strain.map { min(100, max(0, ($0 / 21) * 100)) }
    }

    private var strainCaption: String? {
        guard let s = metrics.today?.strain else { return nil }
        return String(format: "%.1f / 21", s)
    }

    @ViewBuilder
    private func ringSlot(value: Double?, color: Color, label: String,
                           destination: MetricKind, caption: String? = nil,
                           accessibilityDetail: String? = nil) -> some View {
        VStack(spacing: WH.Spacing.xs) {
            NavigationLink(destination: MetricDetailView(kind: destination)) {
                if let value {
                    PercentRing(value: value, size: 104, strokeWidth: 10, color: color, label: label,
                                accessibilityDetail: accessibilityDetail)
                } else {
                    PendingPercentRing(size: 104, strokeWidth: 10, label: label)
                }
            }
            .buttonStyle(.plain)

            if let caption {
                Text(caption)
                    .font(WH.Font.caption)
                    .foregroundStyle(WH.Color.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Sleep card

    private var sleepCard: some View {
        let sleepMin: Double? = {
            if let m = metrics.today?.totalSleepMin, m > 0 { return m }
            if let s = metrics.lastNight {
                let d = Double(s.endTs - s.startTs) / 60
                return d > 0 ? d : nil
            }
            return nil
        }()

        let efficiency: Double? = {
            guard sleepMin != nil else { return nil }
            if let e = metrics.today?.efficiency, e > 0 { return e }
            if let e = metrics.lastNight?.efficiency, e > 0 { return e }
            return nil
        }()

        return VStack(alignment: .leading, spacing: WH.Spacing.sm) {
            HStack {
                Text("LAST NIGHT")
                    .font(WH.Font.cardTitle)
                    .foregroundStyle(WH.Color.textSecondary)
                    .tracking(1.2)
                Spacer()
            }

            if let min = sleepMin {
                HStack(alignment: .lastTextBaseline, spacing: WH.Spacing.sm) {
                    Text(formatSleepMinutes(min))
                        .font(WH.Font.metricLarge())
                        .foregroundStyle(WH.Color.textPrimary)
                        .monospacedDigit()

                    if let eff = efficiency {
                        Text("·  \(Int((eff * 100).rounded()))% efficiency")
                            .font(WH.Font.unit)
                            .foregroundStyle(WH.Color.textSecondary)
                    }

                    Spacer(minLength: 0)
                }
            } else {
                Text("No sleep data")
                    .font(WH.Font.metricMedium())
                    .foregroundStyle(WH.Color.textSecondary)
            }
        }
        .padding(WH.Spacing.md)
        .background(WH.Color.surface,
                    in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))
    }

    // MARK: - Reorderable HRV / RHR / Stress row

    private var reorderableTileRow: some View {
        HStack(spacing: WH.Spacing.sm) {
            ForEach(tileOrder, id: \.self) { kind in
                tile(for: kind)
                    .frame(maxWidth: .infinity)
                    .onDrag {
                        draggedTile = kind
                        return NSItemProvider(object: kind.rawValue as NSString)
                    }
                    .onDrop(of: [.plainText],
                            delegate: TileDropDelegate(item: kind,
                                                        order: $tileOrder,
                                                        draggedItem: $draggedTile))
                    // Drag-and-drop is hard/impossible to use with VoiceOver, so every tile also
                    // exposes "Move left/right" as VoiceOver custom actions — a real alternative,
                    // not just a fallback in name.
                    .accessibilityAction(named: Text("Move left")) { moveTile(kind, by: -1) }
                    .accessibilityAction(named: Text("Move right")) { moveTile(kind, by: 1) }
            }
        }
        // Persist whenever the order settles (drag completes, VoiceOver move, or app relaunches
        // with a new drop).
        .onChange(of: tileOrder) { newOrder in
            TileOrderStore.save(newOrder)
        }
    }

    private func moveTile(_ kind: TodayTileKind, by offset: Int) {
        guard let index = tileOrder.firstIndex(of: kind) else { return }
        let newIndex = index + offset
        guard tileOrder.indices.contains(newIndex) else { return }
        tileOrder.swapAt(index, newIndex)
    }

    @ViewBuilder
    private func tile(for kind: TodayTileKind) -> some View {
        switch kind {
        case .hrv:
            NavigationLink(destination: MetricDetailView(kind: .hrv)) { hrvCard }
                .buttonStyle(.plain)
        case .rhr:
            NavigationLink(destination: MetricDetailView(kind: .rhr)) { rhrCard }
                .buttonStyle(.plain)
        case .stress:
            // Opens the stress HISTORY (recomputed from stored R-R intervals), not just the
            // explainer — the explainer is now the (i) button inside that screen.
            NavigationLink(destination: StressDetailView()) { stressCard }
                .buttonStyle(.plain)
                // Overrides MetricCard's own default label so the band (Calm/Elevated/High) is
                // spoken too, not just the raw index number.
                .accessibilityLabel(stressAccessibilityLabel)
        }
    }

    private var stressAccessibilityLabel: String {
        guard let idx = live.stressIndex ?? recentStress?.index else {
            return "Stress, not available. Wear your strap for a few minutes to get a reading."
        }
        let band = BaevskyStress.band(for: idx)
        return "Stress, \(band.label), index \(Int(idx.rounded())). Double tap to see the last 24 hours."
    }

    private var hrvCard: some View {
        let hrv = metrics.today?.avgHrv ?? metrics.lastNight?.avgHrv
        let value = hrv.map { String(format: "%.0f", $0) } ?? "—"
        // Fixed: was WH.Color.recoveryGreen, which collides visually with the recovery ring.
        // MetricKind.hrv.color (teal) is the single source of truth for HRV's accent elsewhere.
        let accent: Color = hrv != nil ? MetricKind.hrv.color : WH.Color.textSecondary
        return MetricCard(title: "HRV",
                          value: value,
                          unit: hrv != nil ? "ms" : nil,
                          accentColor: accent,
                          accessory: { tileAccessory() })
    }

    private var rhrCard: some View {
        let rhr = metrics.today?.restingHr ?? metrics.lastNight?.restingHr
        let value = rhr.map { "\($0)" } ?? "—"
        let accent: Color = rhr != nil ? WH.Color.textPrimary : WH.Color.textSecondary
        return MetricCard(title: "Resting HR",
                          value: value,
                          unit: rhr != nil ? "bpm" : nil,
                          accentColor: accent,
                          accessory: { tileAccessory() })
    }

    /// Loads the last few hours of stored stress so the tile has something real to show while the
    /// strap is disconnected. Cheap: a handful of bins, recomputed from rows already on disk.
    private func loadRecentStress() async {
        let now = Int(Date().timeIntervalSince1970)
        recentStress = (await metrics.stressSeries(fromEpoch: now - 6 * 3600, toEpoch: now)).last
    }

    private var stressCard: some View {
        // Live reading wins; the most recent stored one stands in when the strap is away.
        let idx = live.stressIndex ?? recentStress?.index
        let band = idx.map(BaevskyStress.band(for:))
        let value = idx.map { String(format: "%.0f", $0) } ?? "—"
        let caption: String? = {
            guard let band else { return nil }
            if live.stressIndex != nil { return band.label.uppercased() }
            guard let ts = recentStress?.ts else { return band.label.uppercased() }
            let mins = max(0, (Int(Date().timeIntervalSince1970) - ts) / 60)
            return mins < 60 ? "\(band.label.uppercased()) · vor \(mins) min"
                             : "\(band.label.uppercased()) · vor \(mins / 60) h"
        }()
        let accent: Color = {
            switch band {
            case .calm:     return WH.Color.recoveryGreen
            case .elevated: return WH.Color.recoveryYellow
            case .high:     return WH.Color.recoveryRed
            case nil:       return WH.Color.textSecondary
            }
        }()
        return MetricCard(title: "Stress",
                          value: value,
                          unit: nil,
                          accentColor: accent,
                          accessory: { tileAccessory(caption: caption) })
    }

    /// Shared accessory row for the three reorderable tiles: an optional short caption on the
    /// left (used by Stress for its Calm/Elevated/High band) and a drag-handle glyph on the
    /// right, signalling the tile can be dragged to reorder.
    private func tileAccessory(caption: String? = nil) -> some View {
        HStack {
            if let caption {
                Text(caption)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(WH.Color.textSecondary)
                    .tracking(0.5)
            }
            Spacer()
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(WH.Color.textSecondary.opacity(0.35))
                // Purely decorative — the actual reorder affordance for VoiceOver is the
                // "Move left/right" accessibility actions on the tile itself, not this glyph.
                .accessibilityHidden(true)
        }
    }

    // MARK: - Journal card

    /// Today's journal at a glance: shows what's already logged, or a "Log today" prompt.
    /// Tapping opens JournalEntryView for today; "History" pushes the full log.
    private var journalCard: some View {
        let today = JournalStore.dayString()
        let entry = journal.entry(for: today)
        let tagNames = entry.tagIDs.compactMap { id in journal.tags.first { $0.id == id }?.name }
        let noteText = entry.note.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasLog = !tagNames.isEmpty || !noteText.isEmpty

        return VStack(alignment: .leading, spacing: WH.Spacing.sm) {
            HStack {
                Text("JOURNAL")
                    .font(WH.Font.cardTitle)
                    .foregroundStyle(WH.Color.textSecondary)
                    .tracking(1.2)
                Spacer()
                NavigationLink(destination: JournalHistoryView()) {
                    Text("History")
                        .font(WH.Font.caption)
                        .foregroundStyle(WH.Color.teal)
                }
            }

            Button {
                showJournal = true
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        if hasLog {
                            Text(tagNames.isEmpty ? "Logged" : tagNames.joined(separator: " · "))
                                .font(WH.Font.metricMedium(size: 17))
                                .foregroundStyle(WH.Color.textPrimary)
                                .lineLimit(1)
                            if !noteText.isEmpty {
                                Text(noteText)
                                    .font(WH.Font.caption)
                                    .foregroundStyle(WH.Color.textSecondary)
                                    .lineLimit(1)
                            }
                        } else {
                            Text("Log today")
                                .font(WH.Font.metricMedium(size: 17))
                                .foregroundStyle(WH.Color.textSecondary)
                        }
                    }
                    Spacer()
                    Image(systemName: hasLog ? "pencil.circle.fill" : "plus.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(WH.Color.teal)
                        .accessibilityHidden(true)
                }
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(hasLog
                ? "Journal logged for today: \(tagNames.joined(separator: ", "))"
                : "Log today's journal")
            .accessibilityAddTraits(.isButton)
        }
        .padding(WH.Spacing.md)
        .background(WH.Color.surface,
                    in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))
    }

    // MARK: - Live heart-rate chart

    private var hrChartCard: some View {
        VStack(alignment: .leading, spacing: WH.Spacing.sm) {
            HStack(alignment: .lastTextBaseline) {
                Text("HEART RATE")
                    .font(WH.Font.cardTitle)
                    .foregroundStyle(WH.Color.textSecondary)
                    .tracking(1.2)
                Spacer()
                if live.state.connected, let hr = live.state.heartRate {
                    HStack(alignment: .lastTextBaseline, spacing: 3) {
                        Text("\(hr)")
                            .font(WH.Font.metricMedium(size: 22))
                            .foregroundStyle(MetricKind.rawHR.color)
                            .monospacedDigit()
                        Text("bpm")
                            .font(WH.Font.caption)
                            .foregroundStyle(WH.Color.textSecondary)
                    }
                }
            }
            // Labelled on just the header, not the whole card: Swift Charts already gives the
            // Chart below its own per-point VoiceOver navigation (swipe through samples) —
            // combining the whole card into one element would silently swallow that.
            .accessibilityElement(children: .combine)
            .accessibilityLabel(hrChartAccessibilityLabel)

            if hrChartSeries.count >= 2 {
                MetricChart(series: hrChartSeries,
                           kind: .rawHR,
                           showAxes: true,
                           showSelection: true,
                           yDomain: nil,
                           selected: $hrChartSelected)
                    .frame(height: 140)

                Text(live.connected
                     ? "Live · last \(hrChartWindowMinutes) min"
                     : "Recorded · last \(hrChartWindowMinutes) min")
                    .font(WH.Font.caption)
                    .foregroundStyle(WH.Color.textSecondary.opacity(0.6))
            } else {
                HStack {
                    Spacer()
                    VStack(spacing: WH.Spacing.xs) {
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(WH.Color.textSecondary.opacity(0.5))
                        Text("No heart rate in the last hour. Wear the strap, or sync it from the Device tab.")
                            .font(WH.Font.caption)
                            .foregroundStyle(WH.Color.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    Spacer()
                }
                .frame(height: 140)
            }
        }
        .padding(WH.Spacing.md)
        .background(WH.Color.surface,
                    in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))
    }

    /// How far back the heart-rate card looks. Longer than the live-only buffer because most of
    /// the curve now comes from stored samples, not from this session's readings.
    private var hrChartWindowMinutes: Int { 60 }

    /// What the chart actually plots: stored samples first, then this session's live readings.
    ///
    /// Merging the two is what fixes an empty chart right after connecting — the live buffer
    /// starts from scratch on every connect, while the database already holds the last hour. Both
    /// are keyed by second, so a reading present in both is kept once and the live copy wins.
    private var hrChartSeries: [TrendPoint] {
        let cutoff = Date().addingTimeInterval(-Double(hrChartWindowMinutes) * 60)
        var bySecond: [Int: TrendPoint] = [:]
        for p in storedHR where p.date >= cutoff {
            bySecond[Int(p.date.timeIntervalSince1970)] = p
        }
        for p in live.hrHistory where p.date >= cutoff {
            bySecond[Int(p.date.timeIntervalSince1970)] = p
        }
        return bySecond.keys.sorted().compactMap { bySecond[$0] }
    }

    /// Loads the stored part of the chart. Cheap enough to redo whenever the screen appears, a
    /// sync lands, or the strap (re)connects.
    private func loadStoredHR() async {
        storedHR = await metrics.recentHRPoints(minutes: hrChartWindowMinutes)
    }

    private var hrChartAccessibilityLabel: String {
        let series = hrChartSeries
        guard series.count >= 2 else { return "Heart rate chart, no data yet" }
        let latest = Int(series.last?.value.rounded() ?? 0)
        return "Heart rate chart, latest \(latest) beats per minute, over the last \(hrChartWindowMinutes) minutes"
    }

    // MARK: - Empty state

    private var emptyState: some View {
        HStack {
            Spacer()
            VStack(spacing: WH.Spacing.sm) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(WH.Color.textSecondary)
                Text("No metrics yet")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(WH.Color.textPrimary)
                Text("Pull down to refresh")
                    .font(WH.Font.caption)
                    .foregroundStyle(WH.Color.textSecondary)
            }
            .padding(.vertical, WH.Spacing.xxl)
            Spacer()
        }
    }

    // MARK: - Live strap status row (HR + battery when connected; caption when not)

    /// Compact pill showing a single live reading (HR or battery).
    private func liveChip(icon: String, label: String, color: Color) -> some View {
        HStack(spacing: WH.Spacing.xs) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(WH.Color.textPrimary)
                .monospacedDigit()
        }
        .padding(.horizontal, WH.Spacing.sm)
        .padding(.vertical, WH.Spacing.xs)
        .background(WH.Color.surface2,
                    in: Capsule())
    }

    /// Shows live HR + battery pills when connected; otherwise shows the connect caption.
    private var strapNote: some View {
        Group {
            if live.state.connected, let hr = live.state.heartRate {
                HStack(spacing: WH.Spacing.sm) {
                    liveChip(icon: "heart.fill",
                             label: "\(hr) BPM LIVE",
                             color: WH.Color.recoveryRed)
                    if let bat = live.state.batteryPct {
                        let pct = Int(bat.rounded())
                        let batColor: Color = pct > 30 ? WH.Color.recoveryGreen
                                                       : WH.Color.recoveryYellow
                        let batIcon = pct > 70 ? "battery.100" :
                                      pct > 30 ? "battery.50"  : "battery.25"
                        liveChip(icon: batIcon,
                                 label: "\(pct)%",
                                 color: batColor)
                    }
                    Spacer()
                }
            } else {
                HStack(spacing: WH.Spacing.xs) {
                    Image(systemName: "wave.3.right")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(WH.Color.textSecondary.opacity(0.5))
                    Text("Live HR & battery appear when your strap is connected (Device tab)")
                        .font(WH.Font.caption)
                        .foregroundStyle(WH.Color.textSecondary.opacity(0.5))
                        .lineLimit(2)
                }
            }
        }
    }

    // MARK: - Sync footer

    private var syncFooter: some View {
        HStack {
            if metrics.isRefreshing {
                HStack(spacing: WH.Spacing.xs) {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(WH.Color.textSecondary)
                    Text("Updating…")
                        .font(WH.Font.caption)
                        .foregroundStyle(WH.Color.textSecondary)
                }
            } else if let at = metrics.lastRefreshedAt {
                Text("Last updated \(absoluteTime(from: at))")
                    .font(WH.Font.caption)
                    .foregroundStyle(WH.Color.textSecondary)
                    // VoiceOver still gets the relative form ("5 minutes ago") — much easier to
                    // parse by ear than reading a clock time back out loud.
                    .accessibilityLabel("Last updated \(relativeTime(from: at))")
            }
            Spacer()
        }
    }

    // MARK: - Error banner

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: WH.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(WH.Color.recoveryYellow)
            Text(message)
                .font(WH.Font.caption)
                .foregroundStyle(WH.Color.textSecondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(WH.Spacing.sm)
        .background(WH.Color.surface2,
                    in: RoundedRectangle(cornerRadius: WH.Radius.chip, style: .continuous))
    }

    // MARK: - Formatting helpers

    private func formatSleepMinutes(_ totalMin: Double) -> String {
        guard totalMin > 0 else { return "—" }
        let hours = Int(totalMin) / 60
        let mins  = Int(totalMin) % 60
        if hours > 0 && mins > 0 { return "\(hours)h \(mins)m" }
        if hours > 0              { return "\(hours)h" }
        return "\(mins)m"
    }

    private func relativeTime(from date: Date) -> String {
        let elapsed = Int(-date.timeIntervalSinceNow)
        switch elapsed {
        case ..<5:   return "just now"
        case ..<60:  return "\(elapsed)s ago"
        case ..<3600:
            let m = elapsed / 60
            return "\(m)m ago"
        default:
            let h = elapsed / 3600
            return "\(h)h ago"
        }
    }

    /// Clock time, e.g. "14:32" or "9:05 AM" — whichever the device's 12h/24h setting uses.
    /// "Yesterday 14:32" (or a short date beyond that) when the refresh wasn't today, so the
    /// footer never shows a bare time that's actually a day (or more) stale.
    private func absoluteTime(from date: Date) -> String {
        let fmt = DateFormatter()
        fmt.timeStyle = .short
        fmt.dateStyle = .none
        let time = fmt.string(from: date)

        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return time
        } else if cal.isDateInYesterday(date) {
            return "yesterday \(time)"
        } else {
            let dateFmt = DateFormatter()
            dateFmt.dateStyle = .short
            dateFmt.timeStyle = .none
            return "\(dateFmt.string(from: date)) \(time)"
        }
    }
}

// MARK: - TodayTileKind
// The three reorderable tiles below the sleep card. Raw values are persisted to UserDefaults —
// don't rename existing cases without adding a migration, or a user's saved order will look
// stale/corrupt and silently reset to default (see TileOrderStore.load()).
enum TodayTileKind: String, CaseIterable, Hashable {
    case hrv, rhr, stress
}

// MARK: - TileOrderStore
// Persists the user's drag-to-reorder tile order via UserDefaults, as a comma-joined raw-value
// string (there's no native @AppStorage support for a custom array type).

private enum TileOrderStore {
    private static let key = "today.tileOrder.v1"

    static func load() -> [TodayTileKind] {
        let defaultOrder = TodayTileKind.allCases
        let saved = UserDefaults.standard.string(forKey: key)?
            .split(separator: ",")
            .compactMap { TodayTileKind(rawValue: String($0)) } ?? []

        // Validate: the saved order must contain exactly the current case set. Guards against a
        // stale/corrupt save (e.g. from an older app version with a different case list).
        guard saved.count == defaultOrder.count, Set(saved) == Set(defaultOrder) else {
            return defaultOrder
        }
        return saved
    }

    static func save(_ order: [TodayTileKind]) {
        UserDefaults.standard.set(order.map(\.rawValue).joined(separator: ","), forKey: key)
    }
}

// MARK: - TileDropDelegate
// Drives `items.move(fromOffsets:toOffset:)` as the user drags one tile over another.
// Persisting happens in TodayView's `.onChange(of: tileOrder)`, not here.

private struct TileDropDelegate: DropDelegate {
    let item: TodayTileKind
    @Binding var order: [TodayTileKind]
    @Binding var draggedItem: TodayTileKind?

    func dropEntered(info: DropInfo) {
        guard let dragged = draggedItem, dragged != item,
              let from = order.firstIndex(of: dragged),
              let to = order.firstIndex(of: item) else { return }
        guard order[to] != dragged else { return }
        order.move(fromOffsets: IndexSet(integer: from),
                   toOffset: to > from ? to + 1 : to)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedItem = nil
        return true
    }
}

// MARK: - Preview

#Preview("Today — empty (cold start)") {
    TodayView()
        .environmentObject(MetricsRepository(deviceId: "preview"))
        .environmentObject(JournalStore())
}

#Preview("Today — design gallery reference") {
    DesignGallery()
}
