import Foundation
import WhoopProtocol
import WhoopStore

// MARK: - LocalMetricsEngine
//
// On-device computation of the daily metrics from the raw streams the strap offloads.
//
// WHY THIS EXISTS: the original design computed every metric server-side and the phone only
// cached the results (see MetricsCache.swift / ServerSync.pullDerived). With no server
// configured — the default for a personal build — the dailyMetric and sleepSession tables
// stayed empty forever, so the Today and Sleep tabs showed nothing even though the strap's
// history had been offloaded and stored locally. This engine closes that gap: it reads the
// raw hrSample / rrInterval rows already on disk and writes the same DailyMetric and
// CachedSleepSession shapes the UI already reads, so no view code has to change.
//
// HONESTY (this project's standing rule for metrics — see StressMonitor.swift):
// These are OUR OWN estimates from the strap's raw heart data. They are NOT WHOOP's numbers
// and have never been validated against them; WHOOP's recovery/strain/sleep algorithms are
// undisclosed. What each value really is:
//   - restingHr  — a robust low percentile of heart rate during the detected sleep window.
//                  Close to how any wearable derives RHR. The most trustworthy value here.
//   - avgHrv     — RMSSD over the sleep window, the standard short-term HRV measure.
//                  A real, well-defined quantity; WHOOP's own HRV number may differ in
//                  window and filtering.
//   - sleep      — start/end/duration/efficiency from a heart-rate-based detector. Reasonable
//                  for "when did I sleep and roughly how long", not a clinical measurement.
//   - deep/REM/light — NOT computed. Sleep staging needs signals the strap does not expose
//                  on the wire. Left nil on purpose rather than invented (see FINDINGS.md).
//   - recovery   — an HRV-vs-personal-baseline estimate, explicitly a heuristic (see below).
//   - strain     — a heart-rate-reserve exertion accumulation, explicitly a heuristic.
// SpO2, skin temperature and respiration rate stay nil: the strap only emits raw ADC counts
// for those, and the conversion to real units happens in WHOOP's cloud. Guessing them would
// produce a number that looks precise and means nothing.

enum LocalMetricsEngine {

    // MARK: - Configuration

    struct Config {
        /// Bin width for the sleep detector. 5 min smooths out isolated HR spikes without
        /// blurring sleep on/offset beyond usefulness.
        var binSeconds: Int = 300
        /// Shortest run of low-HR bins accepted as a night. Guards against long naps and
        /// against a quiet afternoon on the sofa being logged as sleep.
        var minSleepMinutes: Int = 120
        /// How much wake is bridged inside one night (3 bins = 15 min). Real nights contain
        /// brief awakenings; splitting on every one of them would fragment the session.
        var maxGapBins: Int = 3
        /// Sleep threshold = nightly low HR * (1 + this). 12% sits above resting drift while
        /// staying clearly below awake-and-moving heart rates.
        var sleepHRMarginFraction: Double = 0.12
        /// Estimated max heart rate, for the strain heuristic. Overridden from the profile age
        /// when one is set (220 - age).
        var maxHeartRate: Int = 190

        static let standard = Config()
    }

    // MARK: - Result

    /// One computed night plus the daily row derived from it.
    struct NightResult {
        let session: CachedSleepSession
        let daily: DailyMetric
    }

    // MARK: - Public entry point

    /// Computes sleep + daily metrics for every night found in `hr` / `rr`.
    ///
    /// - Parameters:
    ///   - hr: heart-rate samples, any order.
    ///   - rr: R-R intervals, any order.
    ///   - config: detector tunables.
    /// - Returns: one result per detected night, oldest first. Empty when nothing qualifies.
    ///
    /// Recovery needs a personal baseline, so it is filled in on a second pass once all nights
    /// are known: each night is scored against the nights that came before it.
    static func computeNights(hr: [HRSample],
                              rr: [RRInterval],
                              config: Config = .standard) -> [NightResult] {
        let sortedHR = hr.sorted { $0.ts < $1.ts }
        guard sortedHR.count >= 2 else { return [] }
        let sortedRR = rr.sorted { $0.ts < $1.ts }

        let windows = detectSleepWindows(hr: sortedHR, config: config)
        guard !windows.isEmpty else { return [] }

        // First pass: everything that needs no baseline.
        struct Draft {
            let window: SleepWindow
            let restingHr: Int?
            let avgHrv: Double?
            let strain: Double?
        }

        var drafts: [Draft] = []
        for w in windows {
            let rhr = restingHeartRate(hr: sortedHR, from: w.start, to: w.end)
            let hrv = rmssd(rr: sortedRR, from: w.start, to: w.end)
            // Strain covers the waking day that FOLLOWS this night, i.e. from wake-up until
            // the next sleep onset (or 24 h later, whichever comes first).
            let dayEnd = min(w.end + 86_400, sortedHR.last?.ts ?? w.end)
            let st = strain(hr: sortedHR, from: w.end, to: dayEnd,
                            restingHr: rhr, maxHeartRate: config.maxHeartRate)
            drafts.append(Draft(window: w, restingHr: rhr, avgHrv: hrv, strain: st))
        }

        // Second pass: recovery against the preceding nights' baseline.
        var results: [NightResult] = []
        for (i, d) in drafts.enumerated() {
            let priorHrv = drafts[..<i].compactMap { $0.avgHrv }
            let priorRhr = drafts[..<i].compactMap { $0.restingHr }
            let rec = recovery(hrv: d.avgHrv,
                               restingHr: d.restingHr,
                               baselineHrv: priorHrv,
                               baselineRhr: priorRhr)

            let w = d.window
            let session = CachedSleepSession(startTs: w.start,
                                             endTs: w.end,
                                             efficiency: w.efficiency,
                                             restingHr: d.restingHr,
                                             avgHrv: d.avgHrv,
                                             stagesJSON: nil)

            let daily = DailyMetric(day: dayString(forEpoch: w.end),
                                    totalSleepMin: w.asleepMinutes,
                                    efficiency: w.efficiency,
                                    deepMin: nil,      // not derivable on-device — see file header
                                    remMin: nil,
                                    lightMin: nil,
                                    disturbances: w.disturbances,
                                    restingHr: d.restingHr,
                                    avgHrv: d.avgHrv,
                                    recovery: rec,
                                    strain: d.strain,
                                    exerciseCount: nil,
                                    spo2Pct: nil,       // raw ADC only — see file header
                                    skinTempDevC: nil,
                                    respRateBpm: nil)

            results.append(NightResult(session: session, daily: daily))
        }
        return results
    }

    // MARK: - Sleep detection

    struct SleepWindow {
        let start: Int
        let end: Int
        /// Minutes actually classified as asleep inside [start, end].
        let asleepMinutes: Double
        /// asleepMinutes / time in bed, 0...1.
        let efficiency: Double
        /// Count of separate wake gaps bridged inside the night.
        let disturbances: Int
    }

    /// Finds sleep windows by looking for sustained runs of low heart rate.
    ///
    /// The strap samples heart rate continuously, and heart rate drops markedly and stays down
    /// during sleep. Binning to 5 min medians removes single-sample noise; the threshold is
    /// derived per-run from the person's own low HR rather than a fixed bpm, so it adapts to
    /// individual fitness instead of assuming a population value.
    static func detectSleepWindows(hr: [HRSample], config: Config = .standard) -> [SleepWindow] {
        let bins = medianBins(hr: hr, binSeconds: config.binSeconds)
        guard bins.count >= 4 else { return [] }

        // Personal reference: the 5th percentile across everything we have. Using a low
        // percentile rather than the minimum keeps one artefactual low reading from dragging
        // the threshold down and hiding a whole night.
        let allBpm = bins.map { $0.bpm }
        guard let low = percentile(allBpm, 0.05),
              let high = percentile(allBpm, 0.90) else { return [] }

        // Sleep is only detectable when there IS a day/night contrast in the data. Without this
        // guard a flat trace — strap on a desk, or a stretch of uniformly resting heart rate —
        // would sit entirely under its own low-percentile threshold and get reported as one
        // enormous night. Requiring the resting band to be at least 10% below the active band
        // means "no clear drop" honestly yields no sleep rather than a fabricated one.
        // The upper reference is the 90th percentile, not the median: on a normal night sleep
        // outnumbers wake, which drags the median down into the sleeping range.
        guard low < high * 0.90 else { return [] }

        let threshold = low * (1 + config.sleepHRMarginFraction)

        let minBins = max(1, (config.minSleepMinutes * 60) / config.binSeconds)

        var windows: [SleepWindow] = []
        var runStart: Int? = nil          // index into bins
        var lastAsleep: Int? = nil        // index of last asleep bin in the current run
        var gapBins = 0
        var asleepCount = 0
        var disturbances = 0

        func closeRun(endIndex: Int) {
            guard let s = runStart, asleepCount >= minBins else {
                runStart = nil; lastAsleep = nil; gapBins = 0; asleepCount = 0; disturbances = 0
                return
            }
            let startTs = bins[s].ts
            let endTs = bins[endIndex].ts + config.binSeconds
            let inBedMin = Double(endTs - startTs) / 60.0
            let asleepMin = Double(asleepCount * config.binSeconds) / 60.0
            let eff = inBedMin > 0 ? min(1.0, asleepMin / inBedMin) : 0
            windows.append(SleepWindow(start: startTs,
                                       end: endTs,
                                       asleepMinutes: asleepMin,
                                       efficiency: eff,
                                       disturbances: disturbances))
            runStart = nil; lastAsleep = nil; gapBins = 0; asleepCount = 0; disturbances = 0
        }

        for (i, bin) in bins.enumerated() {
            // A gap in the data itself (strap off / not worn) always ends a run: we must not
            // bridge across hours of missing samples and call it sleep.
            if let prev = lastAsleep, bin.ts - bins[prev].ts > config.binSeconds * (config.maxGapBins + 1) {
                closeRun(endIndex: prev)
            }

            if bin.bpm <= threshold {
                if runStart == nil { runStart = i }
                if gapBins > 0 { disturbances += 1 }
                gapBins = 0
                asleepCount += 1
                lastAsleep = i
            } else if runStart != nil {
                gapBins += 1
                if gapBins > config.maxGapBins, let prev = lastAsleep {
                    closeRun(endIndex: prev)
                }
            }
        }
        if let prev = lastAsleep { closeRun(endIndex: prev) }

        return windows
    }

    // MARK: - Resting heart rate

    /// Robust low heart rate across a window: the 5th percentile, which tracks the true resting
    /// floor without being hostage to a single dropout sample the way min() would be.
    static func restingHeartRate(hr: [HRSample], from: Int, to: Int) -> Int? {
        let inWindow = hr.filter { $0.ts >= from && $0.ts <= to && $0.bpm > 25 && $0.bpm < 220 }
            .map { Double($0.bpm) }
        guard inWindow.count >= 10, let p = percentile(inWindow, 0.05) else { return nil }
        return Int(p.rounded())
    }

    // MARK: - HRV (RMSSD)

    /// Root mean square of successive R-R differences over a window, in milliseconds — the
    /// standard short-term HRV measure and what most wearables report as "HRV".
    ///
    /// Two filters keep artefacts out: implausible intervals (outside 300–2000 ms, i.e. 30–200
    /// bpm) are dropped, and successive pairs are only used when they are close in time and
    /// differ by less than 200 ms. That rejects ectopic beats and, importantly, avoids pairing
    /// two intervals that sit on either side of a gap in the recording.
    static func rmssd(rr: [RRInterval], from: Int, to: Int) -> Double? {
        let vals = rr.filter { $0.ts >= from && $0.ts <= to && $0.rrMs > 300 && $0.rrMs < 2000 }
        guard vals.count >= 20 else { return nil }

        var sumSquares = 0.0
        var n = 0
        for i in 1..<vals.count {
            let a = vals[i - 1]
            let b = vals[i]
            guard b.ts - a.ts <= 10 else { continue }       // same recording stretch
            let diff = Double(b.rrMs - a.rrMs)
            guard abs(diff) < 200 else { continue }          // reject ectopic beats
            sumSquares += diff * diff
            n += 1
        }
        guard n >= 10 else { return nil }
        return (sumSquares / Double(n)).squareRoot()
    }

    // MARK: - Recovery (heuristic)

    /// An HRV-versus-personal-baseline score, 0...1.
    ///
    /// THIS IS A HEURISTIC, NOT WHOOP'S RECOVERY. The idea is the standard one — HRV above your
    /// own recent average indicates a recovered autonomic state, below it indicates strain — but
    /// the mapping constants are chosen for a sensible spread, not validated against anything.
    /// Requires at least 3 prior nights so "your baseline" means something; returns nil before that
    /// rather than scoring against a baseline of one.
    ///
    /// HRV carries the score; resting heart rate applies a modest correction, since an elevated
    /// RHR alongside normal HRV still indicates incomplete recovery.
    static func recovery(hrv: Double?,
                         restingHr: Int?,
                         baselineHrv: [Double],
                         baselineRhr: [Int]) -> Double? {
        guard let hrv, baselineHrv.count >= 3 else { return nil }
        let base = baselineHrv.suffix(14)
        let mean = base.reduce(0, +) / Double(base.count)
        guard mean > 0 else { return nil }

        // ratio 1.00 -> 0.50, ratio 1.33 -> 1.00, ratio 0.67 -> 0.00
        let ratio = hrv / mean
        var score = 0.5 + (ratio - 1.0) * 1.5

        // Resting-HR correction: each bpm above the personal baseline costs 2 points.
        if let restingHr, baselineRhr.count >= 3 {
            let rBase = baselineRhr.suffix(14)
            let rMean = Double(rBase.reduce(0, +)) / Double(rBase.count)
            score -= (Double(restingHr) - rMean) * 0.02
        }
        return min(1.0, max(0.0, score))
    }

    // MARK: - Strain (heuristic)

    /// Accumulated cardiovascular exertion across the waking day, mapped onto WHOOP's familiar
    /// 0–21 range.
    ///
    /// THIS IS A HEURISTIC, NOT WHOOP'S STRAIN. Time is weighted by heart-rate reserve —
    /// (hr - resting) / (max - resting) — squared, so hard minutes count far more than easy ones,
    /// then squashed through a saturating curve so a very long day cannot run away past 21.
    /// The curve constant is chosen so an ordinary active day lands mid-scale.
    static func strain(hr: [HRSample], from: Int, to: Int,
                       restingHr: Int?, maxHeartRate: Int) -> Double? {
        let rest = Double(restingHr ?? 55)
        let maxHR = Double(maxHeartRate)
        guard maxHR > rest + 20 else { return nil }

        let samples = hr.filter { $0.ts >= from && $0.ts <= to && $0.bpm > 25 && $0.bpm < 220 }
        guard samples.count >= 30 else { return nil }

        var load = 0.0
        for i in 1..<samples.count {
            let dt = Double(samples[i].ts - samples[i - 1].ts)
            // Ignore gaps longer than 5 min: the strap was off or not reporting, and we must not
            // credit that time at the heart rate of whichever sample happens to follow it.
            guard dt > 0, dt <= 300 else { continue }
            let minutes = dt / 60.0
            let reserve = (Double(samples[i].bpm) - rest) / (maxHR - rest)
            let f = min(1.0, max(0.0, reserve))
            load += f * f * minutes
        }
        guard load > 0 else { return 0 }

        return 21.0 * (1.0 - exp(-0.008 * load))
    }

    // MARK: - Helpers

    /// Median heart rate per fixed-width time bin, oldest first. Bins with no samples are absent
    /// (not zero-filled), so callers can tell "quiet" apart from "not worn".
    static func medianBins(hr: [HRSample], binSeconds: Int) -> [(ts: Int, bpm: Double)] {
        guard binSeconds > 0, !hr.isEmpty else { return [] }
        var buckets: [Int: [Double]] = [:]
        for s in hr where s.bpm > 25 && s.bpm < 220 {
            let key = (s.ts / binSeconds) * binSeconds
            buckets[key, default: []].append(Double(s.bpm))
        }
        return buckets.keys.sorted().compactMap { key in
            guard let median = percentile(buckets[key] ?? [], 0.5) else { return nil }
            return (ts: key, bpm: median)
        }
    }

    /// Linear-interpolated percentile of an unsorted array. `p` is 0...1.
    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        if sorted.count == 1 { return sorted[0] }
        let pos = min(max(p, 0), 1) * Double(sorted.count - 1)
        let lower = Int(pos.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let frac = pos - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * frac
    }

    /// YYYY-MM-DD in UTC — matching how DailyMetric.day is keyed everywhere else in the store.
    static func dayString(forEpoch epoch: Int) -> String {
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }
}
