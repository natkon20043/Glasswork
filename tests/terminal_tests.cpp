// Tests for the terminal emulator: what a screen looks like after programs print to it.

#include "TestHarness.hpp"

#include "Terminal.hpp"

#include <string>

namespace {

using gw::term::Cell;
using gw::term::MouseMode;
using gw::term::Screen;
using gw::term::TermColor;

/// The text of one row, with trailing blanks removed.
std::string rowText(const Screen& screen, long row) {
    return screen.textInRange(row, 0, row, screen.columns());
}

TEST(plainTextAndLineBreaks) {
    Screen screen(20, 5);
    screen.write("hello\r\nworld");
    CHECK_EQ(rowText(screen, 0), std::string("hello"));
    CHECK_EQ(rowText(screen, 1), std::string("world"));
    CHECK_EQ(screen.cursorRow(), 1);
    CHECK_EQ(screen.cursorColumn(), 5);

    // A bare line feed keeps the column, like a real terminal.
    Screen staircase(20, 5);
    staircase.write("ab\ncd");
    CHECK_EQ(rowText(staircase, 0), std::string("ab"));
    CHECK_EQ(rowText(staircase, 1), std::string("  cd"));
}

TEST(longLinesWrapAndJoinWhenCopied) {
    Screen screen(5, 4);
    screen.write("abcdefgh");
    CHECK_EQ(rowText(screen, 0), std::string("abcde"));
    CHECK_EQ(rowText(screen, 1), std::string("fgh"));
    CHECK(screen.row(0).wrapped);
    CHECK(!screen.row(1).wrapped);
    CHECK_EQ(screen.textInRange(0, 0, 1, 5), std::string("abcdefgh"));  // one line when copied

    screen.write("\r\nxyz");
    CHECK_EQ(screen.textInRange(0, 0, 2, 5), std::string("abcdefgh\nxyz"));
}

TEST(cursorMovementAndSaving) {
    Screen screen(20, 10);
    screen.write("\x1b[5;10H");
    CHECK_EQ(screen.cursorRow(), 4);
    CHECK_EQ(screen.cursorColumn(), 9);
    screen.write("\x1b[2A\x1b[3C");
    CHECK_EQ(screen.cursorRow(), 2);
    CHECK_EQ(screen.cursorColumn(), 12);
    screen.write("\x1b[B\x1b[2D");
    CHECK_EQ(screen.cursorRow(), 3);
    CHECK_EQ(screen.cursorColumn(), 10);
    screen.write("\x1b[100;100H");  // clamps to the corner
    CHECK_EQ(screen.cursorRow(), 9);
    CHECK_EQ(screen.cursorColumn(), 19);
    screen.write("\x1b[H\x1b[3;4H\x1b" "7\x1b[H\x1b" "8");  // save, home, restore
    CHECK_EQ(screen.cursorRow(), 2);
    CHECK_EQ(screen.cursorColumn(), 3);
    screen.write("\x1b[7G");
    CHECK_EQ(screen.cursorColumn(), 6);
    screen.write("\x1b[9d");
    CHECK_EQ(screen.cursorRow(), 8);
}

TEST(erasingPartsOfTheScreen) {
    Screen screen(10, 3);
    screen.write("aaaaaaaaaa\r\nbbbbbbbbbb\r\ncccccccccc");
    screen.write("\x1b[2;5H\x1b[K");  // erase to end of line
    CHECK_EQ(rowText(screen, 1), std::string("bbbb"));
    screen.write("\x1b[1;5H\x1b[1K");  // erase to start of line (includes the cursor cell)
    CHECK_EQ(rowText(screen, 0), std::string("     aaaaa"));
    screen.write("\x1b[3;1H\x1b[2K");
    CHECK_EQ(rowText(screen, 2), std::string(""));
    screen.write("\x1b[2;3H\x1b[J");  // erase below, and the rest of this line
    CHECK_EQ(rowText(screen, 1), std::string("bb"));
    screen.write("\x1b[2J");
    CHECK_EQ(rowText(screen, 0), std::string(""));
    CHECK_EQ(rowText(screen, 1), std::string(""));
}

TEST(colorsAndAttributes) {
    Screen screen(20, 3);
    screen.write("\x1b[31mR\x1b[1;32mG\x1b[0mN\x1b[38;5;196mI\x1b[48;2;10;20;30mT\x1b[39;49mD");
    Cell red = screen.cellAt(0, 0);
    CHECK(red.foreground.isIndexed() && red.foreground.index() == 1);
    Cell boldGreen = screen.cellAt(0, 1);
    CHECK(boldGreen.foreground.index() == 2 && (boldGreen.attributes & gw::term::kBold));
    Cell normal = screen.cellAt(0, 2);
    CHECK(normal.foreground.isDefault() && normal.attributes == 0);
    Cell indexed = screen.cellAt(0, 3);
    CHECK(indexed.foreground.isIndexed() && indexed.foreground.index() == 196);
    Cell truecolor = screen.cellAt(0, 4);
    CHECK(truecolor.background.isRgb() && truecolor.background.red() == 10 && truecolor.background.green() == 20 &&
          truecolor.background.blue() == 30);
    CHECK(truecolor.foreground.isIndexed() && truecolor.foreground.index() == 196);
    Cell reset = screen.cellAt(0, 5);
    CHECK(reset.foreground.isDefault() && reset.background.isDefault());

    // Bright colors, inverse, underline, italic, and turning them off again.
    Screen more(20, 3);
    more.write("\x1b[91;7;4;3mX\x1b[27;24;23mY");
    Cell first = more.cellAt(0, 0);
    CHECK(first.foreground.index() == 9);
    CHECK((first.attributes & gw::term::kInverse) && (first.attributes & gw::term::kUnderline) && (first.attributes & gw::term::kItalic));
    CHECK_EQ(more.cellAt(0, 1).attributes, uint16_t(0));

    // The colon forms some programs use.
    Screen colon(20, 3);
    colon.write("\x1b[38:2::1:2:3mA\x1b[38:5:99mB");
    CHECK(colon.cellAt(0, 0).foreground.isRgb() && colon.cellAt(0, 0).foreground.blue() == 3);
    CHECK(colon.cellAt(0, 1).foreground.index() == 99);
}

TEST(scrollingFillsTheHistory) {
    Screen screen(10, 3);
    screen.write("one\r\ntwo\r\nthree\r\nfour\r\nfive");
    CHECK_EQ(rowText(screen, 0), std::string("three"));
    CHECK_EQ(rowText(screen, 2), std::string("five"));
    CHECK_EQ(screen.historyCount(), size_t(2));
    CHECK_EQ(rowText(screen, -1), std::string("two"));
    CHECK_EQ(rowText(screen, -2), std::string("one"));
    CHECK_EQ(screen.textInRange(-2, 0, 2, 10), std::string("one\ntwo\nthree\nfour\nfive"));
}

TEST(historyHasALimit) {
    Screen screen(10, 2, 5);
    for (int line = 0; line < 50; ++line) {
        screen.write("line " + std::to_string(line) + "\r\n");
    }
    CHECK_EQ(screen.historyCount(), size_t(5));
}

TEST(scrollRegionsAndLineEditing) {
    Screen screen(10, 6);
    screen.write("0\r\n1\r\n2\r\n3\r\n4\r\n5");
    screen.write("\x1b[2;4r");  // rows 2..4 scroll
    screen.write("\x1b[4;1H\n");  // line feed at the bottom of the region
    CHECK_EQ(rowText(screen, 0), std::string("0"));
    CHECK_EQ(rowText(screen, 1), std::string("2"));
    CHECK_EQ(rowText(screen, 2), std::string("3"));
    CHECK_EQ(rowText(screen, 3), std::string(""));
    CHECK_EQ(rowText(screen, 4), std::string("4"));
    CHECK_EQ(rowText(screen, 5), std::string("5"));
    CHECK_EQ(screen.historyCount(), size_t(0));  // a region inside the screen keeps no history

    screen.write("\x1b[r\x1b[2;1H\x1b[2L");  // insert two lines at row 2
    CHECK_EQ(rowText(screen, 1), std::string(""));
    CHECK_EQ(rowText(screen, 2), std::string(""));
    CHECK_EQ(rowText(screen, 3), std::string("2"));
    screen.write("\x1b[2;1H\x1b[2M");  // delete them again
    CHECK_EQ(rowText(screen, 1), std::string("2"));
}

TEST(reverseIndexScrollsDownAtTheTop) {
    Screen screen(10, 3);
    screen.write("a\r\nb\r\nc\x1b[H\x1bM");
    CHECK_EQ(rowText(screen, 0), std::string(""));
    CHECK_EQ(rowText(screen, 1), std::string("a"));
    CHECK_EQ(rowText(screen, 2), std::string("b"));
}

TEST(alternateScreenKeepsTheOriginalSafe) {
    Screen screen(10, 3);
    screen.write("shell prompt\r\n$ ls");
    size_t history = screen.historyCount();
    screen.write("\x1b[?1049h");
    CHECK(screen.onAlternateScreen());
    CHECK_EQ(rowText(screen, 0), std::string(""));
    screen.write("\x1b[HFULL SCREEN APP\x1b[3;1Hmore\r\nand more\r\nand more\r\n");
    screen.write("\x1b[?1049l");
    CHECK(!screen.onAlternateScreen());
    CHECK_EQ(rowText(screen, 0), std::string("shell prom"));  // "shell prompt" wrapped at 10 columns
    CHECK_EQ(rowText(screen, 1), std::string("pt"));
    CHECK_EQ(rowText(screen, 2), std::string("$ ls"));
    CHECK_EQ(screen.historyCount(), history);  // nothing the app scrolled went to history
    CHECK_EQ(screen.cursorRow(), 2);
    CHECK_EQ(screen.cursorColumn(), 4);
}

TEST(tabsMoveToEightColumnStops) {
    Screen screen(30, 2);
    screen.write("a\tb\t\tc");
    CHECK_EQ(screen.cellAt(0, 8).character, uint32_t('b'));
    CHECK_EQ(screen.cellAt(0, 24).character, uint32_t('c'));
    screen.write("\x1b[3g\r\ta");  // clear all stops: a tab goes to the last column
    CHECK_EQ(screen.cursorColumn(), 29);
}

TEST(wideCharactersTakeTwoCells) {
    Screen screen(10, 3);
    screen.write("a\xE6\x97\xA5\xE6\x9C\xAC" "b");  // a 日 本 b
    CHECK_EQ(screen.cellAt(0, 1).character, uint32_t(0x65E5));
    CHECK(screen.cellAt(0, 1).attributes & gw::term::kWideStart);
    CHECK(screen.cellAt(0, 2).attributes & gw::term::kWideEnd);
    CHECK_EQ(screen.cellAt(0, 3).character, uint32_t(0x672C));
    CHECK_EQ(screen.cellAt(0, 5).character, uint32_t('b'));
    CHECK_EQ(screen.textInRange(0, 0, 0, 10), std::string("a\xE6\x97\xA5\xE6\x9C\xAC" "b"));

    // A wide character never straddles the edge; it moves to the next line.
    Screen edge(4, 3);
    edge.write("abc\xE6\x97\xA5");
    CHECK_EQ(rowText(edge, 0), std::string("abc"));
    CHECK_EQ(edge.cellAt(1, 0).character, uint32_t(0x65E5));

    // Overwriting half of one blanks the other half.
    Screen over(10, 2);
    over.write("\xE6\x97\xA5\x1b[1Gx");
    CHECK_EQ(over.cellAt(0, 0).character, uint32_t('x'));
    CHECK_EQ(over.cellAt(0, 1).character, uint32_t(' '));
}

TEST(utf8AcrossWritesAndBrokenBytes) {
    Screen screen(10, 2);
    screen.write("\xC3");            // half of é
    screen.write("\xA9 caf\xC3");
    screen.write("\xA9");
    CHECK_EQ(rowText(screen, 0), std::string("\xC3\xA9 caf\xC3\xA9"));

    Screen broken(10, 2);
    broken.write("a\xFF" "b\xC3" "c");  // stray byte, and a lead byte followed by a letter
    CHECK_EQ(broken.cellAt(0, 0).character, uint32_t('a'));
    CHECK_EQ(broken.cellAt(0, 1).character, uint32_t(0xFFFD));
    CHECK_EQ(broken.cellAt(0, 2).character, uint32_t('b'));
    CHECK_EQ(broken.cellAt(0, 3).character, uint32_t(0xFFFD));
    CHECK_EQ(broken.cellAt(0, 4).character, uint32_t('c'));
}

TEST(deviceReportsGoBackToTheProgram) {
    Screen screen(80, 24);
    std::string replies;
    screen.onReply = [&replies](const std::string& text) { replies += text; };
    screen.write("\x1b[5;7H\x1b[6n");
    CHECK_EQ(replies, std::string("\x1b[5;7R"));
    replies.clear();
    screen.write("\x1b[5n");
    CHECK_EQ(replies, std::string("\x1b[0n"));
    replies.clear();
    screen.write("\x1b[c");
    CHECK(replies.find("\x1b[?") == 0 && replies.back() == 'c');
    replies.clear();
    screen.write("\x1b[18t");
    CHECK_EQ(replies, std::string("\x1b[8;24;80t"));
    replies.clear();
    screen.setDefaultColors(TermColor::rgb(0xAA, 0xBB, 0xCC), TermColor::rgb(0x10, 0x20, 0x30));
    screen.write("\x1b]11;?\x07");
    CHECK_EQ(replies, std::string("\x1b]11;rgb:1010/2020/3030\x1b\\"));
}

TEST(modesProgramsSwitch) {
    Screen screen(10, 3);
    CHECK(!screen.applicationCursorKeys());
    screen.write("\x1b[?1h\x1b[?2004h\x1b[?25l\x1b[?1004h");
    CHECK(screen.applicationCursorKeys());
    CHECK(screen.bracketedPaste());
    CHECK(!screen.cursorVisible());
    CHECK(screen.focusReporting());
    screen.write("\x1b[?1l\x1b[?2004l\x1b[?25h");
    CHECK(!screen.applicationCursorKeys());
    CHECK(!screen.bracketedPaste());
    CHECK(screen.cursorVisible());

    CHECK(screen.mouseMode() == MouseMode::None);
    screen.write("\x1b[?1000h\x1b[?1006h");
    CHECK(screen.mouseMode() == MouseMode::PressRelease && screen.mouseSgr());
    screen.write("\x1b[?1002h");
    CHECK(screen.mouseMode() == MouseMode::Drag);
    screen.write("\x1b[?1002l");
    CHECK(screen.mouseMode() == MouseMode::None);
}

TEST(titlesAndWorkingDirectories) {
    Screen screen(10, 3);
    std::string title;
    std::string directory;
    screen.onTitleChange = [&title](const std::string& text) { title = text; };
    screen.onDirectoryChange = [&directory](const std::string& text) { directory = text; };
    screen.write("\x1b]0;my title\x07");
    CHECK_EQ(title, std::string("my title"));
    screen.write("\x1b]2;second\x1b\\");
    CHECK_EQ(screen.title(), std::string("second"));
    screen.write("\x1b]7;file://laptop/Users/me/My%20Project\x07");
    CHECK_EQ(directory, std::string("/Users/me/My Project"));
    CHECK_EQ(screen.workingDirectory(), std::string("/Users/me/My Project"));
    // Text after an OSC still prints.
    screen.write("ok");
    CHECK_EQ(rowText(screen, 0), std::string("ok"));
}

TEST(lineDrawingCharacterSet) {
    Screen screen(10, 3);
    screen.write("\x1b(0lqqk\x1b(B lqk");
    CHECK_EQ(screen.cellAt(0, 0).character, uint32_t(0x250C));
    CHECK_EQ(screen.cellAt(0, 1).character, uint32_t(0x2500));
    CHECK_EQ(screen.cellAt(0, 3).character, uint32_t(0x2510));
    CHECK_EQ(screen.cellAt(0, 5).character, uint32_t('l'));  // back to plain text
}

TEST(insertingAndDeletingCharacters) {
    Screen screen(10, 2);
    screen.write("abcdef\x1b[3G\x1b[2@");  // insert two blanks at column 3
    CHECK_EQ(rowText(screen, 0), std::string("ab  cdef"));
    screen.write("\x1b[2P");                // delete two characters
    CHECK_EQ(rowText(screen, 0), std::string("abcdef"));
    screen.write("\x1b[3X");                // erase three in place
    CHECK_EQ(rowText(screen, 0), std::string("ab   f"));
    screen.write("\x1b[4h" "Z" "\x1b[4l");   // insert mode shifts text
    CHECK_EQ(rowText(screen, 0), std::string("abZ   f"));
}

TEST(repeatingTheLastCharacter) {
    Screen screen(20, 2);
    screen.write("=\x1b[4b");
    CHECK_EQ(rowText(screen, 0), std::string("====="));
}

TEST(erasingUsesTheCurrentBackground) {
    Screen screen(10, 2);
    screen.write("\x1b[44m\x1b[2K");
    Cell cell = screen.cellAt(0, 5);
    CHECK(cell.background.isIndexed() && cell.background.index() == 4);
}

TEST(resizeKeepsTheCursorAndHistoryInStep) {
    Screen screen(10, 4);
    screen.write("a\r\nb\r\nc\r\nd");
    screen.resize(10, 2);  // the cursor was on the last row, so the top lines go to history
    CHECK_EQ(screen.rows(), 2);
    CHECK_EQ(rowText(screen, 0), std::string("c"));
    CHECK_EQ(rowText(screen, 1), std::string("d"));
    CHECK_EQ(screen.historyCount(), size_t(2));
    screen.resize(10, 4);  // and they come back
    CHECK_EQ(rowText(screen, 0), std::string("a"));
    CHECK_EQ(rowText(screen, 3), std::string("d"));
    CHECK_EQ(screen.cursorRow(), 3);
    CHECK_EQ(screen.historyCount(), size_t(0));

    screen.resize(4, 4);  // narrower: long text is cut
    CHECK_EQ(screen.columns(), 4);
    screen.write("\r\nxyzwv");
    CHECK(screen.cursorColumn() <= 3);
}

TEST(fullResetClearsEverything) {
    Screen screen(10, 3);
    screen.write("\x1b[31m\x1b[?1h\x1b[2;2Htext\x1b" "c");
    CHECK_EQ(rowText(screen, 1), std::string(""));
    CHECK(!screen.applicationCursorKeys());
    CHECK_EQ(screen.cursorRow(), 0);
    screen.write("x");
    CHECK(screen.cellAt(0, 0).foreground.isDefault());
}

TEST(bellAndBackspace) {
    Screen screen(10, 2);
    int bells = 0;
    screen.onBell = [&bells]() { ++bells; };
    screen.write("ab\x08\x08" "X\x07\x07");
    CHECK_EQ(bells, 2);
    CHECK_EQ(rowText(screen, 0), std::string("Xb"));
}

TEST(randomBytesNeverBreakTheScreen) {
    // Whatever arrives, the cursor stays on the screen and rows stay the right shape.
    unsigned seed = 987654321;
    auto next = [&seed]() {
        seed = seed * 1664525u + 1013904223u;
        return static_cast<uint8_t>(seed >> 16);
    };
    Screen screen(23, 9, 50);
    screen.onReply = [](const std::string&) {};
    for (int round = 0; round < 200; ++round) {
        std::string bytes;
        for (int index = 0; index < 400; ++index) {
            uint8_t byte = next();
            // Make control sequences likely.
            if (byte % 11 == 0) {
                bytes += '\x1b';
            }
            if (byte % 13 == 0) {
                bytes += '[';
            }
            bytes += static_cast<char>(byte);
        }
        screen.write(bytes);
        CHECK(screen.cursorRow() >= 0 && screen.cursorRow() < screen.rows());
        CHECK(screen.cursorColumn() >= 0 && screen.cursorColumn() < screen.columns());
        CHECK(screen.historyCount() <= 50);
        if (round % 40 == 0) {
            screen.resize(10 + round % 30, 3 + round % 12);
        }
    }
    for (int row = 0; row < screen.rows(); ++row) {
        CHECK(screen.row(row).cells.size() <= static_cast<size_t>(screen.columns()) + 1);
    }
}

TEST(realisticColoredOutput) {
    // A few lines of what `ls --color` and a colored git status print.
    Screen screen(60, 10);
    screen.write("\x1b[?2004h\x1b[1m\x1b[7m%\x1b[27m\x1b[1m\x1b[0m                                    \r \r");
    screen.write("\x1b[34mdocs\x1b[0m  \x1b[32mrun.sh\x1b[0m  README.md\r\n");
    screen.write("On branch \x1b[1mmain\x1b[m\r\nChanges not staged for commit:\r\n\t\x1b[31mmodified:   src/main.cpp\x1b[m\r\n");
    // The "%" prompt marker line is overwritten by the listing (the program returned to column 0).
    CHECK_EQ(rowText(screen, 0), std::string("docs  run.sh  README.md"));
    CHECK(screen.cellAt(0, 0).foreground.index() == 4);
    CHECK(screen.cellAt(0, 6).foreground.index() == 2);
    CHECK_EQ(rowText(screen, 2), std::string("Changes not staged for commit:"));
    CHECK_EQ(rowText(screen, 3).substr(8, 9), std::string("modified:"));
    CHECK(screen.cellAt(3, 8).foreground.index() == 1);
}

}  // namespace

int main() {
    return harness::runAllTests();
}
