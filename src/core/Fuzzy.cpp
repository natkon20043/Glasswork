#include "Fuzzy.hpp"

#include <algorithm>
#include <limits>

namespace gw {

namespace {

/// ASCII lower-casing; faster than std::tolower, which consults the C locale.
char lower(char character) {
    if (character >= 'A' && character <= 'Z') {
        return static_cast<char>(character - 'A' + 'a');
    }
    return character;
}

bool isLower(char character) {
    return character >= 'a' && character <= 'z';
}

bool isUpper(char character) {
    return character >= 'A' && character <= 'Z';
}

bool isSeparator(char character) {
    return character == '/' || character == '_' || character == '-' || character == '.' || character == ' ';
}

/// Extra points for a match at this position of the candidate.
int positionBonus(std::string_view candidate, size_t position, size_t nameStart) {
    int bonus = 0;
    if (position == 0 || position == nameStart) {
        bonus += 10;  // start of the path or of the file name
    } else if (isSeparator(candidate[position - 1])) {
        bonus += 8;  // start of a word: "gw" → "glass_work"
    } else if (isLower(candidate[position - 1]) && isUpper(candidate[position])) {
        bonus += 7;  // camelCase hump: "ev" → "EditorView"
    }
    if (position >= nameStart) {
        bonus += 3;  // matches in the file name matter more than in its folders
    }
    return bonus;
}

/// Quick rejection: true when every query character appears in order (ignoring case).
bool containsInOrder(std::string_view query, std::string_view candidate) {
    size_t scan = 0;
    for (char wanted : query) {
        char wantedLower = lower(wanted);
        while (scan < candidate.size() && lower(candidate[scan]) != wantedLower) {
            ++scan;
        }
        if (scan == candidate.size()) {
            return false;
        }
        ++scan;
    }
    return true;
}

const int kImpossible = std::numeric_limits<int>::min() / 2;

}  // namespace

std::optional<int> fuzzyScore(std::string_view query, std::string_view candidate, size_t nameStart) {
    if (query.empty()) {
        return 0;
    }
    if (!containsInOrder(query, candidate)) {
        return std::nullopt;
    }

    // The same recurrence as fuzzyMatch below, but row i only ever reads row i-1, so two
    // rows are enough. They are reused between calls (one pair per thread).
    const size_t candidateLength = candidate.size();
    thread_local std::vector<int> previousRow;
    thread_local std::vector<int> currentRow;
    previousRow.assign(candidateLength, kImpossible);
    currentRow.assign(candidateLength, kImpossible);

    const char firstWanted = lower(query[0]);
    for (size_t j = 0; j < candidateLength; ++j) {
        if (lower(candidate[j]) == firstWanted) {
            previousRow[j] = positionBonus(candidate, j, nameStart) - static_cast<int>(j) / 4;
        }
    }
    for (size_t i = 1; i < query.size(); ++i) {
        const char wanted = lower(query[i]);
        std::fill(currentRow.begin(), currentRow.end(), kImpossible);
        int bestEarlier = kImpossible;
        for (size_t j = i; j < candidateLength; ++j) {
            const int atPrevious = previousRow[j - 1];
            if (atPrevious > bestEarlier) {
                bestEarlier = atPrevious;
            }
            if (lower(candidate[j]) != wanted) {
                continue;
            }
            const int bonus = positionBonus(candidate, j, nameStart);

            int consecutive = kImpossible;
            if (atPrevious > kImpossible) {
                consecutive = atPrevious + bonus + 6;
            }
            int gapped = kImpossible;
            if (bestEarlier > kImpossible) {
                gapped = bestEarlier + bonus - 2;
            }
            currentRow[j] = std::max(consecutive, gapped);
        }
        std::swap(previousRow, currentRow);
    }

    int bestScore = kImpossible;
    for (size_t j = 0; j < candidateLength; ++j) {
        bestScore = std::max(bestScore, previousRow[j]);
    }
    if (bestScore <= kImpossible) {
        return std::nullopt;
    }
    return bestScore - static_cast<int>(candidateLength) / 8;  // shorter candidates win ties
}

std::optional<FuzzyMatch> fuzzyMatch(std::string_view query, std::string_view candidate, size_t nameStart) {
    if (query.empty()) {
        return FuzzyMatch{};
    }
    if (!containsInOrder(query, candidate)) {
        return std::nullopt;
    }

    // Dynamic programming: best[i][j] is the best score for matching the first i+1 query
    // characters with query[i] landing on candidate[j]. `from` remembers where query[i-1]
    // landed, to recover the matched positions afterwards.
    const size_t queryLength = query.size();
    const size_t candidateLength = candidate.size();
    const int impossible = kImpossible;
    std::vector<int> best(queryLength * candidateLength, impossible);
    std::vector<int> from(queryLength * candidateLength, -1);
    auto cell = [candidateLength](size_t i, size_t j) { return i * candidateLength + j; };

    for (size_t j = 0; j < candidateLength; ++j) {
        if (lower(candidate[j]) == lower(query[0])) {
            best[cell(0, j)] = positionBonus(candidate, j, nameStart) - static_cast<int>(j) / 4;
        }
    }
    for (size_t i = 1; i < queryLength; ++i) {
        // Running best over earlier positions of the previous character, for gap matches.
        int bestEarlier = impossible;
        int bestEarlierAt = -1;
        for (size_t j = i; j < candidateLength; ++j) {
            size_t previous = j - 1;
            if (best[cell(i - 1, previous)] > bestEarlier) {
                bestEarlier = best[cell(i - 1, previous)];
                bestEarlierAt = static_cast<int>(previous);
            }
            if (lower(candidate[j]) != lower(query[i])) {
                continue;
            }
            int bonus = positionBonus(candidate, j, nameStart);

            // Option 1: directly after the previous match (a consecutive run).
            int consecutive = best[cell(i - 1, previous)];
            if (consecutive > impossible) {
                consecutive += bonus + 6;
            }
            // Option 2: after a gap, with a small penalty.
            int gapped = bestEarlier;
            if (gapped > impossible) {
                gapped += bonus - 2;
            }

            if (consecutive >= gapped && consecutive > impossible) {
                best[cell(i, j)] = consecutive;
                from[cell(i, j)] = static_cast<int>(previous);
            } else if (gapped > impossible) {
                best[cell(i, j)] = gapped;
                from[cell(i, j)] = bestEarlierAt;
            }
        }
    }

    // Pick the best end position, then walk back to collect the matched positions.
    int bestScore = impossible;
    int end = -1;
    for (size_t j = 0; j < candidateLength; ++j) {
        if (best[cell(queryLength - 1, j)] > bestScore) {
            bestScore = best[cell(queryLength - 1, j)];
            end = static_cast<int>(j);
        }
    }
    if (end < 0) {
        return std::nullopt;
    }

    FuzzyMatch match;
    match.score = bestScore - static_cast<int>(candidateLength) / 8;  // shorter candidates win ties
    match.positions.resize(queryLength);
    int position = end;
    for (size_t i = queryLength; i-- > 0;) {
        match.positions[i] = static_cast<uint32_t>(position);
        position = from[cell(i, static_cast<size_t>(position))];
    }
    return match;
}

}  // namespace gw
