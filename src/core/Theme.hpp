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

struct TextStyle {
    Color foreground = 0xD4D4D4FF;
    /// Behind the text; themes rarely set one, user color rules can.
    std::optional<Color> background;
    bool bold = false;
    bool italic = false;
    bool underline = false;
    bool strikethrough = false;
};

/// How well a selector matches a scope path, in VS Code's order: deeper scope wins, then more
/// specific selector, then more parent constraints.
struct SelectorMatch {
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

    long depth = -1;
    size_t specificity = 0;
    size_t parents = 0;
};

// ---- Color helpers

std::optional<Color> parseColor(const std::string& text);
inline double red(Color color) { return ((color >> 24) & 0xFF) / 255.0; }
inline double green(Color color) { return ((color >> 16) & 0xFF) / 255.0; }
inline double blue(Color color) { return ((color >> 8) & 0xFF) / 255.0; }
inline double alpha(Color color) { return (color & 0xFF) / 255.0; }

// ---- Selectors

/// "meta.block string" -> {"meta.block", "string"}
std::vector<std::string> parseSelector(const std::string& selector);

/// `scopes` is outermost first. The last part must match a scope and earlier parts its ancestors,
/// in order. A part matches an equal scope or one it prefixes before a dot ("string" matches "string.quoted").
std::optional<SelectorMatch> matchSelector(const std::vector<std::string>& parts,
                                           const std::vector<std::string>& scopes);

/// A VS Code color theme: workbench `colors` plus TextMate `tokenColors`.
class Theme {
public:
    // ---- Constructors
    /// Allows comments and trailing commas; follows `include`s.
    static std::unique_ptr<Theme> load(const std::filesystem::path& path, bool dark, std::string* error = nullptr);
    static std::unique_ptr<Theme> parse(const std::string& json, bool dark, std::string* error = nullptr);

    // ---- Getters
    const std::string& name() const { return name_; }
    bool isDark() const { return dark_; }
    /// A workbench color such as "editor.background".
    Color color(const std::string& key, Color fallback) const;
    bool hasColor(const std::string& key) const { return colors_.count(key) > 0; }

    // ---- Styling
    /// Thread-safe; cached per scope path.
    TextStyle styleFor(const tm::ScopeNode* scopes) const;
    TextStyle styleFor(const std::vector<std::string>& scopes) const;

private:
    struct Selector {
        /// "meta.block string" -> {"meta.block", "string"}
        std::vector<std::string> parts;
    };

    struct Rule {
        /// Empty applies to everything (the defaults).
        std::vector<Selector> selectors;
        std::optional<Color> foreground;
        std::optional<std::string> fontStyle;
        size_t order = 0;
    };

    // ---- Private functions
    Theme() = default;
    bool merge(const std::string& json, const std::filesystem::path& directory, int depth, std::string* error);

    // ---- Private variables
    std::string name_;
    bool dark_ = true;
    std::map<std::string, Color> colors_;
    std::vector<Rule> rules_;
    TextStyle defaults_;

    mutable std::mutex cacheMutex_;
    mutable std::unordered_map<const tm::ScopeNode*, TextStyle> cache_;
};

}  // namespace gw
