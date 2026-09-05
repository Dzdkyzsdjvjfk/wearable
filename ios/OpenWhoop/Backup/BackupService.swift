import Foundation
import WhoopProtocol
import WhoopStore

// MARK: - BackupService
//
// Export and restore of everything the app has collected, as one JSON file.
//
// WHY THIS EXISTS: this app is sideloaded with a free developer certificate, which expires after
// seven days and has to be reinstalled. The database lives inside the app's sandbox, so any
// reinstall that iOS treats as a fresh install — a changed signing identity, a delete-and-install
// — takes the whole history with it. That is not a hypothetical: it has already cost a night of
// data. The strap cannot help either, because its own buffer is trimmed as soon as the phone
// acknowledges a chunk, so once data has been offloaded it exists only on the phone.
//
// A backup file the user keeps OUTSIDE the app (Files, iCloud Drive, anywhere the share sheet
// reaches) is the only thing that survives that, so exporting is the one manual step that makes
// the data durable. Restore is additive and idempotent: every table upserts by its natural key,
// so importing the same file twice changes nothing, and importing an older backup into a newer
// database only fills gaps — it never deletes what is already there.

enum BackupService {

    /// Bump when the on-disk shape changes incompatibly. Restore refuses newer versions rather
    /// than silently importing something it does not understand.
    static let currentVersion = 1

    struct Payload: Codable {
        var version: Int
        var deviceId: String
        var exportedAt: Int
        var fromTs: Int
        var toTs: Int
        var streams: Streams
        var dailyMetrics: [DailyMetric]
        var sleepSessions: [CachedSleepSession]
    }

    struct Counts: Equatable {
        var hr = 0, rr = 0, events = 0, battery = 0
        var spo2 = 0, skinTemp = 0, resp = 0, gravity = 0
        var dailyMetrics = 0, sleepSessions = 0

        var totalRows: Int {
            hr + rr + events + battery + spo2 + skinTemp + resp + gravity
        }
    }

    enum Failure: LocalizedError {
        case unreadable
        case newerVersion(Int)

        var errorDescription: String? {
            switch self {
            case .unreadable:
                return "Die Datei ist kein gültiges OpenWhoop-Backup."
            case .newerVersion(let v):
                return "Dieses Backup stammt aus einer neueren App-Version (Format \(v))."
            }
        }
    }

    // MARK: - Export

    /// Writes every stored row of the last `daysBack` days to a JSON file in the app's temporary
    /// directory and returns its URL, ready to hand to a share sheet.
    ///
    /// The file name carries the date so several backups sort sensibly side by side in Files.
    static func export(store: WhoopStore, deviceId: String, daysBack: Int = 400) async throws -> URL {
        let now = Int(Date().timeIntervalSince1970)
        let from = now - daysBack * 86_400
        let bigLimit = 2_000_000

        async let hr = store.hrSamples(deviceId: deviceId, from: from, to: now, limit: bigLimit)
        async let rr = store.rrIntervals(deviceId: deviceId, from: from, to: now, limit: bigLimit)
        async let events = store.events(deviceId: deviceId, from: from, to: now, limit: bigLimit)
        async let battery = store.batterySamples(deviceId: deviceId, from: from, to: now, limit: bigLimit)
        async let spo2 = store.spo2Samples(deviceId: deviceId, from: from, to: now, limit: bigLimit)
        async let skin = store.skinTempSamples(deviceId: deviceId, from: from, to: now, limit: bigLimit)
        async let resp = store.respSamples(deviceId: deviceId, from: from, to: now, limit: bigLimit)
        async let grav = store.gravitySamples(deviceId: deviceId, from: from, to: now, limit: bigLimit)

        let streams = Streams(hr: try await hr, rr: try await rr,
                              spo2: try await spo2, skinTemp: try await skin,
                              resp: try await resp, gravity: try await grav,
                              events: try await events, battery: try await battery)

        let fromDay = LocalMetricsEngine.dayString(forEpoch: from)
        let toDay = LocalMetricsEngine.dayString(forEpoch: now)
        let dailies = (try? await store.dailyMetrics(deviceId: deviceId, from: fromDay, to: toDay)) ?? []
        let sessions = (try? await store.sleepSessions(deviceId: deviceId, from: from,
                                                       to: now + 86_400, limit: 1000)) ?? []

        let bundle = Payload(version: currentVersion, deviceId: deviceId, exportedAt: now,
                            fromTs: from, toTs: now, streams: streams,
                            dailyMetrics: dailies, sleepSessions: sessions)

        let encoder = JSONEncoder()
        let data = try encoder.encode(bundle)

        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd-HHmm"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenWhoop-Backup-\(fmt.string(from: Date())).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Row counts a bundle would contribute, for the confirmation line shown after an export.
    static func counts(of bundle: Payload) -> Counts {
        var c = Counts()
        c.hr = bundle.streams.hr.count
        c.rr = bundle.streams.rr.count
        c.events = bundle.streams.events.count
        c.battery = bundle.streams.battery.count
        c.spo2 = bundle.streams.spo2.count
        c.skinTemp = bundle.streams.skinTemp.count
        c.resp = bundle.streams.resp.count
        c.gravity = bundle.streams.gravity.count
        c.dailyMetrics = bundle.dailyMetrics.count
        c.sleepSessions = bundle.sleepSessions.count
        return c
    }

    // MARK: - Restore

    /// Decodes a backup file and merges it into the store. Returns the rows ACTUALLY added
    /// (existing rows are left untouched by the natural-key upserts), so the UI can say
    /// "12 340 Messwerte ergänzt" rather than a meaningless "done".
    ///
    /// Restored stream rows keep `synced = 0`, so if a server is ever configured they upload like
    /// any locally-collected row.
    static func restore(from url: URL, store: WhoopStore, deviceId: String) async throws -> Counts {
        // A file picked from Files/iCloud is outside the sandbox until access is claimed.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url),
              let bundle = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw Failure.unreadable
        }
        guard bundle.version <= currentVersion else { throw Failure.newerVersion(bundle.version) }

        // The backup's own deviceId is ignored on purpose: rows are merged into THIS install's
        // device id, so a restore still lands where the app reads even if the id ever changes.
        let inserted = try await store.insert(bundle.streams, deviceId: deviceId)

        var c = Counts()
        c.hr = inserted.hr; c.rr = inserted.rr; c.events = inserted.events
        c.battery = inserted.battery; c.spo2 = inserted.spo2; c.skinTemp = inserted.skinTemp
        c.resp = inserted.resp; c.gravity = inserted.gravity
        c.sleepSessions = (try? await store.upsertSleepSessions(bundle.sleepSessions,
                                                                deviceId: deviceId)) ?? 0
        c.dailyMetrics = (try? await store.upsertDailyMetrics(bundle.dailyMetrics,
                                                              deviceId: deviceId)) ?? 0
        return c
    }
}
