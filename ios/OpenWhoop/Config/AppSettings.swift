import Foundation

// MARK: - AppSettings
//
// User-facing capture settings that the BLE layer reads directly. Kept as plain UserDefaults so
// both the SwiftUI toggle and BLEManager (which is not a view) see the same value with no plumbing.

enum AppSettings {

    private static let highDensityKey = "com.openwhoop.capture.highDensityHR"

    /// Whether the strap's ~1 Hz REALTIME_DATA stream is switched on while connected.
    ///
    /// ON by default, and it is the single biggest lever on data quality here. The strap's own
    /// history records carry a heart rate for every record but an R-R count only occasionally,
    /// which is why the R-R stream stayed thin (a few hundred beats a week) while heart rate piled
    /// up — and HRV, the stress index and sleep staging all read R-R intervals, not heart rate.
    /// The realtime stream delivers both once per second for as long as the phone is connected.
    ///
    /// Costs: a few bytes per second of BLE airtime, so some strap battery. Turn it off to get the
    /// old behaviour back.
    static var highDensityHR: Bool {
        get {
            // registerDefault-free: absent means "never set", which must read as ON.
            UserDefaults.standard.object(forKey: highDensityKey) as? Bool ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: highDensityKey) }
    }

    // MARK: - Strap clock quality (last measured GET_CLOCK/GET_DATA_RANGE offset)
    //
    // BLEManager measures this live during a connect but keeps it only in memory (on the
    // Backfiller), so the Settings screen had nothing to show once the strap disconnected again.
    // Persisting the last measurement here lets "Was wird getrackt?" answer "is the strap's clock
    // being corrected right now, and by how much" even hours after the connection that measured it.

    private static let clockOffsetKey = "com.openwhoop.strapClock.offsetSeconds"
    private static let clockSourceKey = "com.openwhoop.strapClock.source"
    private static let clockMeasuredAtKey = "com.openwhoop.strapClock.measuredAt"

    /// Last measured (strap RTC − phone wall clock) in seconds; nil before any connect has
    /// measured a drift at or above `Backfiller.clockRepairThreshold`.
    static var strapClockOffsetSeconds: Int? {
        UserDefaults.standard.object(forKey: clockOffsetKey) as? Int
    }

    /// "GET_CLOCK" (authoritative) or "GET_DATA_RANGE" (fallback proxy) — whichever produced the
    /// stored offset above.
    static var strapClockSource: String? {
        UserDefaults.standard.string(forKey: clockSourceKey)
    }

    /// When the stored offset was measured (wall clock at that connect).
    static var strapClockMeasuredAt: Date? {
        let ts = UserDefaults.standard.double(forKey: clockMeasuredAtKey)
        return ts > 0 ? Date(timeIntervalSince1970: ts) : nil
    }

    static func recordStrapClock(offsetSeconds: Int, source: String) {
        let d = UserDefaults.standard
        d.set(offsetSeconds, forKey: clockOffsetKey)
        d.set(source, forKey: clockSourceKey)
        d.set(Date().timeIntervalSince1970, forKey: clockMeasuredAtKey)
    }
}
