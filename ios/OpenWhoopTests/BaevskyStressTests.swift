import XCTest
@testable import OpenWhoop

final class BaevskyStressTests: XCTestCase {

    func testTooFewSamplesReturnsNil() {
        let rr = Array(repeating: 800, count: 19)   // one below the minimum of 20
        XCTAssertNil(BaevskyStress.index(rrMs: rr))
    }

    func testPerfectlyRegularRhythmIsGuardedNotCrashed() {
        // A perfectly flat RR series has MxDMn == 0, which would divide by zero — must return
        // nil rather than +inf/NaN.
        let rr = Array(repeating: 800, count: 40)
        XCTAssertNil(BaevskyStress.index(rrMs: rr))
    }

    func testArtefactFilteringLeavesTooFewSamples() {
        // 15 clean beats + 10 obvious artefacts (< 300ms / > 2000ms) — after filtering, 15 < 20.
        var rr = Array(repeating: 800, count: 15)
        rr.append(contentsOf: Array(repeating: 100, count: 5))
        rr.append(contentsOf: Array(repeating: 2500, count: 5))
        XCTAssertNil(BaevskyStress.index(rrMs: rr))
    }

    func testLowVariabilityYieldsHigherIndexThanHighVariability() {
        // Low-variability window: RR clustered tightly around 800ms → small MxDMn → high SI.
        let lowVariability = (0..<40).map { i in 790 + (i % 3) * 10 }   // 790, 800, 810…
        // High-variability window: RR spread widely around the same mean → larger MxDMn → lower SI.
        let highVariability = (0..<40).map { i in 700 + (i % 9) * 25 } // 700...900 spread

        guard let low = BaevskyStress.index(rrMs: lowVariability),
              let high = BaevskyStress.index(rrMs: highVariability) else {
            return XCTFail("expected both windows to produce a valid index")
        }
        XCTAssertGreaterThan(low, high,
            "a tightly-clustered RR window (low HRV) should score a higher Stress Index than a widely-spread one")
    }

    func testBandThresholds() {
        XCTAssertEqual(BaevskyStress.band(for: 0), .calm)
        XCTAssertEqual(BaevskyStress.band(for: 149.9), .calm)
        XCTAssertEqual(BaevskyStress.band(for: 150), .elevated)
        XCTAssertEqual(BaevskyStress.band(for: 499.9), .elevated)
        XCTAssertEqual(BaevskyStress.band(for: 500), .high)
        XCTAssertEqual(BaevskyStress.band(for: 2000), .high)
    }
}
