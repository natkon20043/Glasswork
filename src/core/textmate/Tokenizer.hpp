#pragma once

#include "Grammar.hpp"

#include <cstdint>
#include <string>
#include <vector>

namespace gw::tm {

/// One entry in an interned scope path, e.g. `source.cpp` › `string.quoted.double.cpp`.
/// Nodes are never freed, so a pointer identifies a scope path for the app's lifetime and
/// themes can cache their colour lookups by pointer.
struct ScopeNode {
    const ScopeNode* parent = nullptr;
    std::string name;
    size_t depth = 0;

    /// Outermost first.
    std::vector<std::string> path() const;
};

/// Pushes `name` (which may hold several space-separated scopes) onto `parent`.
const ScopeNode* pushScopes(const ScopeNode* parent, const std::string& name);

struct Token {
    uint32_t start;  // UTF-8 byte offsets within the line
    uint32_t end;
    const ScopeNode* scopes;
};

/// One open region on the tokenizer's stack.
struct Frame {
    Rule* rule = nullptr;                // whose patterns apply inside the region
    std::shared_ptr<Regex> end;          // how the region ends (back-references filled in)
    const ScopeNode* nameScopes = nullptr;
    const ScopeNode* contentScopes = nullptr;
    /// The begin match ran to the end of its line, so \G anchors at the next line's start.
    bool beganAtLineEnd = false;

    bool operator==(const Frame& other) const {
        return rule == other.rule && end == other.end && nameScopes == other.nameScopes &&
               contentScopes == other.contentScopes && beganAtLineEnd == other.beganAtLineEnd;
    }
};

/// Tokenizer state between lines: the stack of open regions. Comparing states tells the
/// highlighter when an edit's effect has stopped rippling down the file.
struct State {
    std::vector<Frame> frames;
    bool operator==(const State& other) const { return frames == other.frames; }
};

State initialState(Grammar& grammar);

struct LineResult {
    std::vector<Token> tokens;
    State state;
};

/// Tokenizes one line (without its line ending) given the state after the previous line.
/// `base` is the document's grammar, used for `$base` includes.
LineResult tokenizeLine(Grammar& base, const std::string& line, const State& previous);

}  // namespace gw::tm
