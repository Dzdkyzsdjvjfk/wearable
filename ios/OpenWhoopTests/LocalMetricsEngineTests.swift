import XCTest
import WhoopProtocol
@testable import OpenWhoop

/// Tests for the on-device metric computation. The engine is deliberately pure (streams in,
/// values out) so every case here is built from synthetic samples with a known answer.
final class LocalMetricsEngineTests: XCTestCase {

    // MARK: - Helpers

    /// Builds HR samples at a fixed cadence: `bpm(i)` decides the value for each step.
    private func hrSeries(start: Int, count: Int, stepSeconds: Int,
                          bpm: (Int) -> Int) -> [HRSample] {
        (0..<count).map { HRSample(ts: start + $0 * stepSeconds, bpm: bpm($0)) }
    }

    /// One night: `awakeHours` at a high heart rate, then `sleepHours` at a low one.
    private func nightSeries(start: Int, awakeHours: Int, sleepHours: Int,
                             awakeBpm: Int = 75, sleepBpm: Int = 50) -> [HRSample] {
        let step = 60
        let awakeCount = awakeHours * 60
        let sleepCount = sleepHours * 60
        var out = hrSeries(start: start, count: awakeCount, stepSeconds: step) { _ in awakeBpm }
        let sleepStart = start + awakeCount * step
        out += hrSeries(start: sleepStart, count: sleepCount, stepSeconds: step) { _ in sleepBpm }
        return out
    }

    // MARK: - percentile

    func testPercentileEndpointsAndMedian() {
        let v: [Double] = [10, 20, 30, 40, 50]
        XCTAssertEqual(LocalMetricsEngine.percentile(v, 0), 10)
        XCTAssertEqual(LocalMetricsEngine.percentile(v, 1), 50)
        XCTAssertEqual(LocalMetricsEngine.percentile(v, 0.5), 30)
    }

    func testPercentileInterpolates() {
        // Between 10 and 20 at one quarter of the way across a 2-element array.
        XCTAssertEqual(LocalMetricsEngine.percentile([10, 20], 0.25)!, 12.5, accuracy: 0.001)
    }

    func testPercentileEmptyIsNil() {
        XCTAssertNil(LocalMetricsEngine.percentile([], 0.5))
    }

    func testPercentileIgnoresInputOrder() {
        XCTAssertEqual(LocalMetricsEngine.percentile([50, 10, 30, 20, 40], 0.5), 30)
    }

    // MARK: - medianBins

    func testMedianBinsGroupsByWindowAndTakesMedian() {
        // Two 5-min bins: first averages around 60, second around 100.
        var hr = hrSeries(start: 0, count: 5, stepSeconds: 60) { _ in 60 }
        hr += hrSeries(start: 300, count: 5, stepSeconds: 60) { _ in 100 }
        let bins = LocalMetricsEngine.medianBins(hr: hr, binSeconds: 300)
        XCTAssertEqual(bins.count, 2)
        XCTAssertEqual(bins[0].bpm, 60)
        XCTAssertEqual(bins[1].bpm, 100)
        XCTAssertLessThan(bins[0].ts, bins[1].ts, "bins must come out oldest-first")
    }

    func testMedianBinsDropsImplausibleSamples() {
        // 0 bpm and 300 bpm are sensor artefacts and must not reach the median.
        let hr = [HRSample(ts: 0, bpm: 0), HRSample(ts: 1, bpm: 60),
                  HRSample(ts: 2, bpm: 300), HRSample(ts: 3, bpm: 60)]
        let bins = LocalMetricsEngine.medianBins(hr: hr, binSeconds: 300)
        XCTAssertEqual(bins.count, 1)
        XCTAssertEqual(bins[0].bpm, 60)
    }

    // MARK: - Sleep detection

    func testDetectsOneNightFromLowHeartRateStretch() {
        let start = 1_700_000_000
        let hr = nightSeries(start: start, awakeHours: 4, sleepHours: 8)
        let windows = LocalMetricsEngine.detectSleepWindows(hr: hr)

        XCTAssertEqual(windows.count, 1, "one low-HR stretch should yield exactly one night")
        guard let w = windows.first else { return }
        // ~8 h of sleep, allowing a bin of slack at each edge.
        XCTAssertEqual(w.asleepMinutes, 480, accuracy: 15)
        XCTAssertGreaterThan(w.start, start, "sleep must start after the awake stretch")
        XCTAssertGreaterThan(w.efficiency, 0.9)
    }

    func testShortNapIsNotCountedAsSleep() {
        // 45 min below threshold — under the 2 h minimum, so it must be ignored.
        let hr = nightSeries(start: 1_700_000_000, awakeHours: 4, sleepHours: 0)
            + hrSeries(start: 1_700_000_000 + 4 * 3600, count: 45, stepSeconds: 60) { _ in 50 }
        XCTAssertTrue(LocalMetricsEngine.detectSleepWindows(hr: hr).isEmpty)
    }

    func testFlatHeartRateProducesNoNight() {
        // Never varies, so nothing sits meaningfully below the personal low — no sleep.
        let hr = hrSeries(start: 1_700_000_000, count: 12 * 60, stepSeconds: 60) { _ in 60 }
        XCTAssertTrue(LocalMetricsEngine.detectSleepWindows(hr: hr).isEmpty)
    }

    func testEmptyInputIsHandled() {
        XCTAssertTrue(LocalMetricsEngine.detectSleepWindows(hr: []).isEmpty)
        XCTAssertTrue(LocalMetricsEngine.computeNights(hr: [], rr: []).isEmpty)
    }

    func testBriefAwakeningDoesNotSplitTheNight() {
        let start = 1_700_000_000
        var hr = nightSeries(start: start, awakeHours: 2, sleepHours: 4)
        // 10 min awake in the middle, then 4 more hours of sleep.
        let gapStart = start + 6 * 3600
        hr += hrSeries(start: gapStart, count: 10, stepSeconds: 60) { _ in 75 }
        hr += hrSeries(start: gapStart + 600, count: 4 * 60, stepSeconds: 60) { _ in 50 }

        let windows = LocalMetricsEngine.detectSleepWindows(hr: hr)
        XCTAssertEqual(windows.count, 1, "a short awakening must not split one night in two")
        XCTAssertGreaterThanOrEqual(windows.first?.disturbances ?? 0, 1,
                                    "the awakening should still be counted as a disturbance")
    }

    // MARK: - Resting heart rate

    func testRestingHeartRateUsesLowPercentileNotTheMinimum() {
        var hr = hrSeries(start: 0, count: 100, stepSeconds: 60) { _ in 55 }
        hr.append(HRSample(ts: 6_000, bpm: 30))   // single artefactual dip
        let rhr = LocalMetricsEngine.restingHeartRate(hr: hr, from: 0, to: 10_000)
        XCTAssertEqual(rhr, 55, "one low outlier must not become the resting heart rate")
    }

    func testRestingHeartRateNeedsEnoughSamples() {
        let hr = hrSeries(start: 0, count: 5, stepSeconds: 60) { _ in 55 }
        XCTAssertNil(LocalMetricsEngine.restingHeartRate(hr: hr, from: 0, to: 10_000))
    }

    // MARK: - HRV (RMSSD)

    func testRmssdIsZeroForPerfectlyRegularBeats() {
        let rr = (0..<60).map { RRInterval(ts: $0, rrMs: 1000) }
        let v = LocalMetricsEngine.rmssd(rr: rr, from: 0, to: 100)
        XCTAssertNotNil(v)
        XCTAssertEqual(v!, 0, accuracy: 0.001)
    }

    func testRmssdGrowsWithVariability() {
        let steady = (0..<60).map { RRInterval(ts: $0, rrMs: 1000 + ($0 % 2) * 5) }
        let varied = (0..<60).map { RRInterval(ts: $0, rrMs: 1000 + ($0 % 2) * 60) }
        let a = LocalMetricsEngine.rmssd(rr: steady, from: 0, to: 100)
        let b = LocalMetricsEngine.rmssd(rr: varied, from: 0, to: 100)
        XCTAssertNotNil(a); XCTAssertNotNil(b)
        XCTAssertGreaterThan(b!, a!, "a more variable series must score a higher RMSSD")
    }

    func testRmssdNeedsEnoughBeats() {
        let rr = (0..<5).map { RRInterval(ts: $0, rrMs: 1000) }
        XCTAssertNil(LocalMetricsEngine.rmssd(rr: rr, from: 0, to: 100))
    }

    func testRmssdIgnoresPairsAcrossARecordingGap() {
        // Two clean stretches an hour apart. The junction pair must not be counted, otherwise
        // the artificial jump between stretches would inflate HRV.
        var rr = (0..<40).map { RRInterval(ts: $0, rrMs: 1000) }
        rr += (0..<40).map { RRInterval(ts: 3600 + $0, rrMs: 1000) }
        let v = LocalMetricsEngine.rmssd(rr: rr, from: 0, to: 10_000)
        XCTAssertNotNil(v)
        XCTAssertEqual(v!, 0, accuracy: 0.001)
    }

    // MARK: - Recovery

    func testRecoveryNeedsABaseline() {
        XCTAssertNil(LocalMetricsEngine.recovery(hrv: 60, restingHr: 50,
                                                 baselineHrv: [55, 58], baselineRhr: []))
    }

    func testRecoveryIsMidScaleAtBaseline() {
        let r = LocalMetricsEngine.recovery(hrv: 50, restingHr: nil,
                                            baselineHrv: [50, 50, 50], baselineRhr: [])
        XCTAssertNotNil(r)
        XCTAssertEqual(r!, 0.5, accuracy: 0.01, "HRV exactly at baseline should score ~50%")
    }

    func testRecoveryRisesAboveBaselineAndFallsBelow() {
        let base: [Double] = [50, 50, 50]
        let high = LocalMetricsEngine.recovery(hrv: 65, restingHr: nil, baselineHrv: base, baselineRhr: [])!
        let low  = LocalMetricsEngine.recovery(hrv: 35, restingHr: nil, baselineHrv: base, baselineRhr: [])!
        XCTAssertGreaterThan(high, 0.5)
        XCTAssertLessThan(low, 0.5)
    }

    func testRecoveryStaysWithinZeroToOne() {
        let base: [Double] = [50, 50, 50]
        let huge = LocalMetricsEngine.recovery(hrv: 500, restingHr: nil, baselineHrv: base, baselineRhr: [])!
        let tiny = LocalMetricsEngine.recovery(hrv: 1, restingHr: nil, baselineHrv: base, baselineRhr: [])!
        XCTAssertLessThanOrEqual(huge, 1.0)
        XCTAssertGreaterThanOrEqual(tiny, 0.0)
    }

    func testElevatedRestingHeartRateLowersRecovery() {
        let base: [Double] = [50, 50, 50]
        let rhrBase = [50, 50, 50]
        let normal  = LocalMetricsEngine.recovery(hrv: 50, restingHr: 50,
                                                  baselineHrv: base, baselineRhr: rhrBase)!
        let elevated = LocalMetricsEngine.recovery(hrv: 50, restingHr: 60,
                                                   baselineHrv: base, baselineRhr: rhrBase)!
        XCTAssertLessThan(elevated, normal)
    }

    // MARK: - Strain

    func testStrainRisesWithHarderEffort() {
        let easy = hrSeries(start: 0, count: 240, stepSeconds: 60) { _ in 70 }
        let hard = hrSeries(start: 0, count: 240, stepSeconds: 60) { _ in 150 }
        let a = LocalMetricsEngine.strain(hr: easy, from: 0, to: 20_000, restingHr: 50, maxHeartRate: 190)
        let b = LocalMetricsEngine.strain(hr: hard, from: 0, to: 20_000, restingHr: 50, maxHeartRate: 190)
        XCTAssertNotNil(a); XCTAssertNotNil(b)
        XCTAssertGreaterThan(b!, a!)
    }

    func testStrainStaysOnTheWhoopScale() {
        // An extreme day must still land inside 0...21.
        let brutal = hrSeries(start: 0, count: 1440, stepSeconds: 60) { _ in 185 }
        let v = LocalMetricsEngine.strain(hr: brutal, from: 0, to: 200_000,
                                          restingHr: 50, maxHeartRate: 190)
        XCTAssertNotNil(v)
        XCTAssertGreaterThan(v!, 0)
        XCTAssertLessThanOrEqual(v!, 21.0)
    }

    func testStrainIgnoresLongRecordingGaps() {
        // Two short bouts a day apart must not be credited with the idle day between them.
        var hr = hrSeries(start: 0, count: 60, stepSeconds: 60) { _ in 150 }
        hr += hrSeries(start: 86_400, count: 60, stepSeconds: 60) { _ in 150 }
        let gapped = LocalMetricsEngine.strain(hr: hr, from: 0, to: 200_000,
                                               restingHr: 50, maxHeartRate: 190)!
        let continuous = LocalMetricsEngine.strain(
            hr: hrSeries(start: 0, count: 120, stepSeconds: 60) { _ in 150 },
            from: 0, to: 200_000, restingHr: 50, maxHeartRate: 190)!
        XCTAssertEqual(gapped, continuous, accuracy: 0.5,
                       "the untracked day must contribute no strain")
    }

    func testStrainNeedsEnoughSamples() {
        let hr = hrSeries(start: 0, count: 5, stepSeconds: 60) { _ in 120 }
        XCTAssertNil(LocalMetricsEngine.strain(hr: hr, from: 0, to: 10_000,
                                               restingHr: 50, maxHeartRate: 190))
    }

    // MARK: - End-to-end

    func testComputeNightsProducesADailyRowWithSleepAndHeartMetrics() {
        let start = 1_700_000_000
        let hr = nightSeries(start: start, awakeHours: 4, sleepHours: 8)
        // R-R across the sleep stretch, mildly variable so RMSSD is well defined.
        let sleepStart = start + 4 * 3600
        let rr = (0..<2000).map { i in
            RRInterval(ts: sleepStart + i, rrMs: 1100 + (i % 2) * 30)
        }

        let nights = LocalMetricsEngine.computeNights(hr: hr, rr: rr)
        XCTAssertEqual(nights.count, 1)
        guard let n = nights.first else { return }

        XCTAssertNotNil(n.daily.totalSleepMin)
        XCTAssertNotNil(n.daily.restingHr)
        XCTAssertNotNil(n.daily.avgHrv)
        XCTAssertEqual(n.session.startTs, n.session.startTs)
        XCTAssertLessThan(n.session.startTs, n.session.endTs)
        XCTAssertEqual(n.daily.day.count, 10, "day key must be YYYY-MM-DD")

        // Deliberately not computed on-device — must stay nil rather than be invented.
        XCTAssertNil(n.daily.deepMin)
        XCTAssertNil(n.daily.remMin)
        XCTAssertNil(n.daily.lightMin)
        XCTAssertNil(n.daily.spo2Pct)
        XCTAssertNil(n.daily.respRateBpm)

        // Only one night, so there is no baseline yet and recovery must stay nil.
        XCTAssertNil(n.daily.recovery)
    }

    func testRecoveryAppearsOnceEnoughNightsExist() {
        // Five consecutive nights, each 4 h awake + 8 h asleep.
        var hr: [HRSample] = []
        var rr: [RRInterval] = []
        let base = 1_700_000_000
        for night in 0..<5 {
            let start = base + night * 12 * 3600
            hr += nightSeries(start: start, awakeHours: 4, sleepHours: 8)
            let sleepStart = start + 4 * 3600
            rr += (0..<2000).map { i in
                RRInterval(ts: sleepStart + i, rrMs: 1100 + (i % 2) * 30)
            }
        }
        let nights = LocalMetricsEngine.computeNights(hr: hr, rr: rr)
        XCTAssertGreaterThanOrEqual(nights.count, 4)
        XCTAssertNil(nights.first?.daily.recovery, "no baseline for the first night")
        XCTAssertNotNil(nights.last?.daily.recovery, "later nights should score against a baseline")
    }

    func testDayStringIsUTCFormatted() {
        // 1700000000 = 2023-11-14 22:13:20 UTC
        XCTAssertEqual(LocalMetricsEngine.dayString(forEpoch: 1_700_000_000), "2023-11-14")
    }
}
