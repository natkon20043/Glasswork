#pragma once

#include "Grammar.hpp"

#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace gw::tm {

/// One entry in an interned scope path, e.g. `source.cpp` > `string.quoted.double.cpp`. Never freed, so
/// a pointer identifies a path for the app's lifetime and themes can cache by pointer.
struct ScopeNode {
    /// Outermost first.
    std::vector<std::string> path() const;

    const ScopeNode* parent = nullptr;
    std::string name;
    size_t depth = 0;
};

struct Token {
    /// UTF-8 byte offsets within the line.
    uint32_t start;
    uint32_t end;
    const ScopeNode* scopes;
};

/// One open region on the tokenizer's stack.
struct Frame {
    bool operator==(const Frame& other) const {
        return rule == other.rule && end == other.end && nameScopes == other.nameScopes &&
               contentScopes == other.contentScopes && beganAtLineEnd == other.beganAtLineEnd;
    }

    /// Whose patterns apply inside the region.
    Rule* rule = nullptr;
    /// How the region ends, back-references filled in.
    std::shared_ptr<Regex> end;
    const ScopeNode* nameScopes = nullptr;
    const ScopeNode* contentScopes = nullptr;
    /// The begin match ran to the line end, so \G anchors at the next line's start.
    bool beganAtLineEnd = false;
};

/// Stack of open regions between lines. Comparing states tells the highlighter when an edit stopped
/// rippling down the file.
struct State {
    bool operator==(const State& other) const { return frames == other.frames; }

    std::vector<Frame> frames;
};

struct LineResult {
    std::vector<Token> tokens;
    State state;
};

/// `name` may hold several space-separated scopes.
const ScopeNode* pushScopes(const ScopeNode* parent, const std::string& name);

State initialState(Grammar& grammar);

/// `line` has no line ending; `previous` is the state after the previous line; `base` is the
/// document's grammar (for `$base`).
LineResult tokenizeLine(Grammar& base, std::string_view line, const State& previous);

}  // namespace gw::tm
