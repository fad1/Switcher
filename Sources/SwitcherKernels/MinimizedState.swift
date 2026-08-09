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

    /// `tags` bits carried by every window a user can actually switch to, and by
    /// none of the invisible helper windows apps leave lying around (the 500×500
    /// off-screen one almost every app has, Chromium's off-screen bubbles, drag
    /// images). Without this, those helpers keep an app in the switcher forever:
    /// they are off-screen and never minimized, so they look exactly like a
    /// window on another Space.
    ///
    /// Measured, not documented — see the matrix in `MinimizedStateSpecs.md`.
    /// Note it is deliberately "either bit", not both: ordinary windows read
    /// `0x03` in the top byte but some (Activity Monitor's) read `0x02`.
    public static let switchableTags: UInt64 = 0x0300000000000000

    public static func isMinimized(_ w: WsRawWindow) -> Bool {
        w.tags & minimizedTag != 0
    }

    public static func isOrderedIn(_ w: WsRawWindow) -> Bool {
        w.attributes & visibleAttribute != 0
    }

    /// Whether this is a window a user could switch to at all, as opposed to an
    /// app-internal helper window that is never shown.
    public static func isSwitchable(_ w: WsRawWindow) -> Bool {
        w.tags & switchableTags != 0
    }

    /// What to do with a window that CGWindowList accepted via its OFF-SCREEN
    /// branch — the only branch where minimized and other-Space windows are
    /// indistinguishable without this decode.
    public enum Verdict: Equatable {
        /// A real window that is simply on another Space. Keeps its app listed.
        case keep
        /// A real window, minimized.
        case minimized
        /// Not a switchable window at all — an app-internal helper. It must not
        /// keep an app in the switcher, but it is not evidence of minimizing.
        case notSwitchable
    }

    public static func verdict(for w: WsRawWindow) -> Verdict {
        guard isSwitchable(w) else { return .notSwitchable }
        return isMinimized(w) ? .minimized : .keep
    }

    /// Which of `candidates` must NOT keep their app in the switcher — the
    /// minimized ones plus the helper windows that were never switchable.
    ///
    /// **Fails open on every uncertainty**: a wid the query did not return, an
    /// empty result, or a failed query all yield "keep", i.e. today's behavior.
    /// A future macOS that changes these fields must degrade to listing an extra
    /// app, never to hiding one the user is looking for.
    public static func rejectedWids(among candidates: [CGWindowID],
                                    states: [CGWindowID: WsRawWindow]) -> [CGWindowID: Verdict] {
        guard !states.isEmpty else { return [:] }

        var rejected: [CGWindowID: Verdict] = [:]
        for wid in candidates {
            guard let state = states[wid] else { continue }  // not returned → fail open
            let verdict = verdict(for: state)
            if verdict != .keep {
                rejected[wid] = verdict
            }
        }
        return rejected
    }
}
