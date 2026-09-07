import XCTest
import WhoopProtocol
import WhoopStore
@testable import OpenWhoop

// MARK: - SpyBackfillStore

/// @MainActor spy that records calls in order, supporting throw injection per-method.
@MainActor
final class SpyBackfillStore: BackfillStoreWriting {
    enum Call: Equatable {
        case insert
        case enqueueRawBatch(batchId: String)
        case setCursor(name: String, value: Int)
    }

    var calls: [Call] = []
    /// Every Streams handed to insert(), so a test can assert what actually got stored — not just
    /// that a store call happened.
    var inserted: [Streams] = []
    /// Persisted cursor store — survives across Backfiller instances (models a reconnect against
    /// the same on-disk store). `cursor(_:)` reads from here so a resume test can assert the
    /// strap_trim cursor survived a disconnect.
    var cursors: [String: Int] = [:]
    var insertShouldThrow = false
    var enqueueShouldThrow = false
    var setCursorShouldThrow = false
    var insertResult: (hr: Int, rr: Int, events: Int, battery: Int,
                       spo2: Int, skinTemp: Int, resp: Int, gravity: Int) = (0, 0, 0, 0, 0, 0, 0, 0)

    @discardableResult
    func insert(_ streams: Streams, deviceId: String) async throws
        -> (hr: Int, rr: Int, events: Int, battery: Int,
            spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
        if insertShouldThrow { throw TestError.insert }
        calls.append(.insert)
        inserted.append(streams)
        return insertResult
    }

    func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws {
        if enqueueShouldThrow { throw TestError.enqueue }
        calls.append(.enqueueRawBatch(batchId: meta.batchId))
    }

    func setCursor(_ name: String, _ value: Int) async throws {
        if setCursorShouldThrow { throw TestError.setCursor }
        calls.append(.setCursor(name: name, value: value))
        cursors[name] = value
    }

    func cursor(_ name: String) async throws -> Int? { cursors[name] }
}

enum TestError: Error { case insert, enqueue, setCursor }

// MARK: - Frame helpers

private func le32(_ v: UInt32) -> [UInt8] {
    [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
}
private func le16(_ v: UInt16) -> [UInt8] {
    [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]
}

/// Build a METADATA frame (type 49) with cmd byte = metaType and optional payload.
private func metaFrame(_ metaType: UInt8, _ payload: [UInt8] = []) -> [UInt8] {
    frameFromPayload(payload, type: 49, seq: 0, cmd: metaType)
}

/// Build a HISTORY_END frame with the given unix, trim, and trailing `next` u32.
///
/// Real-device data layout (openwhoop): unix(4) + subsec(2) + unk0(4) + trim(4) + next(4) = 18B.
/// The post-hook classifier reads only the first 14 bytes (`<LHLL>` → unix + trim_cursor); the
/// high-freq-sync ack uses data[10:18] = trim(4) + next(4) verbatim. So the FULL end_data is
/// `le32(trim) + le32(next)`.
private func endFrame(unix: UInt32, trim: UInt32, next: UInt32 = 0) -> [UInt8] {
    let payload = le32(unix) + le16(0) + le32(0) + le32(trim) + le32(next)
    return metaFrame(2, payload)
}

/// The 8-byte end_data the ack must echo for an endFrame(trim:next:): data[10:18] = trim ++ next.
private func expectedEndData(trim: UInt32, next: UInt32 = 0) -> [UInt8] {
    le32(trim) + le32(next)
}

/// An arbitrary non-metadata data frame (type 40 = REALTIME_DATA, minimal).
private func dataFrame() -> [UInt8] {
    frameFromPayload([0x00, 0x01], type: 40, seq: 0, cmd: 0)
}

// MARK: - BackfillerTests

@MainActor
final class BackfillerTests: XCTestCase {

    private func defaultRef() -> ClockRef {
        ClockRef(device: 1_000_000, wall: 1_700_000_000)
    }

    // MARK: - clean chunk: START → data → data → END(unix, trim)

    func testCleanChunk() async throws {
        let store = SpyBackfillStore()
        var acks: [UInt32] = []
        var ackEndData: [[UInt8]] = []
        let bf = Backfiller(store: store, deviceId: "whoop-test",
                            ackTrim: { v, e in acks.append(v); ackEndData.append(e) },
                            enableRawCapture: true,
                            extract: { _, _, _ in Streams() })
        bf.clockRef = defaultRef()
        bf.begin()

        let expectedTrim: UInt32 = 9876
        let expectedNext: UInt32 = 0x0102_0304

        await bf.ingest(metaFrame(1))                    // START
        await bf.ingest(dataFrame())                     // data frame 1
        await bf.ingest(dataFrame())                     // data frame 2
        await bf.ingest(endFrame(unix: 1_700_001_000, trim: expectedTrim, next: expectedNext))  // END

        // insert → enqueueRawBatch → setCursor → ackTrim (in that order)
        XCTAssertEqual(store.calls, [
            .insert,
            .enqueueRawBatch(batchId: "hist-whoop-test-\(expectedTrim)"),
            .setCursor(name: "strap_trim", value: Int(expectedTrim))
        ])
        XCTAssertEqual(acks, [expectedTrim])
        // ack carries the verbatim 8-byte end_data = data[10:18] = trim(4) ++ next(4)
        XCTAssertEqual(ackEndData, [expectedEndData(trim: expectedTrim, next: expectedNext)])
    }

    // The ack payload the BLEManager actually sends is [0x01] + end_data (9 bytes). This asserts
    // the Backfiller hands up exactly the 8 bytes the high-freq-sync ack form requires, so a
    // BLEManager built on `[0x01] + endData` matches re/sync_openwhoop.py.
    func testAckEndDataMatchesHistoryEndDataSlice() async throws {
        let store = SpyBackfillStore()
        var captured: [UInt8] = []
        let bf = Backfiller(store: store, deviceId: "whoop-test",
                            ackTrim: { _, e in captured = e },
                            extract: { _, _, _ in Streams() })
        bf.clockRef = defaultRef()
        bf.begin()

        let trim: UInt32 = 0xAABB_CCDD
        let next: UInt32 = 0x1122_3344
        let end = endFrame(unix: 1_700_001_000, trim: trim, next: next)
        await bf.ingest(metaFrame(1))
        await bf.ingest(dataFrame())
        await bf.ingest(end)

        // end_data is precisely frame[17..<25] of the raw HISTORY_END frame.
        XCTAssertEqual(captured, Array(end[17..<25]))
        XCTAssertEqual(captured, expectedEndData(trim: trim, next: next))
        // The on-wire HISTORICAL_DATA_RESULT payload is therefore [0x01] + captured.
        XCTAssertEqual([0x01] + captured, [0x01] + expectedEndData(trim: trim, next: next))
    }

    func testCleanChunkEnqueuesDataFramesOnly() async throws {
        let store = SpyBackfillStore()
        var acks: [UInt32] = []
        var capturedFrames: [[UInt8]] = []
        let d1 = dataFrame()
        let d2 = dataFrame()
        let bf = Backfiller(store: store, deviceId: "whoop-test",
                            ackTrim: { v, _ in acks.append(v) },
                            extract: { frames, _, _ in
                                capturedFrames = frames.map { _ in [] } // just count
                                return Streams()
                            })
        bf.clockRef = defaultRef()
        bf.begin()
        await bf.ingest(metaFrame(1))
        await bf.ingest(d1)
        await bf.ingest(d2)
        await bf.ingest(endFrame(unix: 1_700_001_000, trim: 100))
        // exactly 2 data frames were buffered (START and END are not buffered)
        XCTAssertEqual(capturedFrames.count, 2)
    }

    // MARK: - insert throws → no enqueue, no setCursor, no ack

    func testInsertThrowsSuppressesRest() async throws {
        let store = SpyBackfillStore()
        store.insertShouldThrow = true
        var acks: [UInt32] = []
        let bf = Backfiller(store: store, deviceId: "whoop-test",
                            ackTrim: { v, _ in acks.append(v) },
                            extract: { _, _, _ in Streams() })
        bf.clockRef = defaultRef()
        bf.begin()
        await bf.ingest(metaFrame(1))
        await bf.ingest(dataFrame())
        await bf.ingest(endFrame(unix: 1_700_001_000, trim: 999))

        XCTAssertEqual(store.calls, [], "no calls after insert throws")
        XCTAssertEqual(acks, [], "no ack after insert throws")
    }

    // MARK: - enqueueRawBatch throws → no setCursor, no ack (insert may have succeeded)

    func testEnqueueThrowsSuppressesRest() async throws {
        let store = SpyBackfillStore()
        store.enqueueShouldThrow = true
        var acks: [UInt32] = []
        let bf = Backfiller(store: store, deviceId: "whoop-test",
                            ackTrim: { v, _ in acks.append(v) },
                            enableRawCapture: true,
                            extract: { _, _, _ in Streams() })
        bf.clockRef = defaultRef()
        bf.begin()
        await bf.ingest(metaFrame(1))
        await bf.ingest(dataFrame())
        await bf.ingest(endFrame(unix: 1_700_001_000, trim: 888))

        // insert succeeded (no throw) → .insert recorded; enqueue threw → setCursor and ack absent
        XCTAssertEqual(store.calls, [.insert])
        XCTAssertEqual(acks, [], "no ack after enqueue throws")
    }

    // MARK: - setCursor throws → no ack

    func testSetCursorThrowsSuppressesAck() async throws {
        let store = SpyBackfillStore()
        store.setCursorShouldThrow = true
        var acks: [UInt32] = []
        let bf = Backfiller(store: store, deviceId: "whoop-test",
                            ackTrim: { v, _ in acks.append(v) },
                            enableRawCapture: true,
                            extract: { _, _, _ in Streams() })
        bf.clockRef = defaultRef()
        bf.begin()
        await bf.ingest(metaFrame(1))
        await bf.ingest(dataFrame())
        await bf.ingest(endFrame(unix: 1_700_001_000, trim: 777))

        XCTAssertTrue(store.calls.contains(.insert))
        XCTAssertTrue(store.calls.contains(.enqueueRawBatch(batchId: "hist-whoop-test-777")))
        XCTAssertFalse(store.calls.contains(.setCursor(name: "strap_trim", value: 777)))
        XCTAssertEqual(acks, [], "no ack after setCursor throws")
    }

    // MARK: - multi-chunk: two chunks then HISTORY_COMPLETE

    func testMultiChunkAndComplete() async throws {
        let store = SpyBackfillStore()
        var acks: [UInt32] = []
        let bf = Backfiller(store: store, deviceId: "whoop-test",
                            ackTrim: { v, _ in acks.append(v) },
                            extract: { _, _, _ in Streams() })
        bf.clockRef = defaultRef()
        bf.begin()

        // chunk 1
        await bf.ingest(metaFrame(1))
        await bf.ingest(dataFrame())
        await bf.ingest(endFrame(unix: 1_700_001_000, trim: 100))

        // chunk 2
        await bf.ingest(metaFrame(1))
        await bf.ingest(dataFrame())
        await bf.ingest(endFrame(unix: 1_700_002_000, trim: 200))

        // HISTORY_COMPLETE
        await bf.ingest(metaFrame(3))

        XCTAssertEqual(acks, [100, 200], "two acks, in trim order")
        XCTAssertFalse(bf.isBackfilling, "isBackfilling cleared on COMPLETE")

        // Verify both inserts, enqueues, and setCursors happened
        let insertCount = store.calls.filter { $0 == .insert }.count
        XCTAssertEqual(insertCount, 2)
    }

    // MARK: - timeout clears backfilling state, no ack

    func testTimeoutFiresNoAck() async throws {
        let store = SpyBackfillStore()
        var acks: [UInt32] = []
        let bf = Backfiller(store: store, deviceId: "whoop-test",
                            ackTrim: { v, _ in acks.append(v) },
                            extract: { _, _, _ in Streams() })
        bf.clockRef = defaultRef()
        bf.begin()
        await bf.ingest(metaFrame(1))
        await bf.ingest(dataFrame())

        bf.timeoutFired()

        XCTAssertFalse(bf.isBackfilling, "isBackfilling cleared by timeout")
        XCTAssertEqual(acks, [], "no ack on timeout")
        XCTAssertEqual(store.calls, [], "no store calls on timeout")
    }

    // MARK: - data streamed after begin() WITHOUT an explicit START is captured + acked
    // (high-freq-sync streams records immediately, before/without a START — begin() opens the chunk)

    func testDataAfterBeginCapturedWithoutStart() async throws {
        let store = SpyBackfillStore()
        var acks: [UInt32] = []
        let bf = Backfiller(store: store, deviceId: "whoop-test",
                            ackTrim: { v, _ in acks.append(v) },
                            extract: { _, _, _ in Streams() })
        bf.clockRef = defaultRef()
        bf.begin()

        // No explicit START — begin() already opened the chunk.
        await bf.ingest(dataFrame())
        await bf.ingest(dataFrame())
        await bf.ingest(endFrame(unix: 1_700_001_000, trim: 555))

        XCTAssertEqual(store.calls, [
            .insert,
            .setCursor(name: "strap_trim", value: 555)
        ], "data after begin() is captured + committed even without an explicit START")
        XCTAssertEqual(acks, [555], "trim acked")
    }

    // MARK: - REGRESSION: high-freq-sync = ONE START then REPEATED ENDs; EVERY end must ack.
    // (The old code closed the chunk after the first END, so the 2nd+ ENDs were never acked → the
    //  strap stalled → backfill timed out → trim never advanced → couldn't catch up to live.)

    func testMultiEndSingleStartEveryEndAcked() async throws {
        let store = SpyBackfillStore()
        var acks: [UInt32] = []
        let bf = Backfiller(store: store, deviceId: "whoop-test",
                            ackTrim: { v, _ in acks.append(v) },
                            extract: { _, _, _ in Streams() })
        bf.clockRef = defaultRef()
        bf.begin()

        await bf.ingest(metaFrame(1))                                    // ONE START
        await bf.ingest(dataFrame())
        await bf.ingest(endFrame(unix: 1_700_001_000, trim: 10))         // END 1
        await bf.ingest(dataFrame())                                     // more records, NO new START
        await bf.ingest(endFrame(unix: 1_700_001_050, trim: 20))         // END 2
        await bf.ingest(dataFrame())
        await bf.ingest(endFrame(unix: 1_700_001_100, trim: 30))         // END 3

        XCTAssertEqual(acks, [10, 20, 30], "every HISTORY_END acked, not just the first")
        let inserts = store.calls.filter { $0 == .insert }.count
        XCTAssertEqual(inserts, 3, "each chunk's records persisted")
    }

    // An END with no accumulated records still advances the trim (empty-chunk marker).
    func testEmptyEndStillAcks() async throws {
        let store = SpyBackfillStore()
        var acks: [UInt32] = []
        let bf = Backfiller(store: store, deviceId: "whoop-test",
                            ackTrim: { v, _ in acks.append(v) },
                            extract: { _, _, _ in Streams() })
        bf.clockRef = defaultRef()
        bf.begin()
        await bf.ingest(endFrame(unix: 1_700_001_000, trim: 42))   // END with no preceding data

        XCTAssertEqual(store.calls, [.setCursor(name: "strap_trim", value: 42)],
                       "no insert (empty chunk) but cursor advances")
        XCTAssertEqual(acks, [42], "empty END still acks to advance the offload")
    }

    // The strap answers "no more history" with a HISTORY_END whose end_data is the all-ones
    // sentinel, not a real cursor. The ack still has to go out — that is what completes the
    // handshake — but the sentinel must never be written into strap_trim: it can only ever be
    // equalled, never advanced past, which would poison every future reading of that cursor.
    func testSentinelEndAcksButDoesNotPersistTheCursor() async throws {
        let store = SpyBackfillStore()
        var acks: [UInt32] = []
        let bf = Backfiller(store: store, deviceId: "whoop-test",
                            ackTrim: { v, _ in acks.append(v) },
                            extract: { _, _, _ in Streams() })
        bf.clockRef = defaultRef()
        bf.begin()
        await bf.ingest(endFrame(unix: 1_700_001_000, trim: Backfiller.noDataSentinel))

        XCTAssertEqual(store.calls, [], "the sentinel is not a real cursor and must not be stored")
        XCTAssertEqual(acks, [Backfiller.noDataSentinel],
                       "the strap still gets its ack so the handshake completes")
    }

    // A real trim cursor arriving right after a sentinel must still be persisted normally — the
    // guard is specific to the sentinel value, not a one-way latch.
    func testRealCursorAfterSentinelStillPersists() async throws {
        let store = SpyBackfillStore()
        var acks: [UInt32] = []
        let bf = Backfiller(store: store, deviceId: "whoop-test",
                            ackTrim: { v, _ in acks.append(v) },
                            extract: { _, _, _ in Streams() })
        bf.clockRef = defaultRef()
        bf.begin()
        await bf.ingest(endFrame(unix: 1_700_001_000, trim: Backfiller.noDataSentinel))
        await bf.ingest(endFrame(unix: 1_700_001_060, trim: 99))

        XCTAssertEqual(store.calls, [.setCursor(name: "strap_trim", value: 99)])
        XCTAssertEqual(acks, [Backfiller.noDataSentinel, 99])
    }

    // MARK: - chunk with clockRef == nil → identity-fallback (type-47 is self-contained)

    // type-47 historical payloads are self-timestamped, so the Backfiller no longer blocks on a
    // clockRef: with none set it falls back to an identity ClockRef (device == wall == now) and
    // still persists + acks. (Previously this path no-op'd, which stranded the offload — see the
    // type-47 historical-offload fix.)
    func testChunkWithNilClockRefUsesIdentityFallback() async throws {
        let store = SpyBackfillStore()
        var acks: [UInt32] = []
        let bf = Backfiller(store: store, deviceId: "whoop-test",
                            ackTrim: { v, _ in acks.append(v) },
                            extract: { _, _, _ in Streams() })
        // Do NOT set bf.clockRef → exercises the identity-fallback path.
        bf.begin()

        await bf.ingest(metaFrame(1))
        await bf.ingest(dataFrame())
        await bf.ingest(endFrame(unix: 1_700_001_000, trim: 333))

        XCTAssertEqual(store.calls,
                       [.insert, .setCursor(name: "strap_trim", value: 333)],
                       "identity fallback still persists + advances the trim cursor")
        XCTAssertEqual(acks, [333], "identity fallback still acks the trim")
    }

    // MARK: - isBackfilling state transitions

    func testIsBackfillingSetByBegin() {
        let store = SpyBackfillStore()
        var acks: [UInt32] = []
        let bf = Backfiller(store: store, deviceId: "whoop-test",
                            ackTrim: { v, _ in acks.append(v) },
                            extract: { _, _, _ in Streams() })
        XCTAssertFalse(bf.isBackfilling, "starts idle")
        bf.begin()
        XCTAssertTrue(bf.isBackfilling, "true after begin()")
    }

    func testIsBackfillingClearedByComplete() async throws {
        let store = SpyBackfillStore()
        var acks: [UInt32] = []
        let bf = Backfiller(store: store, deviceId: "whoop-test",
                            ackTrim: { v, _ in acks.append(v) },
                            extract: { _, _, _ in Streams() })
        bf.clockRef = defaultRef()
        bf.begin()
        await bf.ingest(metaFrame(3)) // HISTORY_COMPLETE
        XCTAssertFalse(bf.isBackfilling, "false after COMPLETE")
    }

    // MARK: - raw capture toggle

    func testRawNotEnqueuedWhenToggleOffByDefault() async throws {
        let store = SpyBackfillStore()
        var acks: [UInt32] = []
        // No enableRawCapture passed → defaults OFF.
        let bf = Backfiller(store: store, deviceId: "whoop-test",
                            ackTrim: { v, _ in acks.append(v) },
                            extract: { _, _, _ in Streams() })
        bf.clockRef = defaultRef()
        bf.begin()
        await bf.ingest(metaFrame(1))
        await bf.ingest(dataFrame())
        await bf.ingest(endFrame(unix: 1_700_001_000, trim: 444))

        // insert + setCursor + ack still happen (decoded is durable); enqueueRawBatch does NOT.
        XCTAssertEqual(store.calls, [
            .insert,
            .setCursor(name: "strap_trim", value: 444)
        ], "no enqueueRawBatch when toggle OFF, but decoded + cursor still committed")
        XCTAssertEqual(acks, [444], "trim still acked with raw OFF")
    }

    func testRawEnqueuedWhenToggleOn() async throws {
        let store = SpyBackfillStore()
        var acks: [UInt32] = []
        let bf = Backfiller(store: store, deviceId: "whoop-test",
                            ackTrim: { v, _ in acks.append(v) },
                            enableRawCapture: true,
                            extract: { _, _, _ in Streams() })
        bf.clockRef = defaultRef()
        bf.begin()
        await bf.ingest(metaFrame(1))
        await bf.ingest(dataFrame())
        await bf.ingest(endFrame(unix: 1_700_001_000, trim: 444))

        XCTAssertEqual(store.calls, [
            .insert,
            .enqueueRawBatch(batchId: "hist-whoop-test-444"),
            .setCursor(name: "strap_trim", value: 444)
        ], "enqueueRawBatch IS called when toggle ON")
        XCTAssertEqual(acks, [444])
    }

    func testIsBackfillingClearedByTimeout() {
        let store = SpyBackfillStore()
        var acks: [UInt32] = []
        let bf = Backfiller(store: store, deviceId: "whoop-test",
                            ackTrim: { v, _ in acks.append(v) },
                            extract: { _, _, _ in Streams() })
        bf.begin()
        bf.timeoutFired()
        XCTAssertFalse(bf.isBackfilling, "false after timeout")
    }

    // MARK: - REGRESSION: resume-from-trim after a disconnect mid-drain
    //
    // Audit 4.2. The critical memory fix is "ack EVERY HISTORY_END so the trim advances and the
    // offload catches up across reconnects." This test models a disconnect mid-offload and asserts:
    //   (1) the strap_trim cursor persisted by the FIRST session survives into the SECOND session
    //       (it lives in the shared store, not in the per-connection Backfiller instance);
    //   (2) a chunk left OPEN when the strap goes silent is dropped WITHOUT an ack (no false trim
    //       advance for data that was never durably committed — safe-trim holds);
    //   (3) the reconnect's NEW Backfiller resumes acking the NEXT trims (it does not re-ack the
    //       already-committed chunk-1 trim, and it advances the persisted cursor forward).
    // NB: resume-from-the-right-position is ultimately enforced STRAP-SIDE — the strap re-offloads
    // from its own last-acked trim. The phone's strap_trim cursor is the durable record of that
    // position; this test verifies the cursor survives + only advances forward across the reconnect.
    func testResumeFromTrimAfterDisconnect() async throws {
        // Shared store survives the simulated disconnect (models the on-disk WhoopStore).
        let store = SpyBackfillStore()

        // ── Session 1: ack chunk-1 (trim 10), then the strap goes silent mid-chunk-2. ──
        var acks1: [UInt32] = []
        let bf1 = Backfiller(store: store, deviceId: "whoop-test",
                             ackTrim: { v, _ in acks1.append(v) },
                             extract: { _, _, _ in Streams() })
        bf1.clockRef = defaultRef()
        bf1.begin()
        await bf1.ingest(metaFrame(1))                                   // START
        await bf1.ingest(dataFrame())
        await bf1.ingest(endFrame(unix: 1_700_001_000, trim: 10))        // END 1 → ack 10, cursor=10
        await bf1.ingest(dataFrame())                                    // chunk 2 accumulating…
        bf1.timeoutFired()                                               // strap silent → DISCONNECT

        XCTAssertEqual(acks1, [10], "only the durably-committed chunk-1 trim was acked")
        let cursorAfterSession1 = try await store.cursor("strap_trim")
        XCTAssertEqual(cursorAfterSession1, 10, "strap_trim persisted by session 1")
        // The open chunk-2 was NOT acked (it was never durably committed) — safe-trim holds.
        XCTAssertFalse(store.calls.contains(.setCursor(name: "strap_trim", value: 20)),
                       "no premature trim advance for the interrupted chunk")

        // ── Reconnect: a NEW Backfiller against the SAME store. The persisted cursor survives. ──
        var acks2: [UInt32] = []
        let bf2 = Backfiller(store: store, deviceId: "whoop-test",
                             ackTrim: { v, _ in acks2.append(v) },
                             extract: { _, _, _ in Streams() })
        bf2.clockRef = defaultRef()
        let cursorAtReconnect = try await store.cursor("strap_trim")
        XCTAssertEqual(cursorAtReconnect, 10, "cursor still 10 at reconnect — not reset to 0")

        bf2.begin()
        // The strap resumes the offload from where it left off (chunk 2 onward).
        await bf2.ingest(metaFrame(1))                                   // START (new session)
        await bf2.ingest(dataFrame())
        await bf2.ingest(endFrame(unix: 1_700_001_050, trim: 20))        // END 2 → ack 20
        await bf2.ingest(dataFrame())
        await bf2.ingest(endFrame(unix: 1_700_001_100, trim: 30))        // END 3 → ack 30

        XCTAssertEqual(acks2, [20, 30], "reconnect resumes acking the NEXT trims, not re-acking 10")
        let cursorAfterSession2 = try await store.cursor("strap_trim")
        XCTAssertEqual(cursorAfterSession2, 30,
                       "cursor advanced forward across the reconnect (10 → 30, never backward)")
    }
}

// MARK: - Session telemetry + timestamp vetting
//
// A session used to log the acks it sent and nothing about the data that came back, so "the
// strap said HISTORY_COMPLETE" could not be told apart from "and it delivered nothing" — which
// is exactly the question that matters when a night is missing.

@MainActor
final class BackfillerSessionTelemetryTests: XCTestCase {

    private let now = 1_788_757_000

    func testCountersReportStoredAndRejectedRows() async throws {
        let store = SpyBackfillStore()
        let bf = Backfiller(store: store, deviceId: "whoop-test",
                            ackTrim: { _, _ in },
                            now: { self.now },
                            extract: { _, _, _ in
                                Streams(hr: [HRSample(ts: self.now - 600, bpm: 55),
                                             HRSample(ts: self.now - 540, bpm: 54),
                                             HRSample(ts: self.now - 480, bpm: 56),
                                             // A strap whose clock survived a flat battery badly:
                                             HRSample(ts: self.now + 400 * 86_400, bpm: 60)])
                            })
        bf.clockRef = ClockRef(device: 1_000_000, wall: 1_700_000_000)
        bf.begin()

        await bf.ingest(metaFrame(1))
        await bf.ingest(dataFrame())
        await bf.ingest(endFrame(unix: 1_700_001_000, trim: 42))

        XCTAssertEqual(bf.sessionRows, 3, "only plausible rows count as stored")
        XCTAssertEqual(bf.sessionRejected, 1, "the future-stamped row is counted, not silently kept")
        XCTAssertEqual(bf.sessionOldestTs, now - 600)
        XCTAssertEqual(bf.sessionNewestTs, now - 480)
    }

    func testCountersResetOnANewSession() async throws {
        let store = SpyBackfillStore()
        let bf = Backfiller(store: store, deviceId: "whoop-test",
                            ackTrim: { _, _ in },
                            now: { self.now },
                            extract: { _, _, _ in Streams(hr: [HRSample(ts: self.now, bpm: 50)]) })
        bf.clockRef = ClockRef(device: 1_000_000, wall: 1_700_000_000)
        bf.begin()
        await bf.ingest(metaFrame(1))
        await bf.ingest(dataFrame())
        await bf.ingest(endFrame(unix: 1_700_001_000, trim: 7))
        XCTAssertGreaterThan(bf.sessionRows, 0)

        bf.begin()
        XCTAssertEqual(bf.sessionRows, 0)
        XCTAssertEqual(bf.sessionRejected, 0)
        XCTAssertNil(bf.sessionOldestTs)
    }

    /// A chunk that decodes to nothing usable must leave the counters at zero — that is the
    /// signal the drain loop uses to stop asking for more.
    func testChunkWithOnlyImplausibleRowsStoresNothing() async throws {
        let store = SpyBackfillStore()
        let bf = Backfiller(store: store, deviceId: "whoop-test",
                            ackTrim: { _, _ in },
                            now: { self.now },
                            extract: { _, _, _ in Streams(hr: [HRSample(ts: 0, bpm: 50)]) })
        bf.clockRef = ClockRef(device: 1_000_000, wall: 1_700_000_000)
        bf.begin()
        await bf.ingest(metaFrame(1))
        await bf.ingest(dataFrame())
        await bf.ingest(endFrame(unix: 1_700_001_000, trim: 7))
        XCTAssertEqual(bf.sessionRows, 0)
        XCTAssertEqual(bf.sessionRejected, 1)
    }

    /// The rejected range is the diagnosis: "2900 rows discarded" says nothing, "the strap thought
    /// it was 2029" says everything.
    func testRejectedRangeIsRecorded() async throws {
        let far = now + 900 * 86_400
        let store = SpyBackfillStore()
        let bf = Backfiller(store: store, deviceId: "whoop-test",
                            ackTrim: { _, _ in },
                            now: { self.now },
                            extract: { _, _, _ in
                                Streams(hr: [HRSample(ts: far, bpm: 50),
                                             HRSample(ts: far + 600, bpm: 51)])
                            })
        bf.clockRef = ClockRef(device: 1_000_000, wall: 1_700_000_000)
        bf.begin()
        await bf.ingest(metaFrame(1))
        await bf.ingest(dataFrame())
        await bf.ingest(endFrame(unix: 1_700_001_000, trim: 7))

        XCTAssertEqual(bf.sessionRejected, 2)
        XCTAssertEqual(bf.rejectedOldestTs, far)
        XCTAssertEqual(bf.rejectedNewestTs, far + 600)
    }

    /// A strap whose RTC ran years ahead recorded perfectly good data under impossible timestamps.
    /// With the offset measured at connect, those rows are worth rescuing, not discarding.
    func testMeasuredClockOffsetRescuesMisstampedRows() async throws {
        let offset = 900 * 86_400
        let store = SpyBackfillStore()
        let bf = Backfiller(store: store, deviceId: "whoop-test",
                            ackTrim: { _, _ in },
                            now: { self.now },
                            extract: { _, _, _ in
                                Streams(hr: [HRSample(ts: self.now - 600 + offset, bpm: 55),
                                             HRSample(ts: self.now - 300 + offset, bpm: 57)])
                            })
        bf.strapClockOffset = offset
        bf.clockRef = ClockRef(device: 1_000_000, wall: 1_700_000_000)
        bf.begin()
        await bf.ingest(metaFrame(1))
        await bf.ingest(dataFrame())
        await bf.ingest(endFrame(unix: 1_700_001_000, trim: 7))

        XCTAssertEqual(bf.sessionRows, 2, "both rows land in the store")
        XCTAssertEqual(bf.sessionRepaired, 2)
        XCTAssertEqual(bf.sessionRejected, 0)
        XCTAssertEqual(bf.sessionOldestTs, now - 600, "shifted back onto the real wall clock")
        XCTAssertEqual(bf.sessionNewestTs, now - 300)
        XCTAssertEqual(store.inserted.first?.hr.map(\.ts), [now - 600, now - 300])
    }

    /// The repair must never touch timestamps that are already fine — ordinary seconds-level drift
    /// stays below the threshold and rows are stored exactly as decoded.
    func testSmallDriftNeverRewritesGoodTimestamps() async throws {
        let store = SpyBackfillStore()
        let bf = Backfiller(store: store, deviceId: "whoop-test",
                            ackTrim: { _, _ in },
                            now: { self.now },
                            extract: { _, _, _ in Streams(hr: [HRSample(ts: self.now - 120, bpm: 52)]) })
        bf.strapClockOffset = 45
        bf.clockRef = ClockRef(device: 1_000_000, wall: 1_700_000_000)
        bf.begin()
        await bf.ingest(metaFrame(1))
        await bf.ingest(dataFrame())
        await bf.ingest(endFrame(unix: 1_700_001_000, trim: 7))

        XCTAssertEqual(bf.sessionRepaired, 0)
        XCTAssertEqual(bf.sessionRows, 1)
        XCTAssertEqual(store.inserted.first?.hr.map(\.ts), [now - 120])
    }

    /// An offset that does not explain the timestamps must not be applied — a row that is still
    /// impossible after the shift is dropped, not stored somewhere else that is equally wrong.
    func testOffsetThatDoesNotExplainTheRowStillRejectsIt() async throws {
        let store = SpyBackfillStore()
        let bf = Backfiller(store: store, deviceId: "whoop-test",
                            ackTrim: { _, _ in },
                            now: { self.now },
                            extract: { _, _, _ in Streams(hr: [HRSample(ts: 0, bpm: 50)]) })
        bf.strapClockOffset = 900 * 86_400
        bf.clockRef = ClockRef(device: 1_000_000, wall: 1_700_000_000)
        bf.begin()
        await bf.ingest(metaFrame(1))
        await bf.ingest(dataFrame())
        await bf.ingest(endFrame(unix: 1_700_001_000, trim: 7))

        XCTAssertEqual(bf.sessionRows, 0)
        XCTAssertEqual(bf.sessionRepaired, 0)
        XCTAssertEqual(bf.sessionRejected, 1)
    }
}
