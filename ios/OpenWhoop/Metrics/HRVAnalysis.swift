import Foundation
import WhoopProtocol

// MARK: - HRVAnalysis
//
// Nightly heart-rate variability, computed the way the HRV literature and the serious consumer
// devices actually do it — not as one RMSSD over an eight-hour block.
//
// WHY THE OLD WAY WAS WRONG: a single RMSSD across the whole night mixes sleep stages and the
// circadian drift within the night, and one burst of artefacts anywhere in those hours moves the
// result. The standard approach is the opposite: cut the night into short windows, compute RMSSD
// in each, and aggregate the windows. Marco Altini (HRV4Training) describes exactly this — use the
// whole night rather than a single spot measurement, as many 5-minute rMSSD windows aggregated
// into one score, because HRV differs markedly between sleep stages minute to minute.
//
// ARTEFACT HANDLING: a wrist optical sensor drops and doubles beats. Two filters run before any
// maths, both standard in the HRV literature:
//   1. Plausibility — intervals outside 300…2000 ms (30…200 bpm) are not heartbeats.
//   2. Malik's rule — a beat differing from its predecessor by more than 20 % is an ectopic beat
//      or a detection error, and the PAIR is dropped rather than fed to the successive-difference
//      sum it would dominate.
//
// HONESTY (this project's standing rule): RMSSD itself is a well-defined quantity, so this is one
// of the few numbers here that is not a heuristic. What is uncertain is the INPUT — the strap's
// beat detection is not an ECG, and how many clean beats we get decides how much the number can be
// trusted. That is why `coverage` is reported alongside the value instead of hidden.

struct HRVResult: Equatable {
    /// Median of the per-window RMSSD values, in milliseconds. The headline "HRV" number.
    let rmssd: Double
    /// Mean of the per-window values. Kept for comparison; the median is the reported one because
    /// it shrugs off a single bad window.
    let meanRmssd: Double
    /// Standard deviation of all accepted intervals (SDNN), in milliseconds.
    let sdnn: Double
    /// Mean heart rate implied by the accepted intervals, in bpm.
    let meanHR: Double
    /// How many windows produced a value.
    let windows: Int
    /// Share of raw intervals that survived both filters, 0...1. Low values mean a noisy night.
    let coverage: Double
}

enum HRVAnalysis {

    /// Window length. Five minutes is the short-term HRV standard and what nightly-HRV practice
    /// aggregates over.
    static let windowSeconds = 300

    /// Fewest usable successive pairs a window needs. RMSSD over a handful of beats is noise.
    static let minPairsPerWindow = 20

    /// Malik's rule: reject a successive pair when the second interval differs from the first by
    /// more than this fraction.
    static let malikFraction = 0.20

    /// Computes nightly HRV over `from...to`.
    ///
    /// - Parameter rr: R-R intervals in RECORDING order (WhoopStore.rrIntervals returns them so).
    /// - Returns: nil when no window had enough clean beats — deliberately nil rather than a
    ///   number computed from too little data.
    static func analyse(rr: [RRInterval], from: Int, to: Int) -> HRVResult? {
        let inWindow = rr.filter { $0.ts >= from && $0.ts <= to }
        guard !inWindow.isEmpty else { return nil }

        let plausible = inWindow.filter { $0.rrMs > 300 && $0.rrMs < 2000 }
        guard !plausible.isEmpty else { return nil }

        // Group into fixed 5-minute windows keyed by window start.
        var buckets: [Int: [RRInterval]] = [:]
        for r in plausible {
            buckets[(r.ts / windowSeconds) * windowSeconds, default: []].append(r)
        }

        var perWindow: [Double] = []
        var acceptedAll: [Int] = []
        var pairsConsidered = 0

        for key in buckets.keys.sorted() {
            let beats = buckets[key] ?? []
            guard beats.count >= minPairsPerWindow else { continue }

            var sumSquares = 0.0
            var pairs = 0
            var accepted: [Int] = [beats[0].rrMs]
            for i in 1..<beats.count {
                let a = beats[i - 1], b = beats[i]
                pairsConsidered += 1
                // Two intervals that sit on either side of a recording gap are not successive
                // beats, and pairing them would invent a huge difference.
                guard b.ts - a.ts <= 10 else { accepted.append(b.rrMs); continue }
                let diff = Double(b.rrMs - a.rrMs)
                guard abs(diff) <= malikFraction * Double(a.rrMs) else { continue }   // Malik
                sumSquares += diff * diff
                pairs += 1
                accepted.append(b.rrMs)
            }
            guard pairs >= minPairsPerWindow else { continue }
            perWindow.append((sumSquares / Double(pairs)).squareRoot())
            acceptedAll.append(contentsOf: accepted)
        }

        guard !perWindow.isEmpty, acceptedAll.count >= minPairsPerWindow else { return nil }

        let sorted = perWindow.sorted()
        let median = sorted.count % 2 == 1
            ? sorted[sorted.count / 2]
            : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        let mean = perWindow.reduce(0, +) / Double(perWindow.count)

        let values = acceptedAll.map(Double.init)
        let avg = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - avg) * ($1 - avg) } / Double(values.count)

        return HRVResult(rmssd: median,
                         meanRmssd: mean,
                         sdnn: variance.squareRoot(),
                         meanHR: avg > 0 ? 60_000.0 / avg : 0,
                         windows: perWindow.count,
                         coverage: pairsConsidered > 0
                            ? min(1.0, Double(acceptedAll.count) / Double(plausible.count))
                            : 0)
    }

    /// Short-window RMSSD for the sleep stager, which needs a local value per epoch rather than a
    /// nightly one. Same filters, no window grouping, no minimum-window rule.
    /// Returns nil below `minPairs` usable pairs.
    static func rmssdRaw(_ intervals: [RRInterval], minPairs: Int = 5) -> Double? {
        let plausible = intervals.filter { $0.rrMs > 300 && $0.rrMs < 2000 }
        guard plausible.count > minPairs else { return nil }
        var sumSquares = 0.0
        var pairs = 0
        for i in 1..<plausible.count {
            let a = plausible[i - 1], b = plausible[i]
            guard b.ts - a.ts <= 10 else { continue }
            let diff = Double(b.rrMs - a.rrMs)
            guard abs(diff) <= malikFraction * Double(a.rrMs) else { continue }
            sumSquares += diff * diff
            pairs += 1
        }
        guard pairs >= minPairs else { return nil }
        return (sumSquares / Double(pairs)).squareRoot()
    }
}
