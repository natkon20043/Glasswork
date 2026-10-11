#pragma once

#include <string>
#include <string_view>

namespace gw {

/// Edit > Transform commands on UTF-8 text; non-ASCII letters are left alone.
std::string upperCaseText(std::string_view text);
std::string lowerCaseText(std::string_view text);
/// Capital at the start of each word, the rest lower case.
std::string titleCaseText(std::string_view text);

/// Lines separated by '\n'. Case counts (capitals first) unless `ignoreCase`. A final line break stays.
std::string sortLinesText(std::string_view text, bool descending, bool ignoreCase = false);

/// Keeps the first of each repeated line.
std::string uniqueLinesText(std::string_view text);

/// One space per break, next line's leading white space removed. A final line break is kept.
std::string joinLinesText(std::string_view text);

}  // namespace gw
