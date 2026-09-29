#pragma once

#include "Document.hpp"
#include "textmate/Tokenizer.hpp"

#include <deque>
#include <optional>
#include <vector>

namespace gw {

/// Keeps a document's syntax tokens up to date. Lines are tokenized top-down (each line's
/// state depends on the previous one). After an edit only lines from the change onward are
/// redone, and work stops as soon as a line's end state matches what it was before, because
/// everything below is then known to be unchanged.
class Highlighter {
public:
    explicit Highlighter(tm::Grammar* grammar = nullptr) : grammar_(grammar) {}

    void setGrammar(tm::Grammar* grammar);
    tm::Grammar* grammar() const { return grammar_; }

    /// Must be called for every document change, before the next `tokens` call.
    void didChange(const Change& change);

    /// Tokens for `line`, tokenizing any earlier lines first, but doing at most `budget`
    /// lines of work. Returns nullopt if the line isn't ready yet; call again later (the
    /// work done so far is kept). With no grammar, returns nullopt.
    const std::vector<tm::Token>* tokens(const TextBuffer& buffer, size_t line, size_t budget = 5000);

    /// Lines [0, validLines) have up-to-date tokens.
    size_t validLines() const { return valid_; }

    /// How far past the tokenized part a line may be for `tokens` to simply keep going down
    /// the file. Farther than that, a small "island" around the line is tokenized instead.
    static constexpr size_t kNearLines = 400;

private:
    /// A stretch of lines tokenized on its own, starting from a guessed starting point rather
    /// than the top of the file. Lets a jump far into a huge file show colours at once. The
    /// guess is right nearly always (top-level code has the same starting state everywhere).
    struct Island {
        size_t first = 0;                            // buffer line of the island's first entry
        std::deque<tm::State> states;                // the state after each line
        std::deque<std::vector<tm::Token>> tokens;   // deques keep earlier results in place
        size_t valid = 0;                            // entries before this are up to date
        size_t reusableFrom = 0;                     // like Highlighter's: after an edit, entries in
        size_t reusableUntil = 0;                    // this range are right again once states match
        size_t end() const { return first + valid; }
    };

    const std::vector<tm::Token>* islandTokens(const TextBuffer& buffer, size_t line);
    /// A line where tokenizing can start with the plain top-level state: a line at the left
    /// edge that follows a blank line, shortly above `line`.
    static size_t chooseAnchor(const TextBuffer& buffer, size_t line);

    std::vector<Island> islands_;  // most recently used last
    tm::Grammar* grammar_;
    std::vector<tm::State> states_;              // state after each line
    std::vector<std::vector<tm::Token>> tokens_;
    size_t valid_ = 0;          // lines before this are current
    size_t reusableFrom_ = 0;   // from the last edited line up to reusableUntil_, slots hold
    size_t reusableUntil_ = 0;  // pre-edit results, still right once end states match again
};

}  // namespace gw
