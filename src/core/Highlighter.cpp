#include "Highlighter.hpp"

#include <algorithm>

namespace gw {

void Highlighter::setGrammar(tm::Grammar* grammar) {
    grammar_ = grammar;
    islands_.clear();
    states_.clear();
    tokens_.clear();
    valid_ = reusableFrom_ = reusableUntil_ = 0;
}

void Highlighter::didChange(const Change& change) {
    // Islands: one that starts at or after the edit is dropped. One the edit lands inside keeps
    // its lines and, like the main list, re-tokenizes only until states agree again.
    for (size_t index = islands_.size(); index-- > 0;) {
        Island& island = islands_[index];
        if (island.first >= change.firstLine) {
            islands_.erase(islands_.begin() + static_cast<long>(index));
            continue;
        }
        size_t inside = change.firstLine - island.first;
        if (inside >= island.tokens.size()) continue;  // after the island: nothing to do
        if (change.lineDelta > 0) {
            island.states.insert(island.states.begin() + static_cast<long>(inside), static_cast<size_t>(change.lineDelta), tm::State{});
            island.tokens.insert(island.tokens.begin() + static_cast<long>(inside), static_cast<size_t>(change.lineDelta),
                                 std::vector<tm::Token>{});
        } else if (change.lineDelta < 0) {
            size_t count = std::min(static_cast<size_t>(-change.lineDelta), island.tokens.size() - inside);
            if (inside + count >= island.tokens.size()) count = island.tokens.size() - inside - 1;
            island.states.erase(island.states.begin() + static_cast<long>(inside), island.states.begin() + static_cast<long>(inside + count));
            island.tokens.erase(island.tokens.begin() + static_cast<long>(inside), island.tokens.begin() + static_cast<long>(inside + count));
        }
        size_t lastEdited = inside + static_cast<size_t>(std::max(0L, change.lineDelta));
        if (island.valid > inside) {
            long shifted = static_cast<long>(island.valid) + change.lineDelta;
            island.reusableFrom = lastEdited;
            island.reusableUntil = static_cast<size_t>(std::max(shifted, static_cast<long>(lastEdited)));
        } else {
            island.reusableFrom = island.reusableUntil = 0;
        }
        island.valid = std::min(island.valid, inside);
    }

    size_t first = std::min(change.firstLine, states_.size());
    // Keep the per-line arrays aligned with the buffer. Entries are added or removed at the
    // start of the edited range, so the slot of the last edited line keeps the old end state
    // of the last line the edit replaced: exactly what its new end state is compared with.
    if (change.lineDelta > 0) {
        size_t count = static_cast<size_t>(change.lineDelta);
        states_.insert(states_.begin() + static_cast<long>(first), count, tm::State{});
        tokens_.insert(tokens_.begin() + static_cast<long>(first), count, {});
    } else if (change.lineDelta < 0) {
        size_t count = std::min(static_cast<size_t>(-change.lineDelta), states_.size() - first);
        if (first + count >= states_.size()) count = states_.size() > first ? states_.size() - first - 1 : 0;
        states_.erase(states_.begin() + static_cast<long>(first), states_.begin() + static_cast<long>(first + count));
        tokens_.erase(tokens_.begin() + static_cast<long>(first), tokens_.begin() + static_cast<long>(first + count));
    }
    size_t lastEdited = first + static_cast<size_t>(std::max(0L, change.lineDelta));
    if (valid_ > first) {
        long shifted = static_cast<long>(valid_) + change.lineDelta;
        reusableFrom_ = lastEdited;
        reusableUntil_ = static_cast<size_t>(std::max(shifted, static_cast<long>(lastEdited)));
    } else {
        reusableFrom_ = reusableUntil_ = 0;
    }
    valid_ = std::min(valid_, first);
}

const std::vector<tm::Token>* Highlighter::tokens(const TextBuffer& buffer, size_t line, size_t budget) {
    if (!grammar_ || line >= buffer.lineCount()) return nullptr;
    if (states_.size() != buffer.lineCount()) {
        states_.resize(buffer.lineCount());
        tokens_.resize(buffer.lineCount());
        valid_ = std::min(valid_, buffer.lineCount());
        reusableUntil_ = std::min(reusableUntil_, buffer.lineCount());
    }
    if (line < valid_) return &tokens_[line];
    if (line - valid_ >= kNearLines) return islandTokens(buffer, line);

    size_t work = 0;
    while (valid_ <= line) {
        if (work >= budget) return nullptr;
        auto result = tm::tokenizeLine(*grammar_, buffer.line(valid_),
                                       valid_ == 0 ? tm::initialState(*grammar_) : states_[valid_ - 1]);
        // Past the edit: if this line now ends in the same state as before the edit, every
        // line after it (up to the old frontier) still has correct tokens.
        bool converged = valid_ >= reusableFrom_ && valid_ < reusableUntil_ && result.state == states_[valid_];
        tokens_[valid_] = std::move(result.tokens);
        states_[valid_] = std::move(result.state);
        ++valid_;
        ++work;
        if (converged) {
            valid_ = std::max(valid_, reusableUntil_);
            reusableFrom_ = reusableUntil_ = 0;
        }
    }
    return &tokens_[line];
}

size_t Highlighter::chooseAnchor(const TextBuffer& buffer, size_t line) {
    const size_t reach = 160;
    size_t lowest = line > reach ? line - reach : 0;
    // Start a little above the wanted line, so the island has some code to settle in on.
    size_t from = line > 12 ? line - 12 : 0;
    for (size_t candidate = from + 1; candidate-- > lowest;) {
        std::string_view text = buffer.line(candidate);
        if (text.empty() || text[0] == ' ' || text[0] == '\t') continue;
        bool afterBlank = candidate == 0;
        if (!afterBlank) {
            std::string_view above = buffer.line(candidate - 1);
            afterBlank = above.find_first_not_of(" \t") == std::string::npos;
        }
        if (afterBlank) return candidate;
    }
    return line > 80 ? line - 80 : 0;
}

const std::vector<tm::Token>* Highlighter::islandTokens(const TextBuffer& buffer, size_t line) {
    const size_t lookAhead = 40;        // tokenize a bit past the wanted line, ready for scrolling
    const size_t extendReach = 250;     // continue an island rather than start a new one
    const size_t maxIslands = 4;

    size_t found = islands_.size();
    for (size_t index = islands_.size(); index-- > 0;) {
        const Island& island = islands_[index];
        if (line >= island.first && line < island.end() + extendReach) {
            found = index;
            break;
        }
    }
    if (found == islands_.size()) {
        if (islands_.size() >= maxIslands) islands_.erase(islands_.begin());
        Island fresh;
        fresh.first = chooseAnchor(buffer, line);
        islands_.push_back(std::move(fresh));
        found = islands_.size() - 1;
    } else if (found + 1 != islands_.size()) {
        std::rotate(islands_.begin() + static_cast<long>(found), islands_.begin() + static_cast<long>(found) + 1, islands_.end());
        found = islands_.size() - 1;
    }

    Island& island = islands_[found];
    size_t wanted = line - island.first;
    size_t stop = std::min(buffer.lineCount() - island.first, wanted + lookAhead + 1);
    while (island.valid < stop) {
        size_t index = island.valid;
        auto result = tm::tokenizeLine(*grammar_, buffer.line(island.first + index),
                                       index == 0 ? tm::initialState(*grammar_) : island.states[index - 1]);
        bool converged = index >= island.reusableFrom && index < island.reusableUntil && index < island.states.size() &&
                         result.state == island.states[index];
        if (index < island.tokens.size()) {
            island.tokens[index] = std::move(result.tokens);
            island.states[index] = std::move(result.state);
        } else {
            island.tokens.push_back(std::move(result.tokens));
            island.states.push_back(std::move(result.state));
        }
        ++island.valid;
        if (converged) {
            island.valid = std::max(island.valid, island.reusableUntil);
            island.reusableFrom = island.reusableUntil = 0;
        }
    }
    return &island.tokens[wanted];
}

}  // namespace gw
