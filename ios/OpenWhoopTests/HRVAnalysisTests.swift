import XCTest
import WhoopProtocol
@testable import OpenWhoop

/// Covers the windowed, artefact-filtered nightly HRV that replaced a single RMSSD over the whole
/// night.
final class HRVAnalysisTests: XCTestCase {

    private let base = 1_700_000_000

    /// Beats spaced by their own duration, so timestamps advance like real ones.
    private func beats(from start: Int, minutes: Int, rr: (Int) -> Int) -> [RRInterval] {
        var out: [RRInterval] = []
        var tMs = start * 1000
        let endMs = (start + minutes * 60) * 1000
        var i = 0
        while tMs < endMs {
            let v = rr(i)
            out.append(RRInterval(ts: tMs / 1000, rrMs: v))
            tMs += v
            i += 1
        }
        return out
    }

    func testReturnsNilWithoutEnoughBeats() {
        let rr = [RRInterval(ts: base, rrMs: 900), RRInterval(ts: base + 1, rrMs: 910)]
        XCTAssertNil(HRVAnalysis.analyse(rr: rr, from: base - 10, to: base + 3600))
    }

    func testComputesOverMultipleWindows() {
        let rr = beats(from: base, minutes: 30) { i in 900 + (i % 5) * 20 }
        guard let r = HRVAnalysis.analyse(rr: rr, from: base, to: base + 30 * 60) else {
            return XCTFail("expected a result")
        }
        XCTAssertGreaterThanOrEqual(r.windows, 5, "30 minutes must yield several 5-minute windows")
        XCTAssertGreaterThan(r.rmssd, 0)
        XCTAssertGreaterThan(r.sdnn, 0)
        // ~900 ms intervals is ~67 bpm.
        XCTAssertEqual(r.meanHR, 67, accuracy: 6)
    }

    func testHigherVariabilityGivesHigherRMSSD() {
        let calm = beats(from: base, minutes: 20) { i in 900 + (i % 3) * 10 }
        let variable = beats(from: base, minutes: 20) { i in 900 + (i % 3) * 60 }
        let a = HRVAnalysis.analyse(rr: calm, from: base, to: base + 1200)?.rmssd ?? 0
        let b = HRVAnalysis.analyse(rr: variable, from: base, to: base + 1200)?.rmssd ?? 0
        XCTAssertGreaterThan(b, a)
    }

    /// The core reason for the rewrite: one bad stretch must not move the nightly number much,
    /// because the median across windows ignores it.
    func testOneCorruptedWindowBarelyMovesTheMedian() {
        var clean = beats(from: base, minutes: 40) { i in 900 + (i % 5) * 20 }
        let reference = HRVAnalysis.analyse(rr: clean, from: base, to: base + 2400)!.rmssd

        // Wreck one 5-minute window with alternating half/double beats (a classic optical
        // miss-and-double artefact).
        let badStart = base + 10 * 60
        clean.removeAll { $0.ts >= badStart && $0.ts < badStart + 300 }
        var tMs = badStart * 1000
        var i = 0
        while tMs < (badStart + 300) * 1000 {
            let v = i % 2 == 0 ? 450 : 1800
            clean.append(RRInterval(ts: tMs / 1000, rrMs: v))
            tMs += v
            i += 1
        }
        clean.sort { $0.ts < $1.ts }

        let polluted = HRVAnalysis.analyse(rr: clean, from: base, to: base + 2400)!.rmssd
        XCTAssertEqual(polluted, reference, accuracy: reference * 0.35,
                       "a single corrupted window must not dominate the night")
    }

    func testMalikFilterRejectsImplausibleJumps() {
        // Every second beat jumps far more than 20 % — nothing should survive as a valid pair.
        let rr = beats(from: base, minutes: 20) { i in i % 2 == 0 ? 600 : 1400 }
        XCTAssertNil(HRVAnalysis.analyse(rr: rr, from: base, to: base + 1200),
                     "beat-to-beat jumps beyond Malik's 20 % rule are artefacts, not variability")
    }

    func testIntervalsOutsidePlausibleRangeAreIgnored() {
        var rr = beats(from: base, minutes: 20) { i in 900 + (i % 4) * 25 }
        rr.append(RRInterval(ts: base + 30, rrMs: 50))
        rr.append(RRInterval(ts: base + 31, rrMs: 5_000))
        rr.sort { $0.ts < $1.ts }
        let r = HRVAnalysis.analyse(rr: rr, from: base, to: base + 1200)
        XCTAssertNotNil(r)
        XCTAssertGreaterThan(r!.rmssd, 0)
        XCTAssertLessThan(r!.rmssd, 200)
    }

    func testShortWindowHelperUsedByTheStager() {
        let rr = beats(from: base, minutes: 3) { i in 900 + (i % 4) * 20 }
        XCTAssertNotNil(HRVAnalysis.rmssdRaw(rr))
        XCTAssertNil(HRVAnalysis.rmssdRaw(Array(rr.prefix(3))), "too few beats → nil, not a guess")
    }
}
