#include "RowMap.hpp"

#include <algorithm>

namespace gw {

void RowMap::assign(size_t lineCount, uint32_t rowsPerLine) {
    rows_.assign(lineCount, rowsPerLine);
    rebuildTree();
}

void RowMap::assign(std::vector<uint32_t> rows) {
    rows_ = std::move(rows);
    rebuildTree();
}

void RowMap::clear() {
    rows_.clear();
    tree_.clear();
}

/// Builds the tree in one pass instead of adding every line separately.
void RowMap::rebuildTree() {
    size_t count = rows_.size();
    tree_.assign(count + 1, 0);
    for (size_t index = 1; index <= count; ++index) {
        tree_[index] += rows_[index - 1];
        size_t parent = index + (index & (~index + 1));
        if (parent <= count) {
            tree_[parent] += tree_[index];
        }
    }
}

void RowMap::setRows(size_t line, uint32_t rows) {
    int64_t difference = static_cast<int64_t>(rows) - static_cast<int64_t>(rows_[line]);
    if (difference == 0) {
        return;
    }
    rows_[line] = rows;
    for (size_t index = line + 1; index < tree_.size(); index += index & (~index + 1)) {
        tree_[index] = static_cast<uint64_t>(static_cast<int64_t>(tree_[index]) + difference);
    }
}

void RowMap::replaceLines(size_t first, size_t oldCount, const std::vector<uint32_t>& newRows) {
    first = std::min(first, rows_.size());
    oldCount = std::min(oldCount, rows_.size() - first);
    auto begin = rows_.begin() + static_cast<long>(first);
    begin = rows_.erase(begin, begin + static_cast<long>(oldCount));
    rows_.insert(begin, newRows.begin(), newRows.end());
    rebuildTree();
}

uint64_t RowMap::firstRow(size_t line) const {
    uint64_t total = 0;
    size_t index = std::min(line, rows_.size());
    while (index > 0) {
        total += tree_[index];
        index -= index & (~index + 1);
    }
    return total;
}

size_t RowMap::lineForRow(uint64_t row) const {
    size_t count = rows_.size();
    if (count == 0) {
        return 0;
    }
    // Walk down the tree to the last position whose rows above sum to at most `row`.
    size_t position = 0;
    size_t step = 1;
    while (step * 2 <= count) {
        step *= 2;
    }
    uint64_t remaining = row;
    for (; step > 0; step /= 2) {
        size_t next = position + step;
        if (next <= count && tree_[next] <= remaining) {
            position = next;
            remaining -= tree_[next];
        }
    }
    // `position` lines fit entirely above the row, so the row belongs to line `position`.
    if (position >= count) {
        // Past the end: the last line that shows anything.
        size_t last = count - 1;
        while (last > 0 && rows_[last] == 0) {
            --last;
        }
        return last;
    }
    // Lines with no rows can sit at `position`; move on to one that has some.
    while (position + 1 < count && rows_[position] == 0) {
        ++position;
    }
    return position;
}

}  // namespace gw
