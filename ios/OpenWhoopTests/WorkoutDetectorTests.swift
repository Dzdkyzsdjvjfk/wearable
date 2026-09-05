import XCTest
import WhoopProtocol
@testable import OpenWhoop

/// Covers on-device workout detection — what makes the Workouts tab work with no server.
final class WorkoutDetectorTests: XCTestCase {

    private let base = 1_700_000_000   // arbitrary fixed epoch

    /// HR samples every 10 s for `minutes` minutes at `bpm`, starting `offsetMin` after `base`.
    private func samples(offsetMin: Int, minutes: Int, bpm: Int) -> [HRSample] {
        let start = base + offsetMin * 60
        return stride(from: 0, to: minutes * 60, by: 10).map {
            HRSample(ts: start + $0, bpm: bpm)
        }
    }

    private func detect(_ hr: [HRSample],
                        restingHr: Int? = 60,
                        age: Int? = 30,
                        weightKg: Double? = nil) -> [Workout] {
        WorkoutDetector.detect(hr: hr, deviceId: "my-whoop", restingHr: restingHr,
                               age: age, weightKg: weightKg)
    }

    // MARK: - Detection

    func testNoDataYieldsNoWorkouts() {
        XCTAssertTrue(detect([]).isEmpty)
    }

    func testQuietDayYieldsNoWorkouts() {
        // A whole hour at 70 bpm: above resting, nowhere near 40 % heart-rate reserve (112 bpm).
        XCTAssertTrue(detect(samples(offsetMin: 0, minutes: 60, bpm: 70)).isEmpty)
    }

    func testSustainedElevatedHeartRateIsDetectedAsOneBout() {
        let hr = samples(offsetMin: 0, minutes: 20, bpm: 65)
            + samples(offsetMin: 20, minutes: 30, bpm: 150)
            + samples(offsetMin: 50, minutes: 20, bpm: 65)
        let found = detect(hr)
        XCTAssertEqual(found.count, 1)
        let w = found[0]
        XCTAssertEqual(w.durationS, 30 * 60, accuracy: 120)
        XCTAssertEqual(w.avgHr, 150, accuracy: 3)
        XCTAssertEqual(w.peakHr, 150)
        XCTAssertEqual(w.startTs, base + 20 * 60, accuracy: 120)
        XCTAssertNotNil(w.strain)
        XCTAssertNil(w.kind, "sport type is never guessed from heart rate alone")
    }

    func testShortBurstBelowMinimumDurationIsIgnored() {
        // Five hard minutes is a flight of stairs, not a workout.
        let hr = samples(offsetMin: 0, minutes: 15, bpm: 65)
            + samples(offsetMin: 15, minutes: 5, bpm: 160)
            + samples(offsetMin: 20, minutes: 15, bpm: 65)
        XCTAssertTrue(detect(hr).isEmpty)
    }

    func testShortDipInsideABoutDoesNotSplitIt() {
        // A two-minute rest between sets must not turn one session into two.
        let hr = samples(offsetMin: 0, minutes: 10, bpm: 65)
            + samples(offsetMin: 10, minutes: 12, bpm: 150)
            + samples(offsetMin: 22, minutes: 2, bpm: 95)     // rest, still above the exit floor
            + samples(offsetMin: 24, minutes: 12, bpm: 150)
            + samples(offsetMin: 36, minutes: 10, bpm: 65)
        let found = detect(hr)
        XCTAssertEqual(found.count, 1, "a short dip must be bridged, not split the bout")
        XCTAssertGreaterThan(found[0].durationS, 20 * 60)
    }

    func testLongGapInDataEndsTheBout() {
        // Two separate sessions hours apart must never be merged across the empty stretch.
        let hr = samples(offsetMin: 0, minutes: 20, bpm: 150)
            + samples(offsetMin: 180, minutes: 20, bpm: 150)
        let found = detect(hr)
        XCTAssertEqual(found.count, 2)
        XCTAssertLessThan(found[0].durationS, 40 * 60)
    }

    func testTwoSeparateSessionsAreTwoWorkouts() {
        let hr = samples(offsetMin: 0, minutes: 5, bpm: 65)
            + samples(offsetMin: 5, minutes: 20, bpm: 145)
            + samples(offsetMin: 25, minutes: 40, bpm: 65)
            + samples(offsetMin: 65, minutes: 25, bpm: 155)
        let found = detect(hr)
        XCTAssertEqual(found.count, 2)
        XCTAssertLessThan(found[0].startTs, found[1].startTs, "bouts come back oldest first")
    }

    func testThresholdScalesWithRestingHeartRate() {
        // 115 bpm clears the threshold for a resting-60 person but not for a resting-95 one.
        let hr = samples(offsetMin: 0, minutes: 25, bpm: 115)
        XCTAssertEqual(detect(hr, restingHr: 60).count, 1)
        XCTAssertTrue(detect(hr, restingHr: 95).isEmpty)
    }

    func testIdIsStableAcrossRuns() {
        let hr = samples(offsetMin: 10, minutes: 20, bpm: 150)
        XCTAssertEqual(detect(hr).map(\.id), detect(hr).map(\.id))
    }

    // MARK: - Zones

    func testZoneSharesSumTo100() {
        let hr = samples(offsetMin: 0, minutes: 25, bpm: 150)
        guard let w = detect(hr).first else { return XCTFail("expected a workout") }
        let total = w.zoneTimePct.values.reduce(0, +)
        XCTAssertEqual(total, 100, accuracy: 0.01)
    }

    func testZoneAssignmentFollowsPercentOfMaxHR() {
        // 150 bpm of a 190 max is 79 % → zone 3 (70–80 %).
        let bins = [(ts: 0, bpm: 150.0)]
        let dist = WorkoutDetector.zoneDistribution(bins: bins, maxHR: 190)
        XCTAssertEqual(dist[3], 100, accuracy: 0.01)
    }

    // MARK: - Calories

    func testCaloriesRequireAWeightRatherThanBeingInvented() {
        let hr = samples(offsetMin: 0, minutes: 30, bpm: 150)
        XCTAssertNil(detect(hr, weightKg: nil).first?.caloriesKcal,
                     "no body weight → no number, rather than a guessed one")
        let withWeight = detect(hr, weightKg: 75).first
        XCTAssertNotNil(withWeight?.caloriesKcal)
        // Half an hour at 150 bpm for 75 kg lands in a plausible few-hundred-kcal range.
        XCTAssertGreaterThan(withWeight?.caloriesKcal ?? 0, 150)
        XCTAssertLessThan(withWeight?.caloriesKcal ?? 9_999, 700)
        // kJ is the same energy, just converted.
        XCTAssertEqual((withWeight?.caloriesKj ?? 0) / (withWeight?.caloriesKcal ?? 1),
                       4.184, accuracy: 0.001)
    }
}
