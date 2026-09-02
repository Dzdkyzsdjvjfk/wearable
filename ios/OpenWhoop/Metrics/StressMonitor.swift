import Foundation

// MARK: - BaevskyStress
// Baevsky "Stress Index" (SI) — a classic, published autonomic-stress estimate computed purely
// from R-R interval statistics (Baevsky & Chernikova, 1997):
//
//     SI = AMo(%) / (2 · Mo(s) · MxDMn(s))
//
//     Mo    = modal RR interval (the most common ~50ms-binned value), in seconds
//     AMo   = percentage of samples that fall in the modal bin
//     MxDMn = range between the longest and shortest RR interval in the sample, in seconds
//
// Higher SI = less heart-rate variability = more sympathetic ("fight or flight") activity.
//
// IMPORTANT — this is NOT a WHOOP metric. WHOOP's own stress score (if any) uses a different,
// undisclosed algorithm, and this formula has never been validated against it — like every
// metric in this app, there is no WHOOP ground truth to check against (see
// server/ingest/docs/2026-05-26-metrics-methodology.md). It's included because it's an honest,
// transparent, purely on-device computation from the strap's real live R-R stream — see
// StressExplainerView for the in-app disclosure shown to the user.
enum BaevskyStress {

    enum Band: String {
        case calm, elevated, high

        var label: String {
            switch self {
            case .calm:     return "Calm"
            case .elevated: return "Elevated"
            case .high:     return "High"
            }
        }
    }

    /// Bin width for the mode histogram, in milliseconds. 50ms is the standard Baevsky bin size.
    private static let binWidthMs = 50.0

    /// Minimum beats required for a stable estimate. Below this, returns nil rather than a
    /// noisy number.
    private static let minSamples = 20

    /// Computes the Stress Index from a window of R-R intervals, in milliseconds.
    /// Returns nil when there isn't enough clean data for a stable estimate.
    static func index(rrMs: [Int]) -> Double? {
        // Discard obvious artefacts (< 30 bpm or > 200 bpm) before binning.
        let values = rrMs.filter { $0 > 300 && $0 < 2000 }
        guard values.count >= minSamples else { return nil }

        // Mode: the most frequent 50ms-wide bin, reported as its bin-center in seconds.
        var bins: [Int: Int] = [:]
        for rr in values {
            let bin = Int((Double(rr) / binWidthMs).rounded())
            bins[bin, default: 0] += 1
        }
        guard let (modalBin, modalCount) = bins.max(by: { $0.value < $1.value }) else { return nil }
        let moSec = (Double(modalBin) * binWidthMs) / 1000.0
        let amoPct = (Double(modalCount) / Double(values.count)) * 100.0

        guard let maxRR = values.max(), let minRR = values.min() else { return nil }
        let mxdmnSec = Double(maxRR - minRR) / 1000.0

        // Guard divide-by-near-zero (a perfectly flat, artefact-free window is unrealistic but
        // not impossible on a very short buffer).
        guard moSec > 0, mxdmnSec > 0.01 else { return nil }

        return amoPct / (2 * moSec * mxdmnSec)
    }

    /// Buckets a raw SI value into a coarse, human-readable band. Thresholds follow commonly
    /// cited ranges for resting SI (< ~150 normal/calm, 150–500 elevated, > 500 high) —
    /// approximate, not a medical or clinical cutoff.
    static func band(for index: Double) -> Band {
        switch index {
        case ..<150:    return .calm
        case 150..<500: return .elevated
        default:        return .high
        }
    }
}
