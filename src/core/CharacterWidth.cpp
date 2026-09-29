#include "CharacterWidth.hpp"

namespace gw {

int codePointCells(uint32_t c) {
    if (c < 0x300) return 1;
    // Combining marks, zero-width joiners and variation selectors take no room of their own.
    if ((c >= 0x0300 && c <= 0x036F) || (c >= 0x0483 && c <= 0x0489) || (c >= 0x0591 && c <= 0x05BD) ||
        (c >= 0x200B && c <= 0x200F) || (c >= 0x2028 && c <= 0x202E) || (c >= 0x2060 && c <= 0x2064) ||
        (c >= 0x20D0 && c <= 0x20FF) || (c >= 0xFE00 && c <= 0xFE0F) || (c >= 0xFE20 && c <= 0xFE2F) || c == 0xFEFF ||
        (c >= 0x1AB0 && c <= 0x1AFF) || (c >= 0x1DC0 && c <= 0x1DFF) || (c >= 0xE0100 && c <= 0xE01EF)) {
        return 0;
    }
    // East Asian wide and fullwidth characters, and emoji.
    if ((c >= 0x1100 && c <= 0x115F) || c == 0x2329 || c == 0x232A || (c >= 0x2E80 && c <= 0x303E) ||
        (c >= 0x3041 && c <= 0x33FF) || (c >= 0x3400 && c <= 0x4DBF) || (c >= 0x4E00 && c <= 0x9FFF) ||
        (c >= 0xA000 && c <= 0xA4CF) || (c >= 0xAC00 && c <= 0xD7A3) || (c >= 0xF900 && c <= 0xFAFF) ||
        (c >= 0xFE30 && c <= 0xFE6F) || (c >= 0xFF00 && c <= 0xFF60) || (c >= 0xFFE0 && c <= 0xFFE6) ||
        (c >= 0x1F300 && c <= 0x1F64F) || (c >= 0x1F680 && c <= 0x1F6FF) || (c >= 0x1F900 && c <= 0x1F9FF) ||
        (c >= 0x1FA70 && c <= 0x1FAFF) || (c >= 0x20000 && c <= 0x3FFFD)) {
        return 2;
    }
    return 1;
}

}  // namespace gw
