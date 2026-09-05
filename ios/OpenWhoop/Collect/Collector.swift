import Foundation
import WhoopProtocol
import WhoopStore

/// The subset of WhoopStore the Collector needs. A protocol so tests can inject a spy
/// (WhoopStore is `final`). WhoopStore conforms via the extension below.
/// Not @MainActor — the WhoopStore actor's async methods satisfy the async requirements;
/// a @MainActor SpyStore in tests also conforms (async witnesses hop actors).
protocol StoreWriting: AnyObject {
    @discardableResult
    func insert(_ streams: Streams, deviceId: String, markSynced: Bool) async throws
        -> (hr: Int, rr: Int, events: Int, battery: Int,
            spo2: Int, skinTemp: Int, resp: Int, gravity: Int)
    func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws
}
extension StoreWriting {
    /// Source-compat shim: existing callers (Collector live, Backfiller) call `insert(_:deviceId:)`
    /// with no `markSynced`, meaning the rows still need uploading (synced = 0).
    @discardableResult
    func insert(_ streams: Streams, deviceId: String) async throws
        -> (hr: Int, rr: Int, events: Int, battery: Int,
            spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
        try await insert(streams, deviceId: deviceId, markSynced: false)
    }
}
extension WhoopStore: StoreWriting {}

/// Cadence: flush after this many buffered frames OR this many seconds since the last
/// flush — whichever first. Also flushed explicitly on disconnect/foreground.
struct CollectorPolicy {
    var maxFrames: Int
    var maxInterval: TimeInterval
    /// Defensive cap on the PRE-CLOCK buffer only (see `ingest`). Generous default —
    /// ~4096 frames at ~60 bytes/frame is ~240KB, far beyond the handful seen pre-clock
    /// normally. Custom init keeps `.init(maxFrames:maxInterval:)` call sites compiling.
    var maxPreClockFrames: Int
    /// Flush cadence for the standard-HR (0x2A37) buffer, which is independent of the frame
    /// buffer above. Deliberately much shorter: those readings need no clock correlation, so
    /// there is nothing to wait for and a short interval means a freshly-worn strap shows up in
    /// the stored data (and therefore in the charts) almost immediately.
    var standardMaxInterval: TimeInterval
    init(maxFrames: Int, maxInterval: TimeInterval, maxPreClockFrames: Int = 4096,
         standardMaxInterval: TimeInterval = 10) {
        self.maxFrames = maxFrames
        self.maxInterval = maxInterval
        self.maxPreClockFrames = maxPreClockFrames
        self.standardMaxInterval = standardMaxInterval
    }
    static let `default` = CollectorPolicy(maxFrames: 64, maxInterval: 30, maxPreClockFrames: 4096)
}

/// Buffers complete (reassembled) frames and periodically persists them:
/// parse → extractStreams(clockRef) → store.insert (DECODED FIRST, durable) →
/// store.enqueueRawBatch (raw, transient outbox) → clear buffer.
/// Because decoded is committed before raw is queued, pruning raw never loses a metric.
@MainActor
final class Collector {
    private let store: StoreWriting
    /// Concrete store for prune + stats (the StoreWriting seam covers the hot insert/enqueue path;
    /// prune/stats are infrequent so a direct reference is clearer than widening the protocol).
    private let concreteStore: WhoopStore?
    private let deviceId: String
    private let policy: CollectorPolicy
    /// Research toggle. When false (DEFAULT) no raw frames are persisted at all — the app is
    /// decoded-only. Injected for tests; backed by UserDefaults in the production init site.
    private let enableRawCapture: Bool
    private let now: () -> Int
    /// Wall clock in MILLIseconds. Used only by the standard-HR path, which reconstructs each
    /// individual beat's own moment from the R-R durations (see ingestStandardHR). Defaults to
    /// `now() * 1000` so tests injecting a fake `now` stay deterministic; the production init
    /// site passes a real millisecond clock.
    private let nowMs: () -> Int
    private let monotonic: () -> TimeInterval

    /// Set once the GET_CLOCK correlation lands (E1). Until then, frames buffer un-persisted.
    var clockRef: ClockRef?
    /// On-demand bounded raw-capture window. ORs into the raw-persist gate so a "capture
    /// activity sample" action can persist raw even when `enableRawCapture` is off. The window's
    /// monotonic deadline auto-expires so a missed stop callback can't leak raw forever.
    private var rawCapture = RawCaptureWindow()
    private var buffer: [[UInt8]] = []
    private var batchStartedAt: TimeInterval
    var bufferedCount: Int { buffer.count }

    /// Readings already decoded from the standard BLE Heart Rate characteristic (0x2A37).
    /// Separate from `buffer` because 2A37 payloads are not WhoopPacket-framed, so there is
    /// nothing to reassemble/extractStreams here; each reading is stamped with wall-clock
    /// `now()` directly (no device-clock correlation needed -- 2A37 always reports the current
    /// moment). See ingestStandardHR(bpm:rrMs:) below.
    private var standardHR: [HRSample] = []
    private var standardRR: [RRInterval] = []
    private var standardBatchStartedAt: TimeInterval
    var standardBufferedCount: Int { standardHR.count + standardRR.count }

    init(store: StoreWriting, deviceId: String,
         policy: CollectorPolicy = .default,
         enableRawCapture: Bool = false,
         now: @escaping () -> Int = { Int(Date().timeIntervalSince1970) },
         nowMs: (() -> Int)? = nil,
         monotonic: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }) {
        self.store = store; self.deviceId = deviceId; self.policy = policy
        self.enableRawCapture = enableRawCapture
        self.now = now; self.monotonic = monotonic
        self.nowMs = nowMs ?? { now() * 1000 }
        self.batchStartedAt = monotonic()
        self.standardBatchStartedAt = monotonic()
        self.concreteStore = store as? WhoopStore
    }

    /// Light storage summary for the UI. nil if there's no concrete store or the read throws.
    func storageStats() async -> (decodedRows: Int, rawBatches: Int, rawBytes: Int)? {
        guard let s = concreteStore else { return nil }
        return try? await s.storageStats()
    }

    /// Max persisted HR sample ts (the biometric "data frontier" for the stuck-strap watchdog).
    /// nil if there's no concrete store or nothing persisted yet. Mirrors storageStats().
    func latestHRSampleTs() async -> Int? {
        guard let s = concreteStore else { return nil }
        return try? await s.latestHRSampleTs(deviceId: deviceId)
    }

    /// Apply the raw-retention policy. Returns rows pruned (0 if no concrete store).
    @discardableResult
    func prune() async -> Int {
        guard let s = concreteStore else { return 0 }
        return (try? await s.pruneRaw(now: now(),
                                keepWindowSeconds: PrunePolicy.keepWindowSeconds,
                                maxUnsyncedBytes: PrunePolicy.maxUnsyncedBytes)) ?? 0
    }

    /// Buffer one complete frame (synchronous: preserves delegate arrival order).
    /// Auto-flushes via a detached Task when the cadence threshold is hit (flush is async).
    func ingest(_ frame: [UInt8]) {
        buffer.append(frame)
        // Pre-clock only: bound memory if GET_CLOCK never lands while data keeps flowing.
        // Drop OLDEST beyond the cap (keep most recent). Post-clock this branch is skipped —
        // the cadence flush below bounds the buffer instead.
        if clockRef == nil && buffer.count > policy.maxPreClockFrames {
            buffer.removeFirst(buffer.count - policy.maxPreClockFrames)
        }
        guard clockRef != nil else { return }   // can't correlate ts yet → keep buffering
        if buffer.count >= policy.maxFrames || (monotonic() - batchStartedAt) >= policy.maxInterval {
            Task { @MainActor in await self.flush() }
        }
    }

    /// Persist + queue everything buffered. No-op when empty or before a clock ref exists.
    /// Buffer is snapshotted and cleared SYNCHRONOUSLY before the first await so that any
    /// concurrent ingest() calls during persistence accumulate into the NEXT batch cleanly.
    func flush() async {
        // Always drain the standard-HR buffer too, independent of the frame/clockRef gate below,
        // so a disconnect (which calls flush()) never drops the last few 2A37 readings.
        await flushStandardHR()
        guard let ref = clockRef, !buffer.isEmpty else { return }
        // SNAPSHOT + CLEAR before any await: decoded-before-raw ordering AND the
        // buffer-snapshot-before-await invariant are both satisfied here.
        let frames = buffer
        buffer.removeAll(keepingCapacity: true)

        let parsed = frames.map { parseFrame($0) }
        let streams = extractStreams(parsed, deviceClockRef: ref.device, wallClockRef: ref.wall)
        do {
            try await store.insert(streams, deviceId: deviceId)   // DECODED FIRST (durable)
        } catch {
            // Re-buffer at the front so these frames are retried on the next cadence.
            buffer.insert(contentsOf: frames, at: 0)
            return
        }
        // Reset only after a successful insert so the interval trigger keeps firing if
        // inserts fail (batchStartedAt must NOT advance on a failed drain).
        batchStartedAt = monotonic()
        // RAW SECOND (transient outbox), only when the research toggle is ON. Default OFF →
        // decoded-only, no raw is stored. Failure is non-fatal — decoded is already durable.
        guard enableRawCapture || rawCapture.isActive(at: monotonic()) else { return }
        let wall = now()
        let tsValues = streams.hr.map(\.ts) + streams.rr.map(\.ts)
            + streams.events.map(\.ts) + streams.battery.map(\.ts)
        let meta = RawBatchMeta(
            batchId: UUID().uuidString, deviceId: deviceId, clockRef: ref, capturedAt: wall,
            startTs: tsValues.min() ?? wall, endTs: tsValues.max() ?? wall,
            frameCount: frames.count, byteSize: frames.reduce(0) { $0 + $1.count })
        try? await store.enqueueRawBatch(meta, frames: frames)
    }

    // MARK: - Standard BLE Heart Rate (0x2A37) live path
    //
    // The custom-protocol REALTIME_DATA stream (routed through ingest(_:)/flush() above) can be
    // gated off (e.g. right after connect, or while a research toggle is off), while 0x2A37 is
    // always subscribed and notifies continuously whenever the strap is worn. Without this path,
    // a live pulse can show correctly on screen (state.heartRate, set directly from 0x2A37) while
    // nothing gets persisted -- this is what actually saves it. Buffered on its own small cadence
    // so it does not depend on clockRef or the frame threshold used by the custom-protocol path.

    /// Ingest one already-decoded reading from the standard Heart Rate characteristic.
    /// No-op for a non-positive bpm (guards against a malformed/zero reading).
    ///
    /// PER-BEAT TIMESTAMPS: one notification carries the R-R intervals of the beats that just
    /// happened, oldest first. Stamping them all with the arrival second was wrong twice over:
    ///   1. `rrInterval`'s natural key is (deviceId, ts, rrMs), so two beats of the same length
    ///      inside one second collapsed into a single stored row — silently dropping beats.
    ///   2. HRV (RMSSD) and the stress index read successive differences, so squashing several
    ///      beats onto one instant distorts both.
    /// The last interval ended at arrival, so beat i's own moment is arrival minus the sum of the
    /// intervals that came after it. That reconstruction is exact to the strap's own measurement,
    /// needs no extra protocol data, and spreads the beats across real seconds.
    func ingestStandardHR(bpm: Int, rrMs: [Int]) {
        guard bpm > 0 else { return }
        let arrivalMs = nowMs()
        standardHR.append(HRSample(ts: arrivalMs / 1000, bpm: bpm))

        // Walk newest → oldest accumulating the offset back from arrival, then restore order.
        var offsetsMs: [Int] = []
        offsetsMs.reserveCapacity(rrMs.count)
        var acc = 0
        for rr in rrMs.reversed() {
            offsetsMs.append(acc)
            acc += max(0, rr)
        }
        for (i, rr) in rrMs.enumerated() {
            let offset = offsetsMs[rrMs.count - 1 - i]
            standardRR.append(RRInterval(ts: (arrivalMs - offset) / 1000, rrMs: rr))
        }

        // Small threshold: 2A37 notifies about once per second, so this lands the first readings
        // in the database within seconds of connecting instead of after half a minute.
        let threshold = 8
        if standardBufferedCount >= threshold
            || (monotonic() - standardBatchStartedAt) >= policy.standardMaxInterval {
            Task { @MainActor in await self.flushStandardHR() }
        }
    }

    /// Persist buffered standard-HR/RR readings. No-op when empty. On failure, re-buffers at the
    /// front for retry on the next cadence -- mirrors flush()'s error handling above.
    func flushStandardHR() async {
        guard standardBufferedCount > 0 else { return }
        let hr = standardHR
        let rr = standardRR
        standardHR.removeAll(keepingCapacity: true)
        standardRR.removeAll(keepingCapacity: true)
        do {
            try await store.insert(Streams(hr: hr, rr: rr), deviceId: deviceId)
        } catch {
            standardHR.insert(contentsOf: hr, at: 0)
            standardRR.insert(contentsOf: rr, at: 0)
            return
        }
        standardBatchStartedAt = monotonic()
    }

    // MARK: - On-demand raw capture

    /// Open a bounded raw-capture window so the next flushes persist raw even with the global
    /// research toggle off. Auto-expires at the (clamped) monotonic deadline.
    func beginRawCapture(seconds: TimeInterval) {
        rawCapture.open(at: monotonic(), duration: seconds)
    }

    /// Flush WHILE the window is still active so the just-captured frames get persisted as raw,
    /// THEN close the window.
    func endRawCapture() async {
        await flush()
        rawCapture.close()
    }
}
