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
}
