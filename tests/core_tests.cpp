// Unit tests for Glasswork's core. A tiny harness keeps the build dependency-free.

#include "Document.hpp"
#include "EditorSettings.hpp"
#include "Fuzzy.hpp"
#include "NavigationHistory.hpp"
#include "Sections.hpp"
#include "Snippet.hpp"
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
