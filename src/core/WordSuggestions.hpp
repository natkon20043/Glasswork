#pragma once

#include "TextBuffer.hpp"

#include <string>
#include <string_view>
#include <vector>

namespace gw {

// ---- Suggestions

/// Document words starting with `prefix`, for files without a language server. The word being typed at
/// `caret` is excluded. Commonest first, then alphabetical; an all-lowercase prefix matches any case.
/// Reads only lines within `lineRadius` of the caret.
std::vector<std::string> wordSuggestions(const TextBuffer& buffer, std::string_view prefix, Position caret,
                                         size_t maxResults = 200, size_t lineRadius = 20000);

}  // namespace gw
