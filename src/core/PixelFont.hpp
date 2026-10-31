#pragma once

#include <array>
#include <cstdint>
#include <vector>

namespace gw::pixelfont {

/// One glyph, top row first; bit 4 of a row is its leftmost pixel. Rows 0-6 stand on the baseline,
/// rows 7-8 hang below it.
using Glyph = std::array<uint8_t, 9>;

// ---- Glyphs
/// Printable ASCII and a few symbols (arrows, ⌘ ⇧ ⌥ ⌃, ■ ▲ ▼, • …); nullptr for the rest, which
/// CoreText draws with a system font instead.
const Glyph* glyph(char32_t character);

// ---- Font file
/// A TrueType font, "Glasswork Pixel", drawn from the glyphs: every pixel an exact square, so at a
/// whole number of screen pixels per font pixel it stays sharp.
std::vector<uint8_t> trueTypeData();

// ---- Metrics, in font pixels
constexpr int kGlyphWidth = 5;
constexpr int kGlyphRows = 9;
constexpr int kRowsAboveBaseline = 7;
constexpr int kAdvance = 6;
constexpr int kLineHeight = 12;
/// From the top of a line down to the baseline.
constexpr int kBaseline = 9;
/// The point size is this many times the size of one font pixel in points.
constexpr int kPixelsPerEm = 10;
constexpr int kUnitsPerPixel = 100;
constexpr char32_t kFirstCharacter = 0x20;
constexpr char32_t kLastCharacter = 0x7E;

}  // namespace gw::pixelfont
