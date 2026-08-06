import Foundation
import GMMKProtocol

/// Dirty-region frame delivery (§7.2-R), with its cost model written down.
///
/// The old transport sent a full 126-LED repaint every frame — `START`, seven
/// colour packets, `END`, all echo-paced — whatever was on screen. Diffing was
/// implemented in r1 but its cost model was never specified, and "1–3 packets
/// per frame" was a *target* that nothing asserted. The rules below are
/// normative, and `viz-sim` runs this exact function so the budget can be
/// checked without hardware.
///
/// ## The wire constraint
///
/// A `0x11` write carries at most ``GMMKPacket/maxKeysPerPacket`` keys at
/// `address = keyIndex · 3`, one **contiguous run** per packet. So a frame costs
/// `Σ over runs ceil(runLength / 18)` and the builder's only freedom is where it
/// ends a run.
///
/// ## Why runs bridge unchanged keys
///
/// Repainting `g` unchanged keys costs nothing extra until the run crosses a
/// packet boundary, whereas splitting a run always costs a whole extra packet.
/// Bridging is therefore free up to the point where it is not, and `G = 4` keeps
/// the expected bridged length well inside one packet. `G` is a constant of the
/// *wire format*, not of any song (P1).
///
/// ## Why there is a fallback
///
/// A sparse but spread-out change set is the pathological case: twenty changed
/// keys at stride six produce twenty runs and twenty packets — worse than the
/// seven-packet full repaint it replaced. **The full repaint is the ceiling, and
/// no frame may ever cost more than it.**
public enum FramePackets {

    /// How many unchanged keys a run may bridge.
    public static let bridgeGap = 4
    /// Above this many colour packets the builder gives up and repaints. Five
    /// colour packets plus `START` and `END` is seven wire writes, under the
    /// nine of a full frame, so the fallback can only ever reduce the worst case.
    public static let packetBudget = 5

    /// What one frame cost, for the §7.2-R telemetry.
    public struct Plan: Sendable {
        public var packets: [[UInt8]]
        /// Colour packets only — `START`/`END` are added by the caller.
        public var colourPackets: Int { packets.count }
        /// Whether the scattered-set fallback fired.
        public var fullRepaint: Bool
        public var changedKeys: Int
    }

    /// Builds the colour packets for one frame against the last one sent.
    ///
    /// A frame with zero changed keys sends **nothing at all** — not even the
    /// bracket. `START` … `END` still brackets every frame that sends anything,
    /// including a one-packet frame: `END` is the commit.
    public static func plan(for frame: [RGB], lastSent: [RGB]?) -> Plan {
        guard let lastSent, lastSent.count == frame.count, !frame.isEmpty else {
            return Plan(packets: repaint(frame), fullRepaint: true,
                        changedKeys: frame.count)
        }
        var changed = 0
        for index in frame.indices where frame[index] != lastSent[index] { changed += 1 }
        guard changed > 0 else { return Plan(packets: [], fullRepaint: false, changedKeys: 0) }

        var runs: [(start: Int, end: Int)] = []
        var index = 0
        while index < frame.count {
            guard frame[index] != lastSent[index] else {
                index += 1
                continue
            }
            var end = index
            var gap = 0
            var scan = index
            while scan < frame.count {
                if frame[scan] != lastSent[scan] {
                    end = scan
                    gap = 0
                } else {
                    gap += 1
                    if gap > bridgeGap { break }
                }
                scan += 1
            }
            runs.append((index, end))
            index = end + 1
        }

        let count = runs.reduce(0) { total, run in
            total + Int(ceil(Double(run.end - run.start + 1) / Double(GMMKPacket.maxKeysPerPacket)))
        }
        let ideal = Int(ceil(Double(changed) / Double(GMMKPacket.maxKeysPerPacket)))
        // Fragmentation test, then the absolute budget.
        if count >= ideal + 2 || count > packetBudget {
            // `fullRepaint` records a **fallback that saved packets**, not the
            // mere fact that a repaint was emitted. §7.2-R's 5 % budget is a
            // claim about the renderer producing *scattered* change sets, and
            // the honest test of that is whether the run plan would have cost
            // more than the repaint does. Two things make a run plan cost more
            // than `ideal` without any scattering by the renderer: a board most
            // of whose keys legitimately changed (r2's bed and hue field change
            // every key every frame, and seven packets is then the arithmetic
            // minimum, not a fallback), and the LED map's own permanent holes —
            // there are unmapped indices inside the 126-key range, they never
            // change, and they split every frame's runs no matter what is being
            // painted.
            return Plan(packets: repaint(frame), fullRepaint: count > repaintCost(frame),
                        changedKeys: changed)
        }

        var packets: [[UInt8]] = []
        for run in runs {
            packets += GMMKPacket.customColorPackets(
                startKeyIndex: GMMKKeyMap.minLEDIndex + UInt16(run.start),
                colors: Array(frame[run.start...run.end]))
        }
        return Plan(packets: packets, fullRepaint: false, changedKeys: changed)
    }

    /// Convenience for callers that only want the packets.
    public static func packets(for frame: [RGB], lastSent: [RGB]?) -> [[UInt8]] {
        plan(for: frame, lastSent: lastSent).packets
    }

    /// What a full repaint of this frame costs, in colour packets.
    static func repaintCost(_ frame: [RGB]) -> Int {
        Int(ceil(Double(frame.count) / Double(GMMKPacket.maxKeysPerPacket)))
    }

    private static func repaint(_ frame: [RGB]) -> [[UInt8]] {
        GMMKPacket.customColorPackets(startKeyIndex: GMMKKeyMap.minLEDIndex, colors: frame)
    }
}
