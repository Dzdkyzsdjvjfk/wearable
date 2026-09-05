import Foundation
import WhoopProtocol

// MARK: - WorkoutDetector
//
// Finds workout bouts in the stored heart-rate stream, on the phone.
//
// WHY THIS EXISTS: the Workouts tab was written against the server's /v1/workouts endpoint. With
// no server configured — the default for a personal build — it asked nobody and showed an empty
// list forever, even though every beat needed to spot a workout was already sitting in the local
// database. This detector closes that gap the same way LocalMetricsEngine closed it for sleep and
// recovery, and it produces the exact `Workout` shape the existing views already render, so no
// view code has to change.
//
// HOW A BOUT IS FOUND: heart rate is binned to one-minute medians and measured as heart-rate
// RESERVE — (hr - resting) / (max - resting) — rather than raw bpm, so the threshold adapts to
// the person instead of assuming a population value. A run of minutes above the entry threshold
// that lasts long enough is a bout; short dips (a traffic light, a set break) are bridged rather
// than splitting one session into five.
//
// HONESTY (this project's standing rule — see LocalMetricsEngine.swift): these bouts are OUR
// detection from heart rate alone. The strap's own accelerometer stream is not part of it, so a
// genuinely hard but low-heart-rate session (heavy lifting with long rests) can be missed, and a
// long stressful drive can in principle look like light cardio. `kind` is deliberately never
// guessed — heart rate alone cannot tell running from cycling. Calories are an estimate from a
// published HR/weight formula, not a measurement.

enum WorkoutDetector {

    // MARK: - Configuration

    struct Config {
        /// Bin width for the detector. One minute keeps short intervals visible while removing
        /// single-sample spikes.
        var binSeconds: Int = 60
        /// Heart-rate reserve at which a minute counts as "working out". 0.40 is the usual lower
        /// edge of moderate intensity, and sits clearly above ordinary daily activity.
        var entryHRR: Double = 0.40
        /// Once inside a bout, minutes above this lower reserve keep it alive. The hysteresis gap
        /// is what stops a session flickering apart around the entry threshold.
        var exitHRR: Double = 0.30
        /// Shortest bout reported. Below this it is a flight of stairs, not a workout.
        var minMinutes: Int = 10
        /// How many consecutive sub-threshold minutes are bridged inside one bout (rest between
        /// sets, a red light).
        var maxGapMinutes: Int = 3
        /// Fallback max heart rate when the profile has no age. 220 - age is used when it does.
        var fallbackMaxHR: Int = 190
        /// Fallback resting heart rate when no night has been measured yet.
        var fallbackRestingHR: Int = 60

        static let standard = Config()
    }

    // MARK: - Entry point

    /// Detects workout bouts in `hr`.
    ///
    /// - Parameters:
    ///   - hr: heart-rate samples, any order.
    ///   - deviceId: used to build the stable `Workout.id` the views key on.
    ///   - restingHr: the person's measured resting HR; falls back to `config.fallbackRestingHR`.
    ///   - age: used for max HR (220 - age); falls back to `config.fallbackMaxHR`.
    ///   - weightKg: enables the calorie estimate; without it calories stay nil rather than guessed.
    /// - Returns: bouts oldest first.
    static func detect(hr: [HRSample],
                       deviceId: String,
                       restingHr: Int?,
                       age: Int?,
                       weightKg: Double?,
                       sex: String? = nil,
                       config: Config = .standard) -> [Workout] {
        let bins = LocalMetricsEngine.medianBins(hr: hr, binSeconds: config.binSeconds)
        guard bins.count >= config.minMinutes else { return [] }

        let rest = Double(restingHr ?? config.fallbackRestingHR)
        let maxHR = Double(age.map { max(120, 220 - $0) } ?? config.fallbackMaxHR)
        guard maxHR > rest + 20 else { return [] }

        func reserve(_ bpm: Double) -> Double { (bpm - rest) / (maxHR - rest) }

        // --- Pass 1: mark the bins that belong to a bout ------------------------------------
        var runs: [[Int]] = []          // each run = indices into `bins`
        var current: [Int] = []
        var pendingGap: [Int] = []      // sub-threshold bins held while we see if the bout resumes

        func closeRun() {
            if !current.isEmpty { runs.append(current) }
            current = []
            pendingGap = []
        }

        for (i, bin) in bins.enumerated() {
            // A hole in the DATA (strap off, not synced) always ends a bout: we must not bridge
            // across missing time and report a three-hour "workout" made of two short ones.
            if let last = current.last ?? pendingGap.last,
               bin.ts - bins[last].ts > config.binSeconds * (config.maxGapMinutes + 1) {
                closeRun()
            }

            let r = reserve(bin.bpm)
            if r >= config.entryHRR || (!current.isEmpty && r >= config.exitHRR) {
                // Resuming after a short dip: the bridged minutes belong to the bout.
                current.append(contentsOf: pendingGap)
                pendingGap = []
                current.append(i)
            } else if !current.isEmpty {
                pendingGap.append(i)
                if pendingGap.count > config.maxGapMinutes { closeRun() }
            }
        }
        closeRun()

        // --- Pass 2: turn qualifying runs into Workouts -------------------------------------
        var out: [Workout] = []
        for run in runs {
            guard run.count >= config.minMinutes, let first = run.first, let last = run.last else { continue }
            let startTs = bins[first].ts
            let endTs = bins[last].ts + config.binSeconds
            let durationS = endTs - startTs
            guard durationS > 0 else { continue }

            // Real samples inside the window carry the true peak; the bins are medians and would
            // flatten it away.
            let samples = hr.filter { $0.ts >= startTs && $0.ts <= endTs && $0.bpm > 25 && $0.bpm < 220 }
            guard !samples.isEmpty else { continue }
            let avgHr = Double(samples.reduce(0) { $0 + $1.bpm }) / Double(samples.count)
            let peakHr = samples.map(\.bpm).max() ?? Int(avgHr.rounded())

            let strain = LocalMetricsEngine.strain(hr: samples, from: startTs, to: endTs,
                                                   restingHr: restingHr ?? config.fallbackRestingHR,
                                                   maxHeartRate: Int(maxHR))

            let kcal = calories(avgHr: avgHr, minutes: Double(durationS) / 60.0,
                                age: age, weightKg: weightKg, sex: sex)

            out.append(Workout(
                id: "\(deviceId)|\(startTs)",
                deviceId: deviceId,
                startTs: startTs,
                endTs: endTs,
                avgHr: avgHr,
                peakHr: peakHr,
                strain: strain,
                kind: nil,                    // never guessed — heart rate can't tell sports apart
                durationS: durationS,
                zoneTimePct: zoneDistribution(bins: run.map { bins[$0] }, maxHR: maxHR),
                avgHrrPct: reserve(avgHr) * 100,
                hrmax: maxHR,
                hrmaxSource: age != nil ? "profile_age" : "default",
                caloriesKcal: kcal,
                caloriesKj: kcal.map { $0 * 4.184 }))
        }
        return out
    }

    // MARK: - Heart-rate zones

    /// Share of the bout spent in each zone, as percentages keyed 0...5 — the shape
    /// WorkoutDetailView renders. Zones are the standard %HRmax bands: Z1 50–60, Z2 60–70,
    /// Z3 70–80, Z4 80–90, Z5 90+; anything under 50% is Z0 (rest).
    static func zoneDistribution(bins: [(ts: Int, bpm: Double)], maxHR: Double) -> [Int: Double] {
        guard !bins.isEmpty, maxHR > 0 else { return [:] }
        var counts: [Int: Int] = [:]
        for b in bins {
            let pct = b.bpm / maxHR
            let zone: Int
            switch pct {
            case ..<0.50:    zone = 0
            case 0.50..<0.60: zone = 1
            case 0.60..<0.70: zone = 2
            case 0.70..<0.80: zone = 3
            case 0.80..<0.90: zone = 4
            default:          zone = 5
            }
            counts[zone, default: 0] += 1
        }
        let total = Double(bins.count)
        return counts.mapValues { Double($0) / total * 100.0 }
    }

    // MARK: - Calories (estimate)

    /// Keytel et al. (2005) heart-rate energy-expenditure regression, the formula most fitness
    /// apps use when they have heart rate, weight and age but no metabolic cart.
    ///
    /// THIS IS AN ESTIMATE. It assumes steady aerobic work and gets less accurate at very low or
    /// very high intensity. Without a weight in the profile it returns nil rather than inventing
    /// a number from an assumed body mass.
    static func calories(avgHr: Double, minutes: Double, age: Int?, weightKg: Double?,
                         sex: String?) -> Double? {
        guard let weightKg, weightKg > 20, minutes > 0 else { return nil }
        let a = Double(age ?? 30)
        let female = (sex ?? "").lowercased().hasPrefix("f")
        let perMinute: Double = female
            ? (-20.4022 + 0.4472 * avgHr - 0.1263 * weightKg + 0.074 * a) / 4.184
            : (-55.0969 + 0.6309 * avgHr + 0.1988 * weightKg + 0.2017 * a) / 4.184
        let total = perMinute * minutes
        return total > 0 ? total : nil
    }
}
