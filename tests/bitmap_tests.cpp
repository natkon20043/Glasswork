// Tests for bitmap mode: the pixel font's glyphs, the TrueType file made from them, the settings
// the mode locks, and the theme it uses.

#include "TestHarness.hpp"

#include "BitmapMode.hpp"
#include "EditorSettings.hpp"
#include "PixelFont.hpp"
#include "Theme.hpp"

#include <cmath>
#include <cstring>
#include <map>
#include <string>

namespace {

uint16_t readU16(const std::vector<uint8_t>& bytes, size_t at) {
    return static_cast<uint16_t>((bytes[at] << 8) | bytes[at + 1]);
}

uint32_t readU32(const std::vector<uint8_t>& bytes, size_t at) {
    return (static_cast<uint32_t>(readU16(bytes, at)) << 16) | readU16(bytes, at + 2);
}

uint32_t sumOfWords(const std::vector<uint8_t>& bytes, size_t offset, size_t length) {
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

struct TableRecord {
    uint32_t checksum = 0;
    uint32_t offset = 0;
    uint32_t length = 0;
};

std::map<std::string, TableRecord> tablesOf(const std::vector<uint8_t>& font) {
    std::map<std::string, TableRecord> tables;
    uint16_t count = readU16(font, 4);
    for (uint16_t index = 0; index < count; ++index) {
        size_t record = 12 + index * 16u;
        std::string tag(reinterpret_cast<const char*>(&font[record]), 4);
        tables[tag] = {readU32(font, record + 4), readU32(font, record + 8), readU32(font, record + 12)};
    }
    return tables;
}

/// The glyph index the font's format 4 cmap gives `character`, or 0.
uint16_t glyphIndexFor(const std::vector<uint8_t>& font, const TableRecord& cmap, uint16_t character) {
    size_t subtable = cmap.offset + readU32(font, cmap.offset + 8);
    uint16_t segments = readU16(font, subtable + 6) / 2;
    size_t ends = subtable + 14;
    size_t starts = ends + segments * 2u + 2;
    size_t deltas = starts + segments * 2u;
    for (uint16_t segment = 0; segment < segments; ++segment) {
        uint16_t end = readU16(font, ends + segment * 2u);
        uint16_t start = readU16(font, starts + segment * 2u);
        if (character >= start && character <= end) {
            return static_cast<uint16_t>(character + readU16(font, deltas + segment * 2u));
        }
    }
    return 0;
}

int litPixels(const gw::pixelfont::Glyph& glyph) {
    int count = 0;
    for (uint8_t row : glyph) {
        count += __builtin_popcount(row);
    }
    return count;
}

TEST(everyPrintableCharacterHasAGlyph) {
    for (char32_t character = 0x21; character <= 0x7E; ++character) {
        const gw::pixelfont::Glyph* glyph = gw::pixelfont::glyph(character);
        CHECK(glyph != nullptr);
        if (glyph != nullptr) {
            CHECK(litPixels(*glyph) > 0);
            for (uint8_t row : *glyph) {
                CHECK(row < (1u << gw::pixelfont::kGlyphWidth));  // nothing outside five columns
            }
        }
    }
    CHECK_EQ(litPixels(*gw::pixelfont::glyph(U' ')), 0);
    CHECK(gw::pixelfont::glyph(U'\t') == nullptr);
    CHECK(gw::pixelfont::glyph(U'é') == nullptr);
    for (char32_t symbol : {U'⌘', U'⇧', U'⌥', U'⌃', U'←', U'↑', U'→', U'↓', U'■', U'▲', U'▼', U'•', U'…'}) {
        const gw::pixelfont::Glyph* glyph = gw::pixelfont::glyph(symbol);
        CHECK(glyph != nullptr && litPixels(*glyph) > 0);
    }
}

TEST(glyphsSitOnTheBaselineAndDescendersHangBelow) {
    auto belowBaseline = [](char32_t character) {
        const gw::pixelfont::Glyph& glyph = *gw::pixelfont::glyph(character);
        return glyph[7] != 0 || glyph[8] != 0;
    };
    for (char32_t character : {U'g', U'j', U'p', U'q', U'y', U',', U';'}) {
        CHECK(belowBaseline(character));
    }
    for (char32_t character : {U'a', U'A', U'x', U'0', U'_', U'.'}) {
        CHECK(!belowBaseline(character));
        CHECK(gw::pixelfont::glyph(character)->at(6) != 0);  // touches the baseline row
    }
    // Capitals are seven rows tall, small letters five.
    CHECK(gw::pixelfont::glyph(U'H')->at(0) != 0);
    CHECK(gw::pixelfont::glyph(U'n')->at(1) == 0);
    CHECK(gw::pixelfont::glyph(U'n')->at(2) != 0);
}

TEST(trueTypeFileIsWellFormed) {
    std::vector<uint8_t> font = gw::pixelfont::trueTypeData();
    CHECK(font.size() > 1000);
    CHECK_EQ(font.size() % 4, size_t(0));
    CHECK_EQ(readU32(font, 0), uint32_t(0x00010000));
    auto tables = tablesOf(font);
    for (const char* tag : {"OS/2", "cmap", "glyf", "head", "hhea", "hmtx", "loca", "maxp", "name", "post"}) {
        CHECK(tables.count(tag) == 1);
    }
    for (const auto& [tag, record] : tables) {
        CHECK(record.offset % 4 == 0);
        CHECK(record.offset + record.length <= font.size());
        if (tag != "head") {
            CHECK_EQ(sumOfWords(font, record.offset, record.length), record.checksum);
        }
    }
    // The checksum adjustment makes the whole file add up to the magic number.
    CHECK_EQ(sumOfWords(font, 0, font.size()), uint32_t(0xB1B0AFBA));

    const TableRecord& head = tables["head"];
    CHECK_EQ(readU32(font, head.offset + 12), uint32_t(0x5F0F3CF5));
    CHECK_EQ(readU16(font, head.offset + 18), uint16_t(gw::pixelfont::kPixelsPerEm * gw::pixelfont::kUnitsPerPixel));

    uint16_t glyphs = readU16(font, tables["maxp"].offset + 4);
    CHECK_EQ(glyphs, uint16_t(1 + (0x7E - 0x20 + 1) + 13));  // missing glyph, ASCII, symbols
    CHECK_EQ(tables["hmtx"].length, uint32_t(glyphs * 4));
    CHECK_EQ(tables["loca"].length, uint32_t((glyphs + 1) * 4));
    CHECK_EQ(readU32(font, tables["loca"].offset + glyphs * 4u), tables["glyf"].length);
    // Every glyph is one advance wide.
    for (uint16_t index = 0; index < glyphs; ++index) {
        CHECK_EQ(readU16(font, tables["hmtx"].offset + index * 4u), uint16_t(gw::pixelfont::kAdvance * gw::pixelfont::kUnitsPerPixel));
    }
}

TEST(characterMapPointsAtTheRightGlyphs) {
    std::vector<uint8_t> font = gw::pixelfont::trueTypeData();
    auto tables = tablesOf(font);
    const TableRecord& cmap = tables["cmap"];
    CHECK_EQ(glyphIndexFor(font, cmap, ' '), uint16_t(1));
    CHECK_EQ(glyphIndexFor(font, cmap, 'A'), uint16_t('A' - 0x20 + 1));
    CHECK_EQ(glyphIndexFor(font, cmap, '~'), uint16_t('~' - 0x20 + 1));
    CHECK_EQ(glyphIndexFor(font, cmap, 0xE9), uint16_t(0));  // not in the font: another font draws it
    // The symbols after ASCII, each found through its own segment.
    uint16_t afterAscii = uint16_t('~' - 0x20 + 2);
    CHECK_EQ(glyphIndexFor(font, cmap, 0x2022), afterAscii);
    CHECK_EQ(glyphIndexFor(font, cmap, 0x2190), uint16_t(afterAscii + 2));
    CHECK_EQ(glyphIndexFor(font, cmap, 0x2193), uint16_t(afterAscii + 5));
    CHECK_EQ(glyphIndexFor(font, cmap, 0x2318), uint16_t(afterAscii + 8));
    CHECK_EQ(glyphIndexFor(font, cmap, 0x25BC), uint16_t(afterAscii + 12));
    CHECK_EQ(glyphIndexFor(font, cmap, 0x2194), uint16_t(0));

    // The space has no outline; 'A' has one, inside the five-pixel box.
    const TableRecord& loca = tables["loca"];
    auto glyphStart = [&](uint16_t index) { return readU32(font, loca.offset + index * 4u); };
    CHECK_EQ(glyphStart(1), glyphStart(2));
    uint16_t a = glyphIndexFor(font, cmap, 'A');
    CHECK(glyphStart(a + 1) > glyphStart(a));
    size_t outline = tables["glyf"].offset + glyphStart(a);
    CHECK(static_cast<int16_t>(readU16(font, outline)) > 0);
    CHECK_EQ(static_cast<int16_t>(readU16(font, outline + 2)), int16_t(0));
    CHECK_EQ(static_cast<int16_t>(readU16(font, outline + 6)), int16_t(gw::pixelfont::kGlyphWidth * gw::pixelfont::kUnitsPerPixel));
    CHECK_EQ(static_cast<int16_t>(readU16(font, outline + 8)), int16_t(7 * gw::pixelfont::kUnitsPerPixel));
}

TEST(bitmapModeLocksVimAndDropsTheExtras) {
    gw::EditorSettings settings;
    settings.vimMode = false;
    settings.vimCursorSmear = true;
    settings.showMinimap = true;
    settings.editorOpacity = 0.4;
    gw::EditorSettings unchanged = gw::bitmap::withLocks(settings);
    CHECK(!unchanged.vimMode);
    CHECK(unchanged.showMinimap);

    settings.bitmapMode = true;
    gw::EditorSettings locked = gw::bitmap::withLocks(settings);
    CHECK(locked.vimMode);
    CHECK(!locked.showMinimap);
    CHECK(!locked.stickyScroll);
    CHECK(!locked.indentGuides);
    CHECK(!locked.colors.rainbowVariables);
    CHECK_EQ(locked.editorOpacity, 1.0);
    // The smear stays the user's choice, and everything else is left alone.
    CHECK(locked.vimCursorSmear);
    settings.vimCursorSmear = false;
    CHECK(!gw::bitmap::withLocks(settings).vimCursorSmear);
    CHECK_EQ(locked.fontSize, settings.fontSize);
    CHECK_EQ(locked.theme, settings.theme);
}

TEST(bitmapModeComesFromTheAppNotTheSettingsFile) {
    // Glasswork and Glasswork Bitmap share settings.json, so the look must not be saved in it.
    std::string error;
    CHECK(!gw::parseSettings(R"({ "window.bitmapMode": true })", &error).bitmapMode);
    gw::EditorSettings settings;
    settings.bitmapMode = true;
    CHECK(gw::serializeSettings(settings).find("bitmapMode") == std::string::npos);
}

TEST(pixelsAreWholeScreenPixels) {
    CHECK_EQ(gw::bitmap::pixelSize(13), 2.0);
    CHECK_EQ(gw::bitmap::pixelSize(8), 1.0);
    CHECK_EQ(gw::bitmap::pixelSize(1), 1.0);
    for (double size = 8; size <= 40; size += 0.5) {
        double pixel = gw::bitmap::pixelSize(size);
        CHECK(pixel >= 1);
        CHECK_EQ(pixel * 2, static_cast<double>(static_cast<int>(pixel * 2)));
    }
}

/// WCAG contrast between two opaque colors.
double contrast(gw::Color first, gw::Color second) {
    auto luminance = [](gw::Color color) {
        auto channel = [](double value) { return value <= 0.03928 ? value / 12.92 : std::pow((value + 0.055) / 1.055, 2.4); };
        return 0.2126 * channel(gw::red(color)) + 0.7152 * channel(gw::green(color)) + 0.0722 * channel(gw::blue(color));
    };
    double a = luminance(first), b = luminance(second);
    return (std::max(a, b) + 0.05) / (std::min(a, b) + 0.05);
}

TEST(everySchemeHasAThemeAndReadableText) {
    const auto& schemes = gw::bitmap::schemes();
    CHECK_EQ(schemes.size(), size_t(3));
    for (const gw::bitmap::Scheme& scheme : schemes) {
        std::string error;
        auto theme = gw::Theme::parse(scheme.themeJson, true, &error);
        CHECK(theme != nullptr);
        if (theme) {
            CHECK(theme->isDark());
            CHECK(theme->hasColor("editor.background"));
            gw::Color background = theme->color("editor.background", 0);
            gw::Color code = theme->styleFor(std::vector<std::string>{"source.c", "meta.something"}).foreground;
            CHECK(contrast(code, background) >= 4.5);
        }
        // Every kind of text must read on what it sits on.
        CHECK(contrast(scheme.text, scheme.window) >= 4.5);
        CHECK(contrast(scheme.selectionText, scheme.selection) >= 4.5);
        CHECK(contrast(scheme.barText, scheme.bar) >= 4.5);
        CHECK(contrast(scheme.barHighlightText, scheme.barHighlight) >= 4.5);
        CHECK(contrast(scheme.dialogTitleText, scheme.dialogTitle) >= 4.5);
        CHECK(contrast(scheme.inputText, scheme.input) >= 4.5);
        CHECK(contrast(scheme.lineNumberActive, scheme.gutter) >= 4.5);
        CHECK(contrast(scheme.textAccent, scheme.window) >= 4.5);
        CHECK(contrast(scheme.error, scheme.window) >= 3.0);  // always beside its icon
    }
    // Unknown names fall back to the first scheme, so a typo in settings.json can't break the app.
    CHECK_EQ(gw::bitmap::schemeNamed("Low Tide").name, std::string("Low Tide"));
    CHECK_EQ(gw::bitmap::schemeNamed("nonsense").name, std::string("Turbo"));
}

TEST(turboSchemeColorsCodeInTheEgaPalette) {
    std::string error;
    auto theme = gw::Theme::parse(gw::bitmap::schemeNamed("Turbo").themeJson, true, &error);
    CHECK(theme != nullptr);
    if (!theme) {
        return;
    }
    CHECK_EQ(theme->color("editor.background", 0), gw::bitmap::kBlue);
    CHECK_EQ(theme->styleFor(std::vector<std::string>{"source.lua", "keyword.control.lua"}).foreground, gw::bitmap::kWhite);
    CHECK_EQ(theme->styleFor(std::vector<std::string>{"source.lua", "comment.line.double-dash.lua"}).foreground, gw::bitmap::kLightGrey);
    CHECK_EQ(theme->styleFor(std::vector<std::string>{"source.lua", "string.quoted.double.lua"}).foreground, gw::bitmap::kLightCyan);
    CHECK_EQ(theme->styleFor(std::vector<std::string>{"source.lua", "support.function.lua"}).foreground, gw::bitmap::kLightGreen);
    CHECK_EQ(theme->styleFor(std::vector<std::string>{"source.lua", "meta.something"}).foreground, gw::bitmap::kYellow);
}

TEST(lowTideSchemeFollowsOceanLowTide) {
    std::string error;
    auto theme = gw::Theme::parse(gw::bitmap::schemeNamed("Low Tide").themeJson, true, &error);
    CHECK(theme != nullptr);
    if (!theme) {
        return;
    }
    CHECK_EQ(theme->color("editor.background", 0), gw::Color(0x0F111AFF));
    CHECK_EQ(theme->color("editorCursor.foreground", 0), gw::Color(0xFFCC00FF));
    CHECK_EQ(theme->styleFor(std::vector<std::string>{"source.c", "string.quoted.double.c"}).foreground, gw::Color(0xC3E88DFF));
    CHECK_EQ(theme->styleFor(std::vector<std::string>{"source.c", "keyword.control.c"}).foreground, gw::Color(0x89DDFFFF));
    CHECK_EQ(theme->styleFor(std::vector<std::string>{"source.c", "storage.type.c"}).foreground, gw::Color(0xC792EAFF));
    CHECK_EQ(theme->styleFor(std::vector<std::string>{"source.c", "entity.name.function.c"}).foreground, gw::Color(0x82AAFFFF));
    CHECK_EQ(theme->styleFor(std::vector<std::string>{"source.c", "constant.numeric.c"}).foreground, gw::Color(0xF78C6CFF));
    CHECK_EQ(theme->styleFor(std::vector<std::string>{"source.c", "meta.something"}).foreground, gw::Color(0xBABED8FF));
}

TEST(schemeChoiceIsSavedInSettings) {
    std::string error;
    gw::EditorSettings settings = gw::parseSettings(R"({ "bitmap.colors": "Low Tide" })", &error);
    CHECK(error.empty());
    CHECK_EQ(settings.bitmapColors, std::string("Low Tide"));
    CHECK_EQ(gw::parseSettings(gw::serializeSettings(settings), &error).bitmapColors, std::string("Low Tide"));
    CHECK_EQ(gw::parseSettings("{}", &error).bitmapColors, std::string("Turbo"));
}

}  // namespace

int main() {
    return harness::runAllTests();
}
