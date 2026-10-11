#pragma once

#include <array>
#include <memory>
#include <string>
#include <vector>

struct re_pattern_buffer;

namespace gw::tm {

/// Byte offsets of each capture group; -1 for a group that took no part.
struct Match {
    int start() const { return groups.empty() ? -1 : groups[0].first; }
    int end() const { return groups.empty() ? -1 : groups[0].second; }

    bool found = false;
    std::vector<std::pair<int, int>> groups;
};

/// Bytes a match can begin with. `restricted` false means anything (or empty), and `bytes` is
/// meaningless. Errs toward allowing too many bytes, never too few.
struct FirstBytes {
    bool restricted = false;
    std::array<bool, 256> bytes{};
};

FirstBytes analyzeFirstBytes(const std::string& source);

/// Makes text match literally inside a pattern (for back-references in `end`).
std::string escapeForRegex(const std::string& text);

/// Oniguruma regex (Ruby syntax, UTF-8) from a TextMate pattern. A pattern that fails to compile never matches.
class Regex {
public:
    // ---- Constructors and destructor
    explicit Regex(const std::string& source);
    ~Regex();
    Regex(const Regex&) = delete;
    Regex& operator=(const Regex&) = delete;

    // ---- Shared instances
    /// Compiled once per source string, since grammars reuse patterns constantly.
    static std::shared_ptr<Regex> get(const std::string& source);

    // ---- Searching
    /// First match at or after byte `from`.
    Match search(const std::string& text, size_t from) const;
    /// Disables first-byte skipping everywhere so tests can confirm it never changes a result.
    static void setFirstByteSkippingEnabled(bool enabled);

    // ---- Getters
    bool valid() const { return regex_ != nullptr; }
    /// Pattern can only begin with certain bytes, so `search` can skip ahead.
    bool hasFirstBytes() const { return hasFirstBytes_; }
    /// Uses \G. TextMate's \G matches only at the region's begin-match end; Oniguruma's matches
    /// wherever the search starts, so away from the anchor use `withoutAnchor()`.
    bool anchored() const { return anchored_; }
    /// Same pattern with \G unmatchable (itself if it has none).
    const Regex& withoutAnchor() const;
    const std::string& source() const { return source_; }

private:
    // ---- Private variables
    std::string source_;
    re_pattern_buffer* regex_ = nullptr;
    bool anchored_ = false;
    bool hasFirstBytes_ = false;
    std::array<bool, 256> firstBytes_{};
    mutable std::shared_ptr<Regex> unanchored_;
};

}  // namespace gw::tm
