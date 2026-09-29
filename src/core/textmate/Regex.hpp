#pragma once

#include <array>
#include <memory>
#include <string>
#include <vector>

struct re_pattern_buffer;

namespace gw::tm {

/// Result of one regex search: byte offsets of each capture group (-1 when a group didn't
/// take part in the match).
struct Match {
    bool found = false;
    std::vector<std::pair<int, int>> groups;

    int start() const { return groups.empty() ? -1 : groups[0].first; }
    int end() const { return groups.empty() ? -1 : groups[0].second; }
};

/// An Oniguruma regex compiled from a TextMate pattern (Ruby/Oniguruma syntax, UTF-8).
/// Patterns that fail to compile never match, rather than breaking the whole grammar.
class Regex {
public:
    explicit Regex(const std::string& source);
    ~Regex();
    Regex(const Regex&) = delete;
    Regex& operator=(const Regex&) = delete;

    /// Finds the first match starting at or after byte `from` in `text`.
    Match search(const std::string& text, size_t from) const;

    /// True if the pattern can only begin with certain bytes, which lets `search` skip
    /// straight to a plausible spot (or give up at once) instead of trying every position.
    bool hasFirstBytes() const { return hasFirstBytes_; }
    /// Turns the skipping off everywhere, so tests can check it never changes a result.
    static void setFirstByteSkippingEnabled(bool enabled);

    bool valid() const { return regex_ != nullptr; }
    /// Whether the pattern uses \G. In TextMate, \G matches only at the "anchor": where
    /// the enclosing region's begin match ended (on that line). Oniguruma's \G matches at
    /// wherever a search starts, so away from the anchor use `withoutAnchor()` instead.
    bool anchored() const { return anchored_; }
    /// The same pattern with \G made unmatchable (itself if it has no \G).
    const Regex& withoutAnchor() const;
    const std::string& source() const { return source_; }

    /// Shared, compiled regex for a source string. Grammars reuse the same patterns
    /// constantly, and end patterns with back-references get compiled per match.
    static std::shared_ptr<Regex> get(const std::string& source);

private:
    std::string source_;
    re_pattern_buffer* regex_ = nullptr;
    bool anchored_ = false;
    bool hasFirstBytes_ = false;
    std::array<bool, 256> firstBytes_{};
    mutable std::shared_ptr<Regex> unanchored_;
};

/// The bytes a regex match can begin with. `restricted` is false when a match might begin
/// with anything (or be empty), in which case `bytes` means nothing. Errs on the side of
/// allowing too many bytes, never too few.
struct FirstBytes {
    bool restricted = false;
    std::array<bool, 256> bytes{};
};
FirstBytes analyzeFirstBytes(const std::string& source);

/// Escapes text so it matches literally inside a pattern (for back-references in `end`).
std::string escapeForRegex(const std::string& text);

}  // namespace gw::tm
