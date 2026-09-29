#pragma once

#include <cstdint>
#include <optional>
#include <string_view>
#include <vector>

namespace gw {

struct FuzzyMatch {
    int score = 0;
    /// Byte offsets in the candidate of the matched query characters (for highlighting).
    std::vector<uint32_t> positions;
};

/// Matches `query` against `candidate` the way quick-open pickers do: every query character
/// must appear in order (ignoring case), and matches score higher when they land on word
/// starts ("gw" in "glass_work"), run consecutively, or fall in the file name rather than
/// its folders. `nameStart` is where the file name begins in `candidate` (0 if it is only a
/// name). Returns nullopt when the query doesn't match at all.
std::optional<FuzzyMatch> fuzzyMatch(std::string_view query, std::string_view candidate, size_t nameStart = 0);

/// The same score as fuzzyMatch, without the matched positions. Much cheaper (no allocation
/// per candidate), so pickers score every file with this and call fuzzyMatch only for the
/// handful of rows they actually show. Safe to call from several threads at once.
std::optional<int> fuzzyScore(std::string_view query, std::string_view candidate, size_t nameStart = 0);

}  // namespace gw
