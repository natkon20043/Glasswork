#pragma once

#include <cstdint>
#include <string_view>
#include <vector>

namespace gw {

struct WrapResult {
    /// Byte offset where each row starts; the first is 0.
    std::vector<uint32_t> rowStarts;
    /// Indentation cells on every row after the first.
    uint32_t continuationIndent = 0;
};

// ---- Wrapping

/// Soft wrap into rows of at most `columns` cells (at least 4): tabs reach the next stop, wide
/// characters take two cells. Breaks after a space or tab when the row has one, else mid-word.
/// Later rows are indented like the line, at most half the width.
WrapResult wrapLine(std::string_view text, uint32_t columns, uint32_t tabSize);

/// Row count only (at least 1); does not allocate.
uint32_t countWrapRows(std::string_view text, uint32_t columns, uint32_t tabSize);

}  // namespace gw
