import Foundation
import WhoopProtocol
import WhoopStore

// MARK: - BackfillStoreWriting protocol

/// The async subset the Backfiller needs. Plain async protocol (not @MainActor) so both the
/// real WhoopStore actor and a @MainActor SpyBackfillStore in tests can satisfy it.
protocol BackfillStoreWriting: AnyObject {
    @discardableResult
    func insert(_ streams: Streams, deviceId: String) async throws
        -> (hr: Int, rr: Int, events: Int, battery: Int,
            spo2: Int, skinTemp: Int, resp: Int, gravity: Int)
    func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws
    func setCursor(_ name: String, _ value: Int) async throws
    func cursor(_ name: String) async throws -> Int?
}

extension WhoopStore: BackfillStoreWriting {}

// MARK: - Backfiller

/// Historical-offload state machine (idle / backfilling).
///
/// Per-chunk local safe-trim invariant:
///   decode known → await insert (decoded durable) →
///   await enqueueRawBatch (raw durable) →
///   await setCursor(strap_trim) →
///   ackTrim (link-layer confirmed ack to strap)
///
/// A chunk is forgotten only after decoded AND raw are both locally durable AND the ack
/// (.withResponse) is link-layer confirmed. Never waits on the server.
@MainActor
final class Backfiller {
    typealias Extractor = ([ParsedFrame], Int, Int) -> Streams

    private let store: BackfillStoreWriting
    private let deviceId: String
    /// Confirms one HISTORY_END chunk to the strap. Carries both the trim cursor (= first u32
    /// of end_data, used for the `strap_trim` cursor) and the 8-byte `end_data` (= the raw
    /// HISTORY_END metadata.data[10:18]) that the high-freq-sync ack form requires verbatim.
    private let ackTrim: (_ trim: UInt32, _ endData: [UInt8]) -> Void
    private let extract: Extractor
    /// Research toggle. When false (DEFAULT) no raw frames are persisted — the chunk's
    /// decoded streams are still durable and the trim is still acked (decoded is the product of
    /// record). Injected for tests; backed by UserDefaults in the production init site.
    private let enableRawCapture: Bool

    /// The clock reference set by BLEManager when GET_CLOCK confirms (required for decoding).
    var clockRef: ClockRef?

    /// True while a historical offload session is active.
    private(set) var isBackfilling = false

    // MARK: - Session telemetry
    //
    // Until now a session logged the acks it sent and nothing about what came back, so "the strap
    // said HISTORY_COMPLETE" was indistinguishable from "and it delivered nothing". These counters
    // are what the Device log reports at the end of every offload.

    /// Decoded rows committed during the CURRENT session (all streams together).
    private(set) var sessionRows = 0
    /// Oldest / newest record timestamp seen this session, for the log line.
    private(set) var sessionOldestTs: Int?
    private(set) var sessionNewestTs: Int?
    /// Rows dropped because their timestamp was not plausible (see `isPlausible`).
    private(set) var sessionRejected = 0
    /// Oldest / newest timestamp among the REJECTED rows. Without this the log could say "2900
    /// rows discarded" and still not say whether the strap stamped them in 1970 or in 2029 — which
    /// is the whole question when a night is missing.
    private(set) var rejectedOldestTs: Int?
    private(set) var rejectedNewestTs: Int?
    /// Rows whose timestamp was implausible but became plausible after subtracting the measured
    /// strap-RTC offset, i.e. rescued rather than thrown away.
    private(set) var sessionRepaired = 0

    /// The strap's RTC error, measured at connect as (strap clock − phone clock) BEFORE any
    /// SET_CLOCK correction. Type-47 history carries the strap's own absolute unix stamps, so a
    /// wrong RTC makes a whole backlog land years away from now — stored, but outside every window
    /// the app ever reads, which looks exactly like no data at all. Set by BLEManager; 0 means
    /// "not measured" and disables the repair.
    var strapClockOffset = 0
    /// Only offsets past this are treated as a broken RTC. Below it, ordinary drift is left alone
    /// so healthy timestamps are never rewritten.
    static let clockRepairThreshold = 6 * 3_600

    /// Wall clock, injectable for tests.
    private let now: () -> Int

    /// A record timestamp is only usable if it lands in a sane window around the present. The
    /// strap stamps its own history from its RTC; if that RTC is wrong (it survives a flat
    /// battery badly), records arrive stamped years away, get stored, and then sit outside every
    /// window the app reads — invisible data that looks exactly like no data at all. Dropping and
    /// COUNTING them turns that failure into something the diagnostics can show.
    static func isPlausible(_ ts: Int, now: Int) -> Bool {
        ts > now - 400 * 86_400 && ts < now + 86_400
    }

    /// Buffered data frames for the current open chunk (between START and END).
    private var chunk: [[UInt8]] = []
    /// Whether a START has been received and we're accumulating a chunk.
    private var chunkOpen = false

    init(store: BackfillStoreWriting,
         deviceId: String,
         ackTrim: @escaping (_ trim: UInt32, _ endData: [UInt8]) -> Void,
         enableRawCapture: Bool = false,
         now: @escaping () -> Int = { Int(Date().timeIntervalSince1970) },
         extract: @escaping Extractor = { extractHistoricalStreams($0, deviceClockRef: $1, wallClockRef: $2) }) {
        self.store = store
        self.deviceId = deviceId
        self.ackTrim = ackTrim
        self.enableRawCapture = enableRawCapture
        self.now = now
        self.extract = extract
    }

    /// Called by BLEManager when the strap signals a historical offload is beginning.
    /// chunkOpen starts TRUE: the high-freq-sync biometric replay streams records immediately and
    /// sends one HISTORY_START then repeated HISTORY_ENDs, so we must accumulate from the outset.
    func begin() {
        isBackfilling = true
        chunk.removeAll(keepingCapacity: true)
        chunkOpen = true
        resetSessionCounters()
    }

    private func resetSessionCounters() {
        sessionRows = 0
        sessionOldestTs = nil
        sessionNewestTs = nil
        sessionRejected = 0
        sessionRepaired = 0
        rejectedOldestTs = nil
        rejectedNewestTs = nil
    }

    /// Repairs, keeps or drops each row by its timestamp, and updates the session counters.
    ///
    /// Three outcomes per row, in order:
    ///   1. plausible already          → kept as is;
    ///   2. implausible, but plausible after subtracting the measured strap-RTC offset → repaired
    ///      (the strap's clock was wrong while it recorded; the data itself is fine);
    ///   3. still implausible          → dropped, and its timestamp recorded so the log can say
    ///      *where* the strap thinks it was.
    private func vet(_ streams: Streams) -> Streams {
        let t = now()
        let offset = abs(strapClockOffset) >= Backfiller.clockRepairThreshold ? strapClockOffset : 0

        var repaired = 0
        var rejected = 0
        var rejLo: Int?
        var rejHi: Int?

        /// nil = drop this row; otherwise the timestamp to store it under.
        func fix(_ ts: Int) -> Int? {
            if Backfiller.isPlausible(ts, now: t) { return ts }
            if offset != 0 {
                let corrected = ts - offset
                if Backfiller.isPlausible(corrected, now: t) {
                    repaired += 1
                    return corrected
                }
            }
            rejected += 1
            rejLo = min(rejLo ?? ts, ts)
            rejHi = max(rejHi ?? ts, ts)
            return nil
        }

        let hr = streams.hr.compactMap { s in fix(s.ts).map { HRSample(ts: $0, bpm: s.bpm) } }
        let rr = streams.rr.compactMap { s in fix(s.ts).map { RRInterval(ts: $0, rrMs: s.rrMs) } }
        let spo2 = streams.spo2.compactMap { s in
            fix(s.ts).map { SpO2Sample(ts: $0, red: s.red, ir: s.ir, unit: s.unit) } }
        let skin = streams.skinTemp.compactMap { s in
            fix(s.ts).map { SkinTempSample(ts: $0, raw: s.raw, unit: s.unit) } }
        let resp = streams.resp.compactMap { s in
            fix(s.ts).map { RespSample(ts: $0, raw: s.raw, unit: s.unit) } }
        let grav = streams.gravity.compactMap { s in
            fix(s.ts).map { GravitySample(ts: $0, x: s.x, y: s.y, z: s.z, unit: s.unit) } }
        let events = streams.events.compactMap { e in
            fix(e.ts).map { WhoopEvent(ts: $0, kind: e.kind, payload: e.payload) } }
        let battery = streams.battery.compactMap { b in
            fix(b.ts).map { BatterySample(ts: $0, soc: b.soc, mv: b.mv, charging: b.charging) } }

        sessionRepaired += repaired
        sessionRejected += rejected
        if let lo = rejLo { rejectedOldestTs = min(rejectedOldestTs ?? lo, lo) }
        if let hi = rejHi { rejectedNewestTs = max(rejectedNewestTs ?? hi, hi) }
        sessionRows += hr.count + rr.count + spo2.count + skin.count
            + resp.count + grav.count + events.count + battery.count

        let stamps = hr.map(\.ts) + rr.map(\.ts) + spo2.map(\.ts) + skin.map(\.ts)
            + resp.map(\.ts) + grav.map(\.ts) + events.map(\.ts) + battery.map(\.ts)
        if let lo = stamps.min() { sessionOldestTs = min(sessionOldestTs ?? lo, lo) }
        if let hi = stamps.max() { sessionNewestTs = max(sessionNewestTs ?? hi, hi) }

        return Streams(hr: hr, rr: rr, spo2: spo2, skinTemp: skin, resp: resp,
                       gravity: grav, events: events, battery: battery)
    }

    /// Feed one raw BLE frame into the state machine. May trigger async store operations.
    func ingest(_ frame: [UInt8]) async {
        switch classifyHistoricalMeta(parseFrame(frame)) {
        case .start:
            isBackfilling = true
            chunk.removeAll(keepingCapacity: true)
            chunkOpen = true
        case .end(let unix, let trim):
            await finishChunk(unix: unix, trim: trim, endFrame: frame)
        case .complete:
            isBackfilling = false
            chunk.removeAll(keepingCapacity: true)
            chunkOpen = false
        case .other:
            if chunkOpen { chunk.append(frame) }
        }
    }

    /// The 8-byte `end_data` the high-freq-sync ack requires: metadata.data[10:18].
    /// metadata.data begins at frame[7] (after [type,seq,cmd]), so end_data = frame[17:25].
    /// trim cursor = the first u32 of end_data (data[10:14]). Returns nil if the frame is too
    /// short to contain the field (shouldn't happen for a real HISTORY_END, which is >=14 data
    /// bytes, but guards against a malformed frame).
    static func endData(from frame: [UInt8]) -> [UInt8]? {
        guard frame.count >= 25 else { return nil }
        return Array(frame[17..<25])
    }

    /// Commit one HISTORY_END chunk: (persist decoded → enqueueRaw when present) → setCursor → ackTrim.
    /// Early-returns on any throw to preserve the safe-trim invariant.
    ///
    /// CRITICAL: high-freq-sync sends ONE HISTORY_START then REPEATED HISTORY_ENDs (a chunk-close
    /// every ~50 records). So we must ack EVERY end and keep accumulating afterwards — NOT close
    /// the chunk after the first. We snapshot+clear the accumulated frames but leave `chunkOpen`
    /// TRUE so the records following this END become the next chunk. An END with no accumulated
    /// records is still acked (it advances the strap's trim) — that's how the offload progresses.
    /// `endFrame` carries the 8-byte `end_data` the ack requires.
    /// The strap signals "nothing left to give" with a HISTORY_END whose end_data is the
    /// all-ones sentinel, not a real cursor value. Acking it completes the handshake exactly like
    /// any other END — the strap expects that regardless of what it sent — but persisting
    /// UInt32.max as our own strap_trim bookkeeping would leave that cursor stuck at a value nothing
    /// can ever exceed, poisoning it for good.
    static let noDataSentinel: UInt32 = 0xFFFFFFFF

    private func finishChunk(unix: UInt32, trim: UInt32, endFrame: [UInt8]) async {
        guard let endData = Backfiller.endData(from: endFrame) else { return }

        let frames = chunk
        chunk.removeAll(keepingCapacity: true)   // next records accumulate into the next chunk

        if !frames.isEmpty {
            // type-47 HISTORICAL_DATA carries its OWN real-unix timestamp — extractHistoricalStreams
            // ignores the clock offset for it — so the historical offload does NOT need GET_CLOCK.
            // If the (device,wall) correlation isn't established yet (e.g. GET_CLOCK silent), fall back
            // to an identity ref (device==wall==now): the offset math becomes a no-op, type-47 still
            // decodes to correct wall time, and we can persist + ack + upload. The correlation is only
            // truly required to map REALTIME (type-40/43) device-epoch timestamps, never in a hist chunk.
            let ref = clockRef ?? { let now = Int(Date().timeIntervalSince1970); return ClockRef(device: now, wall: now) }()
            let parsed = frames.map { parseFrame($0) }
            let decoded = vet(extract(parsed, ref.device, ref.wall))
            do { try await store.insert(decoded, deviceId: deviceId) } catch { return }

            // RAW: only persisted when the research toggle is ON. Default OFF → decoded-only; the
            // chunk is still durably committed (decoded) so the trim is safe to advance + ack.
            if enableRawCapture {
                let meta = RawBatchMeta(
                    batchId: "hist-\(deviceId)-\(trim)",
                    deviceId: deviceId,
                    clockRef: ref,
                    capturedAt: Int(Date().timeIntervalSince1970),
                    startTs: ref.wall,
                    endTs: ref.wall,
                    frameCount: frames.count,
                    byteSize: frames.reduce(0) { $0 + $1.count })
                do { try await store.enqueueRawBatch(meta, frames: frames) } catch { return }
            }
        }
        if trim != Backfiller.noDataSentinel {
            do { try await store.setCursor("strap_trim", Int(trim)) } catch { return }
        }

        ackTrim(trim, endData)
    }

    /// Called when a backfill watchdog timer fires (strap went silent mid-offload).
    /// Clears state without acking — the chunk was never durably committed.
    func timeoutFired() {
        isBackfilling = false
        chunk.removeAll(keepingCapacity: true)
        chunkOpen = false
    }
}
