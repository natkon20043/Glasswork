#pragma once

#include "TextBuffer.hpp"

namespace gw {

/// Next bigger selection: word, inside brackets, brackets too, line, enclosing brackets... up to the
/// document. Returns `current` when nothing bigger exists. Brackets in strings and comments count.
Range expandedSelection(const TextBuffer& buffer, Range current);

}  // namespace gw
