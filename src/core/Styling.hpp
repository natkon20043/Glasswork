#pragma once

#include "Theme.hpp"
#include "textmate/Tokenizer.hpp"

#include <map>
#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

namespace gw {

/// User styling layered over the theme; unset fields keep what the theme (or an earlier rule) chose.
struct StyleOverride {
    bool empty() const {
        return !foreground && !background && !bold && !italic && !underline;
    }

    std::optional<Color> foreground;
    std::optional<Color> background;
    std::optional<bool> bold;
    std::optional<bool> italic;
    std::optional<bool> underline;
};

/// Style for everything a TextMate selector matches, e.g. "variable.parameter" or "meta.function string".
struct ScopeStyleRule {
    std::string scope;
    StyleOverride style;
};

struct ColorCustomizations {
    /// Applied over the theme like VS Code's `editor.tokenColorCustomizations`.
    std::vector<ScopeStyleRule> scopeRules;
    /// Per-name styles (e.g. `total` in gold), applied to code only, never strings or comments.
    std::map<std::string, StyleOverride> identifiers;
    /// Each variable gets a color derived from its name.
    bool rainbowVariables = true;
};

/// A run of a line with one final look.
struct StyledSpan {
    /// UTF-8 byte offsets within the line.
    uint32_t start = 0;
    uint32_t end = 0;
    TextStyle style;
};

/// Final look of every piece of a line, in order: theme colors, user scope rules, rainbow variables,
/// per-name colors.
class Stylist {
public:
    // ---- Constructors
    Stylist(const Theme& theme, ColorCustomizations customizations);

    // ---- Styling
    std::vector<StyledSpan> styleLine(std::string_view text, const std::vector<tm::Token>& tokens);
    /// Theme plus the user's scope rules.
    TextStyle styleForScopes(const tm::ScopeNode* scopes);
    /// Always the same color for the same name.
    static Color rainbowColor(std::string_view name, bool darkTheme);

    // ---- Getters
    const ColorCustomizations& customizations() const { return customizations_; }

private:
    // ---- Private functions
    /// True where plain identifiers are variables: not keywords, types, functions, strings or comments.
    bool isVariableScope(const tm::ScopeNode* scopes);
    /// Strings and comments, where name-based colors never apply.
    bool isTextScope(const tm::ScopeNode* scopes);

    // ---- Private variables
    const Theme& theme_;
    ColorCustomizations customizations_;
    // Parsed once, parallel to scopeRules.
    std::vector<std::vector<std::string>> ruleSelectors_;
    std::unordered_map<const tm::ScopeNode*, TextStyle> styleCache_;
    std::unordered_map<const tm::ScopeNode*, bool> variableCache_;
    std::unordered_map<const tm::ScopeNode*, bool> textCache_;
};

/// Applies the set fields of `override` onto `style`.
void applyOverride(TextStyle& style, const StyleOverride& override);

}  // namespace gw
