import XCTest
import WhoopProtocol
@testable import OpenWhoop

/// Covers the sleep stager: the feature pipeline (30-s epochs, Gaussian-smoothed motion,
/// difference-of-Gaussians heart rate) and the stage rules taken from sleep physiology.
final class SleepStagingTests: XCTestCase {

    private let night = 1_700_000_000    // arbitrary fixed "lights out"

    // MARK: - Fixture builders

    /// One synthetic night: HR every 30 s following `bpm(minute)`, motion every 30 s following
    /// `move(minute)` (0 = perfectly still).
    private func fixture(minutes: Int,
                         bpm: (Int) -> Double,
                         move: (Int) -> Double) -> ([HRSample], [GravitySample]) {
        var hr: [HRSample] = []
        var motion: [GravitySample] = []
        var drift = 0.0
        for step in 0..<(minutes * 2) {
            let ts = night + step * 30
            let minute = step / 2
            hr.append(HRSample(ts: ts, bpm: Int(bpm(minute).rounded())))
            // Motion is expressed as how far the gravity vector moves between samples.
            drift += move(minute)
            motion.append(GravitySample(ts: ts, x: drift, y: 0, z: 1))
        }
        return (hr, motion)
    }

    private func rrFor(hr: [HRSample], jitter: (Int) -> Int) -> [RRInterval] {
        var out: [RRInterval] = []
        for (i, s) in hr.enumerated() where s.bpm > 0 {
            let mean = 60_000 / s.bpm
            for k in 0..<20 {
                out.append(RRInterval(ts: s.ts + k / 4, rrMs: mean + jitter(i + k)))
            }
        }
        return out
    }

    // MARK: - Guard rails

    func testTooShortAWindowIsNotStaged() {
        let (hr, motion) = fixture(minutes: 20, bpm: { _ in 55 }, move: { _ in 0 })
        XCTAssertNil(SleepStaging.stage(hr: hr, rr: [], motion: motion,
                                        from: night, to: night + 20 * 60))
    }

    func testTooSparseHeartRateIsNotStaged() {
        // One sample every 10 minutes is below the density the epochs need.
        let hr = (0..<40).map { HRSample(ts: night + $0 * 600, bpm: 55) }
        XCTAssertNil(SleepStaging.stage(hr: hr, rr: [], motion: [],
                                        from: night, to: night + 400 * 60),
                     "too little data must yield nothing rather than a plausible-looking guess")
    }

    // MARK: - Whole-night behaviour

    /// A night shaped like a real one: quiet low-HR blocks (deep), a raised-HR but motionless
    /// block late on (REM), and a restless block with movement (wake).
    private func realisticNight() -> ([HRSample], [RRInterval], [GravitySample]) {
        let (hr, motion) = fixture(
            minutes: 420,
            bpm: { m in
                switch m {
                case ..<30:     return 62          // settling
                case 30..<120:  return 48          // deep
                case 120..<180: return 55          // light
                case 180..<220: return 66          // REM-ish: up, but still
                case 220..<300: return 52          // light/deep mix
                case 300..<330: return 72          // awake, restless
                default:        return 56
                }
            },
            move: { m in (300..<330).contains(m) ? 0.05 : 0.0 })
        let rr = rrFor(hr: hr) { i in (i % 7) * 8 - 24 }
        return (hr, rr, motion)
    }

    func testStagesCoverTheWholeWindowWithoutOverlap() {
        let (hr, rr, motion) = realisticNight()
        guard let r = SleepStaging.stage(hr: hr, rr: rr, motion: motion,
                                         from: night, to: night + 420 * 60) else {
            return XCTFail("expected a staging result")
        }
        XCTAssertFalse(r.stages.isEmpty)
        XCTAssertEqual(r.stages.first?.start, night)
        for i in 1..<r.stages.count {
            XCTAssertEqual(r.stages[i].start, r.stages[i - 1].end,
                           "segments must be contiguous — no gaps, no overlaps")
        }
        let total = r.deepMinutes + r.remMinutes + r.lightMinutes + r.wakeMinutes
        XCTAssertEqual(total, 420, accuracy: 1.0)
    }

    func testMotionIsUsedWhenPresentAndReportedWhenNot() {
        let (hr, rr, motion) = realisticNight()
        let withMotion = SleepStaging.stage(hr: hr, rr: rr, motion: motion,
                                            from: night, to: night + 420 * 60)
        XCTAssertEqual(withMotion?.usedMotion, true)

        let without = SleepStaging.stage(hr: hr, rr: rr, motion: [],
                                         from: night, to: night + 420 * 60)
        XCTAssertEqual(without?.usedMotion, false,
                       "staging without motion must say so rather than claim the same confidence")
    }

    func testRestlessHighHeartRateBlockIsScoredAsWake() {
        let (hr, rr, motion) = realisticNight()
        guard let r = SleepStaging.stage(hr: hr, rr: rr, motion: motion,
                                         from: night, to: night + 420 * 60) else {
            return XCTFail("expected a staging result")
        }
        let restlessStart = night + 300 * 60
        let overlapping = r.stages.filter { $0.end > restlessStart && $0.start < restlessStart + 1800 }
        XCTAssertTrue(overlapping.contains { $0.stage == "wake" },
                      "movement plus an elevated heart rate is the definition of awake here")
    }

    func testNoRemIsScoredInTheFirstHalfHour() {
        let (hr, rr, motion) = realisticNight()
        guard let r = SleepStaging.stage(hr: hr, rr: rr, motion: motion,
                                         from: night, to: night + 420 * 60) else {
            return XCTFail("expected a staging result")
        }
        let early = r.stages.filter { $0.start < night + SleepStaging.remLockoutSeconds }
        XCTAssertFalse(early.contains { $0.stage == "rem" },
                       "REM latency: the settling-down period must not be scored as REM")
    }

    func testEveryBoutIsAtLeastTheMinimumLength() {
        let (hr, rr, motion) = realisticNight()
        guard let r = SleepStaging.stage(hr: hr, rr: rr, motion: motion,
                                         from: night, to: night + 420 * 60) else {
            return XCTFail("expected a staging result")
        }
        let minSeconds = SleepStaging.minBoutEpochs * SleepStaging.epochSeconds
        for s in r.stages {
            XCTAssertGreaterThanOrEqual(s.end - s.start, minSeconds,
                                        "single-epoch flicker must be smoothed away")
        }
    }

    func testStagesJSONRoundTripsThroughTheHypnogramParser() {
        let stages = [SleepStage(start: night, end: night + 600, stage: "light"),
                      SleepStage(start: night + 600, end: night + 1800, stage: "deep")]
        guard let json = SleepStaging.stagesJSON(stages) else { return XCTFail("no JSON") }
        guard let parsed = parseStages(json) else { return XCTFail("hypnogram could not parse it") }
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[1].stage, "deep")
        XCTAssertEqual(parsed[0].start, Double(night))
    }

    // MARK: - Signal helpers

    func testGapFillingInterpolatesRatherThanZeroing() {
        var values: [Double] = [60, 0, 0, 66]
        SleepStaging.fillGaps(&values, have: [true, false, false, true])
        XCTAssertEqual(values[1], 62, accuracy: 0.5)
        XCTAssertEqual(values[2], 64, accuracy: 0.5)
    }

    func testGaussianSmoothingKeepsTheMeanAndLength() {
        let values = (0..<40).map { Double(50 + ($0 % 5) * 4) }
        let smooth = SleepStaging.gaussianSmooth(values, sigmaEpochs: 2)
        XCTAssertEqual(smooth.count, values.count)
        let a = values.reduce(0, +) / Double(values.count)
        let b = smooth.reduce(0, +) / Double(smooth.count)
        XCTAssertEqual(b, a, accuracy: 1.0)
    }

    func testMinimumBoutEnforcementAbsorbsShortRuns() {
        var labels = [String](repeating: "light", count: 40)
        labels[20] = "rem"          // a single stray epoch
        let cleaned = SleepStaging.enforceMinimumBouts(labels)
        XCTAssertFalse(cleaned.contains("rem"))
    }
}
