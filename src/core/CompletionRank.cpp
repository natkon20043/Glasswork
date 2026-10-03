#include "CompletionRank.hpp"

#include "Fuzzy.hpp"

#include <algorithm>

namespace gw {

namespace {

char lowerCase(char character) {
    if (character >= 'A' && character <= 'Z') {
        return static_cast<char>(character - 'A' + 'a');
    }
    return character;
}

bool startsWithIgnoringCase(std::string_view text, std::string_view prefix) {
    if (prefix.size() > text.size()) {
        return false;
    }
    for (size_t index = 0; index < prefix.size(); ++index) {
        if (lowerCase(text[index]) != lowerCase(prefix[index])) {
            return false;
        }
    }
    return true;
}

bool startsWithExactCase(std::string_view text, std::string_view prefix) {
    return text.substr(0, prefix.size()) == prefix;
}

/// How many of the typed letters sit in the candidate with exactly the case typed. Typing
/// "Vec" should favour "Vec" over "vec" when both match.
int sameCaseLetters(std::string_view query, std::string_view candidate) {
    int count = 0;
    size_t scan = 0;
    for (char wanted : query) {
        while (scan < candidate.size() && lowerCase(candidate[scan]) != lowerCase(wanted)) {
            ++scan;
        }
        if (scan == candidate.size()) {
            break;
        }
        if (candidate[scan] == wanted) {
            ++count;
        }
        ++scan;
    }
    return count;
}

struct Scored {
    size_t index;
    int score;
};

}  // namespace

void CompletionHistory::accepted(const std::string& label, int kind) {
    for (auto entry = recent_.begin(); entry != recent_.end(); ++entry) {
        if (entry->label == label && entry->kind == kind) {
            recent_.erase(entry);
            break;
        }
    }
    recent_.push_front(Entry{label, kind});
    while (recent_.size() > capacity_) {
        recent_.pop_back();
    }
}

int CompletionHistory::boost(const std::string& label, int kind) const {
    for (size_t position = 0; position < recent_.size(); ++position) {
        if (recent_[position].label == label && recent_[position].kind == kind) {
            // The newest gets the full boost, fading to a small one for the oldest.
            int fade = static_cast<int>(position) * maximumBoost / static_cast<int>(capacity_ + 1);
            return std::max(1, maximumBoost - fade);
        }
    }
    return 0;
}

std::vector<size_t> rankCompletions(std::string_view query,
                                    const std::vector<CompletionCandidate>& candidates,
                                    const CompletionHistory& history,
                                    size_t limit) {
    std::vector<Scored> scored;
    scored.reserve(candidates.size());

    for (size_t index = 0; index < candidates.size(); ++index) {
        const CompletionCandidate& candidate = candidates[index];
        const std::string& text = candidate.filterText.empty() ? candidate.label : candidate.filterText;

        int score = 0;
        if (!query.empty()) {
            std::optional<int> fuzzy = fuzzyScore(query, text);
            if (!fuzzy) {
                continue;
            }
            score = *fuzzy;
            if (startsWithExactCase(text, query)) {
                score += 400;
            } else if (startsWithIgnoringCase(text, query)) {
                score += 300;
            }
            if (text.size() == query.size() && startsWithIgnoringCase(text, query)) {
                score += 100;  // the whole name typed
            }
            score += sameCaseLetters(query, text) * 2;
        }

        score += history.boost(candidate.label, candidate.kind);
        if (query.empty() && candidate.preselect) {
            score += 1000;
        }
        if (candidate.deprecated) {
            score -= 150;
        }
        scored.push_back(Scored{index, score});
    }

    std::stable_sort(scored.begin(), scored.end(), [&](const Scored& a, const Scored& b) {
        if (a.score != b.score) {
            return a.score > b.score;
        }
        const CompletionCandidate& left = candidates[a.index];
        const CompletionCandidate& right = candidates[b.index];
        if (left.sortText != right.sortText) {
            return left.sortText < right.sortText;
        }
        if (left.label.size() != right.label.size()) {
            return left.label.size() < right.label.size();
        }
        return a.index < b.index;
    });

    std::vector<size_t> result;
    size_t count = std::min(limit, scored.size());
    result.reserve(count);
    for (size_t position = 0; position < count; ++position) {
        result.push_back(scored[position].index);
    }
    return result;
}

}  // namespace gw
