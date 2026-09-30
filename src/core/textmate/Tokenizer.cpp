#include "Tokenizer.hpp"

#include <algorithm>
#include <map>
#include <mutex>
#include <unordered_map>

namespace gw::tm {

// MARK: Scope interning

std::vector<std::string> ScopeNode::path() const {
    std::vector<std::string> names;
    for (const ScopeNode* node = this; node; node = node->parent) names.push_back(node->name);
    std::reverse(names.begin(), names.end());
    return names;
}

const ScopeNode* pushScopes(const ScopeNode* parent, const std::string& name) {
    static std::mutex mutex;
    static std::map<std::pair<const ScopeNode*, std::string>, std::unique_ptr<ScopeNode>> nodes;
    const ScopeNode* node = parent;
    size_t start = 0;
    std::lock_guard lock(mutex);
    while (start < name.size()) {
        size_t space = name.find(' ', start);
        std::string part = name.substr(start, space == std::string::npos ? std::string::npos : space - start);
        start = space == std::string::npos ? name.size() : space + 1;
        if (part.empty()) continue;
        auto key = std::make_pair(node, part);
        auto found = nodes.find(key);
        if (found == nodes.end()) {
            auto created = std::make_unique<ScopeNode>();
            created->parent = node;
            created->name = part;
            created->depth = node ? node->depth + 1 : 1;
            found = nodes.emplace(key, std::move(created)).first;
        }
        node = found->second.get();
    }
    return node;
}

State initialState(Grammar& grammar) {
    Frame root;
    root.rule = grammar.root();
    root.nameScopes = pushScopes(nullptr, grammar.scopeName());
    root.contentScopes = root.nameScopes;
    return State{{root}};
}

namespace {

/// Lines longer than this are only partly highlighted, so minified files stay responsive.
constexpr size_t kMaxTokenizedBytes = 20000;
constexpr int kMaxIterationsPerLine = 20000;

/// "$1" and "${1:/downcase}" in scope names refer to captured text.
std::string substituteCaptures(const std::string& name, const Match& match, const std::string& text) {
    if (name.find('$') == std::string::npos) return name;
    std::string result;
    for (size_t index = 0; index < name.size(); ++index) {
        if (name[index] != '$' || index + 1 >= name.size()) {
            result += name[index];
            continue;
        }
        size_t cursor = index + 1;
        bool braced = name[cursor] == '{';
        if (braced) ++cursor;
        size_t digits = cursor;
        while (digits < name.size() && std::isdigit(static_cast<unsigned char>(name[digits]))) ++digits;
        if (digits == cursor) {
            result += name[index];
            continue;
        }
        int group = std::stoi(name.substr(cursor, digits - cursor));
        std::string transform;
        if (braced) {
            size_t close = name.find('}', digits);
            if (close == std::string::npos) {
                result += name[index];
                continue;
            }
            transform = name.substr(digits, close - digits);
            digits = close + 1;
        }
        std::string captured;
        if (group < static_cast<int>(match.groups.size()) && match.groups[group].first >= 0) {
            captured = text.substr(match.groups[group].first, match.groups[group].second - match.groups[group].first);
            // Scope names can't contain dots from user text (e.g. HTML tag names).
            while (!captured.empty() && captured.front() == '.') captured.erase(0, 1);
        }
        if (transform == ":/downcase") std::transform(captured.begin(), captured.end(), captured.begin(), ::tolower);
        if (transform == ":/upcase") std::transform(captured.begin(), captured.end(), captured.begin(), ::toupper);
        result += captured;
        index = digits - 1;
    }
    return result;
}

/// Fills \1…\9 in an end pattern with the text the begin pattern captured.
std::string fillBackReferences(const std::string& source, const Match& match, const std::string& text) {
    std::string result;
    for (size_t index = 0; index < source.size(); ++index) {
        if (source[index] == '\\' && index + 1 < source.size()) {
            char next = source[index + 1];
            if (std::isdigit(static_cast<unsigned char>(next))) {
                int group = next - '0';
                if (group < static_cast<int>(match.groups.size()) && match.groups[group].first >= 0) {
                    result += escapeForRegex(text.substr(match.groups[group].first,
                                                         match.groups[group].second - match.groups[group].first));
                }
                ++index;
                continue;
            }
            result += source[index];
            result += next;
            ++index;
            continue;
        }
        result += source[index];
    }
    return result;
}

size_t nextCharacterBoundary(const std::string& text, size_t position) {
    ++position;
    while (position < text.size() && (static_cast<unsigned char>(text[position]) & 0xC0) == 0x80) ++position;
    return position;
}

class LineTokenizer {
public:
    LineTokenizer(Grammar& base, const std::string& text, int depth) : base_(base), text_(text), depth_(depth) {}

    /// Runs from `position` to the end of the text, updating `state`.
    void run(size_t position, State& state) {
        if (!state.frames.empty() && position == 0) position = checkWhileRegions(state);
        // \G may match at this line's start only if the region's begin match ended the line
        // before; that's a one-line allowance.
        anchor_ = -1;
        if (position == 0 && state.frames.back().beganAtLineEnd) {
            anchor_ = 0;
            state.frames.back().beganAtLineEnd = false;
        }

        std::vector<std::pair<Rule*, size_t>> emptyPushes;  // guards push/pop loops at one spot
        for (int iteration = 0; iteration < kMaxIterationsPerLine; ++iteration) {
            Frame& top = state.frames.back();
            if (position >= text_.size()) break;

            // Find the earliest match among the region's end and its patterns. On a tie the
            // end wins, unless the rule asked for its end to be tried last.
            const Match* best = nullptr;
            Rule* bestRule = nullptr;
            bool bestIsEnd = false;
            Match endMatch;
            if (top.end) {
                endMatch = search(*top.end, position);
                if (endMatch.found && !top.rule->applyEndPatternLast) {
                    best = &endMatch;
                    bestIsEnd = true;
                }
            }
            for (Rule* rule : top.rule->grammar->candidates(top.rule, &base_)) {
                if (!rule->match) continue;
                const Match& match = cachedSearch(*rule->match, position);
                if (!match.found) continue;
                if (!best || match.start() < best->start()) {
                    best = &match;
                    bestRule = rule;
                    bestIsEnd = false;
                    if (match.start() == static_cast<int>(position)) break;  // can't do better
                }
            }
            if (top.end && top.rule->applyEndPatternLast && endMatch.found &&
                (!best || endMatch.start() < best->start())) {
                best = &endMatch;
                bestRule = nullptr;
                bestIsEnd = true;
            }

            if (!best) {
                emit(position, text_.size(), top.contentScopes);
                position = text_.size();
                break;
            }
            Match match = *best;  // copy: the cache may change below
            size_t start = static_cast<size_t>(match.start()), end = static_cast<size_t>(match.end());
            emit(position, start, top.contentScopes);

            if (bestIsEnd) {
                Rule* rule = top.rule;
                const ScopeNode* scopes = top.nameScopes;
                emitCaptures(match, rule->endCaptures, scopes, start, end);
                if (state.frames.size() > 1) state.frames.pop_back();
                anchor_ = -1;
                position = end;
                continue;
            }

            if (bestRule->kind == Rule::Kind::Match) {
                const ScopeNode* scopes = pushScopes(top.contentScopes, substituteCaptures(bestRule->name, match, text_));
                emitCaptures(match, bestRule->captures, scopes, start, end);
                position = end > start ? end : advanceOne(start, top.contentScopes);
                continue;
            }

            // A region starts here (begin/end or begin/while).
            if (end == start) {
                auto key = std::make_pair(bestRule, start);
                if (std::find(emptyPushes.begin(), emptyPushes.end(), key) != emptyPushes.end()) {
                    position = advanceOne(start, top.contentScopes);  // it would loop forever
                    continue;
                }
                emptyPushes.push_back(key);
            } else {
                emptyPushes.clear();
            }
            Frame frame;
            frame.rule = bestRule;
            frame.nameScopes = pushScopes(top.contentScopes, substituteCaptures(bestRule->name, match, text_));
            frame.contentScopes = pushScopes(frame.nameScopes, substituteCaptures(bestRule->contentName, match, text_));
            if (bestRule->kind == Rule::Kind::BeginEnd) {
                frame.end = bestRule->endHasBackReferences
                                ? Regex::get(fillBackReferences(bestRule->endSource, match, text_))
                                : bestRule->end;
            }
            emitCaptures(match, bestRule->beginCaptures, frame.nameScopes, start, end);
            frame.beganAtLineEnd = end >= text_.size();
            state.frames.push_back(frame);
            anchor_ = static_cast<int>(end);  // \G now means "right where this region began"
            position = end;
        }
        if (position < text_.size()) emit(position, text_.size(), state.frames.back().contentScopes);
    }

    std::vector<Token> tokens;

private:
    /// Begin/while regions continue only while each new line matches their `while` pattern
    /// at its start; the first one that doesn't closes itself and everything inside it.
    size_t checkWhileRegions(State& state) {
        size_t position = 0;
        for (size_t index = 1; index < state.frames.size(); ++index) {
            Frame& frame = state.frames[index];
            if (frame.rule->kind != Rule::Kind::BeginWhile || !frame.rule->whilePattern) continue;
            Match match = frame.rule->whilePattern->search(text_, position);
            if (!match.found || match.start() != static_cast<int>(position)) {
                state.frames.resize(index);
                break;
            }
            emitCaptures(match, frame.rule->whileCaptures, frame.nameScopes, position, static_cast<size_t>(match.end()));
            position = static_cast<size_t>(match.end());
        }
        return position;
    }

    size_t advanceOne(size_t position, const ScopeNode* scopes) {
        size_t next = std::min(nextCharacterBoundary(text_, position), text_.size());
        emit(position, next, scopes);
        return next;
    }

    /// The right variant of a pattern for a search starting at `position` (see Regex::anchored).
    const Regex& forPosition(const Regex& regex, size_t position) const {
        return regex.anchored() && static_cast<int>(position) != anchor_ ? regex.withoutAnchor() : regex;
    }

    Match search(const Regex& regex, size_t position) { return forPosition(regex, position).search(text_, position); }

    /// Searches, reusing an earlier result that is still ahead of `position`.
    const Match& cachedSearch(const Regex& pattern, size_t position) {
        const Regex& regex = forPosition(pattern, position);
        auto& entry = cache_[&regex];
        bool reusable = entry.valid && !regex.anchored() && entry.from <= position &&
                        (!entry.match.found || entry.match.start() >= static_cast<int>(position));
        if (!reusable) {
            entry.match = regex.search(text_, position);
            entry.from = position;
            entry.valid = true;
        }
        return entry.match;
    }

    void emit(size_t start, size_t end, const ScopeNode* scopes) {
        if (end <= start) return;
        if (!tokens.empty() && tokens.back().end == start && tokens.back().scopes == scopes) {
            tokens.back().end = static_cast<uint32_t>(end);
            return;
        }
        tokens.push_back({static_cast<uint32_t>(start), static_cast<uint32_t>(end), scopes});
    }

    /// Emits [start, end) with capture-group scopes layered on top of `scopes`.
    void emitCaptures(const Match& match, const std::map<int, Rule*>& captures, const ScopeNode* scopes,
                      size_t start, size_t end) {
        if (captures.empty()) {
            emit(start, end, scopes);
            return;
        }
        struct Span {
            size_t start, end;
            Rule* rule;
        };
        std::vector<Span> spans;
        for (const auto& [index, rule] : captures) {
            if (index >= static_cast<int>(match.groups.size())) continue;
            auto [from, to] = match.groups[index];
            if (from < 0 || to <= from) continue;
            spans.push_back({static_cast<size_t>(from), static_cast<size_t>(to), rule});
        }
        std::sort(spans.begin(), spans.end(), [](const Span& a, const Span& b) {
            return a.start != b.start ? a.start < b.start : a.end > b.end;  // outer spans first
        });

        std::vector<Token> local;
        auto put = [&](size_t from, size_t to, const ScopeNode* node) {
            if (to <= from) return;
            if (!local.empty() && local.back().end == from && local.back().scopes == node) {
                local.back().end = static_cast<uint32_t>(to);
            } else {
                local.push_back({static_cast<uint32_t>(from), static_cast<uint32_t>(to), node});
            }
        };
        struct Open {
            size_t end;
            const ScopeNode* scopes;
        };
        std::vector<Open> open{{end, scopes}};
        std::vector<std::pair<Span, const ScopeNode*>> withPatterns;
        size_t cursor = start;
        for (const Span& span : spans) {
            if (span.start < start || span.start >= end) continue;
            while (open.size() > 1 && open.back().end <= span.start) {
                put(cursor, open.back().end, open.back().scopes);
                cursor = std::max(cursor, open.back().end);
                open.pop_back();
            }
            put(cursor, span.start, open.back().scopes);
            cursor = std::max(cursor, span.start);
            const ScopeNode* node = pushScopes(open.back().scopes, substituteCaptures(span.rule->name, match, text_));
            size_t spanEnd = std::min(span.end, open.back().end);
            if (!span.rule->patterns.empty()) withPatterns.push_back({{span.start, spanEnd, span.rule}, node});
            open.push_back({spanEnd, node});
        }
        while (!open.empty()) {
            put(cursor, open.back().end, open.back().scopes);
            cursor = std::max(cursor, open.back().end);
            open.pop_back();
        }

        // Captures with their own patterns get their text tokenized by those patterns.
        if (depth_ < 4) {
            for (const auto& [span, node] : withPatterns) {
                std::string piece = text_.substr(span.start, span.end - span.start);
                LineTokenizer nested(base_, piece, depth_ + 1);
                Frame frame;
                frame.rule = span.rule;
                frame.nameScopes = node;
                frame.contentScopes = node;
                State state{{frame}};
                nested.run(0, state);
                std::vector<Token> replacement;
                for (Token token : nested.tokens) {
                    token.start += static_cast<uint32_t>(span.start);
                    token.end += static_cast<uint32_t>(span.start);
                    replacement.push_back(token);
                }
                splice(local, span.start, span.end, replacement);
            }
        }
        for (const Token& token : local) emit(token.start, token.end, token.scopes);
    }

    /// Replaces whatever covers [from, to) in `tokens` with `replacement`.
    static void splice(std::vector<Token>& tokens, size_t from, size_t to, const std::vector<Token>& replacement) {
        std::vector<Token> result;
        for (const Token& token : tokens) {
            if (token.end <= from || token.start >= to) {
                result.push_back(token);
                continue;
            }
            if (token.start < from) result.push_back({token.start, static_cast<uint32_t>(from), token.scopes});
            if (token.end > to) result.push_back({static_cast<uint32_t>(to), token.end, token.scopes});
        }
        result.insert(result.end(), replacement.begin(), replacement.end());
        std::sort(result.begin(), result.end(), [](const Token& a, const Token& b) { return a.start < b.start; });
        tokens = std::move(result);
    }

    struct CachedMatch {
        bool valid = false;
        size_t from = 0;
        Match match;
    };

    Grammar& base_;
    const std::string& text_;
    int depth_;
    int anchor_ = -1;  // where \G may match on this line, or -1
    std::unordered_map<const Regex*, CachedMatch> cache_;
};

}  // namespace

LineResult tokenizeLine(Grammar& base, std::string_view line, const State& previous) {
    LineResult result;
    result.state = previous.frames.empty() ? initialState(base) : previous;

    // Grammars expect each line to end with "\n" (for `$` and end-of-line patterns).
    std::string text(line.size() > kMaxTokenizedBytes ? line.substr(0, kMaxTokenizedBytes) : line);
    text += '\n';
    LineTokenizer tokenizer(base, text, 0);
    tokenizer.run(0, result.state);

    // Drop the synthetic newline and give any untokenized tail the plain scopes.
    const ScopeNode* plain = result.state.frames.front().contentScopes;
    for (Token& token : tokenizer.tokens) {
        if (token.start >= line.size()) continue;
        token.end = std::min<uint32_t>(token.end, static_cast<uint32_t>(line.size()));
        result.tokens.push_back(token);
    }
    size_t covered = result.tokens.empty() ? 0 : result.tokens.back().end;
    if (covered < line.size()) result.tokens.push_back({static_cast<uint32_t>(covered), static_cast<uint32_t>(line.size()), plain});
    return result;
}

}  // namespace gw::tm
