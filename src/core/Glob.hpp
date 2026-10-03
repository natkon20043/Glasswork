#pragma once

#include <regex>
#include <string>

namespace gw {

/// A file glob as language servers and extensions write them: `*` matches within one path
/// segment, `**` across segments (and zero of them), `?` one character, `{a,b}` alternatives and
/// `[abc]` / `[!abc]` character classes. Matching is against a path relative to some base, with
/// `/` separators.
class GlobPattern {
public:
    explicit GlobPattern(const std::string& glob);

    /// Whether the whole relative path matches. A pattern with no `/` in it also matches the file
    /// name alone anywhere (`*.cpp` finds `src/a.cpp`), as VS Code does.
    bool matches(const std::string& relativePath) const;

    const std::string& source() const { return source_; }

private:
    std::string source_;
    bool matchesNameAnywhere_ = false;
    std::regex regex_;
};

}  // namespace gw
