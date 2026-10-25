// Tests for soft wrapping, the line/row map and code folding.

#include "TestHarness.hpp"

#include "EditorConfig.hpp"
#include "Folding.hpp"
#include "LineStore.hpp"
#include "RowMap.hpp"
#include "SemanticTokens.hpp"
#include "Tasks.hpp"
#include "TextBuffer.hpp"
#include "Wrap.hpp"

#include <filesystem>
#include <fstream>
#include <random>
#include <string>
#include <unistd.h>

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

// ---- .editorconfig

TEST(editorConfigGlobs) {
    CHECK(gw::editorConfigGlobMatches("*", "a.txt"));
    CHECK(gw::editorConfigGlobMatches("*", "src/deep/a.txt"));  // a bare pattern matches at any depth
    CHECK(gw::editorConfigGlobMatches("*.py", "src/x.py"));
    CHECK(!gw::editorConfigGlobMatches("*.py", "src/x.pyc"));
    CHECK(gw::editorConfigGlobMatches("*.{js,ts}", "app/main.ts"));
    CHECK(!gw::editorConfigGlobMatches("*.{js,ts}", "app/main.py"));
    CHECK(gw::editorConfigGlobMatches("Makefile", "sub/Makefile"));
    CHECK(gw::editorConfigGlobMatches("lib/**.js", "lib/a/b/c.js"));
    CHECK(!gw::editorConfigGlobMatches("lib/*.js", "lib/a/b.js"));  // a slash pattern is anchored, * stops at /
    CHECK(gw::editorConfigGlobMatches("lib/*.js", "lib/b.js"));
    CHECK(gw::editorConfigGlobMatches("file{1..3}.txt", "file2.txt"));
    CHECK(!gw::editorConfigGlobMatches("file{1..3}.txt", "file4.txt"));
    CHECK(gw::editorConfigGlobMatches("[abc].txt", "b.txt"));
    CHECK(gw::editorConfigGlobMatches("[!abc].txt", "d.txt"));
    CHECK(!gw::editorConfigGlobMatches("[!abc].txt", "a.txt"));
}

TEST(editorConfigReadsSectionsInOrder) {
    const char* text =
        "# top\nroot = true\n\n"
        "[*]\nindent_style = space\nindent_size = 4\ntrim_trailing_whitespace = true\n\n"
        "[*.md]\ntrim_trailing_whitespace = false\n\n"
        "[Makefile]\nindent_style = tab\nindent_size = unset\n";
    gw::EditorConfigResult cpp;
    bool root = gw::applyEditorConfigText(text, "/p", "/p/src/a.cpp", cpp);
    CHECK(root);
    CHECK_EQ(*cpp.useTabs, false);
    CHECK_EQ(*cpp.indentSize, 4);
    CHECK_EQ(*cpp.trimTrailingWhitespace, true);

    gw::EditorConfigResult markdown;
    gw::applyEditorConfigText(text, "/p", "/p/README.md", markdown);
    CHECK_EQ(*markdown.trimTrailingWhitespace, false);  // the later section wins
    CHECK_EQ(*markdown.indentSize, 4);

    gw::EditorConfigResult makefile;
    gw::applyEditorConfigText(text, "/p", "/p/Makefile", makefile);
    CHECK_EQ(*makefile.useTabs, true);
    CHECK(!makefile.indentSize.has_value());  // unset
}

TEST(editorConfigFilesAreFoundAndCombined) {
    std::filesystem::path base = std::filesystem::temp_directory_path() / ("gw-editorconfig-" + std::to_string(::getpid()));
    std::filesystem::create_directories(base / "inner");
    {
        std::ofstream(base / ".editorconfig") << "root = true\n[*]\nindent_size = 2\ninsert_final_newline = true\n";
        std::ofstream(base / "inner" / ".editorconfig") << "[*.txt]\nindent_size = 8\n";
    }
    gw::EditorConfigResult result = gw::editorConfigFor(base / "inner" / "a.txt");
    CHECK_EQ(*result.indentSize, 8);                 // the closer file wins
    CHECK_EQ(*result.insertFinalNewline, true);      // and the outer one still applies
    gw::EditorConfigResult other = gw::editorConfigFor(base / "inner" / "a.cpp");
    CHECK_EQ(*other.indentSize, 2);
    std::filesystem::remove_all(base);
}

// ---- Semantic tokens

TEST(semanticTokensDecodeRelativePositions) {
    // line 0: two tokens; then line 2: one token (its start is counted from the line start).
    std::vector<uint32_t> data = {
        0, 4, 3, 1, 0,   // line 0, column 4, length 3, type 1
        0, 5, 2, 2, 1,   // same line, 5 further on: column 9
        2, 1, 6, 0, 0,   // two lines down, column 1
    };
    std::vector<gw::SemanticToken> tokens = gw::decodeSemanticTokens(data);
    CHECK_EQ(tokens.size(), size_t(3));
    CHECK_EQ(tokens[0].line, 0u);
    CHECK_EQ(tokens[0].startUnit, 4u);
    CHECK_EQ(tokens[1].startUnit, 9u);
    CHECK_EQ(tokens[1].modifiers, 1u);
    CHECK_EQ(tokens[2].line, 2u);
    CHECK_EQ(tokens[2].startUnit, 1u);
    CHECK_EQ(tokens[2].lengthUnits, 6u);
    // A truncated list keeps the whole tokens and drops the rest.
    CHECK_EQ(gw::decodeSemanticTokens({0, 1, 2, 3, 4, 9, 9}).size(), size_t(1));
}

TEST(semanticTokenScopes) {
    CHECK_EQ(gw::scopeForSemanticType("function", {}), std::string("entity.name.function"));
    CHECK_EQ(gw::scopeForSemanticType("class", {}), std::string("entity.name.type.class"));
    CHECK(gw::scopeForSemanticType("variable", {}).empty());   // left to the grammar and rainbow colors
    CHECK(gw::scopeForSemanticType("keyword", {}).empty());
}

TEST(semanticTokensFollowEdits) {
    std::vector<gw::SemanticToken> tokens;
    for (uint32_t line = 0; line < 6; ++line) {
        tokens.push_back({line, 0, 1, 0, 0});
    }
    // Lines 2..3 replaced by three lines: one more line in the file.
    gw::adjustSemanticTokensForEdit(tokens, 2, 3, 1);
    CHECK_EQ(tokens.size(), size_t(4));        // lines 2 and 3 lost their tokens
    CHECK_EQ(tokens[0].line, 0u);
    CHECK_EQ(tokens[1].line, 1u);
    CHECK_EQ(tokens[2].line, 5u);              // old line 4 is now line 5
    CHECK_EQ(tokens[3].line, 6u);
    // An edit that keeps the line count only drops the edited line.
    gw::adjustSemanticTokensForEdit(tokens, 0, 0, 0);
    CHECK_EQ(tokens.size(), size_t(3));
    CHECK_EQ(tokens[0].line, 1u);
}

// ---- LineStore

TEST(lineStoreSplitsTextIntoLines) {
    size_t crlf = 0, lf = 0;
    gw::LineStore store = gw::LineStore::fromText("one\r\ntwo\nthree\r\n\nlast", &crlf, &lf);
    CHECK_EQ(store.size(), size_t(5));
    CHECK_EQ(std::string(store.view(0)), std::string("one"));
    CHECK_EQ(std::string(store.view(1)), std::string("two"));
    CHECK_EQ(std::string(store.view(2)), std::string("three"));
    CHECK_EQ(std::string(store.view(3)), std::string(""));
    CHECK_EQ(std::string(store.view(4)), std::string("last"));
    CHECK_EQ(crlf, size_t(2));
    CHECK_EQ(lf, size_t(2));
    CHECK_EQ(store.editedLineCount(), size_t(0));  // nothing has been copied out yet

    gw::LineStore empty = gw::LineStore::fromText("", nullptr, nullptr);
    CHECK_EQ(empty.size(), size_t(1));
    gw::LineStore trailing = gw::LineStore::fromText("a\n", nullptr, nullptr);
    CHECK_EQ(trailing.size(), size_t(2));
}

TEST(lineStoreCopiesOnlyEditedLines) {
    gw::LineStore store = gw::LineStore::fromText("aaa\nbbb\nccc", nullptr, nullptr);
    std::string_view untouched = store.view(0);
    store.edit(1) += "!";
    CHECK_EQ(std::string(store.view(1)), std::string("bbb!"));
    CHECK_EQ(store.editedLineCount(), size_t(1));
    CHECK_EQ(std::string(untouched), std::string("aaa"));   // still valid: the block didn't move
    store.edit(2) += "?";
    CHECK_EQ(std::string(store.view(1)), std::string("bbb!"));  // and editing another line didn't move this one
    // A line costs 8 bytes of bookkeeping.
    CHECK_EQ(sizeof(gw::LineStore::LineRef), size_t(8));
}

TEST(lineStoreMatchesAPlainVectorOfStrings) {
    std::mt19937 random(2024);
    std::vector<std::string> model;
    std::string text;
    for (int line = 0; line < 200; ++line) {
        std::string content = "line " + std::to_string(line) + std::string(random() % 30, 'x');
        model.push_back(content);
        text += content + (line + 1 < 200 ? "\n" : "");
    }
    gw::LineStore store = gw::LineStore::fromText(std::move(text), nullptr, nullptr);
    for (int step = 0; step < 4000; ++step) {
        int action = static_cast<int>(random() % 4);
        if (action == 0 && !model.empty()) {
            size_t index = random() % model.size();
            std::string extra = std::to_string(step);
            store.edit(index) += extra;
            model[index] += extra;
        } else if (action == 1) {
            size_t index = random() % (model.size() + 1);
            std::vector<std::string> added;
            size_t count = 1 + random() % 3;
            for (size_t n = 0; n < count; ++n) {
                added.push_back("new" + std::to_string(step) + "_" + std::to_string(n));
            }
            model.insert(model.begin() + static_cast<long>(index), added.begin(), added.end());
            store.insertOwned(index, std::move(added));
        } else if (action == 2 && model.size() > 2) {
            size_t first = random() % model.size();
            size_t last = std::min(model.size(), first + 1 + random() % 3);
            model.erase(model.begin() + static_cast<long>(first), model.begin() + static_cast<long>(last));
            store.erase(first, last);
        }
        if (step % 50 == 0) {
            CHECK_EQ(store.size(), model.size());
            for (size_t index = 0; index < model.size(); ++index) {
                if (std::string(store.view(index)) != model[index]) {
                    CHECK(false);
                    return;
                }
            }
        }
    }
    CHECK_EQ(store.size(), model.size());
}

// ---- Tasks

TEST(tasksAreDetectedFromBuildFiles) {
    std::filesystem::path base = std::filesystem::temp_directory_path() / ("gw-tasks-" + std::to_string(::getpid()));
    std::filesystem::create_directories(base);
    std::ofstream(base / "CMakeLists.txt") << "project(x)\n";
    std::ofstream(base / "package.json") << R"({"scripts": {"build": "tsc", "test": "jest", "lint": "eslint .", "x; rm -rf ~": "true"}})";
    std::ofstream(base / "yarn.lock") << "";
    std::ofstream(base / "Makefile") << "all: main\nmain:\n\tcc x.c\ntest:\n\t./a.out\nCC := cc\n";

    std::vector<gw::Task> tasks = gw::detectTasks(base);
    auto find = [&](const std::string& command) {
        for (const gw::Task& task : tasks) {
            if (task.command == command) {
                return true;
            }
        }
        return false;
    };
    CHECK(find("cmake --build build"));
    CHECK(find("yarn run 'build'"));    // the project uses yarn
    CHECK(find("yarn run 'lint'"));
    CHECK(find("yarn run 'x; rm -rf ~'"));  // a script's name is never run as a command
    CHECK(find("make"));
    CHECK(find("make main"));
    CHECK(!find("make CC"));            // a variable, not a target
    CHECK(tasks.front().kind == gw::Task::Kind::Build);  // builds come first
    std::filesystem::remove_all(base);
}

TEST(runningASingleFile) {
    CHECK_EQ(gw::commandToRunFile("/p/a b.py", "python"), std::string("python3 '/p/a b.py'"));
    std::string compile = gw::commandToRunFile("/p/main.cpp", "cpp");
    CHECK(compile.find("clang++") == 0);
    CHECK(compile.find("${TMPDIR:-/tmp}/glasswork-run") != std::string::npos);  // not the shared /tmp
    CHECK(compile.find(" /tmp/") == std::string::npos);
    CHECK(gw::commandToRunFile("/p/notes.txt", "plaintext").empty());
    CHECK_EQ(gw::shellQuote("it's"), std::string("'it'\\''s'"));
}

}  // namespace

int main() {
    return harness::runAllTests();
}
