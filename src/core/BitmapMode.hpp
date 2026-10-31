#pragma once

#include "EditorSettings.hpp"
#include "Theme.hpp"

#include <string>
#include <vector>

namespace gw::bitmap {

/// One look for Glasswork Bitmap: every color its windows, bars, menus and popups use, and the code's
/// color theme.
struct Scheme {
    std::string name;
    /// A VS Code color theme for the code.
    const char* themeJson = nullptr;

    // Behind the windows: a checkerboard of two colors.
    Color desktop = 0;
    Color desktopDots = 0;

    // The code and side windows.
    Color window = 0;
    Color frame = 0;
    Color frameDim = 0;
    Color text = 0;
    Color textDim = 0;
    Color textAccent = 0;
    Color selection = 0;
    Color selectionText = 0;
    Color gutter = 0;
    Color lineNumber = 0;
    Color lineNumberActive = 0;
    Color scrollTrack = 0;
    Color scrollThumb = 0;
    Color scrollButton = 0;
    Color scrollArrow = 0;
    Color closeBox = 0;

    // The menu bar, status line, menus, dialogs and popups.
    Color bar = 0;
    Color barText = 0;
    Color barHotkey = 0;
    Color barDim = 0;
    Color barHighlight = 0;
    Color barHighlightText = 0;
    Color dialogTitle = 0;
    Color dialogTitleText = 0;

    // Lists and the debugger.
    Color folder = 0;
    Color file = 0;
    Color add = 0;
    Color link = 0;
    Color error = 0;
    Color warning = 0;
    Color info = 0;
    Color good = 0;
    Color input = 0;
    Color inputText = 0;
};

// ---- Settings
/// What bitmap mode changes: Vim always on, and none of the extra drawing (minimap, sticky lines,
/// guides, rainbow colors, see-through code). Settings without bitmap mode come back as they are.
EditorSettings withLocks(EditorSettings settings);

// ---- Sizes
/// The size of one font pixel, in points, for an editor font size: half-point steps from 1, so
/// every pixel is a whole number of screen pixels on a Retina display.
double pixelSize(double fontSize);

// ---- Looks
/// Turbo (EGA blue, the first), Low Tide (after the Ocean Low Tide theme) and Phosphor (a green screen).
const std::vector<Scheme>& schemes();
/// The first scheme for a name it doesn't know.
const Scheme& schemeNamed(const std::string& name);

// ---- Palette (0xRRGGBBAA): the sixteen EGA colors of the old DOS IDEs, which Turbo uses
constexpr Color kBlack = 0x000000FF;
constexpr Color kBlue = 0x0000AAFF;
constexpr Color kGreen = 0x00AA00FF;
constexpr Color kCyan = 0x00AAAAFF;
constexpr Color kRed = 0xAA0000FF;
constexpr Color kMagenta = 0xAA00AAFF;
constexpr Color kBrown = 0xAA5500FF;
constexpr Color kLightGrey = 0xAAAAAAFF;
constexpr Color kDarkGrey = 0x555555FF;
constexpr Color kLightBlue = 0x5555FFFF;
constexpr Color kLightGreen = 0x55FF55FF;
constexpr Color kLightCyan = 0x55FFFFFF;
constexpr Color kLightRed = 0xFF5555FF;
constexpr Color kLightMagenta = 0xFF55FFFF;
constexpr Color kYellow = 0xFFFF55FF;
constexpr Color kWhite = 0xFFFFFFFF;

}  // namespace gw::bitmap
