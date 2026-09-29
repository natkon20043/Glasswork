#pragma once

#include <cstdint>

namespace gw {

/// How many character cells a code point takes on screen in a monospaced font: 0 for
/// combining marks, 2 for East Asian wide characters and emoji, otherwise 1.
int codePointCells(uint32_t codePoint);

}  // namespace gw
