import XCTest
import WhoopProtocol
import WhoopStore
@testable import OpenWhoop

@MainActor
final class CollectorTests: XCTestCase {
    private func hex(_ s: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(s.count / 2)
        var i = s.startIndex
        while i < s.endIndex { let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j }
        return out
    }
    // Real REALTIME_DATA frame (HR=60) — produces one HR decoded sample.
    private let hr60 = "aa1800ff28020f3de10128663c00000000000000000001010d844e7c"

    private func makeStore() async throws -> WhoopStore {
        let store = try await WhoopStore(path: ":memory:")
        try await store.upsertDevice(id: "my-whoop", mac: nil, name: "test")
        return store
    }

    func testBuffersWithoutPersistingUntilClockRefSet() async throws {
        let store = try await makeStore()
        let c = Collector(store: store, deviceId: "my-whoop",
                          policy: .init(maxFrames: 1, maxInterval: 60))
        c.ingest(hex(hr60))
        let stats = try await store.storageStats()
        XCTAssertEqual(stats.decodedRows, 0, "no persist before a ClockRef")
        XCTAssertEqual(stats.rawBatches, 0)
        XCTAssertEqual(c.bufferedCount, 1)
    }

    func testFrameThresholdPersistsDecodedAndEnqueuesRaw() async throws {
        let store = try await makeStore()
        let c = Collector(store: store, deviceId: "my-whoop",
                          policy: .init(maxFrames: 2, maxInterval: 60),
                          enableRawCapture: true)
        c.clockRef = ClockRef(device: 1_700_000_000, wall: 1_716_400_000)
        c.ingest(hex(hr60))
        let statsBefore = try await store.storageStats()
        XCTAssertEqual(statsBefore.rawBatches, 0, "below threshold")
        c.ingest(hex(hr60))   // hits maxFrames=2 → threshold reached; flush explicitly for determinism
        await c.flush()
        let stats = try await store.storageStats()
        XCTAssertGreaterThan(stats.decodedRows, 0, "decoded HR samples persisted")
        XCTAssertEqual(stats.rawBatches, 1, "one raw batch enqueued")
        XCTAssertEqual(c.bufferedCount, 0, "buffer cleared after flush")
    }

    func testFlushDrainsPartialBuffer() async throws {
        let store = try await makeStore()
        let c = Collector(store: store, deviceId: "my-whoop",
                          policy: .init(maxFrames: 100, maxInterval: 3600),
                          enableRawCapture: true)
        c.clockRef = ClockRef(device: 1_700_000_000, wall: 1_716_400_000)
        c.ingest(hex(hr60))
        await c.flush()
        let stats = try await store.storageStats()
        XCTAssertEqual(stats.rawBatches, 1)
        XCTAssertGreaterThan(stats.decodedRows, 0)
    }

    func testIntervalCadenceTriggersFlush() async throws {
        var fakeTime: TimeInterval = 0
        let store = try await makeStore()
        let c = Collector(store: store, deviceId: "my-whoop",
                          policy: .init(maxFrames: 100, maxInterval: 5),
                          enableRawCapture: true,
                          monotonic: { fakeTime })
        c.clockRef = ClockRef(device: 1_700_000_000, wall: 1_716_400_000)
        c.ingest(hex(hr60))                             // buffered, below frame threshold
        let statsBefore = try await store.storageStats()
        XCTAssertEqual(statsBefore.rawBatches, 0)
        fakeTime = 6                                    // advance past maxInterval (5s)
        c.ingest(hex(hr60))                             // elapsed >= maxInterval → threshold reached; flush explicitly for determinism
        await c.flush()
        let stats = try await store.storageStats()
        XCTAssertEqual(stats.rawBatches, 1)
        XCTAssertEqual(c.bufferedCount, 0)
    }

    func testPreClockBufferIsCappedDropOldest() async throws {
        let store = try await makeStore()
        let c = Collector(store: store, deviceId: "my-whoop",
                          policy: .init(maxFrames: 1000, maxInterval: 3600, maxPreClockFrames: 3))
        // No clockRef set → frames buffer but are capped at 3 (oldest dropped).
        for _ in 0..<10 { c.ingest(hex(hr60)) }
        XCTAssertEqual(c.bufferedCount, 3, "pre-clock buffer capped, oldest dropped")
        let stats = try await store.storageStats()
        XCTAssertEqual(stats.decodedRows, 0, "still nothing persisted pre-clock")
    }

    // MARK: - REGRESSION: pre-clock buffered frames get the CORRECT ts once the clock lands

    /// Audit 4.2 (clock-correlation edge case): frames that arrive BEFORE GET_CLOCK lands are
    /// buffered un-persisted; once `clockRef` is set and we flush, those buffered frames must be
    /// persisted with the CORRECT wall ts (device ts → wall via the clock offset), not dropped and
    /// not mis-timestamped. The hr60 fixture's device ts is 31_538_447; with a clockRef whose
    /// `device` equals that value the mapped wall ts is exactly `wall` (offset = wall − device → 0).
    func testPreClockFramesFlushWithCorrectTsOnceClockLands() async throws {
        let store = try await makeStore()
        let c = Collector(store: store, deviceId: "my-whoop",
                          policy: .init(maxFrames: 100, maxInterval: 3600))   // no auto-flush
        // Ingest BEFORE any clockRef — frame buffers, nothing persisted yet.
        c.ingest(hex(hr60))
        XCTAssertEqual(c.bufferedCount, 1)
        let preClockRows = try await store.storageStats().decodedRows
        XCTAssertEqual(preClockRows, 0, "nothing persisted pre-clock")

        // Clock lands. device == the frame's device ts → wall offset is 0, so mapped ts == wall.
        let wall = 1_716_400_000
        c.clockRef = ClockRef(device: 31_538_447, wall: wall)
        await c.flush()

        let hr = try await store.hrSamples(deviceId: "my-whoop", from: 0, to: Int.max, limit: 10)
        XCTAssertEqual(hr.count, 1, "buffered pre-clock frame is persisted once the clock lands")
        XCTAssertEqual(hr[0].ts, wall, "pre-clock frame mapped to the CORRECT wall ts, not dropped")
        XCTAssertEqual(hr[0].bpm, 60)
        XCTAssertEqual(c.bufferedCount, 0, "buffer drained after the post-clock flush")
    }

    func testDecodedPersistedBeforeRawEnqueued() async throws {
        // Ordering invariant: a store that fails raw enqueue must still have decoded rows.
        let real = try await makeStore()
        let spy = SpyStore(wrapping: real, failRawEnqueue: true)
        let c = Collector(store: spy, deviceId: "my-whoop",
                          policy: .init(maxFrames: 1, maxInterval: 60),
                          enableRawCapture: true)
        c.clockRef = ClockRef(device: 1_700_000_000, wall: 1_716_400_000)
        c.ingest(hex(hr60))   // insert succeeds, enqueueRawBatch throws; flush explicitly for determinism
        await c.flush()
        let decodedRows = try await real.storageStats().decodedRows
        XCTAssertGreaterThan(decodedRows, 0,
                             "decoded committed before raw attempted")
    }

    // MARK: - raw capture toggle

    func testRawNotEnqueuedWhenToggleOffByDefault() async throws {
        let real = try await makeStore()
        let spy = SpyStore(wrapping: real, failRawEnqueue: false)
        // No enableRawCapture passed → defaults OFF.
        let c = Collector(store: spy, deviceId: "my-whoop",
                          policy: .init(maxFrames: 1, maxInterval: 60))
        c.clockRef = ClockRef(device: 1_700_000_000, wall: 1_716_400_000)
        c.ingest(hex(hr60))
        await c.flush()
        let decodedRows = try await real.storageStats().decodedRows
        XCTAssertGreaterThan(decodedRows, 0, "decoded still persisted with raw OFF")
        XCTAssertEqual(spy.rawEnqueueCount, 0, "enqueueRawBatch must NOT be called when toggle OFF")
    }

    func testRawEnqueuedWhenToggleOn() async throws {
        let real = try await makeStore()
        let spy = SpyStore(wrapping: real, failRawEnqueue: false)
        let c = Collector(store: spy, deviceId: "my-whoop",
                          policy: .init(maxFrames: 1, maxInterval: 60),
                          enableRawCapture: true)
        c.clockRef = ClockRef(device: 1_700_000_000, wall: 1_716_400_000)
        c.ingest(hex(hr60))
        await c.flush()
        XCTAssertEqual(spy.rawEnqueueCount, 1, "enqueueRawBatch IS called when toggle ON")
    }

    // MARK: - on-demand raw capture window (toggle OFF)

    func testOnDemandWindowEnqueuesRawWhileActive() async throws {
        var fakeTime: TimeInterval = 100
        let real = try await makeStore()
        let spy = SpyStore(wrapping: real, failRawEnqueue: false)
        // Toggle OFF by default — only the on-demand window should enable raw.
        let c = Collector(store: spy, deviceId: "my-whoop",
                          policy: .init(maxFrames: 1, maxInterval: 60),
                          monotonic: { fakeTime })
        c.clockRef = ClockRef(device: 1_700_000_000, wall: 1_716_400_000)
        c.beginRawCapture(seconds: 60)          // window: [100, 160]
        fakeTime = 130                          // INSIDE the window
        c.ingest(hex(hr60))
        await c.flush()
        XCTAssertEqual(spy.rawEnqueueCount, 1,
                       "raw enqueued while the on-demand window is active even with toggle OFF")
    }

    func testOnDemandWindowDoesNotEnqueueAfterExpiry() async throws {
        var fakeTime: TimeInterval = 100
        let real = try await makeStore()
        let spy = SpyStore(wrapping: real, failRawEnqueue: false)
        let c = Collector(store: spy, deviceId: "my-whoop",
                          policy: .init(maxFrames: 1, maxInterval: 60),
                          monotonic: { fakeTime })
        c.clockRef = ClockRef(device: 1_700_000_000, wall: 1_716_400_000)
        c.beginRawCapture(seconds: 60)          // window: [100, 160]
        fakeTime = 200                          // PAST the deadline
        c.ingest(hex(hr60))
        await c.flush()
        let decodedRows = try await real.storageStats().decodedRows
        XCTAssertGreaterThan(decodedRows, 0, "decoded still persisted after window expiry")
        XCTAssertEqual(spy.rawEnqueueCount, 0,
                       "raw NOT enqueued once the on-demand window has expired (toggle OFF)")
    }

    func testEndRawCaptureFlushesThenCloses() async throws {
        var fakeTime: TimeInterval = 100
        let real = try await makeStore()
        let spy = SpyStore(wrapping: real, failRawEnqueue: false)
        let c = Collector(store: spy, deviceId: "my-whoop",
                          policy: .init(maxFrames: 100, maxInterval: 3600),   // no auto-flush
                          monotonic: { fakeTime })
        c.clockRef = ClockRef(device: 1_700_000_000, wall: 1_716_400_000)
        c.beginRawCapture(seconds: 60)          // window: [100, 160]
        fakeTime = 130
        c.ingest(hex(hr60))                     // buffered, below frame threshold
        await c.endRawCapture()                 // flushes WHILE active → raw enqueued, then closes
        XCTAssertEqual(spy.rawEnqueueCount, 1, "endRawCapture flushes buffered frames as raw")
        // After close, a subsequent flush inside the old window must NOT enqueue raw.
        c.ingest(hex(hr60))
        await c.flush()
        XCTAssertEqual(spy.rawEnqueueCount, 1, "window closed → no further raw enqueue")
    }

    // MARK: - Standard BLE Heart Rate (0x2A37) live path

    func testStandardHRPersistsWithoutClockRef() async throws {
        let store = try await makeStore()
        let c = Collector(store: store, deviceId: "my-whoop",
                          policy: .init(maxFrames: 100, maxInterval: 3600))
        // No clockRef at all -- this path must not depend on it (2A37 needs no correlation).
        c.ingestStandardHR(bpm: 61, rrMs: [800])
        await c.flushStandardHR()
        let hr = try await store.hrSamples(deviceId: "my-whoop", from: 0, to: Int.max, limit: 10)
        let rr = try await store.rrIntervals(deviceId: "my-whoop", from: 0, to: Int.max, limit: 10)
        XCTAssertEqual(hr.count, 1)
        XCTAssertEqual(hr[0].bpm, 61)
        XCTAssertEqual(rr.count, 1)
        XCTAssertEqual(rr[0].rrMs, 800)
    }

    func testStandardHRIgnoresNonPositiveBpm() async throws {
        let store = try await makeStore()
        let c = Collector(store: store, deviceId: "my-whoop",
                          policy: .init(maxFrames: 100, maxInterval: 3600))
        c.ingestStandardHR(bpm: 0, rrMs: [])
        XCTAssertEqual(c.standardBufferedCount, 0, "non-positive bpm must not be buffered")
    }

    func testStandardHRThresholdTriggersAutoFlush() async throws {
        let store = try await makeStore()
        let c = Collector(store: store, deviceId: "my-whoop",
                          policy: .init(maxFrames: 100, maxInterval: 3600))
        for _ in 0..<20 { c.ingestStandardHR(bpm: 60, rrMs: []) }   // hits the 20-reading threshold
        // The auto-flush is a detached Task; give it a beat to run.
        try await Task.sleep(nanoseconds: 200_000_000)
        let hr = try await store.hrSamples(deviceId: "my-whoop", from: 0, to: Int.max, limit: 50)
        XCTAssertEqual(hr.count, 20)
        XCTAssertEqual(c.standardBufferedCount, 0)
    }

    func testGenericFlushAlsoDrainsStandardHRBuffer() async throws {
        let store = try await makeStore()
        let c = Collector(store: store, deviceId: "my-whoop",
                          policy: .init(maxFrames: 100, maxInterval: 3600))
        c.ingestStandardHR(bpm: 58, rrMs: [])   // below the standalone threshold
        XCTAssertEqual(c.standardBufferedCount, 1)
        await c.flush()   // the same flush() the app calls on disconnect
        XCTAssertEqual(c.standardBufferedCount, 0, "flush() must drain standard-HR readings too")
        let hr = try await store.hrSamples(deviceId: "my-whoop", from: 0, to: Int.max, limit: 10)
        XCTAssertEqual(hr.count, 1)
    }
}

/// Test double proving decoded-before-raw ordering (WhoopStore is final → protocol seam).
@MainActor
final class SpyStore: StoreWriting {
    private let wrapped: WhoopStore
    private let failRawEnqueue: Bool
    private(set) var rawEnqueueCount = 0
    init(wrapping: WhoopStore, failRawEnqueue: Bool) {
        self.wrapped = wrapping; self.failRawEnqueue = failRawEnqueue
    }
    func insert(_ streams: Streams, deviceId: String, markSynced: Bool) async throws
        -> (hr: Int, rr: Int, events: Int, battery: Int,
            spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
        try await wrapped.insert(streams, deviceId: deviceId, markSynced: markSynced)
    }
    func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws {
        rawEnqueueCount += 1
        struct RawEnqueueFailed: Error {}
        if failRawEnqueue { throw RawEnqueueFailed() }
        try await wrapped.enqueueRawBatch(meta, frames: frames)
    }
}
