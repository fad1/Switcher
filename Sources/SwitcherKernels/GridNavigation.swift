import Foundation

/// A selected cell in the switcher's icon grid. `.noSelection` (-1, -1) is the
/// marker the panel uses once its last app has been removed.
public struct GridPosition: Equatable {
    public var row: Int
    public var column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }

    public static let noSelection = GridPosition(row: -1, column: -1)
}

/// Selection movement over the switcher's grid, which is a list of rows filled
/// left-to-right. Only the row *lengths* matter, so this is pure arithmetic over
/// `[Int]` — the panel owns the views.
///
/// The last row is usually shorter than the others, which is what most of these
/// rules exist for: next/previous walk in reading order and wrap at both ends,
/// while up/down move by row and clamp the column into the destination row.
public enum GridNavigation {

    /// Tab / Right arrow. Wraps from the last cell back to the first.
    public static func next(from p: GridPosition, rowLengths: [Int]) -> GridPosition {
        guard rowLengths.indices.contains(p.row) else { return p }

        if p.column < rowLengths[p.row] - 1 {
            return GridPosition(row: p.row, column: p.column + 1)
        }
        if p.row < rowLengths.count - 1 {
            return GridPosition(row: p.row + 1, column: 0)
        }
        return GridPosition(row: 0, column: 0)
    }

    /// Shift+Tab / Left arrow / Shift tap. Wraps from the first cell to the last
    /// cell of the last row — which is the shorter one, hence the recomputation.
    public static func previous(from p: GridPosition, rowLengths: [Int]) -> GridPosition {
        guard rowLengths.indices.contains(p.row) else { return p }

        if p.column > 0 {
            return GridPosition(row: p.row, column: p.column - 1)
        }
        if p.row > 0 {
            return GridPosition(row: p.row - 1, column: rowLengths[p.row - 1] - 1)
        }
        let lastRow = rowLengths.count - 1
        return GridPosition(row: lastRow, column: rowLengths[lastRow] - 1)
    }

    /// Up arrow. A no-op in a single-row panel; wraps to the last row otherwise.
    public static func up(from p: GridPosition, rowLengths: [Int]) -> GridPosition {
        guard rowLengths.count > 1, rowLengths.indices.contains(p.row) else { return p }

        let row = p.row > 0 ? p.row - 1 : rowLengths.count - 1
        return GridPosition(row: row, column: min(p.column, rowLengths[row] - 1))
    }

    /// Down arrow. A no-op in a single-row panel; wraps to the first row otherwise.
    public static func down(from p: GridPosition, rowLengths: [Int]) -> GridPosition {
        guard rowLengths.count > 1, rowLengths.indices.contains(p.row) else { return p }

        let row = p.row < rowLengths.count - 1 ? p.row + 1 : 0
        return GridPosition(row: row, column: min(p.column, rowLengths[row] - 1))
    }

    /// Where the panel opens: a flat MRU index (1 forward, last app in reverse)
    /// converted to a cell. Returns nil when there is nothing to select, in which
    /// case the caller leaves the current selection alone.
    ///
    /// The clamp matters because the flat index divides by a full row's width: an
    /// index landing past the end of a short last row would otherwise select a
    /// cell that does not exist.
    public static func initialPosition(flatIndex: Int, itemCount: Int, itemsPerRow: Int,
                                       rowLengths: [Int]) -> GridPosition? {
        guard itemsPerRow > 0, !rowLengths.isEmpty else { return nil }

        let index = min(flatIndex, itemCount - 1)
        guard index >= 0 else { return nil }

        var row = index / itemsPerRow
        var column = index % itemsPerRow
        if row >= rowLengths.count {
            row = rowLengths.count - 1
            column = rowLengths[row] - 1
        } else if column >= rowLengths[row] {
            column = rowLengths[row] - 1
        }
        return GridPosition(row: row, column: column)
    }

    /// Where the selection lands after the selected app was removed (H or Q) and
    /// the grid reflowed. An emptied grid selects nothing.
    public static func clampAfterRemoval(_ p: GridPosition, rowLengths: [Int]) -> GridPosition {
        guard !rowLengths.isEmpty else { return .noSelection }

        var row = p.row
        var column = p.column
        if row >= rowLengths.count {
            row = rowLengths.count - 1
        }
        if row >= 0, column >= rowLengths[row] {
            column = rowLengths[row] - 1
        }
        return GridPosition(row: row, column: column)
    }
}
