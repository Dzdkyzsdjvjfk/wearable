import Foundation
import WhoopProtocol

// MARK: - StressHistory
//
// Turns the stored R-R intervals into a stress TIME SERIES, so the Stress tile is no longer a
// live-only number that vanishes on disconnect.
//
// WHY THIS CAN BE COMPUTED AFTER THE FACT: the Baevsky Stress Index (see StressMonitor.swift) is
// a pure function of a window of R-R intervals. Nothing about it needs the strap to be connected
// *now* — it only needs enough beats inside the window. Every beat the strap streams live and
// every beat recovered from its historical offload is already persisted in `rrInterval`, so the
// same formula applied per time-bin yields the history retroactively, including for nights and
// hours the phone spent in a pocket. No new storage, no new protocol work, and it also works for
// data collected before this feature existed.
//
// HONESTY (this project's standing rule — see StressMonitor.swift and LocalMetricsEngine.swift):
// this is our own estimate from a published 1997 HRV formula, not a WHOOP metric, and there is no
// WHOOP ground truth to validate it against. Read it as a relative trend across the day, not as a
// precise or clinical value.

/// One computed stress reading: the bin's start time and its index.
struct StressPoint: Identifiable, Equatable {
    let ts: Int          // bin start, unix seconds
    let index: Double    // Baevsky Stress Index
    var id: Int { ts }
    var band: BaevskyStress.Band { BaevskyStress.band(for: index) }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(ts)) }
}

/// Aggregate view of a stress series, for the summary row above the chart.
struct StressSummary: Equatable {
    let average: Double
    let peak: Double
    let calmShare: Double       // 0...1 of computed bins
    let elevatedShare: Double
    let highShare: Double
    let binCount: Int
    /// Total wall time the computed bins cover, in minutes.
    let coveredMinutes: Int
}

enum StressHistory {

    /// Bin width. 5 minutes is the same granularity the sleep detector uses and comfortably holds
    /// enough beats (~300 at a resting 60 bpm) for a stable Mo/AMo estimate, while still resolving
    /// a stressful meeting or a hard set from the hour around it.
    static let defaultBinSeconds = 300

    /// Fewest beats a bin needs before it gets a value. Below this the index is noise, so the bin
    /// is left out entirely rather than plotted as a wrong number — a gap in the chart honestly
    /// means "not enough beats here", never "calm".
    static let minBeatsPerBin = 25

    /// Computes the stress series for the supplied R-R intervals.
    ///
    /// - Parameters:
    ///   - rr: R-R intervals in recording order (WhoopStore.rrIntervals already returns them so).
    ///   - binSeconds: bin width; defaults to 5 minutes.
    ///   - minBeats: minimum beats per bin; defaults to `minBeatsPerBin`.
    /// - Returns: points for every bin that had enough beats, oldest first.
    static func series(rr: [RRInterval],
                       binSeconds: Int = defaultBinSeconds,
                       minBeats: Int = minBeatsPerBin) -> [StressPoint] {
        guard binSeconds > 0, !rr.isEmpty else { return [] }

        var bins: [Int: [Int]] = [:]
        for r in rr where r.rrMs > 300 && r.rrMs < 2000 {
            let key = (r.ts / binSeconds) * binSeconds
            bins[key, default: []].append(r.rrMs)
        }

        return bins.keys.sorted().compactMap { key in
            let beats = bins[key] ?? []
            guard beats.count >= minBeats, let idx = BaevskyStress.index(rrMs: beats) else { return nil }
            return StressPoint(ts: key, index: idx)
        }
    }

    /// Summary of a computed series. nil for an empty series.
    static func summary(_ points: [StressPoint], binSeconds: Int = defaultBinSeconds) -> StressSummary? {
        guard !points.isEmpty else { return nil }
        let values = points.map(\.index)
        let n = Double(points.count)
        var calm = 0, elevated = 0, high = 0
        for p in points {
            switch p.band {
            case .calm:     calm += 1
            case .elevated: elevated += 1
            case .high:     high += 1
            }
        }
        return StressSummary(average: values.reduce(0, +) / n,
                             peak: values.max() ?? 0,
                             calmShare: Double(calm) / n,
                             elevatedShare: Double(elevated) / n,
                             highShare: Double(high) / n,
                             binCount: points.count,
                             coveredMinutes: points.count * binSeconds / 60)
    }

    /// Smooths a series with a centred moving average over `window` bins (odd numbers work best).
    /// The raw per-bin index is spiky by nature; the chart draws the smoothed line so a trend is
    /// readable, and keeps the raw points for the tap-to-inspect value.
    static func smoothed(_ points: [StressPoint], window: Int = 3) -> [StressPoint] {
        guard window > 1, points.count > window else { return points }
        let half = window / 2
        return points.indices.map { i in
            let lo = max(0, i - half)
            let hi = min(points.count - 1, i + half)
            let slice = points[lo...hi].map(\.index)
            let avg = slice.reduce(0, +) / Double(slice.count)
            return StressPoint(ts: points[i].ts, index: avg)
        }
    }
}
