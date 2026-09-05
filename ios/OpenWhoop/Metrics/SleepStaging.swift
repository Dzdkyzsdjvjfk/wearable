import Foundation
import WhoopProtocol

// MARK: - SleepStaging
//
// Estimates wake / light / deep / REM for a detected night from the three signals the strap
// actually delivers: heart rate, R-R intervals, and wrist motion (the type-47 gravity triplet).
//
// WHY THIS IS NOW POSSIBLE — and why it used to say "not derivable":
// The earlier note in LocalMetricsEngine was that staging "needs signals the strap does not expose
// on the wire". That is true of EEG, which is what a sleep lab scores from. It is not true of the
// approach every wrist wearable actually uses: motion plus cardiac features. Apple Watch data
// scored against polysomnography (Walch et al., SLEEP 2019) reaches ~90 % accuracy for sleep vs
// wake and ~72 % for wake/NREM/REM from exactly these two signal families — and the type-47
// history records here carry heart rate, R-R counts AND a gravity triplet per record.
//
// FEATURE DESIGN, following that paper:
//   - 30-second epochs (the PSG scoring epoch).
//   - Motion → an "activity count" per epoch (how much the gravity vector moved), smoothed with a
//     Gaussian, σ ≈ 50 s.
//   - Heart rate → the DEVIATION from a slow baseline, via a difference-of-Gaussians filter
//     (σ₁ = 120 s, σ₂ = 600 s). What matters for staging is not absolute bpm but "higher or lower
//     than this person is running tonight".
//   - Heart-rate variability in the epoch's neighbourhood: the paper uses the standard deviation
//     of heart rate; where R-R intervals exist we additionally use RMSSD, which is the better
//     measure of the same thing.
//
// STAGE RULES, from the sleep-physiology literature (Tobaldini et al., Front. Physiol. 2013):
// parasympathetic tone rises progressively from wake into N3 and then reverses in REM. So:
//   deep  — heart rate at its nightly floor, high RMSSD, very steady, essentially no motion
//   REM   — heart rate back up near waking levels, RMSSD down, unsteady beat-to-beat, and yet
//           almost no motion at all (muscle atonia) — that combination is what distinguishes REM
//           from being awake
//   wake  — movement, or a clearly elevated heart rate with movement
//   light — everything else, which is also what most of a night is
//
// HONESTY (this project's standing rule): these are estimates from an indirect signal. The ceiling
// for this class of method is around 70 % epoch agreement for three classes against a sleep lab,
// and separating deep from light is the weakest part of it. Treat the hypnogram as "roughly how
// the night was shaped", not as a measurement. Where the input is too thin to support even that —
// no motion data, or fewer than a few heart-rate samples per minute — the stager returns nil and
// the app shows nothing rather than a plausible-looking invention.

struct SleepStage: Equatable {
    let start: Int      // epoch seconds
    let end: Int
    let stage: String   // "wake" | "light" | "deep" | "rem" — the strings HypnogramView renders
}

struct StagingResult: Equatable {
    let stages: [SleepStage]
    let deepMinutes: Double
    let remMinutes: Double
    let lightMinutes: Double
    let wakeMinutes: Double
    /// True when wrist motion was available. Without it the stager leans on heart rate alone and
    /// is measurably weaker — the UI says so rather than pretending otherwise.
    let usedMotion: Bool
}

enum SleepStaging {

    static let epochSeconds = 30

    /// Minimum heart-rate sample density (samples per minute of the window) before staging is
    /// attempted at all. Below this the epochs are mostly interpolation.
    static let minSamplesPerMinute = 0.5

    /// Shortest run of one stage that is kept. Real REM and slow-wave bouts last minutes; anything
    /// shorter is the classifier flickering, so it is absorbed into its neighbours.
    static let minBoutEpochs = 10        // 5 minutes

    /// No REM is accepted before this much sleep has elapsed. REM latency in healthy adults is
    /// roughly an hour and a half; allowing it at minute two would let the first settling-down
    /// period masquerade as REM.
    static let remLockoutSeconds = 30 * 60

    // MARK: - Entry point

    static func stage(hr: [HRSample],
                      rr: [RRInterval],
                      motion: [GravitySample],
                      from: Int,
                      to: Int) -> StagingResult? {
        let duration = to - from
        guard duration >= 45 * 60 else { return nil }

        let hrIn = hr.filter { $0.ts >= from && $0.ts <= to && $0.bpm > 25 && $0.bpm < 220 }
            .sorted { $0.ts < $1.ts }
        guard Double(hrIn.count) / (Double(duration) / 60.0) >= minSamplesPerMinute else { return nil }

        let epochCount = duration / epochSeconds
        guard epochCount >= 60 else { return nil }

        // --- Per-epoch heart rate (carried forward, then smoothed) --------------------------
        var hrPerEpoch = [Double](repeating: 0, count: epochCount)
        var haveHR = [Bool](repeating: false, count: epochCount)
        for s in hrIn {
            let idx = min(epochCount - 1, max(0, (s.ts - from) / epochSeconds))
            hrPerEpoch[idx] = hrPerEpoch[idx] == 0 ? Double(s.bpm) : (hrPerEpoch[idx] + Double(s.bpm)) / 2
            haveHR[idx] = true
        }
        fillGaps(&hrPerEpoch, have: haveHR)

        // --- Per-epoch motion ---------------------------------------------------------------
        let motionIn = motion.filter { $0.ts >= from && $0.ts <= to }.sorted { $0.ts < $1.ts }
        let usedMotion = motionIn.count >= epochCount / 4
        var activity = [Double](repeating: 0, count: epochCount)
        if usedMotion {
            var previous: GravitySample?
            var sums = [Double](repeating: 0, count: epochCount)
            var counts = [Double](repeating: 0, count: epochCount)
            for m in motionIn {
                defer { previous = m }
                guard let p = previous else { continue }
                let d = ((m.x - p.x) * (m.x - p.x)
                       + (m.y - p.y) * (m.y - p.y)
                       + (m.z - p.z) * (m.z - p.z)).squareRoot()
                let idx = min(epochCount - 1, max(0, (m.ts - from) / epochSeconds))
                sums[idx] += d
                counts[idx] += 1
            }
            for i in 0..<epochCount { activity[i] = counts[i] > 0 ? sums[i] / counts[i] : 0 }
            activity = gaussianSmooth(activity, sigmaEpochs: 50.0 / Double(epochSeconds))
        }

        // --- Heart-rate features -------------------------------------------------------------
        // Difference of Gaussians: fast baseline minus slow baseline = "above or below where this
        // night is sitting right now", which is what the stage rules are written against.
        let fast = gaussianSmooth(hrPerEpoch, sigmaEpochs: 120.0 / Double(epochSeconds))
        let slow = gaussianSmooth(hrPerEpoch, sigmaEpochs: 600.0 / Double(epochSeconds))
        var hrDeviation = [Double](repeating: 0, count: epochCount)
        for i in 0..<epochCount { hrDeviation[i] = fast[i] - slow[i] }

        // Local instability of the beat (the paper's heart-rate standard deviation feature).
        let hrStd = rollingStdDev(hrPerEpoch, halfWindow: 5)      // ±2.5 min

        // RMSSD around each epoch where R-R intervals exist — the better variability measure.
        let rrIn = rr.filter { $0.ts >= from && $0.ts <= to }.sorted { $0.ts < $1.ts }
        var rmssd = [Double?](repeating: nil, count: epochCount)
        if !rrIn.isEmpty {
            for i in 0..<epochCount {
                let centre = from + i * epochSeconds
                let slice = rrIn.filter { $0.ts >= centre - 150 && $0.ts <= centre + 150 }
                rmssd[i] = HRVAnalysis.rmssdRaw(slice)
            }
        }

        // --- Reference levels -------------------------------------------------------------------
        let hrFloor = percentile(hrPerEpoch, 0.05) ?? hrPerEpoch.min() ?? 0
        let hrCeiling = percentile(hrPerEpoch, 0.95) ?? hrPerEpoch.max() ?? 0
        let hrSpan = max(1.0, hrCeiling - hrFloor)
        // Movement threshold, relative to how much this night moved at all. A fraction of the
        // night's own high-water mark works on both ends: on a restless night the tossing clears
        // it, and on a still night the 95th percentile is ~0 so the small absolute floor keeps
        // sensor noise from being scored as getting up. (An earlier version took a percentile of
        // only the non-zero epochs and scaled it UP, which could land above the night's own
        // maximum activity — and then nothing ever cleared it.)
        let motionThreshold = usedMotion
            ? max(0.015, (percentile(activity, 0.95) ?? 0) * 0.35)
            : Double.greatestFiniteMagnitude
        let rmssdValues = rmssd.compactMap { $0 }
        let rmssdHigh = percentile(rmssdValues, 0.60)
        let rmssdLow = percentile(rmssdValues, 0.35)
        let stdMedian = percentile(hrStd, 0.50) ?? 0

        // --- Classify ---------------------------------------------------------------------------
        var labels = [String](repeating: "light", count: epochCount)
        for i in 0..<epochCount {
            let relative = (hrPerEpoch[i] - hrFloor) / hrSpan     // 0 = nightly floor, 1 = ceiling
            let moving = usedMotion && activity[i] > motionThreshold
            let elevated = hrDeviation[i] > 0.6 || relative > 0.72
            let low = hrDeviation[i] < -0.3 || relative < 0.30
            let steady = hrStd[i] <= stdMedian
            let vagal = rmssd[i].flatMap { v in rmssdHigh.map { v >= $0 } } ?? steady
            let withdrawn = rmssd[i].flatMap { v in rmssdLow.map { v <= $0 } } ?? !steady

            if moving && elevated {
                labels[i] = "wake"
            } else if low && vagal && steady && !moving {
                labels[i] = "deep"
            } else if elevated && withdrawn && !moving
                        && (i * epochSeconds) >= remLockoutSeconds {
                labels[i] = "rem"
            } else if moving {
                // Movement without an elevated heart rate is a turn in bed, not waking up.
                labels[i] = "light"
            } else {
                labels[i] = "light"
            }
        }

        labels = medianSmooth(labels)
        labels = enforceMinimumBouts(labels)

        // --- Pack into segments -------------------------------------------------------------------
        var stages: [SleepStage] = []
        var runStart = 0
        for i in 1...epochCount {
            if i == epochCount || labels[i] != labels[runStart] {
                stages.append(SleepStage(start: from + runStart * epochSeconds,
                                         end: from + i * epochSeconds,
                                         stage: labels[runStart]))
                runStart = i
            }
        }

        func minutes(_ stage: String) -> Double {
            Double(labels.filter { $0 == stage }.count) * Double(epochSeconds) / 60.0
        }
        return StagingResult(stages: stages,
                             deepMinutes: minutes("deep"),
                             remMinutes: minutes("rem"),
                             lightMinutes: minutes("light"),
                             wakeMinutes: minutes("wake"),
                             usedMotion: usedMotion)
    }

    /// Stage segments as the JSON string CachedSleepSession.stagesJSON carries and
    /// HypnogramView parses ([{start,end,stage}]).
    static func stagesJSON(_ stages: [SleepStage]) -> String? {
        let payload = stages.map { ["start": $0.start, "end": $0.end, "stage": $0.stage] as [String: Any] }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Signal helpers

    /// Linear interpolation across epochs with no sample, so the smoothing filters see a
    /// continuous series instead of zeros.
    static func fillGaps(_ values: inout [Double], have: [Bool]) {
        guard let firstKnown = have.firstIndex(of: true) else { return }
        let lastKnown = have.lastIndex(of: true) ?? firstKnown
        for i in 0..<firstKnown { values[i] = values[firstKnown] }
        for i in (lastKnown + 1)..<values.count { values[i] = values[lastKnown] }
        var i = firstKnown
        while i <= lastKnown {
            if have[i] { i += 1; continue }
            var j = i
            while j <= lastKnown && !have[j] { j += 1 }
            let before = values[i - 1], after = values[min(j, lastKnown)]
            let span = Double(j - i + 1)
            for k in i..<j {
                let t = Double(k - i + 1) / span
                values[k] = before + (after - before) * t
            }
            i = j
        }
    }

    static func gaussianSmooth(_ values: [Double], sigmaEpochs: Double) -> [Double] {
        guard sigmaEpochs > 0.3, values.count > 2 else { return values }
        let radius = max(1, Int((sigmaEpochs * 2.5).rounded()))
        var kernel = [Double]()
        for d in -radius...radius {
            let x = Double(d) / sigmaEpochs
            kernel.append(exp(-0.5 * x * x))
        }
        let norm = kernel.reduce(0, +)
        return values.indices.map { i in
            var acc = 0.0
            for (k, w) in kernel.enumerated() {
                let idx = min(values.count - 1, max(0, i + k - radius))
                acc += values[idx] * w
            }
            return acc / norm
        }
    }

    static func rollingStdDev(_ values: [Double], halfWindow: Int) -> [Double] {
        values.indices.map { i in
            let lo = max(0, i - halfWindow), hi = min(values.count - 1, i + halfWindow)
            let slice = Array(values[lo...hi])
            let mean = slice.reduce(0, +) / Double(slice.count)
            let v = slice.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(slice.count)
            return v.squareRoot()
        }
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        if sorted.count == 1 { return sorted[0] }
        let pos = min(max(p, 0), 1) * Double(sorted.count - 1)
        let lower = Int(pos.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (pos - Double(lower))
    }

    /// Replaces each label with the most common label in a ±2-epoch neighbourhood, which removes
    /// isolated single-epoch flips without moving real transitions.
    static func medianSmooth(_ labels: [String]) -> [String] {
        guard labels.count > 5 else { return labels }
        return labels.indices.map { i in
            let lo = max(0, i - 2), hi = min(labels.count - 1, i + 2)
            var counts: [String: Int] = [:]
            for l in labels[lo...hi] { counts[l, default: 0] += 1 }
            return counts.max { a, b in a.value < b.value }?.key ?? labels[i]
        }
    }

    /// Absorbs runs shorter than `minBoutEpochs` into whichever neighbour they touch, so the
    /// hypnogram shows sleep bouts rather than a barcode.
    static func enforceMinimumBouts(_ labels: [String]) -> [String] {
        guard labels.count > minBoutEpochs else { return labels }
        var out = labels
        var start = 0
        while start < out.count {
            var end = start
            while end + 1 < out.count && out[end + 1] == out[start] { end += 1 }
            let length = end - start + 1
            if length < minBoutEpochs {
                let replacement = start > 0 ? out[start - 1]
                                : (end + 1 < out.count ? out[end + 1] : out[start])
                for i in start...end { out[i] = replacement }
            }
            start = end + 1
        }
        return out
    }
}
