import XCTest
import WhoopProtocol
@testable import OpenWhoop

/// Covers the retroactive stress series: the thing that turns the live-only Stress tile into a
/// 6 h / 24 h / 7 d history computed from stored R-R intervals.
final class StressHistoryTests: XCTestCase {

    /// Builds `count` R-R intervals starting at `start`, spaced by their own duration so the
    /// timestamps advance like real beats do.
    private func beats(from start: Int, count: Int, rrMs: @escaping (Int) -> Int) -> [RRInterval] {
        var out: [RRInterval] = []
        var tMs = start * 1000
        for i in 0..<count {
            let rr = rrMs(i)
            out.append(RRInterval(ts: tMs / 1000, rrMs: rr))
            tMs += rr
        }
        return out
    }

    func testEmptyInputYieldsEmptySeries() {
        XCTAssertTrue(StressHistory.series(rr: []).isEmpty)
        XCTAssertNil(StressHistory.summary([]))
    }

    func testBinWithTooFewBeatsIsOmittedRatherThanGuessed() {
        // 10 beats is under minBeatsPerBin — the bin must be absent, NOT plotted as calm.
        let rr = beats(from: 1_000_000, count: 10) { _ in 900 }
        XCTAssertTrue(StressHistory.series(rr: rr).isEmpty)
    }

    func testProducesOnePointPerWellFilledBin() {
        // ~60 beats per 5-min bin over 3 bins.
        let rr = beats(from: 1_000_000, count: 3 * 60) { i in 800 + (i % 7) * 20 }
        let series = StressHistory.series(rr: rr, binSeconds: 300)
        XCTAssertGreaterThanOrEqual(series.count, 2)
        // Bin starts must be aligned to the bin width and strictly increasing.
        for p in series { XCTAssertEqual(p.ts % 300, 0) }
        XCTAssertEqual(series.map(\.ts), series.map(\.ts).sorted())
    }

    func testGapInDataProducesGapInSeriesNotAFabricatedPoint() {
        let early = beats(from: 1_000_000, count: 60) { i in 800 + (i % 5) * 20 }
        // Two hours later, after a stretch with no beats at all.
        let late = beats(from: 1_007_200, count: 60) { i in 800 + (i % 5) * 20 }
        let series = StressHistory.series(rr: early + late, binSeconds: 300)
        XCTAssertGreaterThanOrEqual(series.count, 2)
        // Nothing may appear in the empty hour between the two clusters.
        let middle = series.filter { $0.ts > 1_001_000 && $0.ts < 1_006_000 }
        XCTAssertTrue(middle.isEmpty, "an empty stretch must stay empty, not be interpolated")
    }

    func testLowVariabilityScoresHigherStressThanHighVariability() {
        // The whole point of the index: a flat, rigid rhythm = sympathetic dominance = high SI.
        let rigid = beats(from: 2_000_000, count: 120) { i in 800 + (i % 2) * 10 }
        let variable = beats(from: 3_000_000, count: 120) { i in 700 + (i % 11) * 40 }
        let rigidIdx = StressHistory.series(rr: rigid).map(\.index).max() ?? 0
        let variableIdx = StressHistory.series(rr: variable).map(\.index).max() ?? 0
        XCTAssertGreaterThan(rigidIdx, variableIdx)
    }

    func testArtefactsAreFilteredBeforeBinning() {
        // Implausible intervals (<300 ms / >2000 ms) must not reach the formula.
        var rr = beats(from: 4_000_000, count: 60) { _ in 900 }
        rr.append(RRInterval(ts: 4_000_010, rrMs: 12))
        rr.append(RRInterval(ts: 4_000_011, rrMs: 9_000))
        let clean = StressHistory.series(rr: rr)
        XCTAssertFalse(clean.isEmpty)
        XCTAssertTrue(clean.allSatisfy { $0.index.isFinite && $0.index > 0 })
    }

    func testSummarySharesSumToOne() {
        let rr = beats(from: 5_000_000, count: 4 * 60) { i in 800 + (i % 9) * 25 }
        let series = StressHistory.series(rr: rr)
        guard let s = StressHistory.summary(series) else { return XCTFail("expected a summary") }
        XCTAssertEqual(s.calmShare + s.elevatedShare + s.highShare, 1.0, accuracy: 0.0001)
        XCTAssertEqual(s.binCount, series.count)
        XCTAssertGreaterThan(s.coveredMinutes, 0)
        XCTAssertGreaterThanOrEqual(s.peak, s.average)
    }

    func testSmoothingPreservesTimestampsAndLength() {
        let rr = beats(from: 6_000_000, count: 6 * 60) { i in 800 + (i % 6) * 30 }
        let series = StressHistory.series(rr: rr)
        let smooth = StressHistory.smoothed(series)
        XCTAssertEqual(smooth.count, series.count)
        XCTAssertEqual(smooth.map(\.ts), series.map(\.ts))
    }

    func testBandThresholdsMatchTheLegend() {
        XCTAssertEqual(BaevskyStress.band(for: 100), .calm)
        XCTAssertEqual(BaevskyStress.band(for: 300), .elevated)
        XCTAssertEqual(BaevskyStress.band(for: 900), .high)
    }
}
