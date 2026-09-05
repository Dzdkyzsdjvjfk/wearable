import SwiftUI

// MARK: - WorkoutsView
// M5 Workouts tab — auto-detected workout bouts for the last 30 days.
// MetricsRepository.workouts() serves them from the server when one is configured and otherwise
// detects them on-device from the stored heart-rate stream (see WorkoutDetector.swift), so this
// tab works on a personal build with no server. Refresh on .task + pull-to-refresh.

struct WorkoutsView: View {
    @EnvironmentObject private var metrics: MetricsRepository

    // MARK: - State

    @State private var workouts: [Workout] = []
    @State private var isLoading = true
    @State private var errorMessage: String? = nil

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                WH.Color.background.ignoresSafeArea()

                if isLoading {
                    loadingView
                } else {
                    listContent
                }
            }
            // Hide the system nav bar on the root; pushed detail views manage their own bars.
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .task {
            await reload()
        }
        .refreshable {
            await reload()
        }
    }

    // MARK: - Loading view

    private var loadingView: some View {
        VStack(spacing: WH.Spacing.md) {
            ProgressView()
                .tint(WH.Color.textSecondary)
            Text("Loading workouts…")
                .font(WH.Font.caption)
                .foregroundStyle(WH.Color.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - List / empty content

    private var listContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {

                // Custom tight header (replaces the hidden system large-title nav bar)
                ScreenHeader("Workouts")

                if let err = errorMessage {
                    errorBanner(err)
                        .padding(.horizontal, WH.Spacing.md)
                        .padding(.top, WH.Spacing.sm)
                }

                if workouts.isEmpty {
                    emptyState
                } else {
                    workoutList
                }
            }
        }
        .background(WH.Color.background)
    }

    // MARK: - Workout list

    private var workoutList: some View {
        VStack(spacing: 1) {
            ForEach(workouts) { workout in
                NavigationLink(destination: WorkoutDetailView(workout: workout)) {
                    workoutRow(workout)
                }
                .buttonStyle(.plain)
            }
        }
        .background(WH.Color.surface,
                    in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))
        .padding(WH.Spacing.md)
    }

    private func workoutRow(_ w: Workout) -> some View {
        HStack(spacing: WH.Spacing.sm) {

            // Date + time column
            VStack(alignment: .leading, spacing: 2) {
                Text(rowDate(w.startTs))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(WH.Color.textPrimary)
                Text(rowTime(w.startTs))
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(WH.Color.textSecondary)
            }
            .frame(width: 72, alignment: .leading)

            // Duration
            Text(formatDuration(w.durationS))
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(WH.Color.textSecondary)
                .frame(width: 44, alignment: .leading)

            Spacer()

            // Avg HR
            VStack(alignment: .trailing, spacing: 1) {
                Text(String(format: "%.0f", w.avgHr))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(WH.Color.textPrimary)
                    .monospacedDigit()
                Text("bpm")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(WH.Color.textSecondary)
            }
            .frame(width: 44, alignment: .trailing)

            // Strain badge
            strainBadge(w.strain)

            // Calories
            VStack(alignment: .trailing, spacing: 1) {
                Text(w.caloriesKcal.map { String(format: "%.0f", $0) } ?? "—")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(w.caloriesKcal != nil ? WH.Color.recoveryYellow : WH.Color.textSecondary)
                    .monospacedDigit()
                Text(w.caloriesKcal != nil ? "kcal" : "")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(WH.Color.textSecondary)
            }
            .frame(width: 40, alignment: .trailing)

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(WH.Color.textSecondary.opacity(0.5))
        }
        .padding(.horizontal, WH.Spacing.md)
        .padding(.vertical, WH.Spacing.sm)
    }

    private func strainBadge(_ strain: Double?) -> some View {
        Group {
            if let s = strain {
                Text(String(format: "%.1f", s))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(WH.Color.strainBlue)
                    .monospacedDigit()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(WH.Color.strainBlue.opacity(0.15),
                                in: RoundedRectangle(cornerRadius: WH.Radius.small, style: .continuous))
            } else {
                Text("—")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(WH.Color.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(WH.Color.surface2,
                                in: RoundedRectangle(cornerRadius: WH.Radius.small, style: .continuous))
            }
        }
        .frame(width: 52, alignment: .center)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: WH.Spacing.sm) {
            Image(systemName: "figure.run.circle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(WH.Color.textSecondary)
            Text("No workouts detected yet")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(WH.Color.textPrimary)
            Text("Workouts are found on your phone from your stored heart rate: at least 10 minutes above 40 % of your heart-rate reserve. Add your age and weight under Body Profile for a sharper threshold and calorie estimates.")
                .font(WH.Font.caption)
                .foregroundStyle(WH.Color.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, WH.Spacing.xl)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, WH.Spacing.xxl)
    }

    // MARK: - Error banner

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: WH.Spacing.sm) {
            Image(systemName: "wifi.slash")
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

    // MARK: - Data loading

    private func reload() async {
        errorMessage = nil
        let (from, to) = dateRange()
        let result = await metrics.workouts(from: from, to: to)
        workouts = result
        if isLoading { isLoading = false }
    }

    private func dateRange() -> (from: String, to: String) {
        let cal = Calendar(identifier: .gregorian)
        let utc = TimeZone(identifier: "UTC")!
        let fmt = DateFormatter()
        fmt.calendar = cal
        fmt.timeZone = utc
        fmt.dateFormat = "yyyy-MM-dd"
        let today = Date()
        let from = cal.date(byAdding: .day, value: -30, to: today) ?? today
        return (fmt.string(from: from), fmt.string(from: today))
    }

    // MARK: - Formatting

    private func rowDate(_ ts: Int) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(ts))
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE M/d"
        return fmt.string(from: d)
    }

    private func rowTime(_ ts: Int) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(ts))
        let fmt = DateFormatter()
        fmt.dateStyle = .none
        fmt.timeStyle = .short
        return fmt.string(from: d)
    }

    private func formatDuration(_ seconds: Int) -> String {
        let totalMin = seconds / 60
        let h = totalMin / 60
        let m = totalMin % 60
        if h > 0 && m > 0 { return "\(h)h \(m)m" }
        if h > 0           { return "\(h)h" }
        return "\(m)m"
    }
}

// MARK: - Preview

#Preview("Workouts — empty") {
    WorkoutsView()
        .environmentObject(MetricsRepository(deviceId: "preview"))
}
