#include "Styling.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>

namespace gw {

namespace {

bool startsWith(const std::string& text, const char* prefix) {
    return text.rfind(prefix, 0) == 0;
}

bool isIdentifierStart(unsigned char byte) {
    return std::isalpha(byte) || byte == '_' || byte >= 0x80;
}

bool isIdentifierByte(unsigned char byte) {
    return std::isalnum(byte) || byte == '_' || byte >= 0x80;
}

/// Converts a hue/saturation/lightness colour (each 0…1) to 0xRRGGBBAA.
Color colorFromHSL(double hue, double saturation, double lightness) {
    double chroma = (1 - std::abs(2 * lightness - 1)) * saturation;
    double huePrime = hue * 6;
    double second = chroma * (1 - std::abs(std::fmod(huePrime, 2.0) - 1));

    double red = 0;
    double green = 0;
    double blue = 0;
    if (huePrime < 1) {
        red = chroma;
        green = second;
    } else if (huePrime < 2) {
        red = second;
        green = chroma;
    } else if (huePrime < 3) {
        green = chroma;
        blue = second;
    } else if (huePrime < 4) {
        green = second;
        blue = chroma;
    } else if (huePrime < 5) {
        red = second;
        blue = chroma;
    } else {
        red = chroma;
        blue = second;
    }

    double match = lightness - chroma / 2;
    auto toByte = [](double value) {
        return static_cast<uint32_t>(std::lround(std::clamp(value, 0.0, 1.0) * 255));
    };
    return (toByte(red + match) << 24) | (toByte(green + match) << 16) | (toByte(blue + match) << 8) | 0xFF;
}

}  // namespace

void applyOverride(TextStyle& style, const StyleOverride& override) {
    if (override.foreground) {
        style.foreground = *override.foreground;
    }
    if (override.background) {
        style.background = *override.background;
    }
    if (override.bold) {
        style.bold = *override.bold;
    }
    if (override.italic) {
        style.italic = *override.italic;
    }
    if (override.underline) {
        style.underline = *override.underline;
    }
}

Stylist::Stylist(const Theme& theme, ColorCustomizations customizations)
    : theme_(theme), customizations_(std::move(customizations)) {
    for (const ScopeStyleRule& rule : customizations_.scopeRules) {
        ruleSelectors_.push_back(parseSelector(rule.scope));
    }
}

Color Stylist::rainbowColor(std::string_view name, bool darkTheme) {
    // FNV-1a hash of the name picks a hue; saturation and lightness are fixed so every
    // colour reads well on the theme's background.
    uint32_t hash = 2166136261u;
    for (char character : name) {
        hash ^= static_cast<unsigned char>(character);
        hash *= 16777619u;
    }
    double hue = static_cast<double>(hash % 360) / 360.0;
    if (darkTheme) {
        return colorFromHSL(hue, 0.65, 0.74);
    }
    return colorFromHSL(hue, 0.70, 0.36);
}

TextStyle Stylist::styleForScopes(const tm::ScopeNode* scopes) {
    auto cached = styleCache_.find(scopes);
    if (cached != styleCache_.end()) {
        return cached->second;
    }

    TextStyle style = theme_.styleFor(scopes);

    // User rules are applied from least to most specific match, so the most specific wins.
    std::vector<std::string> path;
    if (scopes) {
        path = scopes->path();
    }
    std::vector<std::pair<SelectorMatch, size_t>> matches;
    for (size_t index = 0; index < customizations_.scopeRules.size(); ++index) {
        std::optional<SelectorMatch> match = matchSelector(ruleSelectors_[index], path);
        if (match) {
            matches.emplace_back(*match, index);
        }
    }
    std::sort(matches.begin(), matches.end());
    for (const auto& [match, index] : matches) {
        applyOverride(style, customizations_.scopeRules[index].style);
    }

    styleCache_[scopes] = style;
    return style;
}

bool Stylist::isTextScope(const tm::ScopeNode* scopes) {
    auto cached = textCache_.find(scopes);
    if (cached != textCache_.end()) {
        return cached->second;
    }
    bool text = false;
    for (const tm::ScopeNode* node = scopes; node != nullptr; node = node->parent) {
        if (startsWith(node->name, "string") || startsWith(node->name, "comment")) {
            text = true;
            break;
        }
    }
    textCache_[scopes] = text;
    return text;
}

bool Stylist::isVariableScope(const tm::ScopeNode* scopes) {
    auto cached = variableCache_.find(scopes);
    if (cached != variableCache_.end()) {
        return cached->second;
    }

    bool variable = false;
    if (scopes == nullptr || scopes->parent == nullptr) {
        // Only the grammar's root scope: a plain identifier the grammar didn't classify.
        variable = true;
    } else {
        const std::string& innermost = scopes->name;
        if (startsWith(innermost, "variable.")) {
            // `this` and `self` are keywords in all but name.
            variable = !startsWith(innermost, "variable.language");
        } else if (startsWith(innermost, "meta.")) {
            // Structural scopes (a function body, a parameter list) hold plain names.
            variable = true;
        }
    }
    if (variable && isTextScope(scopes)) {
        variable = false;
    }

    variableCache_[scopes] = variable;
    return variable;
}

std::vector<StyledSpan> Stylist::styleLine(const std::string& text, const std::vector<tm::Token>& tokens) {
    std::vector<StyledSpan> spans;
    bool dark = theme_.isDark();
    bool wantsNames = customizations_.rainbowVariables || !customizations_.identifiers.empty();

    for (const tm::Token& token : tokens) {
        uint32_t tokenEnd = std::min<uint32_t>(token.end, static_cast<uint32_t>(text.size()));
        if (token.start >= tokenEnd) {
            continue;
        }
        TextStyle base = styleForScopes(token.scopes);

        bool splitIntoNames = wantsNames && !isTextScope(token.scopes);
        if (!splitIntoNames) {
            spans.push_back({token.start, tokenEnd, base});
            continue;
        }

        // Walk the token, giving each identifier its own look where one applies.
        bool rainbowHere = customizations_.rainbowVariables && isVariableScope(token.scopes);
        uint32_t position = token.start;
        uint32_t plainStart = token.start;
        while (position < tokenEnd) {
            unsigned char byte = static_cast<unsigned char>(text[position]);
            bool atWordStart = isIdentifierStart(byte) &&
                               (position == 0 || !isIdentifierByte(static_cast<unsigned char>(text[position - 1])));
            if (!atWordStart) {
                ++position;
                continue;
            }

            uint32_t wordEnd = position;
            while (wordEnd < tokenEnd && isIdentifierByte(static_cast<unsigned char>(text[wordEnd]))) {
                ++wordEnd;
            }
            std::string word = text.substr(position, wordEnd - position);

            TextStyle style = base;
            bool changed = false;
            if (rainbowHere) {
                style.foreground = rainbowColor(word, dark);
                changed = true;
            }
            auto custom = customizations_.identifiers.find(word);
            if (custom != customizations_.identifiers.end()) {
                applyOverride(style, custom->second);
                changed = true;
            }

            if (changed) {
                if (plainStart < position) {
                    spans.push_back({plainStart, position, base});
                }
                spans.push_back({position, wordEnd, style});
                plainStart = wordEnd;
            }
            position = wordEnd;
        }
        if (plainStart < tokenEnd) {
            spans.push_back({plainStart, tokenEnd, base});
        }
    }
    return spans;
}

}  // namespace gw
