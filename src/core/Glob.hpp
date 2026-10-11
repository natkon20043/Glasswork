#pragma once

#include <regex>
#include <string>

namespace gw {

/// Glob as language servers and extensions write it: `*` within a path segment, `**` across segments,
/// `?`, `{a,b}` and `[abc]` / `[!abc]`. Matches paths relative to a base with `/` separators.
class GlobPattern {
public:
    // ---- Constructors
    explicit GlobPattern(const std::string& glob);

    // ---- Matching
    /// A pattern without `/` also matches the file name alone anywhere, as in VS Code.
    bool matches(const std::string& relativePath) const;

    // ---- Getters
    const std::string& source() const { return source_; }

private:
    // ---- Private variables
    std::string source_;
    bool matchesNameAnywhere_ = false;
    std::regex regex_;
};

}  // namespace gw
