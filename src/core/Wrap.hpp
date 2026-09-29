#pragma once

#include <cstdint>
#include <string_view>
#include <vector>

namespace gw {

/// Soft wrapping of one line of text into rows of at most `columns` character cells.
///
/// Rows break after a space or tab when there is one in the row, otherwise in the middle of a
/// long word. Rows after the first are indented by the line's own indentation (at most half
/// the width), like most editors. The measure is character cells (tabs to the next tab stop,
/// wide characters two cells), so it does not depend on fonts and can be tested.
struct WrapResult {
    /// Byte offset where each row starts; the first is always 0.
    std::vector<uint32_t> rowStarts;
    /// Cells of indentation on every row after the first.
    uint32_t continuationIndent = 0;
};

/// Wraps `text`. `columns` below 4 is treated as 4.
WrapResult wrapLine(std::string_view text, uint32_t columns, uint32_t tabSize);

/// Only the number of rows (at least 1); does not allocate.
uint32_t countWrapRows(std::string_view text, uint32_t columns, uint32_t tabSize);

}  // namespace gw
