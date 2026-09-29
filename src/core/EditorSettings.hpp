#pragma once

#include "Styling.hpp"

#include <optional>
#include <string>

namespace gw {

/// Everything a user can change, stored in a VS Code-style settings.json (JSON with comments).
struct EditorSettings {
    double fontSize = 13;
    std::string fontFamily;  // empty: SF Mono
    int tabSize = 4;
    /// Wrap long lines to the width of the editor instead of scrolling sideways.
    bool wordWrap = false;
    double editorOpacity = 0.62;
    std::string theme = "Dark Modern";

    bool highlightOccurrences = true;
    bool showMinimap = true;
    bool indentGuides = true;
    bool bracketPairColors = true;
    bool sectionDividers = true;
    /// Colour types, functions and macros by what a language server knows they are.
    bool semanticHighlighting = true;
    /// Show each problem's message at the end of its line.
    bool inlineDiagnostics = true;
    /// Run language servers (completion, problems, hover, rename…).
    bool languageServers = true;

    /// Save files a moment after the last edit, and when the window loses focus.
    bool autoSave = false;
    /// Remove spaces and tabs at the ends of lines when saving (an .editorconfig can override).
    bool trimTrailingWhitespace = false;
    /// Make sure files end with a newline when saving (an .editorconfig can override).
    bool insertFinalNewline = false;
    /// Terminal text size in points; 0 means one point smaller than the editor's.
    double terminalFontSize = 0;
    /// Program the terminal runs, e.g. "/bin/zsh" or "/opt/homebrew/bin/fish". Empty: $SHELL.
    std::string terminalShell;

    ColorCustomizations colors;
};

/// Reads settings. Keys that are missing or invalid keep their defaults, so a hand-edited
/// file with a typo still loads; `error` describes the first problem found, if any.
EditorSettings parseSettings(const std::string& jsonc, std::string* error = nullptr);

/// Writes settings as a commented settings.json that explains every option.
std::string serializeSettings(const EditorSettings& settings);

/// "#RRGGBB", or "#RRGGBBAA" when not fully opaque.
std::string colorToHex(Color color);

/// "bold italic underline" style strings, both directions.
std::string fontStyleString(const StyleOverride& style);
void applyFontStyleString(StyleOverride& style, const std::string& fontStyle);

}  // namespace gw
