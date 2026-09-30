#pragma once

#include "TextBuffer.hpp"

#include <string>
#include <string_view>
#include <vector>

namespace gw {

/// Words already in the document that start with `prefix`, for completion in files that have
/// no language server. The word being typed at `caret` is not offered to itself. Commonest
/// first, then alphabetical. A prefix in all lower case matches any case ("fo" finds "Foo").
///
/// Only the lines within `lineRadius` of the caret are read, so a huge file stays quick.
std::vector<std::string> wordSuggestions(const TextBuffer& buffer, std::string_view prefix, Position caret,
                                         size_t maxResults = 200, size_t lineRadius = 20000);

}  // namespace gw
