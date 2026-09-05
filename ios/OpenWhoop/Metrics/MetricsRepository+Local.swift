import Foundation
import WhoopStore

// MARK: - MetricsRepository + on-device computation & diagnostics
//
// Split out of MetricsRepository.swift so the read facade there stays about reading the cache.
// Everything here is about FILLING that cache without a server, and about reporting honestly
// what could and could not be filled.
//
// Background: the original design computed every metric server-side and the phone only cached
// the result. With no server configured -- the default for a personal build -- dailyMetric and
// sleepSession stayed empty forever, so every tab showed nothing even though the strap's history
// had been offloaded and stored locally. LocalMetricsEngine closes that gap; this file wires it
// in and exposes the diagnostics the Settings screen shows.

// MARK: - Tracking diagnostics model
//
// Deliberately at file scope rather than nested inside MetricsRepository: nested types in a
// @MainActor class inherit that isolation, which makes an Identifiable conformance awkward to
// use from a plain SwiftUI ForEach.

/// One checked capability on the diagnostics screen.
struct TrackingDiagnosticItem: Identifiable {
    enum Status { case ok, partial, missing }
    let id: String
    let name: String
    let status: Status
    let detail: String
}

/// How much of one day actually carries data. This is the number that decides whether a night or
/// a workout can be found at all, so it is worth showing plainly instead of leaving the user to
/// infer it from a metric that silently stayed empty.
struct DayCoverage: Identifiable {
    let dayStart: Int
    let minutes: Int
    var id: Int { dayStart }
    /// 0...1 of a 24 h day.
    var fraction: Double { min(1.0, Double(minutes) / (24 * 60)) }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(dayStart)) }
}

/// Snapshot of what the app can currently track.
struct TrackingDiagnostics {
    var serverConfigured: Bool = false
    var totalStoredRows: Int = 0
    var latestSample: Date?
    var nightsComputed: Int = 0
    var workoutsDetected: Int = 0
    var rawStreams: [TrackingDiagnosticItem] = []
    var metrics: [TrackingDiagnosticItem] = []
    /// Last 7 days, oldest first — days with no data at all are included as zero.
    var coverage: [DayCoverage] = []
}

extension MetricsRepository {

    // MARK: - On-device metric computation

    /// Derives sleep sessions and daily metrics from the raw streams already on disk and writes
    /// them into the same cache tables the views read. This is what makes the app work without a
    /// server; see LocalMetricsEngine.swift for the methods and their honest limitations.
    ///
    /// Server precedence: when a server IS configured we only fill days it has not supplied, so
    /// real server numbers are never overwritten by local estimates. With no server we always
    /// rewrite our own rows, so improvements to the engine take effect on the next refresh.
    /// Best-effort throughout — a failure here must never break a refresh.
    func computeLocalMetrics(daysBack: Int = 14) async {
        guard let store else { return }

        let now = Int(Date().timeIntervalSince1970)
        let from = now - daysBack * 86_400

        let hr = (try? await store.hrSamples(deviceId: deviceId, from: from, to: now,
                                             limit: 250_000)) ?? []
        guard hr.count >= 100 else { return }   // not enough to say anything meaningful
        let rr = (try? await store.rrIntervals(deviceId: deviceId, from: from, to: now,
                                               limit: 400_000)) ?? []
        // Wrist motion, when the strap's history records carry it: the sleep stager needs it to
        // tell REM (still, but heart rate up) from being awake (moving, heart rate up).
        let motion = (try? await store.gravitySamples(deviceId: deviceId, from: from, to: now,
                                                      limit: 400_000)) ?? []

        let nights = LocalMetricsEngine.computeNights(hr: hr, rr: rr, motion: motion)
        guard !nights.isEmpty else { return }

        let fromDay = LocalMetricsEngine.dayString(forEpoch: from)
        let toDay = LocalMetricsEngine.dayString(forEpoch: now)
        let existingDays = Set(((try? await store.dailyMetrics(deviceId: deviceId,
                                                               from: fromDay,
                                                               to: toDay)) ?? []).map { $0.day })
        let hasServer = serverSync != nil

        var dailies: [DailyMetric] = []
        var sessions: [CachedSleepSession] = []
        for night in nights {
            if hasServer && existingDays.contains(night.daily.day) { continue }
            dailies.append(night.daily)
            sessions.append(night.session)
        }
        guard !dailies.isEmpty else { return }

        _ = try? await store.upsertSleepSessions(sessions, deviceId: deviceId)
        _ = try? await store.upsertDailyMetrics(dailies, deviceId: deviceId)
    }

    // MARK: - Stress history (Today → Stress tile → StressDetailView)

    /// Stress index over time, computed on demand from the stored R-R intervals.
    ///
    /// Nothing is cached: the whole series for a day is a few hundred bins over a few tens of
    /// thousands of beats, which is fast enough to recompute on every open, and recomputing means
    /// the chart automatically includes beats that arrived from a backfill seconds ago and never
    /// goes stale against the raw data.
    func stressSeries(fromEpoch: Int, toEpoch: Int,
                      binSeconds: Int = StressHistory.defaultBinSeconds) async -> [StressPoint] {
        await ensureOpen()
        guard let store else { return [] }
        let rr = (try? await store.rrIntervals(deviceId: deviceId, from: fromEpoch, to: toEpoch,
                                               limit: 500_000)) ?? []
        return StressHistory.series(rr: rr, binSeconds: binSeconds)
    }

    // MARK: - Stored heart-rate series (seeds the Today chart)

    /// Recent heart-rate samples from the LOCAL database as chart points, newest last.
    ///
    /// The Today chart used to plot only readings that arrived since the app connected, so it sat
    /// empty for the first minutes of every connection — and showed nothing at all for a strap
    /// that had just been synced. Seeding it from stored rows means the chart is populated the
    /// moment the screen opens, and the live stream simply extends it.
    func recentHRPoints(minutes: Int = 60) async -> [TrendPoint] {
        await ensureOpen()
        guard let store else { return [] }
        let now = Int(Date().timeIntervalSince1970)
        let rows = (try? await store.hrSamples(deviceId: deviceId, from: now - minutes * 60,
                                               to: now, limit: 20_000)) ?? []
        return rows.map {
            TrendPoint(id: "s\($0.ts)",
                       date: Date(timeIntervalSince1970: TimeInterval($0.ts)),
                       value: Double($0.bpm))
        }
    }

    // MARK: - Local workout detection (Workouts tab without a server)

    /// Detects workout bouts on-device from the stored heart-rate stream.
    ///
    /// Resting HR comes from the most recent computed night so the intensity threshold is scaled
    /// to the person rather than to a population average; age and weight come from the local Body
    /// Profile, which also unlocks the calorie estimate.
    func localWorkouts(fromEpoch: Int, toEpoch: Int) async -> [Workout] {
        await ensureOpen()
        guard let store else { return [] }
        let hr = (try? await store.hrSamples(deviceId: deviceId, from: fromEpoch, to: toEpoch,
                                             limit: 250_000)) ?? []
        guard hr.count >= 30 else { return [] }

        // Resting HR: prefer a recently measured night, else let the detector use its fallback.
        let recentNight = (try? await store.sleepSessions(deviceId: deviceId,
                                                          from: toEpoch - 14 * 86_400,
                                                          to: toEpoch + 86_400,
                                                          limit: 30))?.last
        let profile = ProfileStorage.load()

        return WorkoutDetector.detect(hr: hr,
                                      deviceId: deviceId,
                                      restingHr: recentNight?.restingHr ?? today?.restingHr,
                                      age: profile?.age,
                                      weightKg: profile?.weightKg,
                                      sex: profile?.sex)
    }

    // MARK: - Backup (Settings → Daten sichern)

    /// Writes a full backup file and returns its URL for the share sheet. See BackupService.
    func exportBackup() async throws -> URL {
        await ensureOpen()
        guard let store else { throw BackupService.Failure.unreadable }
        return try await BackupService.export(store: store, deviceId: deviceId)
    }

    /// Merges a backup file into the local database and refreshes the derived metrics from it,
    /// so restored nights show up immediately instead of after the next sync.
    @discardableResult
    func restoreBackup(from url: URL) async throws -> BackupService.Counts {
        await ensureOpen()
        guard let store else { throw BackupService.Failure.unreadable }
        let counts = try await BackupService.restore(from: url, store: store, deviceId: deviceId)
        await computeLocalMetrics()
        await load()
        return counts
    }

    // MARK: - Tracking diagnostics (Settings → "Was wird getrackt?")

    /// Builds a full picture of what is actually being tracked: which raw streams are arriving
    /// from the strap, and which derived metrics could be computed from them. Read-only.
    /// Live connection state deliberately isn't part of this — the Device tab owns that.
    func diagnostics() async -> TrackingDiagnostics {
        await ensureOpen()
        var out = TrackingDiagnostics()
        out.serverConfigured = serverSync != nil
        guard let store else { return out }

        let now = Int(Date().timeIntervalSince1970)
        let weekAgo = now - 7 * 86_400

        if let stats = try? await store.storageStats() { out.totalStoredRows = stats.decodedRows }
        // try? on a throwing call that itself returns Int? yields Int?? — flatten with ?? nil.
        if let ts = (try? await store.latestHRSampleTs(deviceId: deviceId)) ?? nil {
            out.latestSample = Date(timeIntervalSince1970: TimeInterval(ts))
        }

        // --- Raw streams: is the strap actually delivering this signal? ---
        func item(_ id: String, _ name: String, _ count: Int, _ needed: Int,
                  note: String = "") -> TrackingDiagnosticItem {
            let status: TrackingDiagnosticItem.Status = count == 0 ? .missing : (count < needed ? .partial : .ok)
            var detail: String
            switch status {
            case .missing: detail = "Keine Daten der letzten 7 Tage"
            case .partial: detail = "Nur wenige Messwerte (\(count))"
            case .ok:      detail = "\(count)+ Messwerte"
            }
            if !note.isEmpty { detail += " · \(note)" }
            return TrackingDiagnosticItem(id: id, name: name, status: status, detail: detail)
        }

        let probe = 5_000
        let hr = (try? await store.hrSamples(deviceId: deviceId, from: weekAgo, to: now, limit: probe))?.count ?? 0
        let rr = (try? await store.rrIntervals(deviceId: deviceId, from: weekAgo, to: now, limit: probe))?.count ?? 0
        let spo2 = (try? await store.spo2Samples(deviceId: deviceId, from: weekAgo, to: now, limit: probe))?.count ?? 0
        let temp = (try? await store.skinTempSamples(deviceId: deviceId, from: weekAgo, to: now, limit: probe))?.count ?? 0
        let resp = (try? await store.respSamples(deviceId: deviceId, from: weekAgo, to: now, limit: probe))?.count ?? 0
        let motion = (try? await store.gravitySamples(deviceId: deviceId, from: weekAgo, to: now, limit: probe))?.count ?? 0

        out.rawStreams = [
            item("hr", "Herzfrequenz", hr, 500),
            item("rr", "R-R-Intervalle", rr, 500, note: "Basis für HRV & Stress"),
            item("spo2", "SpO2 (Rohwerte)", spo2, 100, note: "nur Roh-ADC, nicht umrechenbar"),
            item("temp", "Hauttemperatur (Rohwerte)", temp, 100, note: "nur Roh-ADC, nicht umrechenbar"),
            item("resp", "Atmung (Rohwerte)", resp, 100, note: "nur Roh-ADC, nicht umrechenbar"),
            item("motion", "Bewegung (Beschleunigung)", motion, 500,
                 note: "Basis für Schlafphasen"),
        ]

        // --- Derived metrics: what could actually be computed from those streams? ---
        let hrAll = (try? await store.hrSamples(deviceId: deviceId, from: now - 14 * 86_400,
                                                to: now, limit: 250_000)) ?? []
        let rrAll = (try? await store.rrIntervals(deviceId: deviceId, from: now - 14 * 86_400,
                                                  to: now, limit: 400_000)) ?? []
        let motionAll = (try? await store.gravitySamples(deviceId: deviceId, from: now - 14 * 86_400,
                                                         to: now, limit: 400_000)) ?? []
        let nights = LocalMetricsEngine.computeNights(hr: hrAll, rr: rrAll, motion: motionAll)
        out.nightsComputed = nights.count
        let latest = nights.last?.daily

        // Coverage: how many minutes of each of the last 7 days carry a heart-rate sample. Zero-
        // filled so a day the strap wasn't worn is visible as an empty bar rather than missing.
        let measured = (try? await store.hrCoverageByDay(deviceId: deviceId,
                                                         from: weekAgo, to: now)) ?? []
        let byDay = Dictionary(measured.map { ($0.dayStart, $0.minutes) },
                               uniquingKeysWith: { a, _ in a })
        let todayStart = (now / 86_400) * 86_400
        out.coverage = (0..<7).reversed().map { back in
            let dayStart = todayStart - back * 86_400
            return DayCoverage(dayStart: dayStart, minutes: byDay[dayStart] ?? 0)
        }

        out.workoutsDetected = await localWorkouts(fromEpoch: weekAgo, toEpoch: now).count

        func metricItem(_ id: String, _ name: String, _ value: Double?, _ formatted: String,
                        missingHint: String) -> TrackingDiagnosticItem {
            if let value, value.isFinite {
                return TrackingDiagnosticItem(id: id, name: name, status: .ok, detail: formatted)
            }
            return TrackingDiagnosticItem(id: id, name: name, status: .missing, detail: missingHint)
        }

        let sleepMin = latest?.totalSleepMin
        let sleepText = sleepMin.map { "\(Int($0) / 60) h \(Int($0) % 60) min letzte Nacht" } ?? ""
        let rhr = latest?.restingHr
        let hrv = latest?.avgHrv
        let rec = latest?.recovery
        let strain = latest?.strain

        // Stress is no longer live-only: it is recomputed per 5-minute window from the stored
        // R-R intervals, so the diagnostics can report its real 24 h coverage like any other
        // derived metric.
        let stressPoints = StressHistory.series(rr: rrAll.filter { $0.ts >= now - 86_400 })
        let stressAvg = stressPoints.isEmpty ? 0
            : stressPoints.map(\.index).reduce(0, +) / Double(stressPoints.count)
        let stressItem = TrackingDiagnosticItem(
            id: "stress",
            name: "Stress-Verlauf (24 h)",
            status: stressPoints.isEmpty ? .missing : (stressPoints.count < 12 ? .partial : .ok),
            detail: stressPoints.isEmpty
                ? "Zu wenige R-R-Intervalle"
                : "\(stressPoints.count) Messfenster · Ø \(Int(stressAvg.rounded()))")

        // Sleep phases: estimated from heart rate + R-R + motion (see SleepStaging.swift). Says
        // plainly which inputs were available, because motion-less staging is the weaker mode.
        let staged = nights.last?.daily
        let stageItem: TrackingDiagnosticItem = {
            guard let deep = staged?.deepMin, let rem = staged?.remMin else {
                return TrackingDiagnosticItem(
                    id: "stages", name: "Schlafphasen (Tief/REM)", status: .missing,
                    detail: motionAll.isEmpty
                        ? "Keine Bewegungsdaten vom Band — Schätzung nicht möglich"
                        : "Zu wenige Messwerte in der Nacht")
            }
            return TrackingDiagnosticItem(
                id: "stages", name: "Schlafphasen (Schätzung)", status: .ok,
                detail: String(format: "Tief %.0f min · REM %.0f min", deep, rem))
        }()

        out.metrics = [
            metricItem("sleep", "Schlafdauer", sleepMin, sleepText,
                       missingHint: "Keine Nacht erkannt — mind. 2 h zusammenhängende Daten nötig"),
            metricItem("eff", "Schlaf-Effizienz", latest?.efficiency,
                       latest?.efficiency.map { "\(Int($0 * 100)) %" } ?? "",
                       missingHint: "Keine Nacht erkannt"),
            metricItem("rhr", "Ruhepuls", rhr.map(Double.init), rhr.map { "\($0) bpm" } ?? "",
                       missingHint: "Zu wenige Messwerte im Schlaffenster"),
            metricItem("hrv", "HRV (RMSSD)", hrv, hrv.map { String(format: "%.0f ms", $0) } ?? "",
                       missingHint: "Zu wenige R-R-Intervalle"),
            metricItem("recovery", "Recovery (Schätzung)", rec,
                       rec.map { "\(Int($0 * 100)) %" } ?? "",
                       missingHint: "Braucht mind. 3 Nächte als persönliche Basislinie"),
            metricItem("strain", "Strain (Schätzung)", strain,
                       strain.map { String(format: "%.1f / 21", $0) } ?? "",
                       missingHint: "Zu wenige Messwerte am Tag"),
            stressItem,
            stageItem,
            TrackingDiagnosticItem(id: "spo2pct", name: "SpO2 in Prozent", status: .missing,
                           detail: "Nicht berechenbar — Umrechnung passiert in WHOOPs Cloud"),
        ]

        return out
    }

}
