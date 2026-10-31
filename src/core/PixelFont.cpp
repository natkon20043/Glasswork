#include "PixelFont.hpp"

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <iterator>
#include <string>
#include <string_view>

namespace gw::pixelfont {

namespace {

/// Printable ASCII from space to tilde, in order. Each glyph is up to nine rows of five pixels
/// separated by spaces ('#' lit); rows left out at the end are empty.
constexpr std::string_view kGlyphArt[] = {
    "",                                                         // space
    "..#.. ..#.. ..#.. ..#.. ..#.. ..... ..#..",                // !
    ".#.#. .#.#.",                                              // "
    "..... .#.#. ##### .#.#. ##### .#.#.",                      // #
    "..#.. .#### #.#.. .###. ..#.# ####. ..#..",                // $
    "##... ##..# ...#. ..#.. .#... #..## ...##",                // %
    ".##.. #..#. #.#.. .#... #.#.# #..#. .##.#",                // &
    "..#.. ..#..",                                              // '
    "...#. ..#.. .#... .#... .#... ..#.. ...#.",                // (
    ".#... ..#.. ...#. ...#. ...#. ..#.. .#...",                // )
    "..... ..#.. #.#.# .###. #.#.# ..#..",                      // *
    "..... ..#.. ..#.. ##### ..#.. ..#..",                      // +
    "..... ..... ..... ..... ..... ..#.. ..#.. .#...",          // ,
    "..... ..... ..... .###.",                                  // -
    "..... ..... ..... ..... ..... ..... ..#..",                // .
    "....# ....# ...#. ..#.. .#... #.... #....",                // /
    ".###. #...# #..## #.#.# ##..# #...# .###.",                // 0
    "..#.. .##.. ..#.. ..#.. ..#.. ..#.. .###.",                // 1
    ".###. #...# ....# ...#. ..#.. .#... #####",                // 2
    "####. ....# ....# .###. ....# ....# ####.",                // 3
    "...#. ..##. .#.#. #..#. ##### ...#. ...#.",                // 4
    "##### #.... ####. ....# ....# #...# .###.",                // 5
    "..##. .#... #.... ####. #...# #...# .###.",                // 6
    "##### ....# ...#. ..#.. .#... .#... .#...",                // 7
    ".###. #...# #...# .###. #...# #...# .###.",                // 8
    ".###. #...# #...# .#### ....# ...#. .##..",                // 9
    "..... ..... ..#.. ..... ..... ..#..",                      // :
    "..... ..... ..#.. ..... ..... ..#.. ..#.. .#...",          // ;
    "...#. ..#.. .#... #.... .#... ..#.. ...#.",                // <
    "..... ..... ##### ..... #####",                            // =
    ".#... ..#.. ...#. ....# ...#. ..#.. .#...",                // >
    ".###. #...# ....# ...#. ..#.. ..... ..#..",                // ?
    ".###. #...# #.### #.#.# #.### #.... .###.",                // @
    ".###. #...# #...# ##### #...# #...# #...#",                // A
    "####. #...# #...# ####. #...# #...# ####.",                // B
    ".###. #...# #.... #.... #.... #...# .###.",                // C
    "####. #...# #...# #...# #...# #...# ####.",                // D
    "##### #.... #.... ####. #.... #.... #####",                // E
    "##### #.... #.... ####. #.... #.... #....",                // F
    ".###. #...# #.... #.### #...# #...# .####",                // G
    "#...# #...# #...# ##### #...# #...# #...#",                // H
    ".###. ..#.. ..#.. ..#.. ..#.. ..#.. .###.",                // I
    "..### ...#. ...#. ...#. ...#. #..#. .##..",                // J
    "#...# #..#. #.#.. ##... #.#.. #..#. #...#",                // K
    "#.... #.... #.... #.... #.... #.... #####",                // L
    "#...# ##.## #.#.# #.#.# #...# #...# #...#",                // M
    "#...# #...# ##..# #.#.# #..## #...# #...#",                // N
    ".###. #...# #...# #...# #...# #...# .###.",                // O
    "####. #...# #...# ####. #.... #.... #....",                // P
    ".###. #...# #...# #...# #.#.# #..#. .##.#",                // Q
    "####. #...# #...# ####. #.#.. #..#. #...#",                // R
    ".#### #.... #.... .###. ....# ....# ####.",                // S
    "##### ..#.. ..#.. ..#.. ..#.. ..#.. ..#..",                // T
    "#...# #...# #...# #...# #...# #...# .###.",                // U
    "#...# #...# #...# #...# #...# .#.#. ..#..",                // V
    "#...# #...# #...# #.#.# #.#.# #.#.# .#.#.",                // W
    "#...# #...# .#.#. ..#.. .#.#. #...# #...#",                // X
    "#...# #...# .#.#. ..#.. ..#.. ..#.. ..#..",                // Y
    "##### ....# ...#. ..#.. .#... #.... #####",                // Z
    ".###. .#... .#... .#... .#... .#... .###.",                // [
    "#.... #.... .#... ..#.. ...#. ....# ....#",                // backslash
    ".###. ...#. ...#. ...#. ...#. ...#. .###.",                // ]
    "..#.. .#.#. #...#",                                        // ^
    "..... ..... ..... ..... ..... ..... #####",                // _
    ".#... ..#..",                                              // `
    "..... ..... .###. ....# .#### #...# .####",                // a
    "#.... #.... ####. #...# #...# #...# ####.",                // b
    "..... ..... .#### #.... #.... #.... .####",                // c
    "....# ....# .#### #...# #...# #...# .####",                // d
    "..... ..... .###. #...# ##### #.... .####",                // e
    "..##. .#... ####. .#... .#... .#... .#...",                // f
    "..... ..... .#### #...# #...# #...# .#### ....# .###.",    // g
    "#.... #.... ####. #...# #...# #...# #...#",                // h
    "..#.. ..... .##.. ..#.. ..#.. ..#.. .###.",                // i
    "...#. ..... ..##. ...#. ...#. ...#. ...#. #..#. .##..",    // j
    "#.... #.... #..#. #.#.. ##... #.#.. #..#.",                // k
    ".##.. ..#.. ..#.. ..#.. ..#.. ..#.. .###.",                // l
    "..... ..... ##.#. #.#.# #.#.# #.#.# #.#.#",                // m
    "..... ..... ####. #...# #...# #...# #...#",                // n
    "..... ..... .###. #...# #...# #...# .###.",                // o
    "..... ..... ####. #...# #...# #...# ####. #.... #....",    // p
    "..... ..... .#### #...# #...# #...# .#### ....# ....#",    // q
    "..... ..... #.##. ##..# #.... #.... #....",                // r
    "..... ..... .#### #.... .###. ....# ####.",                // s
    ".#... .#... ####. .#... .#... .#... ..##.",                // t
    "..... ..... #...# #...# #...# #...# .####",                // u
    "..... ..... #...# #...# #...# .#.#. ..#..",                // v
    "..... ..... #...# #.#.# #.#.# #.#.# .#.#.",                // w
    "..... ..... #...# .#.#. ..#.. .#.#. #...#",                // x
    "..... ..... #...# #...# #...# #...# .#### ....# .###.",    // y
    "..... ..... ##### ...#. ..#.. .#... #####",                // z
    "...## ..#.. ..#.. .#... ..#.. ..#.. ...##",                // {
    "..#.. ..#.. ..#.. ..#.. ..#.. ..#.. ..#.. ..#..",          // |
    "##... ..#.. ..#.. ...#. ..#.. ..#.. ##...",                // }
    "..... ..... .#..# #.##.",                                  // ~
};

constexpr size_t kAsciiCount = kLastCharacter - kFirstCharacter + 1;
static_assert(std::size(kGlyphArt) == kAsciiCount, "one picture per printable ASCII character");

/// A few symbols beyond ASCII that menus, shortcuts and window frames use, in code point order.
struct ExtraArt {
    char32_t character;
    std::string_view art;
};
constexpr ExtraArt kExtraArt[] = {
    {0x2022, "..... ..... ..... .##.. .##.."},                      // bullet
    {0x2026, "..... ..... ..... ..... ..... ..... #.#.#"},          // ellipsis
    {0x2190, "..... ..#.. .#... ##### .#... ..#.."},                // left arrow
    {0x2191, "..#.. .###. #.#.# ..#.. ..#.. ..#.. ..#.."},          // up arrow
    {0x2192, "..... ..#.. ...#. ##### ...#. ..#.."},                // right arrow
    {0x2193, "..#.. ..#.. ..#.. ..#.. #.#.# .###. ..#.."},          // down arrow
    {0x21E7, "..#.. .#.#. #...# ##.## .#.#. .#.#. .###."},          // shift
    {0x2303, "..... ..... ..#.. .#.#. #...#"},                      // control
    {0x2318, "..... #...# .###. .#.#. .###. #...#"},                // command
    {0x2325, "..... ##.## ..#.. ..#.. ...#. ...##"},                // option
    {0x25A0, "..... ..... .###. .###. .###."},                      // small square
    {0x25B2, "..... ..... ..... ..#.. .###. #####"},                // up triangle
    {0x25BC, "..... ..... ..... ##### .###. ..#.."},                // down triangle
};
constexpr size_t kGlyphCount = kAsciiCount + std::size(kExtraArt);

/// A hollow box, for the font's "missing glyph".
constexpr std::string_view kMissingArt = "##### #...# #...# #...# #...# #...# #####";

Glyph parseGlyph(std::string_view art) {
    Glyph glyph{};
    size_t row = 0;
    size_t column = 0;
    for (char pixel : art) {
        if (pixel == ' ') {
            ++row;
            column = 0;
            continue;
        }
        if (row < glyph.size() && column < static_cast<size_t>(kGlyphWidth) && pixel == '#') {
            glyph[row] |= static_cast<uint8_t>(1u << (kGlyphWidth - 1 - column));
        }
        ++column;
    }
    return glyph;
}

/// ASCII first, then the extra symbols; glyph `index + 1` in the font.
const std::array<Glyph, kGlyphCount>& glyphTable() {
    static const std::array<Glyph, kGlyphCount> table = [] {
        std::array<Glyph, kGlyphCount> glyphs{};
        for (size_t index = 0; index < kAsciiCount; ++index) {
            glyphs[index] = parseGlyph(kGlyphArt[index]);
        }
        for (size_t index = 0; index < std::size(kExtraArt); ++index) {
            glyphs[kAsciiCount + index] = parseGlyph(kExtraArt[index].art);
        }
        return glyphs;
    }();
    return table;
}

/// The character each glyph of the table draws, in the same order.
char32_t characterAt(size_t index) {
    return index < kAsciiCount ? static_cast<char32_t>(kFirstCharacter + index) : kExtraArt[index - kAsciiCount].character;
}

// ---- Outlines

/// Lit pixels from `left` to `right` and `top` to `bottom` (exclusive), rows counted from the top.
struct PixelRect {
    int left = 0;
    int right = 0;
    int top = 0;
    int bottom = 0;
};

/// The glyph as rectangles: runs along each row, joined with the same run in the row above.
std::vector<PixelRect> rectanglesOf(const Glyph& glyph) {
    std::vector<PixelRect> rects;
    std::vector<size_t> open;  // rects that reach the row above
    for (int row = 0; row < kGlyphRows; ++row) {
        std::vector<size_t> stillOpen;
        int column = 0;
        while (column < kGlyphWidth) {
            auto lit = [&](int at) { return (glyph[static_cast<size_t>(row)] >> (kGlyphWidth - 1 - at)) & 1; };
            if (!lit(column)) {
                ++column;
                continue;
            }
            int start = column;
            while (column < kGlyphWidth && lit(column)) {
                ++column;
            }
            auto above = std::find_if(open.begin(), open.end(), [&](size_t index) {
                return rects[index].left == start && rects[index].right == column;
            });
            if (above != open.end()) {
                rects[*above].bottom = row + 1;
                stillOpen.push_back(*above);
            } else {
                rects.push_back({start, column, row, row + 1});
                stillOpen.push_back(rects.size() - 1);
            }
        }
        open = std::move(stillOpen);
    }
    return rects;
}

/// Big-endian bytes, as every TrueType table wants them.
class Writer {
public:
    void u8(uint8_t value) { bytes.push_back(value); }
    void u16(uint16_t value) {
        u8(static_cast<uint8_t>(value >> 8));
        u8(static_cast<uint8_t>(value));
    }
    void i16(int16_t value) { u16(static_cast<uint16_t>(value)); }
    void u32(uint32_t value) {
        u16(static_cast<uint16_t>(value >> 16));
        u16(static_cast<uint16_t>(value));
    }
    void i64(int64_t value) {
        u32(static_cast<uint32_t>(static_cast<uint64_t>(value) >> 32));
        u32(static_cast<uint32_t>(value));
    }
    void tag(const char* text) {
        for (int index = 0; index < 4; ++index) {
            u8(static_cast<uint8_t>(text[index]));
        }
    }
    void padTo4() {
        while (bytes.size() % 4 != 0) {
            u8(0);
        }
    }
    void putU32At(size_t offset, uint32_t value) {
        bytes[offset] = static_cast<uint8_t>(value >> 24);
        bytes[offset + 1] = static_cast<uint8_t>(value >> 16);
        bytes[offset + 2] = static_cast<uint8_t>(value >> 8);
        bytes[offset + 3] = static_cast<uint8_t>(value);
    }

    std::vector<uint8_t> bytes;
};

uint32_t checksum(const std::vector<uint8_t>& bytes, size_t offset, size_t length) {
    uint32_t sum = 0;
    for (size_t index = 0; index < length; index += 4) {
        uint32_t word = 0;
        for (size_t part = 0; part < 4; ++part) {
            size_t at = offset + index + part;
            word = (word << 8) | (at < offset + length ? bytes[at] : 0);
        }
        sum += word;
    }
    return sum;
}

int16_t unitsX(int pixels) { return static_cast<int16_t>(pixels * kUnitsPerPixel); }
/// Row `row` from the top has its top edge `kRowsAboveBaseline - row` pixels above the baseline.
int16_t unitsY(int row) { return static_cast<int16_t>((kRowsAboveBaseline - row) * kUnitsPerPixel); }

struct GlyphOutline {
    std::vector<uint8_t> data;
    int16_t xMin = 0;
    uint16_t contours = 0;
};

GlyphOutline outlineOf(const Glyph& glyph) {
    GlyphOutline outline;
    std::vector<PixelRect> rects = rectanglesOf(glyph);
    if (rects.empty()) {
        return outline;
    }
    int16_t xMin = INT16_MAX, yMin = INT16_MAX, xMax = INT16_MIN, yMax = INT16_MIN;
    for (const PixelRect& rect : rects) {
        xMin = std::min(xMin, unitsX(rect.left));
        xMax = std::max(xMax, unitsX(rect.right));
        yMin = std::min(yMin, unitsY(rect.bottom));
        yMax = std::max(yMax, unitsY(rect.top));
    }
    Writer out;
    out.i16(static_cast<int16_t>(rects.size()));
    out.i16(xMin);
    out.i16(yMin);
    out.i16(xMax);
    out.i16(yMax);
    for (size_t index = 0; index < rects.size(); ++index) {
        out.u16(static_cast<uint16_t>(index * 4 + 3));  // last point of each contour
    }
    out.u16(0);  // no instructions
    for (size_t index = 0; index < rects.size() * 4; ++index) {
        out.u8(0x01);  // on the curve; coordinates are full 16-bit deltas
    }
    // Each rectangle clockwise (y up): bottom left, top left, top right, bottom right.
    std::vector<std::pair<int16_t, int16_t>> points;
    for (const PixelRect& rect : rects) {
        points.push_back({unitsX(rect.left), unitsY(rect.bottom)});
        points.push_back({unitsX(rect.left), unitsY(rect.top)});
        points.push_back({unitsX(rect.right), unitsY(rect.top)});
        points.push_back({unitsX(rect.right), unitsY(rect.bottom)});
    }
    int16_t lastX = 0;
    for (const auto& point : points) {
        out.i16(static_cast<int16_t>(point.first - lastX));
        lastX = point.first;
    }
    int16_t lastY = 0;
    for (const auto& point : points) {
        out.i16(static_cast<int16_t>(point.second - lastY));
        lastY = point.second;
    }
    out.padTo4();
    outline.data = std::move(out.bytes);
    outline.xMin = xMin;
    outline.contours = static_cast<uint16_t>(rects.size());
    return outline;
}

void writeUtf16(Writer& out, std::string_view ascii) {
    for (char character : ascii) {
        out.u16(static_cast<uint16_t>(static_cast<unsigned char>(character)));
    }
}

// ---- Tables

constexpr int16_t kAscender = 9 * kUnitsPerPixel;
constexpr int16_t kDescender = -3 * kUnitsPerPixel;
constexpr uint16_t kAdvanceUnits = kAdvance * kUnitsPerPixel;
constexpr uint16_t kUnitsPerEm = kPixelsPerEm * kUnitsPerPixel;

std::vector<uint8_t> headTable(int16_t xMin, int16_t yMin, int16_t xMax, int16_t yMax) {
    Writer out;
    out.u16(1);
    out.u16(0);
    out.u32(0x00010000);  // font revision 1.0
    out.u32(0);           // checksum adjustment, filled in last
    out.u32(0x5F0F3CF5);
    out.u16(0x000B);      // baseline at y = 0, left side bearing at x = 0, whole-pixel sizes
    out.u16(kUnitsPerEm);
    out.i64(0);
    out.i64(0);
    out.i16(xMin);
    out.i16(yMin);
    out.i16(xMax);
    out.i16(yMax);
    out.u16(0);
    out.u16(6);           // smallest readable size, in pixels per em
    out.i16(2);
    out.i16(1);           // long offsets in 'loca'
    out.i16(0);
    return out.bytes;
}

std::vector<uint8_t> hheaTable(uint16_t glyphCount, int16_t xMaxExtent) {
    Writer out;
    out.u32(0x00010000);
    out.i16(kAscender);
    out.i16(kDescender);
    out.i16(0);
    out.u16(kAdvanceUnits);
    out.i16(0);
    out.i16(0);
    out.i16(xMaxExtent);
    out.i16(1);  // upright caret
    out.i16(0);
    out.i16(0);
    for (int index = 0; index < 4; ++index) {
        out.i16(0);
    }
    out.i16(0);
    out.u16(glyphCount);
    return out.bytes;
}

std::vector<uint8_t> maxpTable(uint16_t glyphCount, uint16_t maxPoints, uint16_t maxContours) {
    Writer out;
    out.u32(0x00010000);
    out.u16(glyphCount);
    out.u16(maxPoints);
    out.u16(maxContours);
    out.u16(0);
    out.u16(0);
    out.u16(2);
    for (int index = 0; index < 8; ++index) {
        out.u16(0);
    }
    return out.bytes;
}

std::vector<uint8_t> os2Table() {
    Writer out;
    out.u16(4);
    out.i16(static_cast<int16_t>(kAdvanceUnits));
    out.u16(400);  // regular weight
    out.u16(5);    // normal width
    out.u16(0);    // installable
    for (int16_t value : {500, 500, 0, 100, 500, 500, 0, 300}) {  // subscript and superscript
        out.i16(value);
    }
    out.i16(kUnitsPerPixel);                                 // strikeout size
    out.i16(static_cast<int16_t>(3 * kUnitsPerPixel));       // strikeout position
    out.i16(0);
    for (uint8_t value : {2, 0, 5, 9, 0, 0, 0, 0, 0, 0}) {  // PANOSE: Latin text, monospaced
        out.u8(value);
    }
    out.u32(1);  // Basic Latin
    out.u32(0);
    out.u32(0);
    out.u32(0);
    out.tag("GWRK");
    out.u16(0x0040);  // regular
    out.u16(static_cast<uint16_t>(kFirstCharacter));
    out.u16(static_cast<uint16_t>(characterAt(kGlyphCount - 1)));
    out.i16(kAscender);
    out.i16(kDescender);
    out.i16(0);
    out.u16(static_cast<uint16_t>(kAscender));
    out.u16(static_cast<uint16_t>(-kDescender));
    out.u32(1);  // Latin 1
    out.u32(0);
    out.i16(static_cast<int16_t>(5 * kUnitsPerPixel));  // x-height
    out.i16(static_cast<int16_t>(kRowsAboveBaseline * kUnitsPerPixel));
    out.u16(0);
    out.u16(0x20);
    out.u16(1);
    return out.bytes;
}

std::vector<uint8_t> cmapTable() {
    // Runs of characters whose glyphs follow each other, then the closing 0xFFFF segment.
    struct Segment {
        uint16_t start;
        uint16_t end;
        uint16_t firstGlyph;
    };
    std::vector<Segment> segments;
    for (size_t index = 0; index < kGlyphCount; ++index) {
        uint16_t character = static_cast<uint16_t>(characterAt(index));
        uint16_t glyph = static_cast<uint16_t>(index + 1);
        if (!segments.empty() && segments.back().end + 1 == character) {
            segments.back().end = character;
        } else {
            segments.push_back({character, character, glyph});
        }
    }
    segments.push_back({0xFFFF, 0xFFFF, 0});
    const uint16_t count = static_cast<uint16_t>(segments.size());
    uint16_t entrySelector = 0;
    while ((2u << entrySelector) <= count) {
        ++entrySelector;
    }
    const uint16_t searchRange = static_cast<uint16_t>(2u << entrySelector);

    Writer out;
    out.u16(0);
    out.u16(2);
    // Unicode (BMP) and Windows Unicode both point at the one subtable after these records.
    out.u16(0);
    out.u16(3);
    out.u32(20);
    out.u16(3);
    out.u16(1);
    out.u32(20);
    out.u16(4);
    out.u16(static_cast<uint16_t>(16 + 8 * count));
    out.u16(0);
    out.u16(static_cast<uint16_t>(count * 2));
    out.u16(searchRange);
    out.u16(entrySelector);
    out.u16(static_cast<uint16_t>(count * 2 - searchRange));
    for (const Segment& segment : segments) {
        out.u16(segment.end);
    }
    out.u16(0);
    for (const Segment& segment : segments) {
        out.u16(segment.start);
    }
    for (const Segment& segment : segments) {
        // The closing segment maps 0xFFFF to glyph 0 (0xFFFF + 1 wraps to 0).
        out.u16(segment.start == 0xFFFF ? 1 : static_cast<uint16_t>(segment.firstGlyph - segment.start));
    }
    for (size_t index = 0; index < segments.size(); ++index) {
        out.u16(0);
    }
    return out.bytes;
}

std::vector<uint8_t> nameTable() {
    const std::pair<uint16_t, std::string_view> names[] = {
        {1, "Glasswork Pixel"},
        {2, "Regular"},
        {3, "Glasswork Pixel Regular"},
        {4, "Glasswork Pixel"},
        {5, "Version 1.0"},
        {6, "GlassworkPixel-Regular"},
    };
    const uint16_t count = static_cast<uint16_t>(std::size(names));
    Writer out;
    out.u16(0);
    out.u16(count);
    out.u16(static_cast<uint16_t>(6 + 12 * count));
    uint16_t offset = 0;
    for (const auto& [identifier, text] : names) {
        out.u16(3);       // Windows
        out.u16(1);       // Unicode BMP
        out.u16(0x0409);  // English (US)
        out.u16(identifier);
        out.u16(static_cast<uint16_t>(text.size() * 2));
        out.u16(offset);
        offset = static_cast<uint16_t>(offset + text.size() * 2);
    }
    for (const auto& name : names) {
        writeUtf16(out, name.second);
    }
    return out.bytes;
}

std::vector<uint8_t> postTable() {
    Writer out;
    out.u32(0x00030000);  // no glyph names
    out.u32(0);
    out.i16(static_cast<int16_t>(-kUnitsPerPixel));
    out.i16(kUnitsPerPixel);
    out.u32(1);           // fixed pitch
    for (int index = 0; index < 4; ++index) {
        out.u32(0);
    }
    return out.bytes;
}

}  // namespace

const Glyph* glyph(char32_t character) {
    if (character >= kFirstCharacter && character <= kLastCharacter) {
        return &glyphTable()[character - kFirstCharacter];
    }
    for (size_t index = 0; index < std::size(kExtraArt); ++index) {
        if (kExtraArt[index].character == character) {
            return &glyphTable()[kAsciiCount + index];
        }
    }
    return nullptr;
}

std::vector<uint8_t> trueTypeData() {
    // Glyph 0 is the missing glyph, then one per character in order.
    std::vector<GlyphOutline> outlines;
    outlines.push_back(outlineOf(parseGlyph(kMissingArt)));
    for (const Glyph& each : glyphTable()) {
        outlines.push_back(outlineOf(each));
    }
    const uint16_t glyphCount = static_cast<uint16_t>(outlines.size());

    Writer glyf, loca, hmtx;
    uint16_t maxContours = 0;
    for (const GlyphOutline& outline : outlines) {
        loca.u32(static_cast<uint32_t>(glyf.bytes.size()));
        glyf.bytes.insert(glyf.bytes.end(), outline.data.begin(), outline.data.end());
        hmtx.u16(kAdvanceUnits);
        hmtx.i16(outline.xMin);
        maxContours = std::max(maxContours, outline.contours);
    }
    loca.u32(static_cast<uint32_t>(glyf.bytes.size()));

    const int16_t xMax = static_cast<int16_t>(kGlyphWidth * kUnitsPerPixel);
    const int16_t yMin = static_cast<int16_t>((kRowsAboveBaseline - kGlyphRows) * kUnitsPerPixel);
    const int16_t yMax = static_cast<int16_t>(kRowsAboveBaseline * kUnitsPerPixel);

    // Tables in the order of their tags, as the directory requires.
    const std::pair<const char*, std::vector<uint8_t>> tables[] = {
        {"OS/2", os2Table()},
        {"cmap", cmapTable()},
        {"glyf", glyf.bytes},
        {"head", headTable(0, yMin, xMax, yMax)},
        {"hhea", hheaTable(glyphCount, xMax)},
        {"hmtx", hmtx.bytes},
        {"loca", loca.bytes},
        {"maxp", maxpTable(glyphCount, static_cast<uint16_t>(maxContours * 4), maxContours)},
        {"name", nameTable()},
        {"post", postTable()},
    };
    const uint16_t tableCount = static_cast<uint16_t>(std::size(tables));

    Writer font;
    font.u32(0x00010000);
    font.u16(tableCount);
    font.u16(128);  // search range: 8 tables * 16
    font.u16(3);
    font.u16(static_cast<uint16_t>(tableCount * 16 - 128));
    size_t directory = font.bytes.size();
    for (size_t index = 0; index < tableCount; ++index) {
        font.tag(tables[index].first);
        font.u32(0);
        font.u32(0);
        font.u32(0);
    }
    size_t headOffset = 0;
    for (size_t index = 0; index < tableCount; ++index) {
        const std::vector<uint8_t>& table = tables[index].second;
        size_t offset = font.bytes.size();
        font.bytes.insert(font.bytes.end(), table.begin(), table.end());
        font.padTo4();
        size_t record = directory + index * 16;
        font.putU32At(record + 4, checksum(font.bytes, offset, table.size()));
        font.putU32At(record + 8, static_cast<uint32_t>(offset));
        font.putU32At(record + 12, static_cast<uint32_t>(table.size()));
        if (std::strcmp(tables[index].first, "head") == 0) {
            headOffset = offset;
        }
    }
    font.putU32At(headOffset + 8, 0xB1B0AFBA - checksum(font.bytes, 0, font.bytes.size()));
    return font.bytes;
}

}  // namespace gw::pixelfont
