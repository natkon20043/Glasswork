#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

namespace gw {

/// Maps document lines to screen rows when lines can take more or fewer than one row: a long
/// line wrapped over several rows takes several, a line hidden inside a fold takes none.
///
/// Answers both directions quickly (a Fenwick tree): the first row of a line, and which line
/// is on a given row. Only used while wrapping or folding is on; otherwise row == line.
class RowMap {
public:
    /// All `lineCount` lines take `rowsPerLine` rows.
    void assign(size_t lineCount, uint32_t rowsPerLine = 1);
    /// Replaces the whole list (one entry per line) and rebuilds the tree.
    void assign(std::vector<uint32_t> rows);
    void clear();

    size_t lineCount() const { return rows_.size(); }
    uint32_t rows(size_t line) const { return rows_[line]; }
    /// Changes one line's row count.
    void setRows(size_t line, uint32_t rows);
    /// Replaces `oldCount` lines starting at `first` with lines that take `newRows` rows each
    /// (one entry per new line). For edits that add or remove lines: cheaper than recounting
    /// every line of the document.
    void replaceLines(size_t first, size_t oldCount, const std::vector<uint32_t>& newRows);

    /// The row a line starts on: the total of the rows above it. `line == lineCount()` gives
    /// the total number of rows.
    uint64_t firstRow(size_t line) const;
    uint64_t totalRows() const { return firstRow(rows_.size()); }
    /// The line that contains screen row `row` (lines with no rows are never returned). Rows
    /// past the end give the last visible line; an empty map gives 0.
    size_t lineForRow(uint64_t row) const;

    /// True when the map has been filled in.
    bool empty() const { return rows_.empty(); }

private:
    void rebuildTree();

    std::vector<uint32_t> rows_;
    std::vector<uint64_t> tree_;  // 1-based Fenwick tree of row counts
};

}  // namespace gw
