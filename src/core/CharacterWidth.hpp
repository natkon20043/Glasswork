#pragma once

#include <cstdint>

namespace gw {

// ---- Measuring

/// Monospace cells a code point takes: 0 combining marks, 2 wide/emoji, otherwise 1.
int codePointCells(uint32_t codePoint);

}  // namespace gw
