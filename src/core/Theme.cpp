#include "Theme.hpp"

#include "Jsonc.hpp"

#include <nlohmann/json.hpp>

#include <algorithm>
#include <fstream>
#include <sstream>

namespace gw {

using nlohmann::json;

namespace {

std::optional<std::string> readFile(const std::filesystem::path& path) {
    std::ifstream file(path, std::ios::binary);
    if (!file) return std::nullopt;
    std::ostringstream contents;
    contents << file.rdbuf();
    return contents.str();
}


bool scopeMatches(const std::string& scope, const std::string& selector) {
    return scope.size() >= selector.size() && scope.compare(0, selector.size(), selector) == 0 &&
           (scope.size() == selector.size() || scope[selector.size()] == '.');
}

std::vector<std::string> split(const std::string& text, char separator) {
    std::vector<std::string> parts;
    std::string current;
    for (char character : text) {
        if (character == separator) {
            if (!current.empty()) parts.push_back(current);
            current.clear();
        } else if (!(separator == ' ' && (character == '\t' || character == '\n'))) {
            current += character;
        }
    }
    if (!current.empty()) parts.push_back(current);
    return parts;
}

std::string trim(const std::string& text) {
    size_t start = text.find_first_not_of(" \t\n");
    size_t end = text.find_last_not_of(" \t\n");
    return start == std::string::npos ? std::string() : text.substr(start, end - start + 1);
}

}  // namespace

std::optional<Color> parseColor(const std::string& text) {
    if (text.size() < 4 || text[0] != '#') return std::nullopt;
    std::string hex = text.substr(1);
    for (char character : hex) {
        if (!std::isxdigit(static_cast<unsigned char>(character))) return std::nullopt;
    }
    if (hex.size() == 3 || hex.size() == 4) {  // #RGB / #RGBA
        std::string expanded;
        for (char character : hex) expanded += std::string(2, character);
        hex = expanded;
    }
    if (hex.size() == 6) hex += "FF";
    if (hex.size() != 8) return std::nullopt;
    return static_cast<Color>(std::stoul(hex, nullptr, 16));
}

std::unique_ptr<Theme> Theme::load(const std::filesystem::path& path, bool dark, std::string* error) {
    auto text = readFile(path);
    if (!text) {
        if (error) *error = "Couldn't read theme " + path.string();
        return nullptr;
    }
    std::unique_ptr<Theme> theme(new Theme());
    theme->dark_ = dark;
    theme->defaults_.foreground = dark ? 0xD4D4D4FF : 0x000000FF;
    if (!theme->merge(*text, path.parent_path(), 0, error)) return nullptr;
    theme->defaults_.foreground = theme->color("editor.foreground", theme->defaults_.foreground);
    return theme;
}

std::unique_ptr<Theme> Theme::parse(const std::string& text, bool dark, std::string* error) {
    std::unique_ptr<Theme> theme(new Theme());
    theme->dark_ = dark;
    theme->defaults_.foreground = dark ? 0xD4D4D4FF : 0x000000FF;
    if (!theme->merge(text, {}, 0, error)) return nullptr;
    theme->defaults_.foreground = theme->color("editor.foreground", theme->defaults_.foreground);
    return theme;
}

bool Theme::merge(const std::string& text, const std::filesystem::path& directory, int depth, std::string* error) {
    json document = parseJsonc(text);
    if (document.is_discarded() || !document.is_object()) {
        if (error) *error = "Theme isn't valid JSON.";
        return false;
    }
    // A theme may build on another: load that first, then layer this one on top.
    if (document.contains("include") && document["include"].is_string() && depth < 8) {
        if (auto parent = readFile(directory / document["include"].get<std::string>())) {
            auto includePath = directory / document["include"].get<std::string>();
            merge(*parent, includePath.parent_path(), depth + 1, nullptr);
        }
    }
    if (document.contains("name") && document["name"].is_string()) name_ = document["name"].get<std::string>();
    if (document.contains("type") && document["type"].is_string()) dark_ = document["type"] != "light";

    if (document.contains("colors") && document["colors"].is_object()) {
        for (const auto& [key, value] : document["colors"].items()) {
            if (!value.is_string()) continue;
            if (auto color = parseColor(value.get<std::string>())) colors_[key] = *color;
        }
    }
    if (document.contains("tokenColors") && document["tokenColors"].is_array()) {
        for (const auto& entry : document["tokenColors"]) {
            if (!entry.is_object() || !entry.contains("settings")) continue;
            Rule rule;
            rule.order = rules_.size();
            const json& settings = entry["settings"];
            if (settings.contains("foreground") && settings["foreground"].is_string()) {
                rule.foreground = parseColor(settings["foreground"].get<std::string>());
            }
            if (settings.contains("fontStyle") && settings["fontStyle"].is_string()) {
                rule.fontStyle = settings["fontStyle"].get<std::string>();
            }
            std::vector<std::string> scopes;
            if (entry.contains("scope")) {
                if (entry["scope"].is_string()) {
                    scopes = split(entry["scope"].get<std::string>(), ',');
                } else if (entry["scope"].is_array()) {
                    for (const auto& scope : entry["scope"]) {
                        if (scope.is_string()) scopes.push_back(scope.get<std::string>());
                    }
                }
            }
            for (const auto& scope : scopes) {
                std::string cleaned = trim(scope);
                if (!cleaned.empty()) rule.selectors.push_back({split(cleaned, ' ')});
            }
            if (rule.selectors.empty() && !entry.contains("scope")) {
                // Global settings: the default foreground for every token.
                if (rule.foreground) colors_.try_emplace("editor.foreground", *rule.foreground);
                continue;
            }
            rules_.push_back(std::move(rule));
        }
    }
    return true;
}

Color Theme::color(const std::string& key, Color fallback) const {
    auto found = colors_.find(key);
    return found != colors_.end() ? found->second : fallback;
}

TextStyle Theme::styleFor(const tm::ScopeNode* scopes) const {
    {
        std::lock_guard lock(cacheMutex_);
        if (auto found = cache_.find(scopes); found != cache_.end()) return found->second;
    }
    TextStyle style = styleFor(scopes ? scopes->path() : std::vector<std::string>{});
    std::lock_guard lock(cacheMutex_);
    cache_[scopes] = style;
    return style;
}

std::vector<std::string> parseSelector(const std::string& selector) {
    return split(trim(selector), ' ');
}

std::optional<SelectorMatch> matchSelector(const std::vector<std::string>& parts,
                                           const std::vector<std::string>& scopes) {
    if (parts.empty()) {
        return std::nullopt;
    }

    // Find the innermost scope that matches the selector's last part.
    long index = static_cast<long>(scopes.size()) - 1;
    while (index >= 0 && !scopeMatches(scopes[static_cast<size_t>(index)], parts.back())) {
        --index;
    }
    if (index < 0) {
        return std::nullopt;
    }

    SelectorMatch match;
    match.depth = index;
    match.specificity = static_cast<size_t>(std::count(parts.back().begin(), parts.back().end(), '.')) + 1;
    match.parents = parts.size() - 1;

    // Every earlier part must match an ancestor, in order from inner to outer.
    long cursor = index - 1;
    for (long part = static_cast<long>(parts.size()) - 2; part >= 0; --part) {
        const std::string& wanted = parts[static_cast<size_t>(part)];
        while (cursor >= 0 && !scopeMatches(scopes[static_cast<size_t>(cursor)], wanted)) {
            --cursor;
        }
        if (cursor < 0) {
            return std::nullopt;
        }
        --cursor;
    }
    return match;
}

TextStyle Theme::styleFor(const std::vector<std::string>& scopes) const {
    // The best-matching rule sets the color; font style is chosen separately, the same way.
    // When two rules match equally well, the later one in the theme wins.
    TextStyle style = defaults_;
    std::optional<std::pair<SelectorMatch, size_t>> bestForeground;
    std::optional<std::pair<SelectorMatch, size_t>> bestFontStyle;

    for (const Rule& rule : rules_) {
        for (const Selector& selector : rule.selectors) {
            std::optional<SelectorMatch> match = matchSelector(selector.parts, scopes);
            if (!match) {
                continue;
            }
            std::pair<SelectorMatch, size_t> ranked{*match, rule.order};

            if (rule.foreground && (!bestForeground || *bestForeground < ranked)) {
                bestForeground = ranked;
                style.foreground = *rule.foreground;
            }
            if (rule.fontStyle && (!bestFontStyle || *bestFontStyle < ranked)) {
                bestFontStyle = ranked;
                const std::string& font = *rule.fontStyle;
                style.bold = font.find("bold") != std::string::npos;
                style.italic = font.find("italic") != std::string::npos;
                style.underline = font.find("underline") != std::string::npos;
                style.strikethrough = font.find("strikethrough") != std::string::npos;
            }
        }
    }
    return style;
}

}  // namespace gw
