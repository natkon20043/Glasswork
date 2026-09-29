#pragma once

#include "textmate/Tokenizer.hpp"

#include <cstdint>
#include <filesystem>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

namespace gw {

/// 0xRRGGBBAA.
using Color = uint32_t;

std::optional<Color> parseColor(const std::string& text);
inline double red(Color color) { return ((color >> 24) & 0xFF) / 255.0; }
inline double green(Color color) { return ((color >> 16) & 0xFF) / 255.0; }
inline double blue(Color color) { return ((color >> 8) & 0xFF) / 255.0; }
inline double alpha(Color color) { return (color & 0xFF) / 255.0; }

struct TextStyle {
    Color foreground = 0xD4D4D4FF;
    /// A highlight drawn behind the text (themes rarely set one; user colour rules can).
    std::optional<Color> background;
    bool bold = false;
    bool italic = false;
    bool underline = false;
    bool strikethrough = false;
};

/// How well a TextMate selector matches a scope path. Higher is a better match, in the same
/// order VS Code uses: a match on a deeper (more inner) scope wins, then the more specific
/// selector (more dot-separated parts), then the one with more parent constraints.
struct SelectorMatch {
    long depth = -1;
    size_t specificity = 0;
    size_t parents = 0;

    bool operator<(const SelectorMatch& other) const {
        if (depth != other.depth) {
            return depth < other.depth;
        }
        if (specificity != other.specificity) {
            return specificity < other.specificity;
        }
        return parents < other.parents;
    }
    bool operator==(const SelectorMatch& other) const = default;
};

/// Splits a selector such as "meta.block string" into its space-separated parts.
std::vector<std::string> parseSelector(const std::string& selector);

/// Matches selector parts against a scope path (outermost scope first). The last part must
/// match some scope; earlier parts must match its ancestors, in order. A part matches a scope
/// equal to it or starting with it followed by a dot ("string" matches "string.quoted").
std::optional<SelectorMatch> matchSelector(const std::vector<std::string>& parts,
                                           const std::vector<std::string>& scopes);

/// A VS Code colour theme: workbench `colors` plus TextMate `tokenColors`.
class Theme {
public:
    /// Loads a theme JSON (comments and trailing commas allowed), following `include`s.
    static std::unique_ptr<Theme> load(const std::filesystem::path& path, bool dark, std::string* error = nullptr);
    static std::unique_ptr<Theme> parse(const std::string& json, bool dark, std::string* error = nullptr);

    const std::string& name() const { return name_; }
    bool isDark() const { return dark_; }

    /// A workbench colour such as "editor.background" or "editorLineNumber.foreground".
    Color color(const std::string& key, Color fallback) const;
    bool hasColor(const std::string& key) const { return colors_.count(key) > 0; }

    /// Style for a token's scope path. Thread-safe and cached per scope path.
    TextStyle styleFor(const tm::ScopeNode* scopes) const;
    TextStyle styleFor(const std::vector<std::string>& scopes) const;

private:
    Theme() = default;
    bool merge(const std::string& json, const std::filesystem::path& directory, int depth, std::string* error);

    struct Selector {
        std::vector<std::string> parts;  // "meta.block string" → {"meta.block", "string"}
    };
    struct Rule {
        std::vector<Selector> selectors;  // an empty list applies to everything (the defaults)
        std::optional<Color> foreground;
        std::optional<std::string> fontStyle;
        size_t order = 0;
    };

    std::string name_;
    bool dark_ = true;
    std::map<std::string, Color> colors_;
    std::vector<Rule> rules_;
    TextStyle defaults_;

    mutable std::mutex cacheMutex_;
    mutable std::unordered_map<const tm::ScopeNode*, TextStyle> cache_;
};

}  // namespace gw
