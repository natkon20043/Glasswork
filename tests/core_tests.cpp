// Unit tests for Glasswork's core. A tiny harness keeps the build dependency-free.

#include "CompletionRank.hpp"
#include "CssColor.hpp"
#include "Document.hpp"
#include "EditorSettings.hpp"
#include "Extensions.hpp"
#include "Fuzzy.hpp"
#include "Glob.hpp"
#include "IconTheme.hpp"
#include "Keybindings.hpp"
#include "NavigationHistory.hpp"
#include "Sections.hpp"
#include "SelectionExpand.hpp"
#include "SettingsLookup.hpp"
#include "Snippet.hpp"
#include "SnippetLibrary.hpp"
#include "Styling.hpp"
#include "TextTransforms.hpp"
#include "WordSuggestions.hpp"
#include "Highlighter.hpp"
#include "TextBuffer.hpp"
#include "Theme.hpp"
#include "textmate/Grammar.hpp"
#include "textmate/Tokenizer.hpp"

#include <cstdio>
#include <filesystem>
#include <fstream>
#include <random>
#include <unistd.h>
#include <functional>
#include <string>
#include <vector>

namespace {

int failures = 0;
int checks = 0;

#define CHECK(condition)                                                          \
    do {                                                                          \
        ++checks;                                                                 \
        if (!(condition)) {                                                       \
            ++failures;                                                           \
            std::printf("  FAIL %s:%d: %s\n", __FILE__, __LINE__, #condition);    \
        }                                                                         \
    } while (0)

#define CHECK_EQ(actual, expected)                                                \
    do {                                                                          \
        ++checks;                                                                 \
        auto actualValue = (actual);                                              \
        auto expectedValue = (expected);                                          \
        if (!(actualValue == expectedValue)) {                                    \
            ++failures;                                                           \
            std::printf("  FAIL %s:%d: %s\n", __FILE__, __LINE__, #actual);       \
        }                                                                         \
    } while (0)

std::vector<std::pair<const char*, std::function<void()>>>& tests() {
    static std::vector<std::pair<const char*, std::function<void()>>> all;
    return all;
}

struct Register {
    Register(const char* name, std::function<void()> body) { tests().emplace_back(name, std::move(body)); }
};

#define TEST(name) \
    void name();   \
    Register register_##name(#name, name); \
    void name()

using gw::Position;
using gw::Range;

// MARK: TextBuffer

TEST(bufferSplitsLinesAndRememberCRLF) {
    gw::TextBuffer crlf("one\r\ntwo\r\nthree");
    CHECK_EQ(crlf.lineCount(), size_t(3));
    CHECK_EQ(crlf.line(1), std::string("two"));
    CHECK(crlf.usesCRLF());
    CHECK_EQ(crlf.text(), std::string("one\r\ntwo\r\nthree"));

    gw::TextBuffer empty("");
    CHECK_EQ(empty.lineCount(), size_t(1));
    gw::TextBuffer trailing("a\n");
    CHECK_EQ(trailing.lineCount(), size_t(2));
}

TEST(bufferInsertsAndErasesAcrossLines) {
    gw::TextBuffer buffer("ab\ncd");
    Position end = buffer.insert({0, 1}, "X\nY");
    CHECK_EQ(buffer.text(), std::string("aX\nYb\ncd"));
    CHECK(end == (Position{1, 1}));

    buffer.erase({{0, 1}, {2, 1}});
    CHECK_EQ(buffer.text(), std::string("ad"));
    CHECK_EQ(buffer.text(Range{{0, 0}, {0, 2}}), std::string("ad"));
}

TEST(bufferMovesByWholeUtf8Characters) {
    gw::TextBuffer buffer("aé😀b");  // é is 2 bytes, 😀 is 4
    Position position{0, 1};
    position = buffer.nextCharacter(position);
    CHECK_EQ(position.column, size_t(3));
    position = buffer.nextCharacter(position);
    CHECK_EQ(position.column, size_t(7));
    position = buffer.previousCharacter(position);
    CHECK_EQ(position.column, size_t(3));
    CHECK_EQ(buffer.clamp({0, 5}).column, size_t(3));  // mid-emoji snaps back
    CHECK(buffer.nextCharacter({0, 8}) == (Position{0, 8}));  // end of document stays put
}

TEST(bufferFindsWords) {
    gw::TextBuffer buffer("int my_value = 42;");
    Range word = buffer.wordAt({0, 6});
    CHECK_EQ(buffer.text(word), std::string("my_value"));
    CHECK_EQ(buffer.nextWordEnd({0, 3}).column, size_t(12));
    CHECK_EQ(buffer.previousWordStart({0, 12}).column, size_t(4));
}

// MARK: Document

TEST(documentMergesTypingIntoOneUndoStep) {
    gw::Document document;
    document.typeText("a");
    document.typeText("b");
    document.typeText("c");
    CHECK_EQ(document.buffer().text(), std::string("abc"));
    CHECK(document.isDirty());
    CHECK(document.undo());
    CHECK_EQ(document.buffer().text(), std::string(""));
    CHECK(document.redo());
    CHECK_EQ(document.buffer().text(), std::string("abc"));
    CHECK(document.selection.caret == (Position{0, 3}));
}

TEST(documentUndoesReplacementsAndRestoresSelection) {
    gw::Document document;
    document.typeText("hello world");
    document.selection = {{0, 6}, {0, 11}};
    document.typeText("there");
    CHECK_EQ(document.buffer().text(), std::string("hello there"));
    document.undo();
    CHECK_EQ(document.buffer().text(), std::string("hello world"));
    CHECK(document.selection.anchor == (Position{0, 6}));
    CHECK(document.selection.caret == (Position{0, 11}));
}

TEST(documentReportsChangedLines) {
    gw::Document document;
    size_t firstLine = 99;
    long delta = 99;
    document.onChange = [&](const gw::Change& change) {
        firstLine = change.firstLine;
        delta = change.lineDelta;
    };
    document.typeText("a\nb\nc");
    CHECK_EQ(firstLine, size_t(0));
    CHECK_EQ(delta, 2L);
    document.replace({{0, 1}, {2, 0}}, "");
    CHECK_EQ(delta, -2L);
    CHECK_EQ(document.buffer().text(), std::string("ac"));
}

// MARK: TextMate

const char* kGrammar = R"json({
  "scopeName": "source.test",
  "patterns": [
    { "include": "#comment" },
    { "match": "\\b(int|return)\\b", "name": "keyword.control.test" },
    { "begin": "\"", "end": "\"", "name": "string.quoted.double.test",
      "patterns": [ { "match": "\\\\.", "name": "constant.character.escape.test" } ] },
    { "match": "(\\w+)(\\()", "captures": {
        "1": { "name": "entity.name.function.test" },
        "2": { "name": "punctuation.paren.test" } } },
    { "begin": "<<(\\w+)", "end": "^\\1$", "name": "string.heredoc.test" }
  ],
  "repository": {
    "comment": { "begin": "/\\*", "end": "\\*/", "name": "comment.block.test" }
  }
})json";

/// The innermost scope covering byte `column`.
std::string innermostScope(const gw::tm::LineResult& result, size_t column) {
    for (const auto& token : result.tokens) {
        if (column >= token.start && column < token.end) return token.scopes ? token.scopes->name : "";
    }
    return "<none>";
}

TEST(tokenizerFindsKeywordsStringsAndCaptures) {
    auto grammar = gw::tm::Grammar::parse(kGrammar, nullptr);
    CHECK(grammar != nullptr);
    if (!grammar) return;
    std::string line = "int x = f(\"a\\n\");";
    auto result = gw::tm::tokenizeLine(*grammar, line, gw::tm::initialState(*grammar));
    CHECK_EQ(innermostScope(result, 0), std::string("keyword.control.test"));
    CHECK_EQ(innermostScope(result, 4), std::string("source.test"));
    CHECK_EQ(innermostScope(result, 8), std::string("entity.name.function.test"));
    CHECK_EQ(innermostScope(result, 9), std::string("punctuation.paren.test"));
    CHECK_EQ(innermostScope(result, 11), std::string("string.quoted.double.test"));
    CHECK_EQ(innermostScope(result, 12), std::string("constant.character.escape.test"));
    // Tokens cover the whole line, in order, without gaps.
    size_t cursor = 0;
    for (const auto& token : result.tokens) {
        CHECK_EQ(size_t(token.start), cursor);
        cursor = token.end;
    }
    CHECK_EQ(cursor, line.size());
    CHECK_EQ(result.state.frames.size(), size_t(1));  // nothing left open
}

TEST(tokenizerCarriesRegionsAcrossLines) {
    auto grammar = gw::tm::Grammar::parse(kGrammar, nullptr);
    if (!grammar) return;
    auto first = gw::tm::tokenizeLine(*grammar, "int a; /* starts", gw::tm::initialState(*grammar));
    CHECK_EQ(first.state.frames.size(), size_t(2));
    CHECK_EQ(innermostScope(first, 10), std::string("comment.block.test"));
    auto second = gw::tm::tokenizeLine(*grammar, "still */ return", first.state);
    CHECK_EQ(innermostScope(second, 0), std::string("comment.block.test"));
    CHECK_EQ(innermostScope(second, 9), std::string("keyword.control.test"));
    CHECK_EQ(second.state.frames.size(), size_t(1));
    CHECK(second.state == gw::tm::initialState(*grammar));
}

TEST(tokenizerFillsBackReferencesInEndPatterns) {
    auto grammar = gw::tm::Grammar::parse(kGrammar, nullptr);
    if (!grammar) return;
    auto state = gw::tm::initialState(*grammar);
    auto begin = gw::tm::tokenizeLine(*grammar, "x = <<EOT", state);
    CHECK_EQ(begin.state.frames.size(), size_t(2));
    auto inside = gw::tm::tokenizeLine(*grammar, "EOTX is not the end", begin.state);
    CHECK_EQ(inside.state.frames.size(), size_t(2));
    auto end = gw::tm::tokenizeLine(*grammar, "EOT", inside.state);
    CHECK_EQ(end.state.frames.size(), size_t(1));
}

TEST(tokenizerAnchorsBackslashGWhereTheRegionBegan) {
    // Like C++'s function definitions: a "head" starts at \G right after `fn`, and must not
    // restart at the beginning of later lines inside the body.
    const char* anchored = R"json({ "scopeName": "source.g", "patterns": [
        { "begin": "fn", "end": "\\}", "name": "meta.fn", "patterns": [
            { "begin": "\\G", "end": "\\{", "name": "meta.head" },
            { "match": "\\w+", "name": "word" } ] } ] })json";
    auto grammar = gw::tm::Grammar::parse(anchored, nullptr);
    CHECK(grammar != nullptr);
    if (!grammar) return;
    auto first = gw::tm::tokenizeLine(*grammar, "fn name {", gw::tm::initialState(*grammar));
    CHECK_EQ(innermostScope(first, 4), std::string("meta.head"));
    auto second = gw::tm::tokenizeLine(*grammar, "body }", first.state);
    CHECK_EQ(innermostScope(second, 0), std::string("word"));
    const gw::tm::ScopeNode* scopes = nullptr;
    for (const auto& token : second.tokens) {
        if (token.start == 0) scopes = token.scopes;
    }
    CHECK(scopes && scopes->parent && scopes->parent->name == "meta.fn");  // not meta.head
    CHECK_EQ(second.state.frames.size(), size_t(1));
}

TEST(tokenizerSurvivesPatternsThatMatchNothing) {
    const char* loopy = R"json({ "scopeName": "source.loop", "patterns": [
        { "match": "(?=x)", "name": "empty.lookahead" },
        { "begin": "(?=y)", "end": "(?=y)", "name": "empty.region" } ] })json";
    auto grammar = gw::tm::Grammar::parse(loopy, nullptr);
    CHECK(grammar != nullptr);
    if (!grammar) return;
    auto result = gw::tm::tokenizeLine(*grammar, "xxyy", gw::tm::initialState(*grammar));
    CHECK(!result.tokens.empty());
    CHECK_EQ(size_t(result.tokens.back().end), size_t(4));
}

// MARK: Highlighter

TEST(highlighterRedoesOnlyWhatAnEditAffects) {
    auto grammar = gw::tm::Grammar::parse(kGrammar, nullptr);
    if (!grammar) return;
    gw::Document document;
    std::string text;
    for (int index = 0; index < 200; ++index) text += "int value = f(1);\n";
    document.replace({{0, 0}, {0, 0}}, text);
    gw::Highlighter highlighter(grammar.get());
    document.onChange = [&](const gw::Change& change) { highlighter.didChange(change); };

    CHECK(highlighter.tokens(document.buffer(), 199) != nullptr);
    CHECK_EQ(highlighter.validLines(), size_t(200));

    // Editing inside line 10 without changing its end state: lines below stay valid.
    document.replace({{10, 4}, {10, 9}}, "count");
    CHECK_EQ(highlighter.validLines(), size_t(10));
    CHECK(highlighter.tokens(document.buffer(), 10) != nullptr);
    CHECK_EQ(highlighter.validLines(), size_t(200));  // converged immediately after line 10

    // Opening a block comment changes every line below.
    document.replace({{20, 0}, {20, 0}}, "/*");
    const auto* tokens = highlighter.tokens(document.buffer(), 150);
    CHECK(tokens != nullptr);
    CHECK(tokens && !tokens->empty() && tokens->front().scopes->name == "comment.block.test");

    // Inserting lines keeps the per-line data aligned.
    document.replace({{20, 0}, {20, 2}}, "a\nb\nc");
    tokens = highlighter.tokens(document.buffer(), 30);
    CHECK(tokens && !tokens->empty() && tokens->front().scopes->name == "keyword.control.test");
    CHECK_EQ(document.buffer().lineCount(), size_t(203));
}

TEST(highlighterStopsAtItsBudget) {
    auto grammar = gw::tm::Grammar::parse(kGrammar, nullptr);
    if (!grammar) return;
    std::string text;
    for (int index = 0; index < 100; ++index) text += "return 1;\n";
    gw::TextBuffer buffer(text);
    gw::Highlighter highlighter(grammar.get());
    CHECK(highlighter.tokens(buffer, 90, 40) == nullptr);
    CHECK_EQ(highlighter.validLines(), size_t(40));
    CHECK(highlighter.tokens(buffer, 90, 100) != nullptr);
}

// MARK: Themes

const char* kTheme = R"json({
  // comments and trailing commas are allowed, as in VS Code
  "name": "Test Theme",
  "type": "dark",
  "colors": { "editor.background": "#1E1E1E", "editor.foreground": "#D4D4D4", },
  "tokenColors": [
    { "scope": "comment", "settings": { "foreground": "#6A9955", "fontStyle": "italic" } },
    { "scope": ["keyword", "storage"], "settings": { "foreground": "#569CD6" } },
    { "scope": "keyword.control", "settings": { "foreground": "#C586C0" } },
    { "scope": "string", "settings": { "foreground": "#CE9178" } },
    { "scope": "meta.embedded string", "settings": { "foreground": "#FF0000" } },
  ],
})json";

TEST(themeResolvesColoursLikeVSCode) {
    std::string error;
    auto theme = gw::Theme::parse(kTheme, true, &error);
    CHECK(theme != nullptr);
    if (!theme) return;
    CHECK_EQ(theme->color("editor.background", 0), gw::Color(0x1E1E1EFF));

    auto comment = theme->styleFor(std::vector<std::string>{"source.cpp", "comment.line.double-slash.cpp"});
    CHECK_EQ(comment.foreground, gw::Color(0x6A9955FF));
    CHECK(comment.italic);

    // "keyword.control" is more specific than "keyword".
    CHECK_EQ(theme->styleFor(std::vector<std::string>{"source.cpp", "keyword.control.return.cpp"}).foreground, gw::Color(0xC586C0FF));
    CHECK_EQ(theme->styleFor(std::vector<std::string>{"source.cpp", "keyword.operator.cpp"}).foreground, gw::Color(0x569CD6FF));
    // A parent selector only applies inside that parent.
    CHECK_EQ(theme->styleFor(std::vector<std::string>{"source.cpp", "string.quoted.cpp"}).foreground, gw::Color(0xCE9178FF));
    CHECK_EQ(theme->styleFor(std::vector<std::string>{"source.md", "meta.embedded.block", "string.quoted"}).foreground, gw::Color(0xFF0000FF));
    // Unmatched scopes fall back to the editor foreground.
    CHECK_EQ(theme->styleFor(std::vector<std::string>{"source.cpp", "variable.other"}).foreground, gw::Color(0xD4D4D4FF));
}

TEST(themeParsesColourFormats) {
    CHECK_EQ(*gw::parseColor("#fff"), gw::Color(0xFFFFFFFF));
    CHECK_EQ(*gw::parseColor("#12345680"), gw::Color(0x12345680));
    CHECK(!gw::parseColor("red").has_value());
}

// MARK: Sections

TEST(sectionsRecogniseMarksPragmasTodosAndFixmes) {
    gw::TextBuffer buffer(
        "#include <vector>\n"
        "// MARK: - Networking\n"
        "int MARK = 1;\n"
        "    // MARK: Helpers\n"
        "#pragma mark - Drawing\n"
        "#pragma mark -\n"
        "  // TODO: handle errors\n"
        "/* FIXME: leaks memory */\n"
        "# MARK: - Python style\n"
        "/* MARK: - Block */\n");
    auto sections = gw::findSections(buffer);
    CHECK_EQ(sections.size(), size_t(8));
    if (sections.size() != 8) return;

    CHECK_EQ(sections[0].line, size_t(1));
    CHECK_EQ(sections[0].title, std::string("Networking"));
    CHECK(sections[0].divider);
    CHECK_EQ(sections[1].title, std::string("Helpers"));
    CHECK(!sections[1].divider);
    CHECK_EQ(sections[2].title, std::string("Drawing"));
    CHECK(sections[2].divider);
    CHECK(sections[3].divider);
    CHECK_EQ(sections[3].title, std::string(""));
    CHECK(sections[4].kind == gw::Section::Kind::Todo);
    CHECK_EQ(sections[4].title, std::string("handle errors"));
    CHECK(sections[5].kind == gw::Section::Kind::Fixme);
    CHECK_EQ(sections[5].title, std::string("leaks memory"));
    CHECK_EQ(sections[6].title, std::string("Python style"));
    CHECK_EQ(sections[7].title, std::string("Block"));  // the closing */ is dropped
    CHECK(sections[7].divider);

    CHECK_EQ(gw::sectionContaining(sections, 0), -1L);
    CHECK_EQ(gw::sectionContaining(sections, 2), 0L);
    CHECK_EQ(gw::sectionContaining(sections, 7), 3L);  // TODOs don't start sections
}

// MARK: Fuzzy matching

TEST(fuzzyMatchesInOrderAndReportsPositions) {
    CHECK(!gw::fuzzyMatch("xyz", "EditorView.mm").has_value());
    auto match = gw::fuzzyMatch("ev", "EditorView.mm");
    CHECK(match.has_value());
    if (match) {
        CHECK_EQ(match->positions.size(), size_t(2));
        CHECK_EQ(match->positions[0], uint32_t(0));
        CHECK_EQ(match->positions[1], uint32_t(6));  // the camelCase "V", not the "e" in "Editor"
    }
}

TEST(fuzzyPrefersWordStartsAndFileNames) {
    auto wordStart = gw::fuzzyMatch("gw", "glass_work.cpp");
    auto midWord = gw::fuzzyMatch("gw", "hogwarts.txt");
    CHECK(wordStart && midWord && wordStart->score > midWord->score);

    std::string inName = "src/app/TabBar.mm";
    std::string inFolder = "tabs/bar/notes.txt";
    auto nameMatch = gw::fuzzyMatch("tabbar", inName, inName.rfind('/') + 1);
    auto folderMatch = gw::fuzzyMatch("tabbar", inFolder, inFolder.rfind('/') + 1);
    CHECK(nameMatch && folderMatch && nameMatch->score > folderMatch->score);
}

TEST(fuzzyScoreAgreesWithFuzzyMatch) {
    const char *paths[] = {
        "src/app/EditorView.mm", "src/core/Fuzzy.cpp", "tests/core_tests.cpp",
        "Platforms/MacOSX.platform/AppKit.framework/NSView.h", "README.md",
    };
    const char *queries[] = {"ev", "fz", "test", "nsview", "appkit", "md", "zzz", ""};
    for (const char *path : paths) {
        std::string candidate = path;
        size_t nameStart = candidate.rfind('/') == std::string::npos ? 0 : candidate.rfind('/') + 1;
        for (const char *query : queries) {
            auto match = gw::fuzzyMatch(query, candidate, nameStart);
            auto score = gw::fuzzyScore(query, candidate, nameStart);
            CHECK(match.has_value() == score.has_value());
            if (match && score) {
                CHECK(match->score == *score);
            }
        }
    }
}

// MARK: Breakpoint lines

TEST(breakpointLinesMoveWithEdits) {
    gw::Document document;
    document.replace({{0, 0}, {0, 0}}, "a\nb\nc\nd\ne");
    document.breakpointLines = {1, 3};
    // A line inserted above moves both down.
    document.replace({{0, 1}, {0, 1}}, "\nnew");
    CHECK(document.breakpointLines == (std::set<size_t>{2, 4}));
    // Removing a line between them moves the later one up and keeps the earlier.
    document.replace({{2, 1}, {3, 1}}, "");   // "b\nc" -> "b" (line 3 merged into line 2)
    CHECK(document.breakpointLines.count(2) == 1);
    CHECK(document.breakpointLines.count(3) == 1);
    // Deleting the line a breakpoint is on drops it.
    document.replace({{2, 1}, {3, 1}}, "");
    CHECK(document.breakpointLines.count(3) == 0);
}

// MARK: Multiple cursors

TEST(extraSelectionsFollowEdits) {
    gw::Document document;
    document.replace({{0, 0}, {0, 0}}, "one\ntwo\nthree");
    // Carets at the end of each line, the primary on the first.
    document.selection = {{0, 3}, {0, 3}};
    document.extraSelections = {{{1, 3}, {1, 3}}, {{2, 5}, {2, 5}}};

    // Typing at the first line moves nothing else sideways (they are on other lines).
    document.replace({{0, 3}, {0, 3}}, "!");
    CHECK(document.extraSelections[0].caret == (gw::Position{1, 3}));
    CHECK(document.extraSelections[1].caret == (gw::Position{2, 5}));

    // A line break above pushes the others down.
    document.replace({{0, 0}, {0, 0}}, "\n");
    CHECK(document.extraSelections[0].caret == (gw::Position{2, 3}));
    CHECK(document.extraSelections[1].caret == (gw::Position{3, 5}));
}

TEST(extraSelectionsOnTheSameLineShift) {
    gw::Document document;
    document.replace({{0, 0}, {0, 0}}, "abcdef");
    document.selection = {{0, 1}, {0, 1}};
    document.extraSelections = {{{0, 4}, {0, 4}}};
    document.replace({{0, 1}, {0, 1}}, "XY");  // two characters go in before the second caret
    CHECK(document.extraSelections[0].caret == (gw::Position{0, 6}));
    document.replace({{0, 0}, {0, 3}}, "");    // and three come out again
    CHECK(document.extraSelections[0].caret == (gw::Position{0, 3}));
}

TEST(undoClearsExtraSelections) {
    gw::Document document;
    document.replace({{0, 0}, {0, 0}}, "text");
    document.extraSelections = {{{0, 1}, {0, 1}}};
    document.undo();
    CHECK(document.extraSelections.empty());
}

// MARK: Expand selection

static bool sameRange(gw::Range range, size_t startLine, size_t startColumn, size_t endLine, size_t endColumn) {
    return range.start == (gw::Position{startLine, startColumn}) && range.end == (gw::Position{endLine, endColumn});
}

TEST(expandSelectionGrowsOutwards) {
    //           0         1         2
    //           0123456789012345678901234567890
    gw::TextBuffer buffer("    call(alpha, beta(gamma));\nnext");
    gw::Range range{{0, 23}, {0, 23}};                 // inside "gamma"
    range = gw::expandedSelection(buffer, range);
    CHECK(sameRange(range, 0, 21, 0, 26));             // gamma
    range = gw::expandedSelection(buffer, range);
    CHECK(sameRange(range, 0, 20, 0, 27));             // (gamma)
    range = gw::expandedSelection(buffer, range);
    CHECK(sameRange(range, 0, 9, 0, 27));              // alpha, beta(gamma)
    range = gw::expandedSelection(buffer, range);
    CHECK(sameRange(range, 0, 8, 0, 28));              // (alpha, beta(gamma))
    range = gw::expandedSelection(buffer, range);
    CHECK(sameRange(range, 0, 4, 0, 29));              // the line without its indent
    range = gw::expandedSelection(buffer, range);
    CHECK(sameRange(range, 0, 0, 0, 29));              // the whole line
    range = gw::expandedSelection(buffer, range);
    CHECK(sameRange(range, 0, 0, 1, 4));               // everything
    range = gw::expandedSelection(buffer, range);
    CHECK(sameRange(range, 0, 0, 1, 4));               // nothing bigger
}

TEST(expandSelectionAcrossLinesAndBracketKinds) {
    gw::TextBuffer buffer("f(a) {\n    if (x[1]) {\n        y;\n    }\n}");
    gw::Range range = gw::expandedSelection(buffer, {{2, 8}, {2, 8}});   // on "y"
    CHECK(sameRange(range, 2, 8, 2, 9));
    range = gw::expandedSelection(buffer, range);                         // the line "y;"
    CHECK(sameRange(range, 2, 8, 2, 10));
    range = gw::expandedSelection(buffer, range);                         // the whole line
    CHECK(sameRange(range, 2, 0, 2, 10));
    range = gw::expandedSelection(buffer, range);                         // inside the inner braces
    CHECK(sameRange(range, 1, 15, 3, 4));
    range = gw::expandedSelection(buffer, range);                         // the braces too
    CHECK(sameRange(range, 1, 14, 3, 5));
}

TEST(expandSelectionIgnoresBracketsThatDoNotPair) {
    gw::TextBuffer buffer("a ) b ( c");
    gw::Range range = gw::expandedSelection(buffer, {{0, 4}, {0, 4}});   // on "b"
    CHECK(sameRange(range, 0, 4, 0, 5));
    range = gw::expandedSelection(buffer, range);                         // no pair: the line
    CHECK(sameRange(range, 0, 0, 0, 9));
}

// MARK: Text transforms

TEST(caseTransforms) {
    CHECK_EQ(gw::upperCaseText("Hello, wörld 9"), std::string("HELLO, WöRLD 9"));
    CHECK_EQ(gw::lowerCaseText("Hello, WORLD"), std::string("hello, world"));
    CHECK_EQ(gw::titleCaseText("the QUICK brown-fox don't"), std::string("The Quick Brown-Fox Don't"));
}

TEST(sortLines) {
    CHECK_EQ(gw::sortLinesText("pear\nApple\napple\nfig\n", false), std::string("Apple\napple\nfig\npear\n"));
    CHECK_EQ(gw::sortLinesText("pear\nApple\nfig", true), std::string("pear\nfig\nApple"));
    CHECK_EQ(gw::sortLinesText("b\nA\na\nB", false, true), std::string("A\na\nb\nB"));  // stable when equal
    CHECK_EQ(gw::sortLinesText("", false), std::string(""));
}

TEST(uniqueLines) {
    CHECK_EQ(gw::uniqueLinesText("a\nb\na\nc\nb\n"), std::string("a\nb\nc\n"));
}

TEST(joinLines) {
    CHECK_EQ(gw::joinLinesText("int a =\n    1 +\n\t2;"), std::string("int a = 1 + 2;"));
    CHECK_EQ(gw::joinLinesText("one\n\ntwo\n"), std::string("one two\n"));
    CHECK_EQ(gw::joinLinesText("single"), std::string("single"));
}

// MARK: Word suggestions

TEST(wordSuggestionsOfferWordsFromTheDocument) {
    gw::TextBuffer buffer("alpha beta alphabet\nAlpine alpha gamma\nal");
    auto words = gw::wordSuggestions(buffer, "al", {2, 2});
    // "alpha" appears twice, so it comes first; the case of a lower-case prefix is ignored.
    CHECK_EQ(words.size(), size_t(3));
    CHECK_EQ(words[0], std::string("alpha"));
    CHECK_EQ(words[1], std::string("Alpine"));
    CHECK_EQ(words[2], std::string("alphabet"));
}

TEST(wordSuggestionsSkipTheWordBeingTypedAndShortWords) {
    gw::TextBuffer buffer("go gone goner\ngon");
    auto words = gw::wordSuggestions(buffer, "gon", {1, 3});
    CHECK_EQ(words.size(), size_t(2));  // "gon" itself is not offered; "go" is too short anyway
    CHECK_EQ(words[0], std::string("gone"));
    CHECK_EQ(words[1], std::string("goner"));
}

TEST(wordSuggestionsWithCapitalPrefixAreCaseSensitive) {
    gw::TextBuffer buffer("Foo foo FooBar\nF");
    auto words = gw::wordSuggestions(buffer, "F", {1, 1});
    CHECK_EQ(words.size(), size_t(2));
    CHECK_EQ(words[0], std::string("Foo"));
    CHECK_EQ(words[1], std::string("FooBar"));
}

TEST(wordSuggestionsOnlyLookNearTheCaret) {
    std::string text;
    for (int line = 0; line < 100; ++line) {
        text += line == 0 ? "faraway\n" : "filler\n";
    }
    text += "fa";
    gw::TextBuffer buffer(text);
    auto near = gw::wordSuggestions(buffer, "fa", {100, 2}, 10, 20);
    CHECK(near.empty());  // line 0 is 100 lines away, outside the radius of 20
    auto all = gw::wordSuggestions(buffer, "fa", {100, 2}, 10, 200);
    CHECK_EQ(all.size(), size_t(1));
}

// MARK: Navigation history

TEST(backAndForwardWalkThroughJumps) {
    gw::NavigationHistory history;
    history.record({"a.cpp", {10, 0}});          // jumped away from a.cpp line 10 ...
    history.record({"b.cpp", {3, 0}});           // ... then from b.cpp line 3
    CHECK(history.canGoBack());
    CHECK(!history.canGoForward());

    auto first = history.back({"c.cpp", {50, 0}});  // now at c.cpp
    CHECK(first.has_value());
    CHECK_EQ(first->path, std::string("b.cpp"));
    CHECK_EQ(first->position.line, size_t(3));
    auto second = history.back({"b.cpp", {3, 0}});
    CHECK_EQ(second->path, std::string("a.cpp"));
    CHECK(!history.back({"a.cpp", {10, 0}}).has_value());  // nowhere further back

    auto again = history.forward({"a.cpp", {10, 0}});
    CHECK_EQ(again->path, std::string("b.cpp"));
    auto last = history.forward({"b.cpp", {3, 0}});
    CHECK_EQ(last->path, std::string("c.cpp"));
    CHECK(!history.forward({"c.cpp", {50, 0}}).has_value());
}

TEST(aNewJumpForgetsForward) {
    gw::NavigationHistory history;
    history.record({"a.cpp", {1, 0}});
    history.back({"b.cpp", {2, 0}});
    CHECK(history.canGoForward());
    history.record({"b.cpp", {2, 0}});
    CHECK(!history.canGoForward());
}

TEST(sameLineIsNotRecordedTwice) {
    gw::NavigationHistory history;
    history.record({"a.cpp", {7, 2}});
    history.record({"a.cpp", {7, 9}});
    auto target = history.back({"a.cpp", {40, 0}});
    CHECK(target.has_value());
    CHECK(!history.back({"a.cpp", {7, 9}}).has_value());  // only one entry was kept
}

TEST(historyKeepsOnlyTheLatestHundred) {
    gw::NavigationHistory history;
    for (size_t line = 0; line < 150; ++line) {
        history.record({"a.cpp", {line, 0}});
    }
    size_t steps = 0;
    gw::NavigationLocation here{"a.cpp", {999, 0}};
    while (auto target = history.back(here)) {
        here = *target;
        ++steps;
    }
    CHECK_EQ(steps, gw::NavigationHistory::kLimit);
}

// MARK: Snippets

TEST(snippetWithPlaceholdersGivesTextAndStops) {
    gw::ParsedSnippet snippet = gw::parseSnippet("foo(${1:a}, ${2:bb})$0");
    CHECK_EQ(snippet.text, std::string("foo(a, bb)"));
    CHECK_EQ(snippet.stops.size(), size_t(3));  // $1, $2, then $0
    CHECK_EQ(snippet.stops[0][0].offset, size_t(4));
    CHECK_EQ(snippet.stops[0][0].length, size_t(1));
    CHECK_EQ(snippet.stops[1][0].offset, size_t(7));
    CHECK_EQ(snippet.stops[1][0].length, size_t(2));
    CHECK_EQ(snippet.stops[2][0].offset, size_t(10));
    CHECK_EQ(snippet.stops[2][0].length, size_t(0));
}

TEST(snippetWithoutFinalStopEndsAtTheEnd) {
    gw::ParsedSnippet snippet = gw::parseSnippet("if ($1) {\n\t$2\n}");
    CHECK_EQ(snippet.stops.size(), size_t(3));
    CHECK_EQ(snippet.stops[2][0].offset, snippet.text.size());  // the implicit final stop
    gw::ParsedSnippet plain = gw::parseSnippet("just text");
    CHECK(plain.hasOnlyFinalStop());
    CHECK(!snippet.hasOnlyFinalStop());
}

TEST(snippetMirrorsShareTheirDefaultText) {
    gw::ParsedSnippet snippet = gw::parseSnippet("for (int ${1:i} = 0; $1 < n; ++$1)");
    CHECK_EQ(snippet.text, std::string("for (int i = 0; i < n; ++i)"));
    CHECK_EQ(snippet.stops[0].size(), size_t(3));  // three places for stop 1
}

TEST(snippetChoicesEscapesAndVariables) {
    gw::ParsedSnippet choice = gw::parseSnippet("${1|public,private|} x");
    CHECK_EQ(choice.text, std::string("public x"));
    gw::ParsedSnippet escaped = gw::parseSnippet("cost: \\$5 \\} $TM_FILENAME ${TM_FILENAME_BASE:fallback}");
    CHECK_EQ(escaped.text, std::string("cost: $5 }  fallback"));
    gw::ParsedSnippet nested = gw::parseSnippet("f(${1:a${2:b}c})");
    CHECK_EQ(nested.text, std::string("f(abc)"));
    CHECK_EQ(nested.stops[0][0].length, size_t(3));
    CHECK_EQ(nested.stops[1][0].length, size_t(1));
}

TEST(snippetIndentsFollowingLines) {
    gw::ParsedSnippet snippet = gw::parseSnippet("a\nb\n$0", "    ");
    CHECK_EQ(snippet.text, std::string("a\n    b\n    "));
    CHECK_EQ(snippet.stops[0][0].offset, snippet.text.size());
}

TEST(tabMovesThroughSnippetPlaceholders) {
    gw::Document document;
    document.replace({{0, 0}, {0, 0}}, "call(x, y);");
    // Pretend "call(x, y)" came from the snippet "call(${1:x}, ${2:y})" starting at column 0.
    gw::ParsedSnippet snippet = gw::parseSnippet("call(${1:x}, ${2:y})");
    document.startSnippet({0, 0}, snippet);
    CHECK(document.snippetActive());
    CHECK(document.selection.range().start == (gw::Position{0, 5}));
    CHECK(document.selection.range().end == (gw::Position{0, 6}));

    document.typeText("first");  // replaces the selected placeholder
    CHECK(document.jumpSnippetStop(+1));
    CHECK(document.selection.range().start == (gw::Position{0, 12}));
    CHECK(document.selection.range().end == (gw::Position{0, 13}));  // "y", moved right by the typing

    CHECK(document.jumpSnippetStop(-1));  // and back to the first one
    CHECK(document.selection.range().start == (gw::Position{0, 5}));
    CHECK(document.selection.range().end == (gw::Position{0, 10}));  // "first"

    CHECK(document.jumpSnippetStop(+1));
    CHECK(document.jumpSnippetStop(+1));  // the final stop, after the closing bracket
    CHECK(document.selection.caret == (gw::Position{0, 14}));
    CHECK(!document.snippetActive());
    CHECK(!document.jumpSnippetStop(+1));  // session over: Tab is an ordinary Tab again
}

TEST(mirroredPlaceholdersGetExtraCursors) {
    gw::Document document;
    gw::ParsedSnippet snippet = gw::parseSnippet("${1:i}+${1:i}");
    document.replace({{0, 0}, {0, 0}}, snippet.text);
    document.startSnippet({0, 0}, snippet);
    CHECK_EQ(document.extraSelections.size(), size_t(1));
    CHECK(document.extraSelections[0].range().start == (gw::Position{0, 2}));
}

TEST(snippetEndsWhenTheCaretLeavesIt) {
    gw::Document document;
    document.replace({{0, 0}, {0, 0}}, "x = f(a);\nlater");
    gw::ParsedSnippet snippet = gw::parseSnippet("f(${1:a})");
    document.startSnippet({0, 4}, snippet);
    document.selection = {{1, 2}, {1, 2}};  // the user clicked somewhere else
    CHECK(!document.jumpSnippetStop(+1));
    CHECK(!document.snippetActive());
}

// MARK: Stylist and settings

TEST(stylistColoursVariablesNamesAndScopes) {
    auto grammar = gw::tm::Grammar::parse(kGrammar, nullptr);
    auto theme = gw::Theme::parse(kTheme, true);
    if (!grammar || !theme) return;
    std::string line = "int value = f(\"value\");";
    auto tokens = gw::tm::tokenizeLine(*grammar, line, gw::tm::initialState(*grammar)).tokens;

    auto styleAt = [](const std::vector<gw::StyledSpan>& spans, uint32_t byte) {
        for (const auto& span : spans) {
            if (byte >= span.start && byte < span.end) return span.style;
        }
        return gw::TextStyle{};
    };

    // Rainbow: the plain identifier gets its name's colour; the string stays a string.
    gw::ColorCustomizations rainbow;
    gw::Stylist rainbowStylist(*theme, rainbow);
    auto spans = rainbowStylist.styleLine(line, tokens);
    CHECK_EQ(styleAt(spans, 4).foreground, gw::Stylist::rainbowColor("value", true));
    CHECK_EQ(styleAt(spans, 15).foreground, gw::Color(0xCE9178FF));  // inside "value"
    CHECK_EQ(gw::Stylist::rainbowColor("value", true), gw::Stylist::rainbowColor("value", true));
    CHECK(gw::Stylist::rainbowColor("value", true) != gw::Stylist::rainbowColor("other", true));

    // A colour set for the name wins over rainbow, and a scope rule adds a highlight.
    gw::ColorCustomizations custom;
    custom.identifiers["value"].foreground = 0x112233FF;
    gw::ScopeStyleRule keywordRule;
    keywordRule.scope = "keyword";
    keywordRule.style.background = 0x33445566;
    keywordRule.style.bold = true;
    custom.scopeRules.push_back(keywordRule);
    gw::Stylist customStylist(*theme, custom);
    spans = customStylist.styleLine(line, tokens);
    CHECK_EQ(styleAt(spans, 4).foreground, gw::Color(0x112233FF));
    CHECK(styleAt(spans, 0).background.has_value());
    CHECK(styleAt(spans, 0).bold);
    CHECK_EQ(styleAt(spans, 0).foreground, gw::Color(0xC586C0FF));  // theme colour kept

    // Spans cover the line without gaps.
    uint32_t cursor = 0;
    for (const auto& span : spans) {
        CHECK_EQ(span.start, cursor);
        cursor = span.end;
    }
    CHECK_EQ(size_t(cursor), line.size());
}

TEST(settingsParseCommentedJsonAndRoundTrip) {
    const char* text = R"json(
    // my settings
    {
      "editor.fontSize": 15,
      "editor.opacity": 0.8,
      "window.glassTint": 0.7,
      "window.frostedBackdrop": true,
      "window.glassStyle": "clear",
      "workbench.colorTheme": "Light+",
      "editor.rainbowVariables": false,
      "files.autoSave": true,
      "files.formatOnSave": true,
      "editor.wordWrap": true,
      "terminal.fontSize": 14,
      "terminal.shell": "/bin/bash",
      "editor.tokenColors": [
        { "scope": "keyword.control", "foreground": "#FF0000", "fontStyle": "bold italic" },
      ],
      "editor.identifierColors": { "total": { "background": "#FFD70033" } },
    })json";
    std::string error;
    gw::EditorSettings settings = gw::parseSettings(text, &error);
    CHECK(error.empty());
    CHECK_EQ(settings.fontSize, 15.0);
    CHECK_EQ(settings.editorOpacity, 0.8);
    CHECK_EQ(settings.glassTint, 0.7);
    CHECK(settings.frostedBackdrop);
    CHECK_EQ(settings.glassStyle, std::string("clear"));
    CHECK_EQ(settings.theme, std::string("Light+"));
    CHECK(settings.autoSave);
    CHECK(settings.formatOnSave);
    CHECK(settings.wordWrap);
    CHECK_EQ(settings.terminalFontSize, 14.0);
    CHECK_EQ(settings.terminalShell, std::string("/bin/bash"));
    CHECK(!settings.colors.rainbowVariables);
    CHECK_EQ(settings.colors.scopeRules.size(), size_t(1));
    CHECK(settings.colors.scopeRules[0].style.italic.value_or(false));
    CHECK_EQ(*settings.colors.identifiers["total"].background, gw::Color(0xFFD70033));

    gw::EditorSettings again = gw::parseSettings(gw::serializeSettings(settings), &error);
    CHECK(error.empty());
    CHECK_EQ(again.fontSize, 15.0);
    CHECK_EQ(again.glassTint, 0.7);
    CHECK(again.frostedBackdrop);
    CHECK_EQ(again.glassStyle, std::string("clear"));
    CHECK_EQ(again.theme, std::string("Light+"));
    CHECK(again.autoSave);
    CHECK(again.formatOnSave);
    CHECK(again.wordWrap);
    CHECK_EQ(again.terminalFontSize, 14.0);
    CHECK_EQ(again.terminalShell, std::string("/bin/bash"));
    CHECK_EQ(again.colors.scopeRules.size(), size_t(1));
    CHECK_EQ(*again.colors.scopeRules[0].style.foreground, gw::Color(0xFF0000FF));
    CHECK_EQ(*again.colors.identifiers["total"].background, gw::Color(0xFFD70033));

    gw::EditorSettings broken = gw::parseSettings("{ not json", &error);
    CHECK(!error.empty());
    CHECK_EQ(broken.fontSize, 13.0);  // defaults

    gw::EditorSettings odd = gw::parseSettings(
        R"({ "window.glassTint": 9, "window.glassStyle": "shiny", "editor.opacity": 0 })", &error);
    CHECK_EQ(odd.glassTint, 1.0);                       // clamped
    CHECK_EQ(odd.glassStyle, std::string("regular"));   // unknown style falls back
    CHECK_EQ(odd.editorOpacity, 0.15);                  // never fully invisible
}

// MARK: Highlighting far into a file

/// Two token lists mean the same if they have the same spans and scopes.
bool sameTokens(const std::vector<gw::tm::Token>* a, const std::vector<gw::tm::Token>* b) {
    if (a == nullptr || b == nullptr) return a == b;
    if (a->size() != b->size()) return false;
    for (size_t index = 0; index < a->size(); ++index) {
        if ((*a)[index].start != (*b)[index].start || (*a)[index].end != (*b)[index].end ||
            (*a)[index].scopes != (*b)[index].scopes) {
            return false;
        }
    }
    return true;
}

std::string testProgram(size_t functions) {
    std::string text;
    for (size_t index = 0; index < functions; ++index) {
        text += "/* function " + std::to_string(index) + "\n   with a comment */\n";
        text += "int f" + std::to_string(index) + "(int a) {\n";
        text += "    int b = g(\"text " + std::to_string(index) + "\");\n";
        text += "    return b;\n";
        text += "}\n\n";
    }
    return text;
}

TEST(highlightingFarIntoAFileMatchesTheExactResult) {
    auto grammar = gw::tm::Grammar::parse(kGrammar, nullptr);
    CHECK(grammar != nullptr);
    if (!grammar) return;
    gw::TextBuffer buffer(testProgram(400));  // about 2800 lines

    gw::Highlighter exact(grammar.get());
    exact.tokens(buffer, buffer.lineCount() - 1, 1000000);  // every line, from the top

    // A fresh highlighter asked for a far line gets an island. It must agree with the exact one.
    gw::Highlighter fast(grammar.get());
    for (size_t line : {2000, 2001, 2030, 2100, 900, 905, 2700}) {
        CHECK(sameTokens(fast.tokens(buffer, line), exact.tokens(buffer, line)));
    }
    CHECK(fast.validLines() < 500);  // it really did skip the top of the file
}

TEST(editingInsideAnIslandStaysCorrect) {
    auto grammar = gw::tm::Grammar::parse(kGrammar, nullptr);
    if (!grammar) return;
    gw::Document document;
    document.replace({{0, 0}, {0, 0}}, testProgram(300));
    gw::Highlighter fast(grammar.get());
    document.onChange = [&fast](const gw::Change& change) { fast.didChange(change); };

    size_t base = 1500;
    fast.tokens(document.buffer(), base + 20);  // an island around line 1500

    // Type inside a line, add a line, delete one, and open a comment that swallows what follows.
    document.replace({{base + 3, 4}, {base + 3, 4}}, "x");
    document.replace({{base + 5, 0}, {base + 5, 0}}, "int extra;\n");
    document.replace({{base + 8, 0}, {base + 9, 0}}, "");
    document.replace({{base + 11, 0}, {base + 11, 0}}, "/* unclosed ");

    // Compare with a highlighter that starts from the top of the edited text.
    gw::Highlighter exact(grammar.get());
    exact.tokens(document.buffer(), document.buffer().lineCount() - 1, 1000000);
    // Only lines above the unclosed comment must agree exactly; below it, the exact result
    // has the comment open while the island (starting after a blank line) may not know.
    for (size_t line = base; line < base + 11; ++line) {
        CHECK(sameTokens(fast.tokens(document.buffer(), line), exact.tokens(document.buffer(), line)));
    }
}

// MARK: Documents on disk

TEST(undoGroupsUndoAndRedoTogether) {
    gw::Document document;
    document.replace({{0, 0}, {0, 0}}, "one two three");
    document.beginUndoGroup();
    document.replace({{0, 0}, {0, 3}}, "1");
    document.replace({{0, 2}, {0, 5}}, "2");
    document.replace({{0, 4}, {0, 9}}, "3");
    document.endUndoGroup();
    CHECK_EQ(document.buffer().line(0), std::string("1 2 3"));

    CHECK(document.undo());  // the whole group at once
    CHECK_EQ(document.buffer().line(0), std::string("one two three"));
    CHECK(document.redo());
    CHECK_EQ(document.buffer().line(0), std::string("1 2 3"));
    CHECK(document.undo());
    CHECK(document.undo());  // then the first edit
    CHECK_EQ(document.buffer().line(0), std::string(""));
}

TEST(readOnlyDocumentsIgnoreEdits) {
    gw::Document document = gw::Document::readOnlyText("one\ntwo\n", "changes.diff");
    CHECK_EQ(document.displayName(), std::string("changes.diff"));
    document.replace({{0, 0}, {0, 3}}, "ONE");
    CHECK_EQ(document.buffer().line(0), std::string("one"));
    CHECK(!document.isDirty());
    CHECK(!document.undo());
}

TEST(reloadFromDiskReplacesOnlyWhatChanged) {
    std::filesystem::path path = std::filesystem::temp_directory_path() / ("glasswork-reload-" + std::to_string(getpid()) + ".txt");
    auto write = [&path](const std::string& text) {
        std::ofstream file(path, std::ios::binary | std::ios::trunc);
        file << text;
    };
    write("alpha\nbeta\ngamma\ndelta\n");
    std::optional<gw::Document> opened = gw::Document::open(path);
    CHECK(opened.has_value());
    gw::Document& document = *opened;
    CHECK(!document.fileChangedOnDisk());

    // Unchanged file: nothing happens.
    CHECK(document.reloadFromDisk() == gw::Document::ReloadResult::Unchanged);

    // Put the caret on the last line, then change a line in the middle on disk.
    document.selection = {{3, 2}, {3, 2}};
    write("alpha\nBETA!\ngamma\ndelta\n");
    CHECK(document.fileChangedOnDisk());
    CHECK(document.reloadFromDisk() == gw::Document::ReloadResult::Reloaded);
    CHECK_EQ(document.buffer().line(1), std::string("BETA!"));
    CHECK_EQ(document.buffer().lineCount(), size_t(5));
    CHECK(!document.isDirty());
    CHECK(!document.fileChangedOnDisk());
    CHECK_EQ(document.selection.caret.line, size_t(3));  // the caret stayed where it was

    // The reload is one undo step.
    CHECK(document.undo());
    CHECK_EQ(document.buffer().line(1), std::string("beta"));
    CHECK(document.isDirty());

    std::filesystem::remove(path);
}

TEST(reloadFromDiskAlwaysEndsWithTheDiskText) {
    std::filesystem::path path = std::filesystem::temp_directory_path() / ("glasswork-reload2-" + std::to_string(getpid()) + ".txt");
    std::mt19937 random(777);
    auto makeText = [&random]() {
        std::string text;
        size_t lines = random() % 7;
        for (size_t line = 0; line < lines; ++line) {
            text += std::string(1, static_cast<char>('a' + random() % 3));
            text += '\n';
        }
        if (random() % 2 == 0 && !text.empty()) {
            text.pop_back();  // sometimes no final newline
        }
        return text;
    };
    for (int round = 0; round < 300; ++round) {
        std::string before = makeText();
        std::string after = makeText();
        {
            std::ofstream file(path, std::ios::binary | std::ios::trunc);
            file << before;
        }
        std::optional<gw::Document> opened = gw::Document::open(path);
        CHECK(opened.has_value());
        {
            std::ofstream file(path, std::ios::binary | std::ios::trunc);
            file << after;
        }
        opened->reloadFromDisk();
        gw::TextBuffer expected(after);
        CHECK_EQ(opened->buffer().text(), expected.text());
    }
    std::filesystem::remove(path);
}


/// What a language server does with an incremental change: find the range by line and UTF-16
/// column in its own copy of the text and splice the new text in.
std::string replaySyncEdits(std::string text, const std::vector<gw::SyncEdit>& edits) {
    auto offsetOf = [](const std::string& source, size_t line, size_t units) {
        size_t offset = 0;
        for (size_t skipped = 0; skipped < line; ++skipped) {
            offset = source.find('\n', offset) + 1;
        }
        size_t counted = 0;
        while (counted < units) {
            unsigned char first = static_cast<unsigned char>(source[offset]);
            size_t width = first >= 0xF0 ? 4 : first >= 0xE0 ? 3 : first >= 0xC0 ? 2 : 1;
            counted += width == 4 ? 2 : 1;
            offset += width;
        }
        return offset;
    };
    for (const gw::SyncEdit& edit : edits) {
        size_t start = offsetOf(text, edit.startLine, edit.startUnits);
        size_t end = offsetOf(text, edit.endLine, edit.endUnits);
        text.replace(start, end - start, edit.text);
    }
    return text;
}

TEST(syncEditsDescribeEditsInUtf16Columns) {
    gw::Document document;
    document.replace({{0, 0}, {0, 0}}, "a\xF0\x9F\x98\x80" "b\xE6\x97\xA5" "c\nsecond line");
    document.recordSyncEdits(true);

    // Insert after the emoji (4 UTF-8 bytes, 2 UTF-16 units) and the CJK character (3 bytes, 1 unit).
    document.replace({{0, 5}, {0, 5}}, "X");
    document.replace({{0, 10}, {0, 10}}, "Y");  // after "a😀Xb日"
    auto edits = document.takeSyncEdits();
    CHECK(edits.has_value());
    CHECK_EQ(edits->size(), size_t(2));
    CHECK_EQ((*edits)[0].startUnits, size_t(3));  // a + emoji (2 units)
    CHECK_EQ((*edits)[0].endUnits, size_t(3));
    CHECK_EQ((*edits)[0].text, std::string("X"));
    CHECK_EQ((*edits)[1].startUnits, size_t(6));  // a(1) + emoji(2) + X(1) + b(1) + CJK(1), measured after the first edit
    // Taking the list empties it.
    CHECK(document.takeSyncEdits()->empty());
}

TEST(syncEditsReplayToTheSameText) {
    gw::Document document;
    document.replace({{0, 0}, {0, 0}}, "one\ntwo \xF0\x9F\x98\x80 emoji\nthree \xE6\x97\xA5\xE6\x9C\xAC\nfour");
    document.recordSyncEdits(true);
    std::string server = document.buffer().text();

    auto sync = [&]() {
        auto edits = document.takeSyncEdits();
        CHECK(edits.has_value());
        server = replaySyncEdits(server, *edits);
        CHECK_EQ(server, document.buffer().text());
    };

    document.replace({{1, 4}, {1, 8}}, "");                       // delete the emoji
    sync();
    document.replace({{0, 1}, {2, 3}}, "-\n-");                    // replace across three lines
    sync();
    document.replace({{0, 0}, {0, 0}}, "\xF0\x9F\x98\x80 start\n");  // insert with a line break at the top
    sync();
    document.beginUndoGroup();
    document.replace({{0, 0}, {0, 2}}, "A");
    document.replace({{1, 0}, {1, 1}}, "BB");
    document.endUndoGroup();
    sync();
    CHECK(document.undo());                                        // undo and redo are edits too
    sync();
    CHECK(document.redo());
    sync();
    CHECK(document.undo());
    CHECK(document.undo());
    sync();
}

TEST(syncEditsSurviveRandomEditing) {
    std::mt19937 random(12345);
    const char* pieces[] = {"x", "hello", "\n", "\xF0\x9F\x98\x80", "\xE6\x97\xA5", " ", "ab\ncd", ""};
    gw::Document document;
    document.replace({{0, 0}, {0, 0}}, "start\nmiddle \xF0\x9F\x98\x80 line\nend");
    document.recordSyncEdits(true);
    std::string server = document.buffer().text();

    for (int round = 0; round < 300; ++round) {
        int edits = 1 + static_cast<int>(random() % 4);
        for (int index = 0; index < edits; ++index) {
            const gw::TextBuffer& buffer = document.buffer();
            size_t line = random() % buffer.lineCount();
            // Pick whole-character boundaries so the text stays valid UTF-8.
            std::string_view text = buffer.line(line);
            std::vector<size_t> boundaries;
            for (size_t byte = 0; byte <= text.size(); ++byte) {
                bool isContinuation = byte < text.size() && (static_cast<unsigned char>(text[byte]) & 0xC0) == 0x80;
                if (!isContinuation) boundaries.push_back(byte);
            }
            size_t startColumn = boundaries[random() % boundaries.size()];
            size_t endColumn = boundaries[random() % boundaries.size()];
            size_t endLine = line;
            if (random() % 5 == 0 && line + 1 < buffer.lineCount()) {
                endLine = line + 1;
                endColumn = 0;
            }
            document.replace({{line, startColumn}, {endLine, endColumn}}, pieces[random() % 8]);
        }
        if (random() % 6 == 0) document.undo();
        if (random() % 9 == 0) document.redo();

        auto list = document.takeSyncEdits();
        CHECK(list.has_value());
        server = replaySyncEdits(server, *list);
        if (server != document.buffer().text()) {
            CHECK_EQ(server, document.buffer().text());
            break;
        }
    }
}

TEST(syncEditsGiveUpWhenTooMuchChanged) {
    gw::Document document;
    document.recordSyncEdits(true);
    for (int index = 0; index < 1200; ++index) {
        document.replace({{0, 0}, {0, 0}}, "x");
    }
    CHECK(!document.takeSyncEdits().has_value());  // caller must send the whole text

    // And it recovers: the next batch is small again.
    document.replace({{0, 0}, {0, 0}}, "y");
    auto small = document.takeSyncEdits();
    CHECK(small.has_value());
    CHECK_EQ(small->size(), size_t(1));

    document.recordSyncEdits(false);
    document.replace({{0, 0}, {0, 0}}, "z");
    CHECK(document.takeSyncEdits()->empty());
}


gw::CompletionCandidate suggestion(const std::string& label, const std::string& sortText = "", int kind = 6) {
    gw::CompletionCandidate candidate;
    candidate.label = label;
    candidate.filterText = label;
    candidate.sortText = sortText.empty() ? label : sortText;
    candidate.kind = kind;
    return candidate;
}

std::vector<std::string> rankedLabels(std::string_view query, const std::vector<gw::CompletionCandidate>& candidates,
                                      const gw::CompletionHistory& history = gw::CompletionHistory()) {
    std::vector<std::string> labels;
    for (size_t index : gw::rankCompletions(query, candidates, history)) {
        labels.push_back(candidates[index].label);
    }
    return labels;
}

TEST(completionRankingPrefersStartsOfNamesAndWordHumps) {
    std::vector<gw::CompletionCandidate> candidates = {suggestion("agwx"), suggestion("glassWork"), suggestion("gwen"),
                                                       suggestion("nothing")};
    auto labels = rankedLabels("gw", candidates);
    CHECK_EQ(labels.size(), size_t(3));  // "nothing" doesn't match
    CHECK_EQ(labels[0], std::string("gwen"));       // starts with it
    CHECK_EQ(labels[1], std::string("glassWork"));  // word starts beat a mid-word hit
    CHECK_EQ(labels[2], std::string("agwx"));
}

TEST(completionRankingFavoursTheCaseTyped) {
    std::vector<gw::CompletionCandidate> candidates = {suggestion("vector"), suggestion("Vector"), suggestion("VECTOR_MAX")};
    CHECK_EQ(rankedLabels("Vec", candidates)[0], std::string("Vector"));
    CHECK_EQ(rankedLabels("vec", candidates)[0], std::string("vector"));
}

TEST(completionRankingUsesRecentChoicesWithoutBeatingBetterMatches) {
    std::vector<gw::CompletionCandidate> candidates = {suggestion("print_all"), suggestion("print_line"), suggestion("sprint")};
    gw::CompletionHistory history;
    history.accepted("print_line", 6);
    auto labels = rankedLabels("pr", candidates, history);
    CHECK_EQ(labels[0], std::string("print_line"));  // same kind of match, but used lately
    CHECK_EQ(labels[1], std::string("print_all"));
    CHECK_EQ(labels[2], std::string("sprint"));

    // A used name that matches worse still doesn't jump over a name that starts with the query.
    gw::CompletionHistory sprintHistory;
    sprintHistory.accepted("sprint", 6);
    CHECK_EQ(rankedLabels("pr", candidates, sprintHistory)[2], std::string("sprint"));
}

TEST(completionRankingDemotesDeprecatedNames) {
    std::vector<gw::CompletionCandidate> candidates = {suggestion("oldName"), suggestion("olderName")};
    candidates[0].deprecated = true;
    CHECK_EQ(rankedLabels("old", candidates)[0], std::string("olderName"));
}

TEST(completionRankingWithNothingTypedFollowsServerHints) {
    std::vector<gw::CompletionCandidate> candidates = {suggestion("zeta", "1"), suggestion("alpha", "2"), suggestion("beta", "3")};
    CHECK_EQ(rankedLabels("", candidates)[0], std::string("zeta"));  // the server's sort text

    candidates[2].preselect = true;
    CHECK_EQ(rankedLabels("", candidates)[0], std::string("beta"));  // its preselected pick wins

    gw::CompletionHistory history;
    history.accepted("alpha", 6);
    candidates[2].preselect = false;
    CHECK_EQ(rankedLabels("", candidates, history)[0], std::string("alpha"));
}

TEST(completionRankingHonoursFilterTextAndLimit) {
    gw::CompletionCandidate item = suggestion("this->value");
    item.filterText = "value";  // typed letters match this, not the label
    CHECK_EQ(rankedLabels("val", {item}).size(), size_t(1));
    CHECK_EQ(rankedLabels("this", {item}).size(), size_t(0));

    std::vector<gw::CompletionCandidate> many;
    for (int index = 0; index < 500; ++index) {
        many.push_back(suggestion("item" + std::to_string(index)));
    }
    CHECK_EQ(gw::rankCompletions("it", many, gw::CompletionHistory(), 50).size(), size_t(50));
}


TEST(openVsxSearchResultsAreParsed) {
    const char* answer = R"json({
      "offset": 0, "totalSize": 2,
      "extensions": [
        {"namespace": "redhat", "name": "vscode-yaml", "displayName": "YAML", "version": "1.25.0",
         "description": "YAML Language Support by Red Hat", "downloadCount": 12345678, "averageRating": 4.5,
         "files": {"icon": "https://open-vsx.org/icon.png", "download": "https://open-vsx.org/x.vsix"}},
        {"namespace": "someone", "name": "tiny", "version": "0.0.1", "downloadCount": 3}
      ]})json";
    auto entries = gw::ExtensionManager::parseSearchResults(answer);
    CHECK_EQ(entries.size(), size_t(2));
    CHECK_EQ(entries[0].id, std::string("redhat.vscode-yaml"));
    CHECK_EQ(entries[0].displayName, std::string("YAML"));
    CHECK_EQ(entries[0].downloads, 12345678L);
    CHECK(entries[0].rating > 4.4 && entries[0].rating < 4.6);
    CHECK_EQ(entries[0].iconURL, std::string("https://open-vsx.org/icon.png"));
    CHECK_EQ(entries[1].id, std::string("someone.tiny"));
    CHECK_EQ(entries[1].displayName, std::string("tiny"));  // no display name: the short name
    CHECK_EQ(entries[1].description, std::string(""));

    CHECK_EQ(gw::ExtensionManager::parseSearchResults("not json").size(), size_t(0));
    CHECK_EQ(gw::ExtensionManager::parseSearchResults("{\"error\": \"nope\"}").size(), size_t(0));
}


TEST(snippetVariablesAreFilledIn) {
    gw::SnippetVariables variables = gw::standardSnippetVariables("/work/app/src/main.cpp", "/work/app");
    CHECK_EQ(variables["TM_FILENAME"], std::string("main.cpp"));
    CHECK_EQ(variables["TM_FILENAME_BASE"], std::string("main"));
    CHECK_EQ(variables["TM_DIRECTORY"], std::string("/work/app/src"));
    CHECK_EQ(variables["RELATIVE_FILEPATH"], std::string("src/main.cpp"));
    CHECK_EQ(variables["WORKSPACE_NAME"], std::string("app"));
    CHECK_EQ(variables["CURRENT_YEAR"].size(), size_t(4));
    CHECK_EQ(variables["UUID"].size(), size_t(36));
    CHECK_EQ(variables["UUID"][14], '4');  // a version 4 UUID

    gw::ParsedSnippet header = gw::parseSnippet("// $TM_FILENAME_BASE ${CURRENT_YEAR}\n#pragma once ${NOPE:fallback} $NOTHING$0", {}, &variables);
    CHECK_EQ(header.text, std::string("// main ") + variables["CURRENT_YEAR"] + "\n#pragma once fallback ");

    // A known variable beats its default; without a table, variables give their default or nothing.
    CHECK_EQ(gw::parseSnippet("${TM_FILENAME:x}", {}, &variables).text, std::string("main.cpp"));
    CHECK_EQ(gw::parseSnippet("${TM_FILENAME:x}").text, std::string("x"));
}

TEST(snippetFilesAreReadLikeVsCodeDoes) {
    const char* file = R"json({
      // comments and trailing commas are allowed
      "For Loop": {"prefix": ["for", "fori"], "body": ["for (int ${1:i} = 0; ${1:i} < ${2:n}; ++${1:i}) {", "\t$0", "}"], "description": "A for loop",},
      "Log": {"prefix": "log", "body": "console.log($1);", "scope": "javascript, typescript"},
      "No prefix": {"body": "x"},
      "No body": {"prefix": "nb"}
    })json";
    auto definitions = gw::parseSnippetFile(file);
    CHECK_EQ(definitions.size(), size_t(3));  // for, fori and log
    CHECK_EQ(definitions[0].prefix, std::string("for"));
    CHECK_EQ(definitions[1].prefix, std::string("fori"));
    CHECK_EQ(definitions[0].body, std::string("for (int ${1:i} = 0; ${1:i} < ${2:n}; ++${1:i}) {\n\t$0\n}"));
    CHECK_EQ(definitions[0].description, std::string("A for loop"));
    CHECK_EQ(definitions[2].scopes.size(), size_t(2));
    CHECK_EQ(definitions[2].description, std::string("Log"));  // no description: the name

    CHECK_EQ(gw::parseSnippetFile("garbage").size(), size_t(0));
}

TEST(snippetLibraryPicksSnippetsForALanguage) {
    std::filesystem::path folder = std::filesystem::temp_directory_path() / ("gw-snippets-" + std::to_string(getpid()));
    std::filesystem::create_directories(folder);
    {
        std::ofstream(folder / "cpp.json") << R"json({"Main": {"prefix": "main", "body": "int main() {}"}})json";
        std::ofstream(folder / "global.code-snippets") << R"json({
          "Todo": {"prefix": "todo", "body": "// TODO: $0"},
          "Log": {"prefix": "log", "body": "console.log($0)", "scope": "javascript"}})json";
    }
    gw::SnippetLibrary library;
    library.addSource("cpp", folder / "cpp.json");
    library.addSource("", folder / "global.code-snippets");

    auto prefixes = [&](const std::string& language) {
        std::vector<std::string> names;
        for (const auto& definition : library.forLanguage(language)) names.push_back(definition.prefix);
        return names;
    };
    CHECK_EQ(prefixes("cpp").size(), size_t(2));         // main + todo
    CHECK_EQ(prefixes("javascript").size(), size_t(2));  // todo + log
    CHECK_EQ(prefixes("python").size(), size_t(1));      // todo only
    CHECK_EQ(prefixes("python")[0], std::string("todo"));
    std::filesystem::remove_all(folder);
}


TEST(extensionManifestsContributeSnippets) {
    namespace fs = std::filesystem;
    fs::path folder = fs::temp_directory_path() / ("gw-ext-snippets-" + std::to_string(getpid()));
    fs::path extension = folder / "extensions" / "demo.snips-1.0.0";
    fs::create_directories(extension / "snippets");
    fs::create_directories(folder / "user-snippets");
    std::ofstream(extension / "package.json") << R"json({
      "name": "snips", "publisher": "demo", "version": "1.0.0",
      "contributes": {"snippets": [{"language": "fake", "path": "./snippets/fake.json"}]}})json";
    std::ofstream(extension / "snippets" / "fake.json") << R"json({"Greet": {"prefix": "greet", "body": ["hello ${1:name}", "$0"]}})json";
    std::ofstream(folder / "user-snippets" / "fake.json") << R"json({"Mine": {"prefix": "mine", "body": "mine"}})json";

    gw::ExtensionManager manager(folder / "extensions");
    manager.setUserSnippetsDirectory(folder / "user-snippets");
    manager.scan();
    auto fake = manager.snippets().forLanguage("fake");
    CHECK_EQ(fake.size(), size_t(2));  // the extension's, then the user's
    CHECK_EQ(fake[0].prefix, std::string("greet"));
    CHECK_EQ(fake[0].body, std::string("hello ${1:name}\n$0"));
    CHECK_EQ(fake[1].prefix, std::string("mine"));
    CHECK_EQ(manager.snippets().forLanguage("cpp").size(), size_t(0));

    manager.scan();  // scanning again doesn't double the list
    CHECK_EQ(manager.snippets().forLanguage("fake").size(), size_t(2));
    fs::remove_all(folder);
}


TEST(settingsAreFoundWhetherWrittenFlatOrNested) {
    nlohmann::json settings = nlohmann::json::parse(R"json({
      "editor.fontSize": 14,
      "python": {"analysis": {"typeCheckingMode": "strict", "extraPaths": ["a"]}},
      "rust-analyzer.check.command": "clippy",
      "rust-analyzer.cargo": {"features": "all"}
    })json");
    CHECK_EQ(gw::settingsSection(settings, "editor.fontSize").get<int>(), 14);                 // flat
    CHECK_EQ(gw::settingsSection(settings, "python.analysis.typeCheckingMode").get<std::string>(), std::string("strict"));  // nested
    CHECK_EQ(gw::settingsSection(settings, "python.analysis")["extraPaths"][0].get<std::string>(), std::string("a"));        // a section
    CHECK_EQ(gw::settingsSection(settings, "python")["analysis"]["typeCheckingMode"].get<std::string>(), std::string("strict"));
    // A section of flat keys becomes one object; flat and nested mix in one section.
    nlohmann::json analyzer = gw::settingsSection(settings, "rust-analyzer");
    CHECK_EQ(analyzer["check.command"].get<std::string>(), std::string("clippy"));
    CHECK_EQ(analyzer["cargo"]["features"].get<std::string>(), std::string("all"));
    CHECK_EQ(gw::settingsSection(settings, "rust-analyzer.cargo.features").get<std::string>(), std::string("all"));
    CHECK(gw::settingsSection(settings, "nothing.here").is_null());
    CHECK(gw::settingsSection(settings, "python.nothing").is_null());
    CHECK(gw::settingsSection(nlohmann::json(), "a").is_null());
}


TEST(globsMatchPathsTheWayEditorsExpect) {
    CHECK(gw::GlobPattern("**/*.cpp").matches("src/core/a.cpp"));
    CHECK(gw::GlobPattern("**/*.cpp").matches("a.cpp"));            // "**/" may be nothing
    CHECK(!gw::GlobPattern("**/*.cpp").matches("src/a.hpp"));
    CHECK(gw::GlobPattern("*.cpp").matches("src/deep/a.cpp"));      // no slash: the name anywhere
    CHECK(!gw::GlobPattern("src/*.cpp").matches("src/deep/a.cpp")); // * stays in one segment
    CHECK(gw::GlobPattern("src/**").matches("src/deep/a.cpp"));
    CHECK(gw::GlobPattern("**/*.{cpp,h,hpp}").matches("x/y/z.hpp"));
    CHECK(!gw::GlobPattern("**/*.{cpp,h,hpp}").matches("x/y/z.py"));
    CHECK(gw::GlobPattern("**/Cargo.toml").matches("Cargo.toml"));
    CHECK(gw::GlobPattern("**/Cargo.toml").matches("crates/a/Cargo.toml"));
    CHECK(gw::GlobPattern("file?.txt").matches("file1.txt"));
    CHECK(!gw::GlobPattern("file?.txt").matches("file12.txt"));
    CHECK(gw::GlobPattern("[ab]*.c").matches("alpha.c"));
    CHECK(!gw::GlobPattern("[!ab]*.c").matches("alpha.c"));
    CHECK(gw::GlobPattern("a.b+c").matches("a.b+c"));               // regex characters are literal
    CHECK(!gw::GlobPattern("a.b").matches("axb"));
    CHECK(!gw::GlobPattern("[unclosed").matches("x"));
}


TEST(keyChordsAreParsedLikeVsCodeWritesThem) {
    auto one = gw::parseKeyChords("cmd+shift+P");
    CHECK(one.has_value());
    CHECK_EQ((*one)[0].key, std::string("p"));
    CHECK((*one)[0].command && (*one)[0].shift && !(*one)[0].control && !(*one)[0].option);

    auto sequence = gw::parseKeyChords("cmd+k cmd+s");
    CHECK_EQ(sequence->size(), size_t(2));
    CHECK_EQ((*sequence)[1].key, std::string("s"));

    auto modifiers = gw::parseKeyChords("ctrl+alt+Win+Return");
    CHECK((*modifiers)[0].control && (*modifiers)[0].option && (*modifiers)[0].command);
    CHECK_EQ((*modifiers)[0].key, std::string("enter"));      // aliases are normalised
    CHECK_EQ((*gw::parseKeyChords("esc"))[0].key, std::string("escape"));
    CHECK_EQ((*gw::parseKeyChords("cmd+/"))[0].key, std::string("/"));
    CHECK_EQ((*gw::parseKeyChords("cmd++"))[0].key, std::string("+"));
    CHECK_EQ((*gw::parseKeyChords("f12"))[0].key, std::string("f12"));

    CHECK(!gw::parseKeyChords("").has_value());
    CHECK(!gw::parseKeyChords("hyper+x").has_value());        // not a modifier
}

TEST(whenClausesAreEvaluatedAgainstTheContext) {
    std::map<std::string, std::string> context = {
        {"editorTextFocus", "true"}, {"editorLangId", "cpp"}, {"resourceExtname", ".cpp"},
        {"terminalFocus", "false"}, {"editorHasSelection", ""},
    };
    auto when = [&](const std::string& clause) { return gw::evaluateWhenClause(clause, context); };
    CHECK(when(""));
    CHECK(when("editorTextFocus"));
    CHECK(!when("terminalFocus"));                              // "false" is false
    CHECK(!when("editorHasSelection"));                         // empty is false
    CHECK(!when("neverHeardOf"));
    CHECK(when("!terminalFocus"));
    CHECK(when("editorTextFocus && editorLangId == 'cpp'"));
    CHECK(!when("editorTextFocus && editorLangId == 'python'"));
    CHECK(when("editorLangId == python || editorLangId == cpp"));
    CHECK(when("editorLangId != 'python'"));
    CHECK(when("!(terminalFocus || editorHasSelection)"));
    CHECK(when("resourceExtname =~ /\\.(cpp|hpp)$/"));
    CHECK(!when("resourceExtname =~ /\\.py$/"));
    CHECK(when("editorTextFocus && !terminalFocus && editorLangId == cpp"));
    CHECK(!when("(("));                                         // nonsense never hangs and never matches
}

TEST(keybindingTableMatchesChordsAndSequences) {
    nlohmann::json fromExtension = nlohmann::json::parse(R"json([
      {"command": "ext.shout", "key": "ctrl+shift+u", "mac": "cmd+shift+u", "when": "editorTextFocus"},
      {"command": "ext.settings", "key": "cmd+k cmd+s"},
      {"command": "ext.cppOnly", "key": "cmd+j", "when": "editorLangId == cpp"},
      {"command": "ext.old", "key": "cmd+9"}
    ])json");
    nlohmann::json fromUser = nlohmann::json::parse(R"json([
      {"command": "user.shout", "key": "cmd+shift+u", "args": {"loud": true}},
      {"command": "-ext.old", "key": "cmd+9"},
      {"command": "ext.old", "key": "cmd+8"}
    ])json");
    gw::KeybindingTable table;
    table.add(fromExtension, false);
    table.add(fromUser, true);

    std::map<std::string, std::string> editor = {{"editorTextFocus", "true"}, {"editorLangId", "cpp"}};
    std::map<std::string, std::string> terminal = {{"terminalFocus", "true"}};
    auto press = [&](const std::string& keys, const std::map<std::string, std::string>& context) {
        return table.match(*gw::parseKeyChords(keys), context);
    };

    // The mac key is used, and the user's binding of the same keys wins.
    auto shout = press("cmd+shift+u", editor);
    CHECK(shout.kind == gw::KeybindingTable::MatchKind::Complete);
    CHECK_EQ(shout.binding->command, std::string("user.shout"));
    CHECK(shout.binding->arguments["loud"].get<bool>());

    // A sequence: the first chord is a prefix, the second completes it.
    CHECK(press("cmd+k", editor).kind == gw::KeybindingTable::MatchKind::Prefix);
    auto settings = press("cmd+k cmd+s", editor);
    CHECK(settings.kind == gw::KeybindingTable::MatchKind::Complete);
    CHECK_EQ(settings.binding->command, std::string("ext.settings"));
    CHECK(press("cmd+k cmd+x", editor).kind == gw::KeybindingTable::MatchKind::None);

    // `when` decides; the same keys do nothing where the clause fails.
    CHECK(press("cmd+j", editor).kind == gw::KeybindingTable::MatchKind::Complete);
    CHECK(press("cmd+j", terminal).kind == gw::KeybindingTable::MatchKind::None);

    // The user took cmd+9 away from the extension's command and gave it cmd+8.
    CHECK(press("cmd+9", editor).kind == gw::KeybindingTable::MatchKind::None);
    CHECK_EQ(press("cmd+8", editor).binding->command, std::string("ext.old"));
    CHECK(press("cmd+q", editor).kind == gw::KeybindingTable::MatchKind::None);
}


TEST(cssColorsAreReadAsExtensionsWriteThem) {
    CHECK_EQ(*gw::parseCssColor("#ff0000"), uint32_t(0xFF0000FF));
    CHECK_EQ(*gw::parseCssColor("#FF000080"), uint32_t(0xFF000080));
    CHECK_EQ(*gw::parseCssColor("#f80"), uint32_t(0xFF8800FF));        // shorthand doubles each digit
    CHECK_EQ(*gw::parseCssColor("#f808"), uint32_t(0xFF880088));
    CHECK_EQ(*gw::parseCssColor("rgb(255, 128, 0)"), uint32_t(0xFF8000FF));
    CHECK_EQ(*gw::parseCssColor("rgba(255, 0, 0, 0.5)"), uint32_t(0xFF000080));
    CHECK_EQ(*gw::parseCssColor("  RGBA(0 0 255 / 100%)  "), uint32_t(0x0000FFFF));
    CHECK_EQ(*gw::parseCssColor("hsl(0, 100%, 50%)"), uint32_t(0xFF0000FF));
    CHECK_EQ(*gw::parseCssColor("hsl(120, 100%, 50%)"), uint32_t(0x00FF00FF));
    CHECK_EQ(*gw::parseCssColor("hsla(240, 100%, 50%, 0.5)"), uint32_t(0x0000FF80));
    CHECK_EQ(*gw::parseCssColor("Orange"), uint32_t(0xFFA500FF));
    CHECK_EQ(*gw::parseCssColor("transparent"), uint32_t(0));
    CHECK(!gw::parseCssColor("").has_value());
    CHECK(!gw::parseCssColor("#12").has_value());
    CHECK(!gw::parseCssColor("#gg0000").has_value());
    CHECK(!gw::parseCssColor("rgb(1, 2)").has_value());
    CHECK(!gw::parseCssColor("notacolour").has_value());
}


TEST(iconThemesChooseTheMostSpecificIcon) {
    namespace fs = std::filesystem;
    fs::path folder = fs::temp_directory_path() / ("gw-icons-" + std::to_string(getpid()));
    fs::create_directories(folder / "dist");
    std::ofstream(folder / "dist" / "theme.json") << R"json({
      "iconDefinitions": {
        "file": {"iconPath": "./../icons/file.svg"}, "js": {"iconPath": "./../icons/js.svg"},
        "test": {"iconPath": "./../icons/test.svg"}, "npm": {"iconPath": "./../icons/npm.svg"},
        "py": {"iconPath": "./../icons/py.svg"}, "folder": {"iconPath": "./../icons/folder.svg"},
        "folderOpen": {"iconPath": "./../icons/folder-open.svg"}, "src": {"iconPath": "./../icons/src.svg"},
        "jsLight": {"iconPath": "./../icons/js-light.svg"}, "font": {"fontCharacter": "\\E001"}
      },
      "file": "file", "folder": "folder", "folderExpanded": "folderOpen",
      "fileExtensions": {"js": "js", "test.js": "test"},
      "fileNames": {"package.json": "npm"},
      "languageIds": {"python": "py"},
      "folderNames": {"src": "src"},
      "light": {"fileExtensions": {"js": "jsLight"}},
      "hidesExplorerArrows": true
    })json";
    auto theme = gw::IconTheme::load(folder / "dist" / "theme.json");
    CHECK(theme.has_value());
    auto name = [&](const fs::path& icon) { return icon.filename().string(); };

    CHECK_EQ(name(theme->iconForFile("main.js", "", false)), std::string("js.svg"));
    CHECK_EQ(name(theme->iconForFile("MAIN.JS", "", false)), std::string("js.svg"));              // case does not matter
    CHECK_EQ(name(theme->iconForFile("a.test.js", "", false)), std::string("test.svg"));          // the longest extension wins
    CHECK_EQ(name(theme->iconForFile("package.json", "", false)), std::string("npm.svg"));        // an exact name beats the extension
    CHECK_EQ(name(theme->iconForFile("script", "python", false)), std::string("py.svg"));         // by language when nothing else matches
    CHECK_EQ(name(theme->iconForFile("notes.xyz", "plaintext", false)), std::string("file.svg")); // the default
    CHECK_EQ(name(theme->iconForFile("main.js", "", true)), std::string("js-light.svg"));         // the light section overrides
    CHECK_EQ(name(theme->iconForFile("a.test.js", "", true)), std::string("test.svg"));           // and falls back to the dark tables
    CHECK((folder / "icons" / "js.svg").lexically_normal() == theme->iconForFile("main.js", "", false));  // paths are relative to the theme file

    CHECK_EQ(name(theme->iconForFolder("src", false, false, false)), std::string("src.svg"));
    CHECK_EQ(name(theme->iconForFolder("docs", false, false, false)), std::string("folder.svg"));
    CHECK_EQ(name(theme->iconForFolder("docs", true, false, false)), std::string("folder-open.svg"));
    CHECK_EQ(name(theme->iconForFolder("project", true, true, false)), std::string("folder-open.svg"));  // no root icon: the folder's
    CHECK(theme->hidesExplorerArrows());

    CHECK(!gw::IconTheme::load(folder / "missing.json").has_value());
    fs::remove_all(folder);
}


TEST(disabledExtensionsAreListedButContributeNothing) {
    namespace fs = std::filesystem;
    fs::path folder = fs::temp_directory_path() / ("gw-ext-disabled-" + std::to_string(getpid()));
    for (const char* name : {"keep", "mute"}) {
        fs::path extension = folder / "extensions" / (std::string("demo.") + name + "-1.0.0");
        fs::create_directories(extension / "snippets");
        std::ofstream(extension / "package.json") << R"json({"name": ")json" << name << R"json(", "publisher": "demo", "version": "1.0.0",
          "main": "./x.js",
          "contributes": {"snippets": [{"language": "fake", "path": "./snippets/s.json"}],
                          "keybindings": [{"command": ")json" << name << R"json(.run", "key": "cmd+j"}]}})json";
        std::ofstream(extension / "snippets" / "s.json") << R"json({"S": {"prefix": ")json" << name << R"json(", "body": "x"}})json";
    }
    gw::ExtensionManager manager(folder / "extensions");
    manager.setDisabled({"demo.mute"});
    manager.scan();
    CHECK_EQ(manager.extensions().size(), size_t(1));
    CHECK_EQ(manager.extensions()[0].id, std::string("demo.keep"));
    CHECK_EQ(manager.disabledExtensions().size(), size_t(1));
    CHECK_EQ(manager.disabledExtensions()[0].id, std::string("demo.mute"));
    auto snippets = manager.snippets().forLanguage("fake");
    CHECK_EQ(snippets.size(), size_t(1));                       // only the enabled extension's
    CHECK_EQ(snippets[0].prefix, std::string("keep"));
    CHECK(manager.contributedKeybindingsJson().find("mute.run") == std::string::npos);
    CHECK(manager.contributedKeybindingsJson().find("keep.run") != std::string::npos);

    manager.setDisabled({});                                    // switch it back on
    manager.scan();
    CHECK_EQ(manager.extensions().size(), size_t(2));
    CHECK_EQ(manager.disabledExtensions().size(), size_t(0));
    fs::remove_all(folder);
}

}  // namespace

int main() {
    for (const auto& [name, body] : tests()) {
        int before = failures;
        body();
        std::printf("%s %s\n", failures == before ? "ok  " : "FAIL", name);
    }
    std::printf("\n%d checks, %d failed\n", checks, failures);
    return failures == 0 ? 0 : 1;
}
