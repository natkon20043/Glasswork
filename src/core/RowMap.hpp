#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

namespace gw {

/// Maps document lines to screen rows when a line can take several rows (wrapped) or none (folded).
/// Fenwick tree: fast both ways. Only used while wrapping or folding is on; otherwise row == line.
class RowMap {
public:
    // ---- Setters
    void assign(size_t lineCount, uint32_t rowsPerLine = 1);
    /// One entry per line; rebuilds the tree.
    void assign(std::vector<uint32_t> rows);
    void setRows(size_t line, uint32_t rows);
    /// Cheaper than recounting every line when an edit adds or removes lines.
    void replaceLines(size_t first, size_t oldCount, const std::vector<uint32_t>& newRows);
    void clear();

    // ---- Getters
    size_t lineCount() const { return rows_.size(); }
    uint32_t rows(size_t line) const { return rows_[line]; }
    bool empty() const { return rows_.empty(); }
    uint64_t totalRows() const { return firstRow(rows_.size()); }

    // ---- Line and row lookup
    /// Rows above `line`; `line == lineCount()` gives the total.
    uint64_t firstRow(size_t line) const;
    /// Never returns a line with no rows. Past the end gives the last visible line; an empty map gives 0.
    size_t lineForRow(uint64_t row) const;

private:
    // ---- Private functions
    void rebuildTree();

    // ---- Private variables
    std::vector<uint32_t> rows_;
    // 1-based Fenwick tree of row counts.
    std::vector<uint64_t> tree_;
};

}  // namespace gw
