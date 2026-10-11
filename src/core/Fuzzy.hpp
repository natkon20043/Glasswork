#pragma once

#include <cstdint>
#include <optional>
#include <string_view>
#include <vector>

namespace gw {

struct FuzzyMatch {
    int score = 0;
    /// Byte offsets of matched query characters in the candidate, for highlighting.
    std::vector<uint32_t> positions;
};

/// Quick-open style matching: query characters must appear in order, ignoring case. Higher for
/// word starts, consecutive runs, and hits in the file name. `nameStart` is where the file name
/// begins in `candidate`. Nothing if no match.
std::optional<FuzzyMatch> fuzzyMatch(std::string_view query, std::string_view candidate, size_t nameStart = 0);

/// Same score without positions and without allocating; thread-safe. Score everything with this,
/// then call fuzzyMatch only for the rows shown.
std::optional<int> fuzzyScore(std::string_view query, std::string_view candidate, size_t nameStart = 0);

}  // namespace gw
