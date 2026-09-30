#include "EditorSettings.hpp"

#include "Jsonc.hpp"

#include <cstdio>
#include <sstream>

namespace gw {

using nlohmann::json;

namespace {

/// Reads a style object: {"foreground": "#..", "background": "#..", "fontStyle": "bold"}.
StyleOverride readStyle(const json& object) {
    StyleOverride style;
    if (!object.is_object()) {
        return style;
    }
    if (object.contains("foreground") && object["foreground"].is_string()) {
        style.foreground = parseColor(object["foreground"].get<std::string>());
    }
    if (object.contains("background") && object["background"].is_string()) {
        style.background = parseColor(object["background"].get<std::string>());
    }
    if (object.contains("fontStyle") && object["fontStyle"].is_string()) {
        applyFontStyleString(style, object["fontStyle"].get<std::string>());
    }
    return style;
}

json writeStyle(const StyleOverride& style) {
    json object = json::object();
    if (style.foreground) {
        object["foreground"] = colorToHex(*style.foreground);
    }
    if (style.background) {
        object["background"] = colorToHex(*style.background);
    }
    if (style.bold || style.italic || style.underline) {
        object["fontStyle"] = fontStyleString(style);
    }
    return object;
}

template <typename Value>
void readValue(const json& document, const char* key, Value& into) {
    if (!document.contains(key)) {
        return;
    }
    const json& value = document[key];
    if constexpr (std::is_same_v<Value, bool>) {
        if (value.is_boolean()) {
            into = value.get<bool>();
        }
    } else if constexpr (std::is_same_v<Value, std::string>) {
        if (value.is_string()) {
            into = value.get<std::string>();
        }
    } else {
        if (value.is_number()) {
            into = value.get<Value>();
        }
    }
}

/// Indents every line of a JSON dump so it nests inside the hand-written template.
std::string indented(const json& value, int spaces) {
    std::string dump = value.dump(2);
    std::string padding(static_cast<size_t>(spaces), ' ');
    std::string result;
    for (size_t index = 0; index < dump.size(); ++index) {
        result += dump[index];
        if (dump[index] == '\n') {
            result += padding;
        }
    }
    return result;
}

}  // namespace

std::string colorToHex(Color color) {
    char buffer[12];
    uint32_t alpha = color & 0xFF;
    if (alpha == 0xFF) {
        std::snprintf(buffer, sizeof buffer, "#%06X", color >> 8);
    } else {
        std::snprintf(buffer, sizeof buffer, "#%08X", color);
    }
    return buffer;
}

std::string fontStyleString(const StyleOverride& style) {
    std::string result;
    auto add = [&result](const char* word) {
        if (!result.empty()) {
            result += ' ';
        }
        result += word;
    };
    if (style.bold.value_or(false)) {
        add("bold");
    }
    if (style.italic.value_or(false)) {
        add("italic");
    }
    if (style.underline.value_or(false)) {
        add("underline");
    }
    return result;
}

void applyFontStyleString(StyleOverride& style, const std::string& fontStyle) {
    style.bold = fontStyle.find("bold") != std::string::npos;
    style.italic = fontStyle.find("italic") != std::string::npos;
    style.underline = fontStyle.find("underline") != std::string::npos;
}

EditorSettings parseSettings(const std::string& jsonc, std::string* error) {
    EditorSettings settings;
    json document = parseJsonc(jsonc);
    if (document.is_discarded() || !document.is_object()) {
        if (error) {
            *error = "settings.json isn't valid JSON, so the defaults are in use.";
        }
        return settings;
    }

    readValue(document, "editor.fontSize", settings.fontSize);
    readValue(document, "editor.fontFamily", settings.fontFamily);
    readValue(document, "editor.tabSize", settings.tabSize);
    readValue(document, "editor.wordWrap", settings.wordWrap);
    readValue(document, "editor.opacity", settings.editorOpacity);
    readValue(document, "window.glassTint", settings.glassTint);
    readValue(document, "window.frostedBackdrop", settings.frostedBackdrop);
    readValue(document, "window.glassStyle", settings.glassStyle);
    readValue(document, "workbench.colorTheme", settings.theme);
    readValue(document, "editor.highlightOccurrences", settings.highlightOccurrences);
    readValue(document, "editor.minimap", settings.showMinimap);
    readValue(document, "editor.indentGuides", settings.indentGuides);
    readValue(document, "editor.bracketPairColorization", settings.bracketPairColors);
    readValue(document, "editor.sectionDividers", settings.sectionDividers);
    readValue(document, "editor.inlineDiagnostics", settings.inlineDiagnostics);
    readValue(document, "editor.stickyScroll", settings.stickyScroll);
    readValue(document, "editor.semanticHighlighting", settings.semanticHighlighting);
    readValue(document, "lsp.enabled", settings.languageServers);
    readValue(document, "editor.rainbowVariables", settings.colors.rainbowVariables);
    readValue(document, "files.autoSave", settings.autoSave);
    readValue(document, "files.trimTrailingWhitespace", settings.trimTrailingWhitespace);
    readValue(document, "files.insertFinalNewline", settings.insertFinalNewline);
    readValue(document, "terminal.fontSize", settings.terminalFontSize);
    readValue(document, "terminal.shell", settings.terminalShell);

    if (document.contains("editor.tokenColors") && document["editor.tokenColors"].is_array()) {
        for (const json& entry : document["editor.tokenColors"]) {
            if (!entry.is_object() || !entry.contains("scope") || !entry["scope"].is_string()) {
                continue;
            }
            ScopeStyleRule rule;
            rule.scope = entry["scope"].get<std::string>();
            rule.style = readStyle(entry);
            settings.colors.scopeRules.push_back(rule);
        }
    }
    if (document.contains("editor.identifierColors") && document["editor.identifierColors"].is_object()) {
        for (const auto& [name, value] : document["editor.identifierColors"].items()) {
            StyleOverride style = readStyle(value);
            if (!style.empty()) {
                settings.colors.identifiers[name] = style;
            }
        }
    }

    // Keep values in sensible ranges even if the file says otherwise.
    settings.fontSize = std::clamp(settings.fontSize, 8.0, 40.0);
    settings.tabSize = std::clamp(settings.tabSize, 1, 16);
    settings.editorOpacity = std::clamp(settings.editorOpacity, 0.15, 1.0);
    settings.glassTint = std::clamp(settings.glassTint, 0.0, 1.0);
    if (settings.glassStyle != "clear") {
        settings.glassStyle = "regular";
    }
    if (settings.terminalFontSize != 0) {
        settings.terminalFontSize = std::clamp(settings.terminalFontSize, 8.0, 40.0);
    }
    return settings;
}

std::string serializeSettings(const EditorSettings& settings) {
    json tokenColors = json::array();
    for (const ScopeStyleRule& rule : settings.colors.scopeRules) {
        json entry = writeStyle(rule.style);
        entry["scope"] = rule.scope;
        tokenColors.push_back(entry);
    }
    json identifierColors = json::object();
    for (const auto& [name, style] : settings.colors.identifiers) {
        identifierColors[name] = writeStyle(style);
    }
    auto boolean = [](bool value) { return value ? "true" : "false"; };

    std::ostringstream out;
    out << "// Glasswork settings. Edit and save: changes apply straight away.\n"
        << "// This file is JSON with comments; trailing commas are fine.\n"
        << "{\n"
        << "  // Text\n"
        << "  \"editor.fontSize\": " << settings.fontSize << ",\n"
        << "  \"editor.fontFamily\": " << json(settings.fontFamily).dump() << ",  // empty = SF Mono\n"
        << "  \"editor.tabSize\": " << settings.tabSize << ",\n"
        << "  \"editor.wordWrap\": " << boolean(settings.wordWrap) << ",  // wrap long lines (View > Word Wrap, \u2325Z)\n"
        << "\n"
        << "  // Files\n"
        << "  \"files.autoSave\": " << boolean(settings.autoSave)
        << ",  // save a moment after you stop typing, and when you switch away\n"
        << "  \"files.trimTrailingWhitespace\": " << boolean(settings.trimTrailingWhitespace)
        << ",  // .editorconfig files can override this per file type\n"
        << "  \"files.insertFinalNewline\": " << boolean(settings.insertFinalNewline) << ",\n"
        << "\n"
        << "  // Terminal\n"
        << "  \"terminal.fontSize\": " << settings.terminalFontSize << ",  // 0 = one point smaller than the editor\n"
        << "  \"terminal.shell\": " << json(settings.terminalShell).dump() << ",  // empty = your login shell\n"
        << "\n"
        << "  // Look\n"
        << "  \"workbench.colorTheme\": " << json(settings.theme).dump() << ",  // View > Theme lists them\n"
        << "  \"editor.opacity\": " << settings.editorOpacity << ",  // 0.15 (see-through) to 1 (solid)\n"
        << "  \"window.glassTint\": " << settings.glassTint << ",  // 0 = clear glass, 1 = strongest tint\n"
        << "  \"window.frostedBackdrop\": " << boolean(settings.frostedBackdrop)
        << ",  // false: the desktop shows through sharply and the glass bends it\n"
        << "  \"window.glassStyle\": " << json(settings.glassStyle).dump() << ",  // \"regular\" or \"clear\" for the sidebar and bars\n"
        << "  \"editor.minimap\": " << boolean(settings.showMinimap) << ",\n"
        << "  \"editor.indentGuides\": " << boolean(settings.indentGuides) << ",\n"
        << "  \"editor.bracketPairColorization\": " << boolean(settings.bracketPairColors) << ",\n"
        << "  \"editor.sectionDividers\": " << boolean(settings.sectionDividers)
        << ",  // lines above \"// MARK: - Name\" comments\n"
        << "  \"editor.inlineDiagnostics\": " << boolean(settings.inlineDiagnostics)
        << ",  // show each problem's message at the end of its line\n"
        << "  \"editor.stickyScroll\": " << boolean(settings.stickyScroll)
        << ",  // pin the current function or class header at the top while you scroll\n"
        << "  \"editor.semanticHighlighting\": " << boolean(settings.semanticHighlighting)
        << ",  // colour types and functions by what the language server knows they are\n"
        << "  \"lsp.enabled\": " << boolean(settings.languageServers)
        << ",  // language servers: problems, completion, hover, rename\n"
        << "  \"editor.highlightOccurrences\": " << boolean(settings.highlightOccurrences)
        << ",  // highlight the word under the caret everywhere\n"
        << "\n"
        << "  // Colours\n"
        << "  // Every variable gets its own colour, chosen from its name.\n"
        << "  \"editor.rainbowVariables\": " << boolean(settings.colors.rainbowVariables) << ",\n"
        << "\n"
        << "  // Colour any kind of code. \"scope\" is a TextMate selector such as \"keyword.control\",\n"
        << "  // \"variable.parameter\" or \"meta.function string\". Right-click > Inspect Colours shows the\n"
        << "  // scopes under the caret. Each entry can set \"foreground\", \"background\" (a highlight)\n"
        << "  // and \"fontStyle\" (\"bold\", \"italic\", \"underline\", combined with spaces).\n"
        << "  \"editor.tokenColors\": " << indented(tokenColors, 2) << ",\n"
        << "\n"
        << "  // Colour specific names wherever they appear in code, e.g.\n"
        << "  // \"total\": { \"foreground\": \"#FFD700\", \"background\": \"#FFD70033\" }\n"
        << "  \"editor.identifierColors\": " << indented(identifierColors, 2) << "\n"
        << "}\n";
    return out.str();
}

}  // namespace gw
