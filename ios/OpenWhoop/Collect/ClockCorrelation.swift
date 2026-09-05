import Foundation
import WhoopProtocol
import WhoopStore

/// Pure helper: correlate the strap's monotonic device clock to wall time.
/// REALTIME_DATA timestamps are a device monotonic epoch; the server/app maps them to
/// unix time using the (device, wall) pair captured at connect via GET_CLOCK + now.
/// No CoreBluetooth, no I/O — fully unit-testable.
enum ClockCorrelation {
    /// Build a `ClockRef` from a decoded GET_CLOCK COMMAND_RESPONSE frame and the wall
    /// time observed when the response arrived. Returns nil unless the frame parsed OK,
    /// passed CRC, and carries a `clock` value.
    static func clockRef(from parsed: ParsedFrame, wall: Int) -> ClockRef? {
        guard parsed.ok, parsed.crcOK != false,
              let device = parsed.parsed["clock"]?.intValue else { return nil }
        return ClockRef(device: device, wall: wall)
    }

    /// Fallback correlation from a REALTIME_DATA frame.
    ///
    /// GET_CLOCK is the intended source, but the strap does not always answer it — and until a
    /// ClockRef exists the Collector cannot map realtime device timestamps to wall time, so every
    /// realtime frame sits in a buffer and is eventually dropped. A realtime frame does not need
    /// the round trip: "realtime" means the sample is from right now, so the frame's own device
    /// timestamp paired with its arrival time IS a valid correlation, accurate to the BLE latency
    /// (well under a second). Used only when GET_CLOCK has not answered.
    static func realtimeClockRef(from parsed: ParsedFrame, wall: Int) -> ClockRef? {
        guard parsed.ok, parsed.crcOK != false,
              parsed.typeName == "REALTIME_DATA",
              let device = parsed.parsed["timestamp"]?.intValue,
              device > 0 else { return nil }
        return ClockRef(device: device, wall: wall)
    }
}
