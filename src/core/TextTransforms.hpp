#pragma once

#include <string>
#include <string_view>

namespace gw {

/// Text commands for the Edit ▸ Transform menu. They work on plain UTF-8 text; letters
/// outside ASCII are left as they are.
std::string upperCaseText(std::string_view text);
std::string lowerCaseText(std::string_view text);
/// Capital letter at the start of each word, the rest lower case.
std::string titleCaseText(std::string_view text);

/// Sorts the lines of `text` (separated by '\n'). Case counts, so capitals come first, unless
/// `ignoreCase` is set. A final line break stays a final line break.
std::string sortLinesText(std::string_view text, bool descending, bool ignoreCase = false);

/// Removes repeated lines, keeping the first of each.
std::string uniqueLinesText(std::string_view text);

/// Joins lines into one, with a single space where each break was and the next line's
/// leading white space removed. A final line break is kept.
std::string joinLinesText(std::string_view text);

}  // namespace gw
