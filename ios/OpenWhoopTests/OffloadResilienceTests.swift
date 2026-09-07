import XCTest
import WhoopProtocol
@testable import OpenWhoop

/// Covers the defences added after two days away produced no data at all: timestamp vetting on
/// the historical offload, the sanity window on the strap's reported newest record, and the
/// sleep detector's night fallback for data that has no day/night contrast.
@MainActor
final class OffloadResilienceTests: XCTestCase {

    private let now = 1_788_757_000

    // MARK: - Timestamp plausibility

    func testPlausibleWindowAcceptsRecentAndRejectsTheAbsurd() {
        XCTAssertTrue(Backfiller.isPlausible(now, now: now))
        XCTAssertTrue(Backfiller.isPlausible(now - 30 * 86_400, now: now), "a month ago is fine")
        XCTAssertFalse(Backfiller.isPlausible(now + 3 * 86_400, now: now),
                       "records from the future mean the strap's clock is wrong")
        XCTAssertFalse(Backfiller.isPlausible(now - 500 * 86_400, now: now))
        XCTAssertFalse(Backfiller.isPlausible(0, now: now), "an RTC reset to the epoch")
    }

    // MARK: - Strap's reported newest record

    private func dataRangeFrame(_ value: Int) -> [UInt8] {
        var f: [UInt8] = [0xAA, 0, 0, 0, 0, 0, 0]
        f += [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
              UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
        return f
    }

    func testDataRangeReadsARecentRecordTime() {
        XCTAssertEqual(BLEManager.dataRangeNewestUnix(from: dataRangeFrame(now - 3600), now: now),
                       now - 3600)
    }

    /// A strap whose RTC is years out still answers GET_DATA_RANGE, and that answer is the
    /// measurement that rescues its backlog — so it has to survive the filter, not be discarded as
    /// noise the way it once was.
    func testDataRangeKeepsAStrapClockThatIsYearsOut() {
        XCTAssertEqual(BLEManager.dataRangeNewestUnix(from: dataRangeFrame(1_879_172_133), now: now),
                       1_879_172_133,
                       "three years ahead is a broken clock we can correct for, not a byte pattern")
    }

    /// The window still has to reject words that cannot be any clock at all, or the liveness check
    /// goes back to reporting nonsense.
    func testDataRangeStillRejectsWordsThatAreNoClockAtAll() {
        XCTAssertNil(BLEManager.dataRangeNewestUnix(from: dataRangeFrame(0), now: now))
        XCTAssertNil(BLEManager.dataRangeNewestUnix(from: dataRangeFrame(now + 40 * 365 * 86_400),
                                                    now: now))
    }

    // MARK: - Sleep detection without day/night contrast

    /// Local midnight, so the synthetic night lands where a night belongs on the clock.
    private func midnight(daysAgo: Int) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let day = cal.startOfDay(for: Date().addingTimeInterval(TimeInterval(-daysAgo * 86_400)))
        return Int(day.timeIntervalSince1970)
    }

    /// Sleep-like heart rate: a slow wander of several bpm across the night, which is what a
    /// living heart does and a stuck sensor does not.
    private func samples(from: Int, hours: Double, bpm: Int, step: Int = 60) -> [HRSample] {
        stride(from: 0, to: Int(hours * 3600), by: step).map { offset -> HRSample in
            let minute = Double(offset) / 60.0
            let wander = Int((sin(minute / 37.0) * 2).rounded())   // ±2 bpm over ~4 h — enough to be
            // alive, too little for the day/night contrast rule, so this exercises the fallback
            return HRSample(ts: from + offset, bpm: bpm + wander)
        }
    }

    /// The case that used to yield nothing: the strap recorded the nights, the phone was away all
    /// day, so the handed-over stretch has no waking heart rate to contrast against.
    func testNightOnlyDataIsStillDetectedAsSleep() {
        // 23:00 → 07:00 across two nights, nothing in between.
        let n1 = midnight(daysAgo: 2) - 3600      // 23:00 the evening before
        let n2 = midnight(daysAgo: 1) - 3600
        let hr = samples(from: n1, hours: 8, bpm: 50) + samples(from: n2, hours: 8, bpm: 51)

        let windows = LocalMetricsEngine.detectSleepWindows(hr: hr)
        XCTAssertFalse(windows.isEmpty,
                       "a recorded night must not be discarded just because the day is missing")
        XCTAssertGreaterThan(windows.first?.asleepMinutes ?? 0, 300)
    }

    /// The thing the contrast guard was protecting against must still be rejected: a flat trace
    /// with no night in it at all (a strap left on a desk during the day).
    func testFlatDaytimeTraceIsStillRejected() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let noon = cal.startOfDay(for: Date().addingTimeInterval(-86_400)).addingTimeInterval(11 * 3600)
        let hr = samples(from: Int(noon.timeIntervalSince1970), hours: 8, bpm: 62)

        XCTAssertTrue(LocalMetricsEngine.detectSleepWindows(hr: hr).isEmpty,
                      "eight flat midday hours are not a night")
    }

    /// An unbroken stretch far longer than a night is a sensor that stopped varying, not sleep.
    func testImplausiblyLongStretchIsRejectedWithoutContrast() {
        let start = midnight(daysAgo: 2) - 3600           // 23:00
        let hr = samples(from: start, hours: 14, bpm: 50)
        XCTAssertTrue(LocalMetricsEngine.detectSleepWindows(hr: hr).isEmpty,
                      "fourteen unbroken hours is not one night")
    }

    func testSpansTheNightRecognisesTheSmallHours() {
        let base = midnight(daysAgo: 1)
        XCTAssertTrue(LocalMetricsEngine.spansTheNight(from: base + 3600, to: base + 5 * 3600))
        XCTAssertFalse(LocalMetricsEngine.spansTheNight(from: base + 10 * 3600, to: base + 16 * 3600))
    }
}
