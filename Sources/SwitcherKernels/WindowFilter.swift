import CoreGraphics
import Foundation

/// One window's fields as read from a `CGWindowListCopyWindowInfo` entry. Plain
/// data, so the accept/reject decision in `WindowFilter` stays pure and testable.
///
/// The optionals record what CGWindowList actually reported: `size` is nil when
/// the bounds key is missing or malformed (a distinct rejection from "too small"),
/// and `ownerName` is nil when the key is absent (a system-process window).
public struct RawWindow: Equatable {
    public let layer: Int
    public let size: CGSize?
    public let isOnScreen: Bool
    public let ownerName: String?
    public let ownerPID: pid_t?

    public init(layer: Int, size: CGSize?, isOnScreen: Bool, ownerName: String?, ownerPID: pid_t?) {
        self.layer = layer
        self.size = size
        self.isOnScreen = isOnScreen
        self.ownerName = ownerName
        self.ownerPID = ownerPID
    }
}

/// Decides which CGWindowList entries count as "this app has a switchable window".
/// See `WindowFilterSpecs.md` for the evidence behind the constants and, in
/// particular, for why the off-screen branch cannot exclude minimized windows.
public enum WindowFilter {

    /// Ordinary windows sit at layer 0; a few apps use small positives (3 =
    /// screensaver/fullscreen video). Negative layers are below the desktop and
    /// anything above this ceiling is system UI (menu bar, Dock).
    public static let minLayer = 0
    public static let maxLayer = 20

    /// Below this in either dimension a "window" is a menu, tooltip or shadow
    /// helper rather than something worth switching to.
    public static let minSize: CGFloat = 50

    public enum Verdict: Equatable {
        /// The window counts. `onScreen` reports which branch accepted it:
        /// false means it was accepted as off-screen, i.e. on another Space —
        /// or minimized, which CGWindowList cannot distinguish (see the spec).
        case accept(onScreen: Bool)
        case rejectLayer
        case rejectNoBounds
        case rejectTooSmall
        case rejectNoOwnerName
    }

    public static func verdict(for w: RawWindow) -> Verdict {
        if w.layer < minLayer || w.layer > maxLayer {
            return .rejectLayer
        }
        guard let size = w.size else {
            return .rejectNoBounds
        }
        if size.width < minSize || size.height < minSize {
            return .rejectTooSmall
        }
        if !w.isOnScreen {
            // A window on another Space reports isOnScreen = false, so off-screen
            // windows must be accepted; a non-empty owner name is what keeps
            // system-process windows out.
            guard let ownerName = w.ownerName, !ownerName.isEmpty else {
                return .rejectNoOwnerName
            }
        }
        return .accept(onScreen: w.isOnScreen)
    }

    public static func accepts(_ w: RawWindow) -> Bool {
        if case .accept = verdict(for: w) { return true }
        return false
    }
}

public extension RawWindow {
    /// Reads one `CGWindowListCopyWindowInfo` entry, applying the defaults the
    /// switcher has always used: a missing layer reads as 0 (an ordinary window)
    /// and a missing on-screen flag reads as false (which routes the window
    /// through the stricter off-screen branch rather than waving it through).
    init(cgWindowInfo window: [String: Any]) {
        let bounds = window[kCGWindowBounds as String] as? [String: CGFloat]
        self.init(
            layer: window[kCGWindowLayer as String] as? Int ?? 0,
            size: bounds.map { CGSize(width: $0["Width"] ?? 0, height: $0["Height"] ?? 0) },
            isOnScreen: window[kCGWindowIsOnscreen as String] as? Bool ?? false,
            ownerName: window[kCGWindowOwnerName as String] as? String,
            ownerPID: window[kCGWindowOwnerPID as String] as? pid_t
        )
    }
}
