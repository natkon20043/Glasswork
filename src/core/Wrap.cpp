#include "Wrap.hpp"

#include "CharacterWidth.hpp"

#include <algorithm>

namespace gw {

namespace {

/// The code point starting at `index` and how many bytes it uses. Bytes that are not valid
/// UTF-8 count as one-byte characters.
uint32_t decodeAt(std::string_view text, size_t index, size_t& length) {
    unsigned char lead = static_cast<unsigned char>(text[index]);
    length = 1;
    if (lead < 0x80) {
        return lead;
    }
    size_t expected = 0;
    uint32_t codePoint = 0;
    if ((lead >> 5) == 0x6) {
        expected = 2;
        codePoint = lead & 0x1F;
    } else if ((lead >> 4) == 0xE) {
        expected = 3;
        codePoint = lead & 0x0F;
    } else if ((lead >> 3) == 0x1E) {
        expected = 4;
        codePoint = lead & 0x07;
    } else {
        return lead;
    }
    if (index + expected > text.size()) {
        return lead;
    }
    for (size_t offset = 1; offset < expected; ++offset) {
        unsigned char next = static_cast<unsigned char>(text[index + offset]);
        if ((next & 0xC0) != 0x80) {
            return lead;
        }
        codePoint = (codePoint << 6) | (next & 0x3F);
    }
    length = expected;
    return codePoint;
}

/// Width in cells of the character at `index`, when it starts at cell `column` of its row.
uint32_t cellsAt(std::string_view text, size_t index, uint32_t column, uint32_t tabSize, size_t& length) {
    uint32_t codePoint = decodeAt(text, index, length);
    if (codePoint == '\t') {
        return tabSize - (column % tabSize);
    }
    return static_cast<uint32_t>(codePointCells(codePoint));
}

/// Cells taken by the leading spaces and tabs.
uint32_t leadingIndentCells(std::string_view text, uint32_t tabSize) {
    uint32_t column = 0;
    for (char character : text) {
        if (character == ' ') {
            ++column;
        } else if (character == '\t') {
            column += tabSize - (column % tabSize);
        } else {
            break;
        }
    }
    return column;
}

/// The shared algorithm. Fills `starts` when given.
uint32_t wrapInto(std::string_view text, uint32_t columns, uint32_t tabSize, std::vector<uint32_t>* starts,
                  uint32_t* continuationOut) {
    columns = std::max<uint32_t>(columns, 4);
    tabSize = std::max<uint32_t>(tabSize, 1);

    uint32_t indent = std::min(leadingIndentCells(text, tabSize), columns / 2);
    if (continuationOut != nullptr) {
        *continuationOut = indent;
    }
    if (starts != nullptr) {
        starts->clear();
        starts->push_back(0);
    }

    uint32_t rows = 1;
    size_t rowStart = 0;
    uint32_t column = 0;            // cell within the current row, counting its indentation
    size_t breakAfter = SIZE_MAX;   // byte where the row could break (just after a space)
    bool rowHasText = false;        // something other than spaces is on this row already

    size_t index = 0;
    while (index < text.size()) {
        size_t length = 1;
        uint32_t cells = cellsAt(text, index, column, tabSize, length);
        bool spaceLike = text[index] == ' ' || text[index] == '\t';

        bool overflows = column + cells > columns && column > (rows > 1 ? indent : 0);
        if (overflows && !spaceLike) {
            size_t newStart = index;
            if (breakAfter != SIZE_MAX && breakAfter > rowStart) {
                newStart = breakAfter;
            }
            ++rows;
            if (starts != nullptr) {
                starts->push_back(static_cast<uint32_t>(newStart));
            }
            rowStart = newStart;
            breakAfter = SIZE_MAX;
            rowHasText = false;
            // Measure what moved down to the new row.
            column = indent;
            size_t cursor = newStart;
            while (cursor < index) {
                size_t movedLength = 1;
                column += cellsAt(text, cursor, column, tabSize, movedLength);
                if (text[cursor] == ' ' || text[cursor] == '\t') {
                    if (rowHasText) {
                        breakAfter = cursor + movedLength;
                    }
                } else {
                    rowHasText = true;
                }
                cursor += movedLength;
            }
            // Recompute this character's width from its new column (tabs).
            cells = cellsAt(text, index, column, tabSize, length);
        }
        column += cells;
        if (spaceLike) {
            // Only a space after some text is a place to break; indentation is not.
            if (rowHasText) {
                breakAfter = index + length;
            }
        } else {
            rowHasText = true;
        }
        index += length;
    }
    return rows;
}

}  // namespace

WrapResult wrapLine(std::string_view text, uint32_t columns, uint32_t tabSize) {
    WrapResult result;
    wrapInto(text, columns, tabSize, &result.rowStarts, &result.continuationIndent);
    return result;
}

uint32_t countWrapRows(std::string_view text, uint32_t columns, uint32_t tabSize) {
    return wrapInto(text, columns, tabSize, nullptr, nullptr);
}

}  // namespace gw
