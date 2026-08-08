import SwitcherKernels

/// Pins selection movement over the icon grid. Most of these are about the last
/// row being shorter than the others, which is where the off-by-ones live.
enum GridNavigationTests {

    private static func at(_ row: Int, _ column: Int) -> GridPosition {
        GridPosition(row: row, column: column)
    }

    /// Two rows of 5, then a short row of 2 — the common multi-row shape.
    private static let ragged = [5, 5, 2]
    private static let singleRow = [4]

    static func runAll() {
        // A. Next
        Check.run("testNextMovesRightWithinARow", testNextMovesRightWithinARow)
        Check.run("testNextFromEndOfRowMovesToStartOfNextRow", testNextFromEndOfRowMovesToStartOfNextRow)
        Check.run("testNextFromLastCellWrapsToTheFirst", testNextFromLastCellWrapsToTheFirst)
        Check.run("testNextWrapsWithinASingleRow", testNextWrapsWithinASingleRow)
        // B. Previous
        Check.run("testPreviousMovesLeftWithinARow", testPreviousMovesLeftWithinARow)
        Check.run("testPreviousFromStartOfRowMovesToEndOfPreviousRow", testPreviousFromStartOfRowMovesToEndOfPreviousRow)
        Check.run("testPreviousFromFirstCellWrapsToLastCellOfTheShortLastRow",
                  testPreviousFromFirstCellWrapsToLastCellOfTheShortLastRow)
        Check.run("testNextAndPreviousAreInverses", testNextAndPreviousAreInverses)
        Check.run("testNextVisitsEveryCellExactlyOnceBeforeWrapping", testNextVisitsEveryCellExactlyOnceBeforeWrapping)
        // C. Up / Down
        Check.run("testUpMovesToTheRowAbove", testUpMovesToTheRowAbove)
        Check.run("testDownMovesToTheRowBelow", testDownMovesToTheRowBelow)
        Check.run("testDownIntoAShortRowClampsTheColumn", testDownIntoAShortRowClampsTheColumn)
        Check.run("testUpWrapsToTheLastRowAndClamps", testUpWrapsToTheLastRowAndClamps)
        Check.run("testDownWrapsToTheFirstRow", testDownWrapsToTheFirstRow)
        Check.run("testUpAndDownAreNoOpsInASingleRowPanel", testUpAndDownAreNoOpsInASingleRowPanel)
        // D. Initial position
        Check.run("testForwardOpenSelectsTheSecondApp", testForwardOpenSelectsTheSecondApp)
        Check.run("testReverseOpenSelectsTheLastApp", testReverseOpenSelectsTheLastApp)
        Check.run("testSingleAppFallsBackToTheOnlyCell", testSingleAppFallsBackToTheOnlyCell)
        Check.run("testIndexPastTheShortLastRowIsClamped", testIndexPastTheShortLastRowIsClamped)
        Check.run("testNoSelectionWhenThereIsNothingToSelect", testNoSelectionWhenThereIsNothingToSelect)
        // E. Clamping after a removal
        Check.run("testSelectionSurvivesARemovalInTheMiddle", testSelectionSurvivesARemovalInTheMiddle)
        Check.run("testColumnClampsWhenItsRowGotShorter", testColumnClampsWhenItsRowGotShorter)
        Check.run("testRowClampsWhenTheLastRowDisappeared", testRowClampsWhenTheLastRowDisappeared)
        Check.run("testEmptiedGridSelectsNothing", testEmptiedGridSelectsNothing)
        Check.run("testNoSelectionMarkerStaysPutWhenRowsRemain", testNoSelectionMarkerStaysPutWhenRowsRemain)
    }

    // MARK: - A. Next (Tab / Right arrow)

    static func testNextMovesRightWithinARow() {
        Check.equal(GridNavigation.next(from: at(0, 0), rowLengths: ragged), at(0, 1))
    }

    static func testNextFromEndOfRowMovesToStartOfNextRow() {
        Check.equal(GridNavigation.next(from: at(0, 4), rowLengths: ragged), at(1, 0))
    }

    static func testNextFromLastCellWrapsToTheFirst() {
        Check.equal(GridNavigation.next(from: at(2, 1), rowLengths: ragged), at(0, 0))
    }

    static func testNextWrapsWithinASingleRow() {
        Check.equal(GridNavigation.next(from: at(0, 3), rowLengths: singleRow), at(0, 0))
    }

    // MARK: - B. Previous (Shift+Tab / Left arrow / Shift tap)

    static func testPreviousMovesLeftWithinARow() {
        Check.equal(GridNavigation.previous(from: at(1, 3), rowLengths: ragged), at(1, 2))
    }

    static func testPreviousFromStartOfRowMovesToEndOfPreviousRow() {
        Check.equal(GridNavigation.previous(from: at(1, 0), rowLengths: ragged), at(0, 4))
    }

    /// Wrapping backward lands on the SHORT last row, so the column comes from
    /// that row's length rather than from the previous row's.
    static func testPreviousFromFirstCellWrapsToLastCellOfTheShortLastRow() {
        Check.equal(GridNavigation.previous(from: at(0, 0), rowLengths: ragged), at(2, 1))
    }

    static func testNextAndPreviousAreInverses() {
        for row in 0..<ragged.count {
            for column in 0..<ragged[row] {
                let p = at(row, column)
                let roundTrip = GridNavigation.previous(from: GridNavigation.next(from: p, rowLengths: ragged),
                                                        rowLengths: ragged)
                Check.equal(roundTrip, p, "next then previous should return to (\(row), \(column))")
            }
        }
    }

    static func testNextVisitsEveryCellExactlyOnceBeforeWrapping() {
        var visited: [String] = []
        var p = at(0, 0)
        for _ in 0..<12 {
            visited.append("\(p.row),\(p.column)")
            p = GridNavigation.next(from: p, rowLengths: ragged)
        }
        Check.equal(visited.count, 12)
        Check.equal(Set(visited).count, 12)
        Check.equal(p, at(0, 0), "the 13th step wraps back to the start")
    }

    // MARK: - C. Up / Down (row movement, column clamped)

    static func testUpMovesToTheRowAbove() {
        Check.equal(GridNavigation.up(from: at(1, 3), rowLengths: ragged), at(0, 3))
    }

    static func testDownMovesToTheRowBelow() {
        Check.equal(GridNavigation.down(from: at(0, 3), rowLengths: ragged), at(1, 3))
    }

    static func testDownIntoAShortRowClampsTheColumn() {
        Check.equal(GridNavigation.down(from: at(1, 4), rowLengths: ragged), at(2, 1))
    }

    static func testUpWrapsToTheLastRowAndClamps() {
        Check.equal(GridNavigation.up(from: at(0, 4), rowLengths: ragged), at(2, 1))
    }

    static func testDownWrapsToTheFirstRow() {
        Check.equal(GridNavigation.down(from: at(2, 1), rowLengths: ragged), at(0, 1))
    }

    static func testUpAndDownAreNoOpsInASingleRowPanel() {
        Check.equal(GridNavigation.up(from: at(0, 2), rowLengths: singleRow), at(0, 2))
        Check.equal(GridNavigation.down(from: at(0, 2), rowLengths: singleRow), at(0, 2))
    }

    // MARK: - D. Initial position when the panel opens

    static func testForwardOpenSelectsTheSecondApp() {
        // Cmd+Tab: index 1, the quick back-and-forth case.
        Check.equal(GridNavigation.initialPosition(flatIndex: 1, itemCount: 12, itemsPerRow: 5,
                                                   rowLengths: ragged), at(0, 1))
    }

    static func testReverseOpenSelectsTheLastApp() {
        // Cmd+Shift+Tab: index count-1, the least recently used app.
        Check.equal(GridNavigation.initialPosition(flatIndex: 11, itemCount: 12, itemsPerRow: 5,
                                                   rowLengths: ragged), at(2, 1))
    }

    static func testSingleAppFallsBackToTheOnlyCell() {
        // Requesting index 1 with one app: min(1, count-1) = 0.
        Check.equal(GridNavigation.initialPosition(flatIndex: 1, itemCount: 1, itemsPerRow: 5,
                                                   rowLengths: [1]), at(0, 0))
    }

    /// The flat index divides by a full row's width, so an index past the end of
    /// a short last row must be clamped into it rather than selecting a
    /// nonexistent cell.
    static func testIndexPastTheShortLastRowIsClamped() {
        Check.equal(GridNavigation.initialPosition(flatIndex: 13, itemCount: 14, itemsPerRow: 5,
                                                   rowLengths: ragged), at(2, 1))
    }

    static func testNoSelectionWhenThereIsNothingToSelect() {
        Check.isNil(GridNavigation.initialPosition(flatIndex: 1, itemCount: 0, itemsPerRow: 5,
                                                   rowLengths: []))
    }

    // MARK: - E. Clamping after a removal (H / Q)

    static func testSelectionSurvivesARemovalInTheMiddle() {
        Check.equal(GridNavigation.clampAfterRemoval(at(1, 2), rowLengths: [5, 4, 2]), at(1, 2))
    }

    static func testColumnClampsWhenItsRowGotShorter() {
        Check.equal(GridNavigation.clampAfterRemoval(at(2, 1), rowLengths: [5, 5, 1]), at(2, 0))
    }

    /// Only the row moves: column 0 is still valid in the row we land on, and the
    /// column is clamped solely when it would fall outside it.
    static func testRowClampsWhenTheLastRowDisappeared() {
        Check.equal(GridNavigation.clampAfterRemoval(at(2, 0), rowLengths: [5, 5]), at(1, 0))
        // ...and when it would fall outside, it clamps to that row's end.
        Check.equal(GridNavigation.clampAfterRemoval(at(2, 4), rowLengths: [5, 3]), at(1, 2))
    }

    static func testEmptiedGridSelectsNothing() {
        Check.equal(GridNavigation.clampAfterRemoval(at(0, 0), rowLengths: []), GridPosition.noSelection)
    }

    /// After the grid empties, the panel keeps the -1/-1 marker until the next
    /// open — feeding it back in must not produce a bogus cell.
    static func testNoSelectionMarkerStaysPutWhenRowsRemain() {
        Check.equal(GridNavigation.clampAfterRemoval(.noSelection, rowLengths: [3]), GridPosition.noSelection)
    }
}
