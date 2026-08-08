import CoreGraphics
import Foundation
import SwitcherKernels

/// Pins which CGWindowList entries count as a switchable window, including the
/// defaults applied when a key is missing. Mirrors `WindowFilterSpecs.md` 1:1.
enum WindowFilterTests {

    private static func window(layer: Int = 0, size: CGSize? = CGSize(width: 800, height: 600),
                               isOnScreen: Bool = true, ownerName: String? = "TextEdit",
                               ownerPID: pid_t? = 501) -> RawWindow {
        RawWindow(layer: layer, size: size, isOnScreen: isOnScreen,
                  ownerName: ownerName, ownerPID: ownerPID)
    }

    static func runAll() {
        // A. Layer
        Check.run("testOrdinaryWindowAtLayerZeroIsAccepted", testOrdinaryWindowAtLayerZeroIsAccepted)
        Check.run("testNegativeLayerIsRejected", testNegativeLayerIsRejected)
        Check.run("testLayerAboveCeilingIsRejected", testLayerAboveCeilingIsRejected)
        Check.run("testSmallPositiveLayersAreAccepted", testSmallPositiveLayersAreAccepted)
        // B. Size
        Check.run("testWindowBelowMinimumSizeIsRejected", testWindowBelowMinimumSizeIsRejected)
        Check.run("testWindowAtExactlyMinimumSizeIsAccepted", testWindowAtExactlyMinimumSizeIsAccepted)
        Check.run("testMissingBoundsIsRejected", testMissingBoundsIsRejected)
        // C. Off-screen branch
        Check.run("testOffScreenWindowWithOwnerNameIsAccepted", testOffScreenWindowWithOwnerNameIsAccepted)
        Check.run("testOffScreenWindowWithoutOwnerNameIsRejected", testOffScreenWindowWithoutOwnerNameIsRejected)
        Check.run("testOffScreenWindowWithEmptyOwnerNameIsRejected", testOffScreenWindowWithEmptyOwnerNameIsRejected)
        Check.run("testOnScreenWindowNeedsNoOwnerName", testOnScreenWindowNeedsNoOwnerName)
        Check.run("testAcceptedVerdictReportsWhichBranchAcceptedIt", testAcceptedVerdictReportsWhichBranchAcceptedIt)
        // D. Minimized-only apps
        Check.run("testMinimizedWindowIsIndistinguishableFromOtherSpaceWindow",
                  testMinimizedWindowIsIndistinguishableFromOtherSpaceWindow)
        // E. Decoding a CGWindowList entry
        Check.run("testDecodesAFullWindowInfoDictionary", testDecodesAFullWindowInfoDictionary)
        Check.run("testMissingLayerDefaultsToZero", testMissingLayerDefaultsToZero)
        Check.run("testMissingOnScreenFlagDefaultsToFalse", testMissingOnScreenFlagDefaultsToFalse)
        Check.run("testMissingBoundsDecodesToNilSize", testMissingBoundsDecodesToNilSize)
        Check.run("testBoundsMissingWidthOrHeightDecodeToZero", testBoundsMissingWidthOrHeightDecodeToZero)
        Check.run("testWrongTypesAreTreatedAsMissing", testWrongTypesAreTreatedAsMissing)
        Check.run("testDecodesTheWindowID", testDecodesTheWindowID)
    }

    // MARK: - A. Layer

    static func testOrdinaryWindowAtLayerZeroIsAccepted() {
        Check.equal(WindowFilter.verdict(for: window(layer: 0)), .accept(onScreen: true))
    }

    static func testNegativeLayerIsRejected() {
        Check.equal(WindowFilter.verdict(for: window(layer: -1)), .rejectLayer)
    }

    static func testLayerAboveCeilingIsRejected() {
        for layer in [21, 25] {
            Check.equal(WindowFilter.verdict(for: window(layer: layer)), .rejectLayer,
                        "layer \(layer) is system UI, not a switchable window")
        }
    }

    static func testSmallPositiveLayersAreAccepted() {
        for layer in [1, 3 /* screensaver / fullscreen video */, 20 /* the boundary */] {
            Check.expect(WindowFilter.accepts(window(layer: layer)), "layer \(layer) should be accepted")
        }
    }

    // MARK: - B. Size

    static func testWindowBelowMinimumSizeIsRejected() {
        Check.equal(WindowFilter.verdict(for: window(size: CGSize(width: 49, height: 200))), .rejectTooSmall)
        Check.equal(WindowFilter.verdict(for: window(size: CGSize(width: 200, height: 49))), .rejectTooSmall)
    }

    static func testWindowAtExactlyMinimumSizeIsAccepted() {
        Check.expect(WindowFilter.accepts(window(size: CGSize(width: 50, height: 50))))
    }

    static func testMissingBoundsIsRejected() {
        // Distinct from too-small: the window reported no bounds at all.
        Check.equal(WindowFilter.verdict(for: window(size: nil)), .rejectNoBounds)
    }

    // MARK: - C. Off-screen branch

    static func testOffScreenWindowWithOwnerNameIsAccepted() {
        // The other-Space case: rejecting it would drop apps that are merely on
        // another desktop.
        Check.equal(WindowFilter.verdict(for: window(isOnScreen: false)), .accept(onScreen: false))
    }

    static func testOffScreenWindowWithoutOwnerNameIsRejected() {
        Check.equal(WindowFilter.verdict(for: window(isOnScreen: false, ownerName: nil)), .rejectNoOwnerName)
    }

    static func testOffScreenWindowWithEmptyOwnerNameIsRejected() {
        Check.equal(WindowFilter.verdict(for: window(isOnScreen: false, ownerName: "")), .rejectNoOwnerName)
    }

    static func testOnScreenWindowNeedsNoOwnerName() {
        // The owner-name guard applies only to the off-screen branch.
        Check.equal(WindowFilter.verdict(for: window(isOnScreen: true, ownerName: nil)), .accept(onScreen: true))
    }

    static func testAcceptedVerdictReportsWhichBranchAcceptedIt() {
        Check.equal(WindowFilter.verdict(for: window(isOnScreen: true)), .accept(onScreen: true))
        Check.equal(WindowFilter.verdict(for: window(isOnScreen: false)), .accept(onScreen: false))
    }

    // MARK: - D. Minimized-only apps (the known limitation, pinned deliberately)

    /// Both states report the same fields, so no rule over CGWindowList alone can
    /// separate them. Excluding minimized windows needs a source outside this
    /// data — see WindowFilterSpecs.md. A change that claims to fix the
    /// limitation has to change this test.
    static func testMinimizedWindowIsIndistinguishableFromOtherSpaceWindow() {
        let minimized = RawWindow(layer: 0, size: CGSize(width: 800, height: 600),
                                  isOnScreen: false, ownerName: "TextEdit", ownerPID: 501)
        let onAnotherSpace = RawWindow(layer: 0, size: CGSize(width: 800, height: 600),
                                       isOnScreen: false, ownerName: "TextEdit", ownerPID: 501)

        Check.equal(minimized, onAnotherSpace)
        Check.expect(WindowFilter.accepts(minimized))
        Check.expect(WindowFilter.accepts(onAnotherSpace))
    }

    // MARK: - E. Decoding a CGWindowList entry

    static func testDecodesAFullWindowInfoDictionary() {
        let raw = RawWindow(cgWindowInfo: [
            kCGWindowLayer as String: 0,
            kCGWindowBounds as String: ["Width": CGFloat(800), "Height": CGFloat(600)],
            kCGWindowIsOnscreen as String: true,
            kCGWindowOwnerName as String: "Safari",
            kCGWindowOwnerPID as String: pid_t(1234),
        ])

        Check.equal(raw.layer, 0)
        Check.equal(raw.size, CGSize(width: 800, height: 600))
        Check.expect(raw.isOnScreen)
        Check.equal(raw.ownerName, "Safari")
        Check.equal(raw.ownerPID, 1234)
    }

    static func testMissingLayerDefaultsToZero() {
        let raw = RawWindow(cgWindowInfo: [
            kCGWindowBounds as String: ["Width": CGFloat(800), "Height": CGFloat(600)],
            kCGWindowIsOnscreen as String: true,
        ])
        Check.equal(raw.layer, 0)
        Check.expect(WindowFilter.accepts(raw))
    }

    static func testMissingOnScreenFlagDefaultsToFalse() {
        // Routes through the stricter off-screen branch rather than waving it through.
        let raw = RawWindow(cgWindowInfo: [
            kCGWindowBounds as String: ["Width": CGFloat(800), "Height": CGFloat(600)],
        ])
        Check.expect(!raw.isOnScreen)
        Check.equal(WindowFilter.verdict(for: raw), .rejectNoOwnerName)
    }

    static func testMissingBoundsDecodesToNilSize() {
        let raw = RawWindow(cgWindowInfo: [kCGWindowLayer as String: 0])
        Check.isNil(raw.size)
        Check.equal(WindowFilter.verdict(for: raw), .rejectNoBounds)
    }

    static func testBoundsMissingWidthOrHeightDecodeToZero() {
        let raw = RawWindow(cgWindowInfo: [
            kCGWindowBounds as String: ["Width": CGFloat(800)],
            kCGWindowIsOnscreen as String: true,
        ])
        Check.equal(raw.size, CGSize(width: 800, height: 0))
        Check.equal(WindowFilter.verdict(for: raw), .rejectTooSmall)
    }

    static func testWrongTypesAreTreatedAsMissing() {
        let raw = RawWindow(cgWindowInfo: [
            kCGWindowLayer as String: "not a number",
            kCGWindowBounds as String: "not a dictionary",
            kCGWindowIsOnscreen as String: "not a bool",
            kCGWindowOwnerPID as String: "not a pid",
        ])
        Check.equal(raw.layer, 0)
        Check.isNil(raw.size)
        Check.expect(!raw.isOnScreen)
        Check.isNil(raw.ownerPID)
    }

    /// The wid is what the WindowServer minimized query is keyed on; without it
    /// a window cannot be checked, and is therefore kept.
    static func testDecodesTheWindowID() {
        let withID = RawWindow(cgWindowInfo: [kCGWindowNumber as String: CGWindowID(4242)])
        Check.equal(withID.windowID, 4242)

        let withoutID = RawWindow(cgWindowInfo: [kCGWindowLayer as String: 0])
        Check.isNil(withoutID.windowID)
    }
}
