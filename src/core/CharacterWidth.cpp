#include "CharacterWidth.hpp"

#include <cstddef>

namespace gw {

namespace {

struct CodePointRange {
    uint32_t first;
    uint32_t last;
};

/// Combining marks, zero-width joiners and variation selectors: they take no room of their own.
constexpr CodePointRange kZeroWidth[] = {
    {0x0300, 0x036F}, {0x0483, 0x0489}, {0x0591, 0x05BD}, {0x1AB0, 0x1AFF}, {0x1DC0, 0x1DFF},
    {0x200B, 0x200F}, {0x2028, 0x202E}, {0x2060, 0x2064}, {0x20D0, 0x20FF}, {0xFE00, 0xFE0F},
    {0xFE20, 0xFE2F}, {0xFEFF, 0xFEFF}, {0xE0100, 0xE01EF},
};

/// East Asian wide and fullwidth characters, and emoji.
constexpr CodePointRange kDoubleWidth[] = {
    {0x1100, 0x115F},   {0x2329, 0x232A},   {0x2E80, 0x303E},   {0x3041, 0x33FF},   {0x3400, 0x4DBF},
    {0x4E00, 0x9FFF},   {0xA000, 0xA4CF},   {0xAC00, 0xD7A3},   {0xF900, 0xFAFF},   {0xFE30, 0xFE6F},
    {0xFF00, 0xFF60},   {0xFFE0, 0xFFE6},   {0x1F300, 0x1F64F}, {0x1F680, 0x1F6FF}, {0x1F900, 0x1F9FF},
    {0x1FA70, 0x1FAFF}, {0x20000, 0x3FFFD},
};

template <size_t Count>
bool isInAny(uint32_t codePoint, const CodePointRange (&ranges)[Count]) {
    for (const CodePointRange& range : ranges) {
        if (codePoint >= range.first && codePoint <= range.last) {
            return true;
        }
    }
    return false;
}

}  // namespace

int codePointCells(uint32_t codePoint) {
    // Everything below the combining marks is one cell; most text never gets past this.
    if (codePoint < 0x300) {
        return 1;
    }
    if (isInAny(codePoint, kZeroWidth)) {
        return 0;
    }
    if (isInAny(codePoint, kDoubleWidth)) {
        return 2;
    }
    return 1;
}

}  // namespace gw
