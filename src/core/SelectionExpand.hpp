#pragma once

#include "TextBuffer.hpp"

namespace gw {

/// The next bigger sensible selection around `current`, for Expand Selection: the word, then
/// what is inside the brackets around it, then the brackets too, the whole line, the brackets
/// around those, and so on out to the whole document. Returns `current` when nothing bigger
/// exists. Brackets inside strings and comments are counted like any others.
Range expandedSelection(const TextBuffer& buffer, Range current);

}  // namespace gw
