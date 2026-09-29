// Tests for soft wrapping, the line/row map and code folding.

#include "TestHarness.hpp"

#include "Folding.hpp"
#include "RowMap.hpp"
#include "TextBuffer.hpp"
#include "Wrap.hpp"

#include <string>

namespace {

TEST(shortLinesTakeOneRow) {
    CHECK_EQ(gw::countWrapRows("hello", 20, 4), 1u);
    CHECK_EQ(gw::countWrapRows("", 20, 4), 1u);
    CHECK_EQ(gw::wrapLine("hello", 20, 4).rowStarts.size(), size_t(1));
}

TEST(longWordsBreakInTheMiddle) {
    gw::WrapResult result = gw::wrapLine(std::string(25, 'a'), 10, 4);
    CHECK_EQ(result.rowStarts.size(), size_t(3));
    CHECK_EQ(result.rowStarts[1], 10u);
    CHECK_EQ(result.rowStarts[2], 20u);
}

TEST(rowsBreakAfterSpaces) {
    // "aaaa bbbb cccc": with 10 columns the second word must not be cut.
    gw::WrapResult result = gw::wrapLine("aaaa bbbb cccc", 10, 4);
    CHECK_EQ(result.rowStarts.size(), size_t(2));
    CHECK_EQ(result.rowStarts[1], 10u);  // "cccc" starts row two, after "aaaa bbbb "
}

TEST(continuationRowsKeepTheIndent) {
    gw::WrapResult result = gw::wrapLine("    abcdefghijklmnopqrstuvwxyz", 16, 4);
    CHECK_EQ(result.continuationIndent, 4u);
    // Row 1 holds 16 cells; later rows hold 16 - 4 = 12.
    CHECK_EQ(result.rowStarts.size(), size_t(3));
    CHECK_EQ(result.rowStarts[1], 16u);
    CHECK_EQ(result.rowStarts[2], 28u);
}

TEST(indentIsCappedAtHalfTheWidth) {
    gw::WrapResult result = gw::wrapLine(std::string(40, ' ') + "text text text", 20, 4);
    CHECK_EQ(result.continuationIndent, 10u);
}

TEST(tabsAndWideCharactersCountAsCells) {
    // A tab is 4 cells here: "a", three tabs (12 cells, spaces may hang past the edge) and
    // then "b" needs a second row at 10 columns.
    CHECK_EQ(gw::countWrapRows("a\t\t\tb", 10, 4), 2u);
    CHECK_EQ(gw::countWrapRows("\t\t\t", 10, 4), 1u);
    // Each of these takes two cells: 6 characters = 12 cells.
    CHECK_EQ(gw::countWrapRows("日本語日本語", 10, 4), 2u);
    CHECK_EQ(gw::countWrapRows("日本語日", 10, 4), 1u);
}

TEST(countMatchesTheRowsListed) {
    std::string text = "the quick brown fox jumps over the lazy dog and keeps running far away";
    for (uint32_t columns : {5u, 8u, 13u, 20u, 33u}) {
        gw::WrapResult result = gw::wrapLine(text, columns, 4);
        CHECK_EQ(gw::countWrapRows(text, columns, 4), static_cast<uint32_t>(result.rowStarts.size()));
        for (size_t row = 1; row < result.rowStarts.size(); ++row) {
            CHECK(result.rowStarts[row] > result.rowStarts[row - 1]);
        }
    }
}

TEST(invalidUtf8DoesNotHang) {
    std::string broken = "abc\xFF\xFE\xC3 def\xE2\x82";
    CHECK(gw::countWrapRows(broken, 6, 4) >= 1u);
}

TEST(rowMapFindsLinesFromRows) {
    gw::RowMap map;
    map.assign(std::vector<uint32_t>{1, 3, 1, 0, 0, 2, 1});
    CHECK_EQ(map.totalRows(), uint64_t(8));
    CHECK_EQ(map.firstRow(0), uint64_t(0));
    CHECK_EQ(map.firstRow(1), uint64_t(1));
    CHECK_EQ(map.firstRow(2), uint64_t(4));
    CHECK_EQ(map.firstRow(5), uint64_t(5));
    CHECK_EQ(map.firstRow(7), uint64_t(8));
    CHECK_EQ(map.lineForRow(0), size_t(0));
    CHECK_EQ(map.lineForRow(1), size_t(1));
    CHECK_EQ(map.lineForRow(3), size_t(1));
    CHECK_EQ(map.lineForRow(4), size_t(2));
    CHECK_EQ(map.lineForRow(5), size_t(5));  // lines 3 and 4 have no rows
    CHECK_EQ(map.lineForRow(6), size_t(5));
    CHECK_EQ(map.lineForRow(7), size_t(6));
    CHECK_EQ(map.lineForRow(100), size_t(6));
}

TEST(rowMapFollowsChanges) {
    gw::RowMap map;
    map.assign(5, 1);
    map.setRows(2, 4);
    CHECK_EQ(map.totalRows(), uint64_t(8));
    CHECK_EQ(map.lineForRow(4), size_t(2));
    CHECK_EQ(map.lineForRow(5), size_t(2));
    CHECK_EQ(map.lineForRow(6), size_t(3));
    CHECK_EQ(map.lineForRow(7), size_t(4));
    map.setRows(2, 0);
    CHECK_EQ(map.lineForRow(2), size_t(3));
    CHECK_EQ(map.firstRow(3), uint64_t(2));
}

TEST(rowMapAgreesWithBruteForce) {
    std::vector<uint32_t> rows;
    unsigned seed = 12345;
    for (int index = 0; index < 500; ++index) {
        seed = seed * 1103515245u + 12345u;
        rows.push_back((seed >> 16) % 4);
    }
    gw::RowMap map;
    map.assign(rows);
    uint64_t total = 0;
    for (uint32_t count : rows) {
        total += count;
    }
    CHECK_EQ(map.totalRows(), total);
    uint64_t row = 0;
    for (size_t line = 0; line < rows.size(); ++line) {
        CHECK_EQ(map.firstRow(line), row);
        for (uint32_t inside = 0; inside < rows[line]; ++inside) {
            CHECK_EQ(map.lineForRow(row + inside), line);
        }
        row += rows[line];
    }
}

TEST(rowMapReplacesLines) {
    gw::RowMap map;
    map.assign(std::vector<uint32_t>{1, 2, 3, 4});
    // Line 1 (2 rows) becomes three lines of 1, 1 and 5 rows.
    map.replaceLines(1, 1, std::vector<uint32_t>{1, 1, 5});
    CHECK_EQ(map.lineCount(), size_t(6));
    CHECK_EQ(map.totalRows(), uint64_t(1 + 1 + 1 + 5 + 3 + 4));
    CHECK_EQ(map.firstRow(4), uint64_t(8));
    CHECK_EQ(map.lineForRow(7), size_t(3));
    // Two lines merge into one.
    map.replaceLines(2, 2, std::vector<uint32_t>{2});
    CHECK_EQ(map.lineCount(), size_t(5));
    CHECK_EQ(map.totalRows(), uint64_t(1 + 1 + 2 + 3 + 4));
}

gw::TextBuffer sample() {
    return gw::TextBuffer(
        "def outer():\n"      // 0
        "    a = 1\n"         // 1
        "\n"                  // 2
        "    def inner():\n"  // 3
        "        b = 2\n"     // 4
        "        c = 3\n"     // 5
        "    return a\n"      // 6
        "\n"                  // 7
        "print(outer())\n");  // 8
}

TEST(foldingUsesIndentation) {
    gw::TextBuffer buffer = sample();
    CHECK(gw::isFoldable(buffer, 0, 4));
    CHECK(!gw::isFoldable(buffer, 1, 4));
    CHECK(gw::isFoldable(buffer, 3, 4));
    CHECK(!gw::isFoldable(buffer, 2, 4));  // blank
    CHECK(!gw::isFoldable(buffer, 8, 4));
    CHECK_EQ(gw::foldEnd(buffer, 0, 4), size_t(6));  // trailing blank line stays visible
    CHECK_EQ(gw::foldEnd(buffer, 3, 4), size_t(5));
    CHECK_EQ(gw::foldEnd(buffer, 8, 4), size_t(8));
}

TEST(foldSetHidesAndReveals) {
    gw::FoldSet folds;
    folds.fold(3, 5);
    CHECK(folds.isFoldHeader(3));
    CHECK(!folds.isHidden(3));
    CHECK(folds.isHidden(4));
    CHECK(folds.isHidden(5));
    CHECK(!folds.isHidden(6));
    // A fold around it absorbs it.
    folds.fold(0, 6);
    CHECK_EQ(folds.all().size(), size_t(1));
    CHECK(folds.isHidden(4));
    CHECK(folds.unfoldHiding(4));
    CHECK(folds.empty());
}

TEST(editsOpenTouchedFoldsAndMoveLaterOnes) {
    gw::FoldSet folds;
    folds.fold(10, 15);
    folds.fold(20, 25);
    // A line is inserted above both: they move down by one.
    folds.adjustForEdit(2, 3, 1);
    CHECK(folds.isFoldHeader(11));
    CHECK(folds.isFoldHeader(21));
    // An edit inside the first opens it.
    folds.adjustForEdit(13, 13, 0);
    CHECK(!folds.isFoldHeader(11));
    CHECK(folds.isFoldHeader(21));
    CHECK_EQ(folds.all().size(), size_t(1));
}

}  // namespace

int main() {
    return harness::runAllTests();
}
