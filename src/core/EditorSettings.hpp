#pragma once

#include "Styling.hpp"

#include <optional>
#include <string>
#include <vector>

namespace gw {

/// Everything a user can change, stored as a VS Code-style settings.json (JSON with comments).
struct EditorSettings {
    // ---- Font and layout
    double fontSize = 13;
    /// Empty: SF Mono.
    std::string fontFamily;
    int tabSize = 4;
    bool wordWrap = false;
    double editorOpacity = 0.40;
    /// 0 clear glass .. 1 strongest tint.
    double glassTint = 0.25;
    /// Off lets the desktop show through sharply; on gives a frosted look.
    bool frostedBackdrop = false;
    /// "regular" or "clear".
    std::string glassStyle = "regular";
    std::string theme = "Dark Modern";
    /// Extension ids ("publisher.name") switched off.
    std::vector<std::string> disabledExtensions;
    /// Empty: built-in symbols.
    std::string iconTheme;

    // ---- Editor features
    bool highlightOccurrences = true;
    bool showMinimap = true;
    /// Vim keys: normal, insert and visual modes (View > Vim Mode).
    bool vimMode = false;
    /// The Vim cursor smears as it moves, a faint trail fading into the cursor.
    bool vimCursorSmear = true;
    bool indentGuides = true;
    bool bracketPairColors = true;
    bool sectionDividers = true;
    bool stickyScroll = true;
    bool semanticHighlighting = true;
    bool inlineDiagnostics = true;
    bool inlayHints = true;
    bool languageServers = true;

    // ---- Saving (an .editorconfig overrides the trim/newline options)
    bool autoSave = false;
    bool trimTrailingWhitespace = false;
    bool insertFinalNewline = false;
    /// Needs a language server that can format.
    bool formatOnSave = false;

    // ---- Terminal
    /// 0: one point smaller than the editor's.
    double terminalFontSize = 0;
    /// Empty: $SHELL.
    std::string terminalShell;

    // ---- Colors
    ColorCustomizations colors;
};

// ---- Reading and writing

/// Missing or invalid keys keep defaults; `error` describes the first problem found.
EditorSettings parseSettings(const std::string& jsonc, std::string* error = nullptr);

/// Writes a commented settings.json explaining every option.
std::string serializeSettings(const EditorSettings& settings);

// ---- Conversions

/// "#RRGGBB", or "#RRGGBBAA" when not fully opaque.
std::string colorToHex(Color color);

/// Converts "bold italic underline" strings both ways.
std::string fontStyleString(const StyleOverride& style);
void applyFontStyleString(StyleOverride& style, const std::string& fontStyle);

}  // namespace gw
