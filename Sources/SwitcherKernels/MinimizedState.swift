import CoreGraphics
import Foundation

/// One window's raw WindowServer fields, read from a single batched
/// `SLSWindowQueryWindows` snapshot. Plain data, so the decode stays pure.
public struct WsRawWindow: Equatable {
    public let wid: CGWindowID
    /// `SLSWindowIteratorGetAttributes`.
    public let attributes: UInt64
    /// `SLSWindowIteratorGetTags` — a SECOND bitfield alongside `attributes`,
    /// and the one carrying minimized.
    public let tags: UInt64

    public init(wid: CGWindowID, attributes: UInt64, tags: UInt64) {
        self.wid = wid
        self.attributes = attributes
        self.tags = tags
    }
}

/// Pure decode of the WindowServer's own minimized bit. The constants were
/// measured locally rather than taken from AltTab — see `MinimizedStateSpecs.md`
/// for the state matrix, the Darwin version it was taken on, and the
/// re-diff-on-each-macOS-major ritual.
public enum MinimizedState {

    /// `tags` bit set exactly while a window is MINIMIZED, and clear for every
    /// state that otherwise looks identical from CGS — notably an `orderOut()`
    /// window and a window on another Space, both of which are off-screen too.
    /// That discrimination is the entire basis of the minimized filter.
    public static let minimizedTag: UInt64 = 1 << 60

    /// `attributes` bit set while the window is ordered in / on screen. Cleared
    /// by minimize, app-hide, moving to another Space, and by a closing window
    /// mid-teardown — so it is an ordered-in signal, NOT a minimized one.
    public static let visibleAttribute: UInt64 = 0x2

    public static func isMinimized(_ w: WsRawWindow) -> Bool {
        w.tags & minimizedTag != 0
    }

    public static func isOrderedIn(_ w: WsRawWindow) -> Bool {
        w.attributes & visibleAttribute != 0
    }

    /// Which of `candidates` should be rejected as minimized.
    ///
    /// **Fails open on every uncertainty**: a wid the query did not return, an
    /// empty result, or a failed query all yield "not minimized", i.e. today's
    /// behavior. A future macOS that changes these fields must degrade to
    /// listing an extra app, never to hiding one the user is looking for.
    public static func minimizedWids(among candidates: [CGWindowID],
                                     states: [CGWindowID: WsRawWindow]) -> Set<CGWindowID> {
        guard !states.isEmpty else { return [] }

        var minimized = Set<CGWindowID>()
        for wid in candidates {
            guard let state = states[wid] else { continue }  // not returned → fail open
            if isMinimized(state) {
                minimized.insert(wid)
            }
        }
        return minimized
    }
}
