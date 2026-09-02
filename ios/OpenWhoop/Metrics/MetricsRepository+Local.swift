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

/// Snapshot of what the app can currently track.
struct TrackingDiagnostics {
    var serverConfigured: Bool = false
    var totalStoredRows: Int = 0
    var latestSample: Date?
    var nightsComputed: Int = 0
    var rawStreams: [TrackingDiagnosticItem] = []
    var metrics: [TrackingDiagnosticItem] = []
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

        let nights = LocalMetricsEngine.computeNights(hr: hr, rr: rr)
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

        out.rawStreams = [
            item("hr", "Herzfrequenz", hr, 500),
            item("rr", "R-R-Intervalle", rr, 500, note: "Basis für HRV & Stress"),
            item("spo2", "SpO2 (Rohwerte)", spo2, 100, note: "nur Roh-ADC, nicht umrechenbar"),
            item("temp", "Hauttemperatur (Rohwerte)", temp, 100, note: "nur Roh-ADC, nicht umrechenbar"),
            item("resp", "Atmung (Rohwerte)", resp, 100, note: "nur Roh-ADC, nicht umrechenbar"),
        ]

        // --- Derived metrics: what could actually be computed from those streams? ---
        let hrAll = (try? await store.hrSamples(deviceId: deviceId, from: now - 14 * 86_400,
                                                to: now, limit: 250_000)) ?? []
        let rrAll = (try? await store.rrIntervals(deviceId: deviceId, from: now - 14 * 86_400,
                                                  to: now, limit: 400_000)) ?? []
        let nights = LocalMetricsEngine.computeNights(hr: hrAll, rr: rrAll)
        out.nightsComputed = nights.count
        let latest = nights.last?.daily

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
            TrackingDiagnosticItem(id: "stages", name: "Schlafphasen (Tief/REM)", status: .missing,
                           detail: "Nicht berechenbar — das Band sendet die nötigen Signale nicht"),
            TrackingDiagnosticItem(id: "spo2pct", name: "SpO2 in Prozent", status: .missing,
                           detail: "Nicht berechenbar — Umrechnung passiert in WHOOPs Cloud"),
        ]

        return out
    }

}
