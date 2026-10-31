#include "BitmapMode.hpp"

#include <algorithm>
#include <cmath>

namespace gw::bitmap {

namespace {

/// Yellow code on EGA blue with white keywords, like Turbo C.
const char* const kTurboTheme = R"json({
  "name": "Bitmap Turbo",
  "type": "dark",
  "colors": {
    "editor.background": "#0000AA",
    "editor.foreground": "#FFFF55",
    "editorCursor.foreground": "#FFFFFF",
    "editor.selectionBackground": "#00AAAA",
    "editor.lineHighlightBackground": "#0A0AC0",
    "editorBracketMatch.border": "#FFFFFF",
    "editor.wordHighlightBackground": "#5555FF60",
    "editor.findMatchBackground": "#AA5500",
    "editor.findMatchHighlightBackground": "#AA550080",
    "terminal.ansiBlue": "#5555FF",
    "terminal.ansiMagenta": "#FF55FF",
    "terminal.ansiCyan": "#55FFFF"
  },
  "tokenColors": [
    { "settings": { "foreground": "#FFFF55" } },
    { "scope": "comment", "settings": { "foreground": "#AAAAAA" } },
    { "scope": ["keyword", "storage", "keyword.control", "storage.modifier", "storage.type"], "settings": { "foreground": "#FFFFFF" } },
    { "scope": ["keyword.operator", "punctuation"], "settings": { "foreground": "#FFFFFF" } },
    { "scope": "string", "settings": { "foreground": "#55FFFF" } },
    { "scope": ["constant.numeric", "constant.language", "constant.character", "constant.other"], "settings": { "foreground": "#FF55FF" } },
    { "scope": "constant.character.escape", "settings": { "foreground": "#FFFFFF" } },
    { "scope": ["support.function", "variable.function", "entity.name.function.call",
                "meta.function-call entity.name.function", "meta.function-call.generic"],
      "settings": { "foreground": "#55FF55" } },
    { "scope": ["entity.name.type", "entity.name.class", "support.type", "support.class"], "settings": { "foreground": "#FFFFFF" } },
    { "scope": ["meta.preprocessor", "keyword.control.directive", "entity.name.tag"], "settings": { "foreground": "#55FF55" } },
    { "scope": ["entity.other.attribute-name", "support.type.property-name"], "settings": { "foreground": "#55FFFF" } },
    { "scope": ["markup.heading", "markup.bold"], "settings": { "foreground": "#FFFFFF" } },
    { "scope": ["markup.inline.raw", "markup.fenced_code"], "settings": { "foreground": "#55FFFF" } },
    { "scope": "markup.inserted", "settings": { "foreground": "#55FF55" } },
    { "scope": "markup.deleted", "settings": { "foreground": "#FF5555" } },
    { "scope": "invalid", "settings": { "foreground": "#FF5555" } }
  ]
})json";

/// The colors of the Ocean Low Tide theme (after Material Ocean): soft lavender code on near black,
/// cyan keywords, purple storage, blue functions, yellow types, green strings, orange numbers.
const char* const kLowTideTheme = R"json({
  "name": "Bitmap Low Tide",
  "type": "dark",
  "colors": {
    "editor.background": "#0F111A",
    "editor.foreground": "#BABED8",
    "editorCursor.foreground": "#FFCC00",
    "editor.selectionBackground": "#135564",
    "editor.lineHighlightBackground": "#090B10",
    "editorBracketMatch.border": "#FFCC00",
    "editor.wordHighlightBackground": "#FF9CAC30",
    "editor.findMatchBackground": "#F78C6C60",
    "editor.findMatchHighlightBackground": "#F78C6C30",
    "terminal.ansiBlue": "#82AAFF",
    "terminal.ansiMagenta": "#C792EA",
    "terminal.ansiCyan": "#89DDFF"
  },
  "tokenColors": [
    { "settings": { "foreground": "#BABED8" } },
    { "scope": ["comment", "string.quoted.docstring"], "settings": { "foreground": "#5F6576" } },
    { "scope": "string", "settings": { "foreground": "#C3E88D" } },
    { "scope": ["punctuation", "constant.other.symbol", "keyword.operator"], "settings": { "foreground": "#89DDFF" } },
    { "scope": "constant.numeric", "settings": { "foreground": "#F78C6C" } },
    { "scope": ["constant.language", "constant.language.boolean"], "settings": { "foreground": "#FF9CAC" } },
    { "scope": "constant.character.escape", "settings": { "foreground": "#BABED8" } },
    { "scope": ["keyword", "keyword.control", "meta.preprocessor", "keyword.control.directive"], "settings": { "foreground": "#89DDFF" } },
    { "scope": "keyword.other", "settings": { "foreground": "#F78C6C" } },
    { "scope": ["storage.type", "storage.modifier", "storage.control"], "settings": { "foreground": "#C792EA" } },
    { "scope": ["entity.name.function", "support.function", "meta.function-call entity.name.function", "variable.function"],
      "settings": { "foreground": "#82AAFF" } },
    { "scope": ["support.type", "support.class", "entity.name.type", "entity.name.class", "entity.other.inherited-class"],
      "settings": { "foreground": "#FFCB6B" } },
    { "scope": ["variable.object.property", "meta.object-literal.key", "entity.name.tag", "support.module"],
      "settings": { "foreground": "#F07178" } },
    { "scope": "entity.other.attribute-name", "settings": { "foreground": "#C792EA" } },
    { "scope": "markup.heading", "settings": { "foreground": "#89DDFF" } },
    { "scope": ["markup.bold", "markup.italic"], "settings": { "foreground": "#F07178" } },
    { "scope": ["markup.inline.raw", "markup.fenced_code"], "settings": { "foreground": "#C3E88D" } },
    { "scope": "markup.inserted", "settings": { "foreground": "#C3E88D" } },
    { "scope": "markup.changed", "settings": { "foreground": "#F78C6C" } },
    { "scope": "markup.deleted", "settings": { "foreground": "#F07178" } },
    { "scope": "invalid", "settings": { "foreground": "#F07178" } }
  ]
})json";

/// Shades of one green, like an old phosphor monitor.
const char* const kPhosphorTheme = R"json({
  "name": "Bitmap Phosphor",
  "type": "dark",
  "colors": {
    "editor.background": "#001400",
    "editor.foreground": "#33FF33",
    "editorCursor.foreground": "#66FF66",
    "editor.selectionBackground": "#0A4A0A",
    "editor.lineHighlightBackground": "#002200",
    "editorBracketMatch.border": "#B6FFB6",
    "editor.wordHighlightBackground": "#33FF3330",
    "editor.findMatchBackground": "#1F9F1F80",
    "editor.findMatchHighlightBackground": "#1F9F1F40",
    "terminal.ansiBlue": "#33FF33",
    "terminal.ansiMagenta": "#66FF66",
    "terminal.ansiCyan": "#B6FFB6"
  },
  "tokenColors": [
    { "settings": { "foreground": "#33FF33" } },
    { "scope": "comment", "settings": { "foreground": "#1F9F1F" } },
    { "scope": ["keyword", "storage", "keyword.control", "storage.type", "storage.modifier"], "settings": { "foreground": "#B6FFB6" } },
    { "scope": "string", "settings": { "foreground": "#8CFF8C" } },
    { "scope": ["constant.numeric", "constant.language", "constant.character"], "settings": { "foreground": "#D4FFD4" } },
    { "scope": ["entity.name.function", "support.function", "variable.function"], "settings": { "foreground": "#66FF66" } },
    { "scope": ["entity.name.type", "entity.name.class", "support.type", "support.class"], "settings": { "foreground": "#B6FFB6" } },
    { "scope": "invalid", "settings": { "foreground": "#D4FFD4" } }
  ]
})json";

Scheme turbo() {
    Scheme s;
    s.name = "Turbo";
    s.themeJson = kTurboTheme;
    s.desktop = 0x000055FF;
    s.desktopDots = kBlue;
    s.window = kBlue;
    s.frame = kWhite;
    s.frameDim = kLightGrey;
    s.text = kWhite;
    s.textDim = kLightGrey;
    s.textAccent = kYellow;
    s.selection = kCyan;
    s.selectionText = kBlack;
    s.gutter = 0x000088FF;
    s.lineNumber = kLightGrey;
    s.lineNumberActive = kWhite;
    s.scrollTrack = kCyan;
    s.scrollThumb = kLightGrey;
    s.scrollButton = kCyan;
    s.scrollArrow = kBlue;
    s.closeBox = kLightGreen;
    s.bar = kLightGrey;
    s.barText = kBlack;
    s.barHotkey = kRed;
    s.barDim = kDarkGrey;
    s.barHighlight = kGreen;
    s.barHighlightText = kBlack;
    s.dialogTitle = kWhite;
    s.dialogTitleText = kBlack;
    s.folder = kYellow;
    s.file = kWhite;
    s.add = kLightGreen;
    s.link = kLightCyan;
    s.error = kLightRed;
    s.warning = kYellow;
    s.info = kLightCyan;
    s.good = kLightGreen;
    s.input = kCyan;
    s.inputText = kBlack;
    return s;
}

Scheme lowTide() {
    Scheme s;
    s.name = "Low Tide";
    s.themeJson = kLowTideTheme;
    s.desktop = 0x090B10FF;
    s.desktopDots = 0x0F111AFF;
    s.window = 0x0F111AFF;
    s.frame = 0x80CBC4FF;
    s.frameDim = 0x4B526DFF;
    s.text = 0xBABED8FF;
    s.textDim = 0x717CB4FF;
    s.textAccent = 0xFFCC00FF;
    s.selection = 0x135564FF;
    s.selectionText = 0xFFFFFFFF;
    s.gutter = 0x090B10FF;
    s.lineNumber = 0x4B526DFF;
    s.lineNumberActive = 0xBABED8FF;
    s.scrollTrack = 0x1A1C25FF;
    s.scrollThumb = 0x717CB4FF;
    s.scrollButton = 0x1A1C25FF;
    s.scrollArrow = 0x80CBC4FF;
    s.closeBox = 0xC3E88DFF;
    s.bar = 0x1A1C25FF;
    s.barText = 0xBABED8FF;
    s.barHotkey = 0xF78C6CFF;
    s.barDim = 0x4B526DFF;
    s.barHighlight = 0x135564FF;
    s.barHighlightText = 0xFFFFFFFF;
    s.dialogTitle = 0x80CBC4FF;
    s.dialogTitleText = 0x0F111AFF;
    s.folder = 0xFFCB6BFF;
    s.file = 0xBABED8FF;
    s.add = 0xC3E88DFF;
    s.link = 0x89DDFFFF;
    s.error = 0xF07178FF;
    s.warning = 0xFFCB6BFF;
    s.info = 0x82AAFFFF;
    s.good = 0xC3E88DFF;
    s.input = 0x1A1C25FF;
    s.inputText = 0xBABED8FF;
    return s;
}

Scheme phosphor() {
    Scheme s;
    s.name = "Phosphor";
    s.themeJson = kPhosphorTheme;
    s.desktop = 0x000000FF;
    s.desktopDots = 0x001A00FF;
    s.window = 0x001400FF;
    s.frame = 0x33FF33FF;
    s.frameDim = 0x1F9F1FFF;
    s.text = 0x33FF33FF;
    s.textDim = 0x1F9F1FFF;
    s.textAccent = 0xB6FFB6FF;
    s.selection = 0x33FF33FF;
    s.selectionText = 0x001400FF;
    s.gutter = 0x000F00FF;
    s.lineNumber = 0x1F9F1FFF;
    s.lineNumberActive = 0x66FF66FF;
    s.scrollTrack = 0x0A3A0AFF;
    s.scrollThumb = 0x33FF33FF;
    s.scrollButton = 0x1F9F1FFF;
    s.scrollArrow = 0x001400FF;
    s.closeBox = 0xB6FFB6FF;
    s.bar = 0x0A4A0AFF;
    s.barText = 0x66FF66FF;
    s.barHotkey = 0xD4FFD4FF;
    s.barDim = 0x1F9F1FFF;
    s.barHighlight = 0x33FF33FF;
    s.barHighlightText = 0x001400FF;
    s.dialogTitle = 0x33FF33FF;
    s.dialogTitleText = 0x001400FF;
    s.folder = 0xB6FFB6FF;
    s.file = 0x33FF33FF;
    s.add = 0x66FF66FF;
    s.link = 0xB6FFB6FF;
    s.error = 0xD4FFD4FF;
    s.warning = 0x99FF99FF;
    s.info = 0x66CC66FF;
    s.good = 0x66FF66FF;
    s.input = 0x0A4A0AFF;
    s.inputText = 0x66FF66FF;
    return s;
}

}  // namespace

EditorSettings withLocks(EditorSettings settings) {
    if (!settings.bitmapMode) {
        return settings;
    }
    settings.vimMode = true;
    settings.showMinimap = false;
    settings.stickyScroll = false;
    settings.indentGuides = false;
    settings.sectionDividers = false;
    settings.bracketPairColors = false;
    settings.colors.rainbowVariables = false;
    settings.frostedBackdrop = false;
    settings.editorOpacity = 1;
    return settings;
}

double pixelSize(double fontSize) {
    // The default 13 pt font gives 2 pt pixels: 12 pt per character, 24 pt per line.
    return std::max(1.0, std::round(fontSize / 6.5 * 2) / 2);
}

const std::vector<Scheme>& schemes() {
    static const std::vector<Scheme> all = {turbo(), lowTide(), phosphor()};
    return all;
}

const Scheme& schemeNamed(const std::string& name) {
    const std::vector<Scheme>& all = schemes();
    auto found = std::find_if(all.begin(), all.end(), [&](const Scheme& scheme) { return scheme.name == name; });
    return found != all.end() ? *found : all.front();
}

}  // namespace gw::bitmap
