#pragma once

#include "Document.hpp"
#include "textmate/Tokenizer.hpp"

#include <deque>
#include <optional>
#include <vector>

namespace gw {

/// Keeps a document's syntax tokens current. Tokenizes top-down; after an edit only lines from the
/// change on are redone, stopping once a line's end state matches its old one.
class Highlighter {
public:
    // ---- Constructors
    explicit Highlighter(tm::Grammar* grammar = nullptr) : grammar_(grammar) {}

    // ---- Setters
    void setGrammar(tm::Grammar* grammar);

    // ---- Editing
    /// Call for every document change, before the next `tokens`.
    void didChange(const Change& change);

    // ---- Tokens
    /// Does at most `budget` lines of work. Nullopt-like null if the line isn't ready (call again,
    /// progress is kept) or there is no grammar.
    const std::vector<tm::Token>* tokens(const TextBuffer& buffer, size_t line, size_t budget = 5000);

    // ---- Getters
    tm::Grammar* grammar() const { return grammar_; }
    /// Lines [0, validLines) have current tokens.
    size_t validLines() const { return valid_; }

    // ---- Constants
    /// Beyond this many lines past the tokenized part, a small island around the line is tokenized instead.
    static constexpr size_t kNearLines = 400;

private:
    /// Lines tokenized on their own from a guessed top-level start, so jumping far into a huge file
    /// shows colors at once.
    struct Island {
        size_t end() const { return first + valid; }

        size_t first = 0;
        std::deque<tm::State> states;
        // Deques keep earlier results in place.
        std::deque<std::vector<tm::Token>> tokens;
        size_t valid = 0;
        // After an edit, entries in [reusableFrom, reusableUntil) are right again once states match.
        size_t reusableFrom = 0;
        size_t reusableUntil = 0;
    };

    // ---- Private functions
    const std::vector<tm::Token>* islandTokens(const TextBuffer& buffer, size_t line);
    /// A left-edge line after a blank line shortly above `line`, where plain top-level state can start.
    static size_t chooseAnchor(const TextBuffer& buffer, size_t line);

    // ---- Private variables
    // Most recently used last.
    std::vector<Island> islands_;
    tm::Grammar* grammar_;
    // State after each line.
    std::vector<tm::State> states_;
    std::vector<std::vector<tm::Token>> tokens_;
    size_t valid_ = 0;
    // From the last edited line to reusableUntil_, slots hold pre-edit results.
    size_t reusableFrom_ = 0;
    size_t reusableUntil_ = 0;
};

}  // namespace gw
