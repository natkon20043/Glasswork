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

/// A user's own look for part of the code, layered on top of the theme. Any field left
/// empty keeps whatever the theme (or an earlier rule) chose.
struct StyleOverride {
    std::optional<Color> foreground;
    std::optional<Color> background;
    std::optional<bool> bold;
    std::optional<bool> italic;
    std::optional<bool> underline;

    bool empty() const {
        return !foreground && !background && !bold && !italic && !underline;
    }
};

/// A style for everything a TextMate selector matches, e.g. "variable.parameter" or
/// "meta.function string".
struct ScopeStyleRule {
    std::string scope;
    StyleOverride style;
};

/// Everything the user has customised about how code is coloured.
struct ColorCustomizations {
    /// Rules for kinds of code (scopes), applied over the theme like VS Code's
    /// `editor.tokenColorCustomizations`.
    std::vector<ScopeStyleRule> scopeRules;

    /// Styles for specific names, e.g. every occurrence of `total` in gold. Applied to code
    /// only, never inside strings or comments.
    std::map<std::string, StyleOverride> identifiers;

    /// Give every variable its own colour, derived from its name (like CLion's "semantic
    /// highlighting"), so the same name is always the same colour.
    bool rainbowVariables = true;
};

/// A run of a line with one final look.
struct StyledSpan {
    uint32_t start = 0;  // UTF-8 byte offsets within the line
    uint32_t end = 0;
    TextStyle style;
};

/// Decides the final look of every piece of a line: the theme's colours, then the user's
/// scope rules, then rainbow variable colours, then colours set for specific names.
class Stylist {
public:
    Stylist(const Theme& theme, ColorCustomizations customizations);

    std::vector<StyledSpan> styleLine(std::string_view text, const std::vector<tm::Token>& tokens);

    /// The look for a scope path from the theme plus the user's scope rules.
    TextStyle styleForScopes(const tm::ScopeNode* scopes);

    /// The colour rainbow highlighting gives a name. Always the same for the same name.
    static Color rainbowColor(std::string_view name, bool darkTheme);

    const ColorCustomizations& customizations() const { return customizations_; }

private:
    /// True where plain identifiers are variables: not keywords, types, functions, strings,
    /// comments or other already-meaningful scopes.
    bool isVariableScope(const tm::ScopeNode* scopes);
    /// Strings and comments, where name-based colours never apply.
    bool isTextScope(const tm::ScopeNode* scopes);

    const Theme& theme_;
    ColorCustomizations customizations_;
    std::vector<std::vector<std::string>> ruleSelectors_;  // parsed once, parallel to scopeRules

    std::unordered_map<const tm::ScopeNode*, TextStyle> styleCache_;
    std::unordered_map<const tm::ScopeNode*, bool> variableCache_;
    std::unordered_map<const tm::ScopeNode*, bool> textCache_;
};

/// Applies the set fields of `override` onto `style`.
void applyOverride(TextStyle& style, const StyleOverride& override);

}  // namespace gw
