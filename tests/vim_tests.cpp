// Tests for Vim mode: keys go in, the text and the caret come out.

#include "TestHarness.hpp"

#include "Vim.hpp"

#include <string>

namespace {

/// A document and an engine, driven by typing. Keys are single characters except where a test
/// uses "<Esc>", "<C-r>" or "<CR>".
struct Session {
    gw::Document document;
    gw::VimEngine engine;

    explicit Session(const std::string& text, gw::Position caret = {0, 0}) {
        document.replace({{0, 0}, {0, 0}}, text);
        document.selection = {caret, caret};
    }

    /// In insert mode the editor does the typing; here that is a plain insertion.
    void type(const std::string& keys) {
        for (size_t at = 0; at < keys.size();) {
            std::string key;
            if (keys.compare(at, 5, "<Esc>") == 0) {
                key = "\x1b";
                at += 5;
            } else if (keys.compare(at, 5, "<C-r>") == 0) {
                key = "\x12";
                at += 5;
            } else if (keys.compare(at, 4, "<CR>") == 0) {
                key = "\r";
                at += 4;
            } else {
                key = std::string(1, keys[at]);
                ++at;
            }
            if (!engine.handleKey(document, key)) {
                document.typeText(key == "\r" ? "\n" : key);
            }
        }
    }

    std::string text() const { return document.buffer().text(); }
    gw::Position caret() const { return document.selection.caret; }
};

TEST(movesWithHjklAndCounts) {
    Session session("abc\ndef\nghi");
    session.type("l");
    CHECK_EQ(session.caret().column, size_t(1));
    session.type("j");
    CHECK_EQ(session.caret().line, size_t(1));
    CHECK_EQ(session.caret().column, size_t(1));
    session.type("2l");
    CHECK_EQ(session.caret().column, size_t(2));  // stops on the last character
    session.type("k");
    CHECK_EQ(session.caret().line, size_t(0));
    session.type("G");
    CHECK_EQ(session.caret().line, size_t(2));
    session.type("gg");
    CHECK_EQ(session.caret().line, size_t(0));
}

TEST(remembersTheColumnMovingDown) {
    Session session("abcdef\nab\nabcdef");
    session.type("4l");
    session.type("j");
    CHECK_EQ(session.caret().column, size_t(1));  // the short line
    session.type("j");
    CHECK_EQ(session.caret().column, size_t(4));  // back to the wanted column
}

TEST(wordMotions) {
    Session session("foo bar.baz  qux");
    session.type("w");
    CHECK_EQ(session.caret().column, size_t(4));
    session.type("w");
    CHECK_EQ(session.caret().column, size_t(7));  // the "." is a word of its own
    session.type("w");
    CHECK_EQ(session.caret().column, size_t(8));
    session.type("e");
    CHECK_EQ(session.caret().column, size_t(10));
    session.type("b");
    CHECK_EQ(session.caret().column, size_t(8));
    session.type("0");
    CHECK_EQ(session.caret().column, size_t(0));
    session.type("W");
    CHECK_EQ(session.caret().column, size_t(4));
    session.type("W");
    CHECK_EQ(session.caret().column, size_t(13));
    session.type("$");
    CHECK_EQ(session.caret().column, size_t(15));
}

TEST(findsCharactersInALine) {
    Session session("a,b,c,d");
    session.type("f,");
    CHECK_EQ(session.caret().column, size_t(1));
    session.type(";");
    CHECK_EQ(session.caret().column, size_t(3));
    session.type(",");
    CHECK_EQ(session.caret().column, size_t(1));
    session.type("0t,");
    CHECK_EQ(session.caret().column, size_t(0));
    session.type("2t,");
    CHECK_EQ(session.caret().column, size_t(2));
}

TEST(deletesWithOperatorsAndMotions) {
    Session session("one two three");
    session.type("dw");
    CHECK_EQ(session.text(), std::string("two three"));
    session.type("de");
    CHECK_EQ(session.text(), std::string(" three"));
    session.type("D");
    CHECK_EQ(session.text(), std::string(""));
}

TEST(deleteWordAtTheEndOfALineStaysOnTheLine) {
    Session session("one two\nthree", {0, 4});
    session.type("dw");
    CHECK_EQ(session.text(), std::string("one \nthree"));
}

TEST(deletesLines) {
    Session session("a\nb\nc\nd\ne", {1, 0});
    session.type("dd");
    CHECK_EQ(session.text(), std::string("a\nc\nd\ne"));
    session.type("2dd");
    CHECK_EQ(session.text(), std::string("a\ne"));
    session.type("kdj");
    CHECK_EQ(session.text(), std::string(""));
}

TEST(deletesTheLastLine) {
    Session session("a\nb", {1, 0});
    session.type("dd");
    CHECK_EQ(session.text(), std::string("a"));
    CHECK_EQ(session.caret().line, size_t(0));
}

TEST(deletesCharacters) {
    Session session("abcdef", {0, 2});
    session.type("x");
    CHECK_EQ(session.text(), std::string("abdef"));
    session.type("2x");
    CHECK_EQ(session.text(), std::string("abf"));
    session.type("X");
    CHECK_EQ(session.text(), std::string("af"));
}

TEST(changesAndTypesInsertMode) {
    Session session("hello world");
    session.type("cwbye<Esc>");
    CHECK_EQ(session.text(), std::string("bye world"));
    CHECK(session.engine.mode() == gw::VimMode::Normal);
    session.type("wC");
    CHECK(session.engine.mode() == gw::VimMode::Insert);
    session.type("there<Esc>");
    CHECK_EQ(session.text(), std::string("bye there"));
}

TEST(cwKeepsTheBlanksAfterTheWord) {
    Session session("foo   bar");
    session.type("cwx<Esc>");
    CHECK_EQ(session.text(), std::string("x   bar"));
}

TEST(changesALineKeepingItsIndent) {
    Session session("    old text\nnext");
    session.type("ccnew<Esc>");
    CHECK_EQ(session.text(), std::string("    new\nnext"));
}

TEST(insertCommandsPlaceTheCaret) {
    Session session("  abc");
    session.type("Ix<Esc>");
    CHECK_EQ(session.text(), std::string("  xabc"));
    session.type("Ay<Esc>");
    CHECK_EQ(session.text(), std::string("  xabcy"));
    session.type("0ia<Esc>");
    CHECK_EQ(session.text(), std::string("a  xabcy"));
    session.type("$az<Esc>");
    CHECK_EQ(session.text(), std::string("a  xabcyz"));
}

TEST(escapeMovesTheCaretBack) {
    Session session("abc");
    session.type("Ax<Esc>");
    CHECK_EQ(session.caret().column, size_t(3));  // on the x, not after it
}

TEST(opensLines) {
    Session session("  one\ntwo");
    session.type("onew<Esc>");
    CHECK_EQ(session.text(), std::string("  one\n  new\ntwo"));
    session.type("Oabove<Esc>");
    CHECK_EQ(session.text(), std::string("  one\n  above\n  new\ntwo"));
}

TEST(yanksAndPastes) {
    Session session("one two");
    session.type("yw");
    CHECK_EQ(session.text(), std::string("one two"));
    session.type("$p");
    CHECK_EQ(session.text(), std::string("one twoone "));
    Session lines("a\nb\nc");
    lines.type("yyjp");
    CHECK_EQ(lines.text(), std::string("a\nb\na\nc"));
    lines.type("P");
    CHECK_EQ(lines.text(), std::string("a\nb\na\na\nc"));
    lines.type("gg3dd");
    CHECK_EQ(lines.text(), std::string("a\nc"));
}

TEST(pastesLinesAtTheEnd) {
    Session session("a\nb", {1, 0});
    session.type("yyp");
    CHECK_EQ(session.text(), std::string("a\nb\nb"));
    CHECK_EQ(session.caret().line, size_t(2));
}

TEST(deleteFillsTheRegisterSoPasteMovesText) {
    Session session("ab cd");
    session.type("dwP");
    CHECK_EQ(session.text(), std::string("ab cd"));
    session.type("0xp");
    CHECK_EQ(session.text(), std::string("ba cd"));
}

TEST(undoesAndRedoes) {
    Session session("one two");
    session.type("dwx");
    CHECK_EQ(session.text(), std::string("wo"));
    session.type("u");
    CHECK_EQ(session.text(), std::string("two"));
    session.type("u");
    CHECK_EQ(session.text(), std::string("one two"));
    session.type("<C-r>");
    CHECK_EQ(session.text(), std::string("two"));
}

TEST(oneUndoTakesBackAWholeInsert) {
    Session session("hello world");
    session.type("cwbye<Esc>");
    CHECK_EQ(session.text(), std::string("bye world"));
    session.type("u");
    CHECK_EQ(session.text(), std::string("hello world"));
    session.type("ofirst<CR>second<Esc>");
    CHECK_EQ(session.text(), std::string("hello world\nfirst\nsecond"));
    session.type("u");
    CHECK_EQ(session.text(), std::string("hello world"));
}

TEST(repeatsWithDot) {
    Session session("a b c d");
    session.type("dw.");
    CHECK_EQ(session.text(), std::string("c d"));
    Session insert("x\ny\nz");
    insert.type("Aend<Esc>j.");
    CHECK_EQ(insert.text(), std::string("xend\nyend\nz"));
    Session change("foo bar baz");
    change.type("cwone<Esc>w.");
    CHECK_EQ(change.text(), std::string("one one baz"));
    Session lines("1\n2\n3\n4");
    lines.type("dd.");
    CHECK_EQ(lines.text(), std::string("3\n4"));
}

TEST(repeatedInsertWithACount) {
    Session session("");
    session.type("3ia<Esc>");
    CHECK_EQ(session.text(), std::string("aaa"));
}

TEST(replacesAndTogglesCase) {
    Session session("abc");
    session.type("rx");
    CHECK_EQ(session.text(), std::string("xbc"));
    session.type("~");
    CHECK_EQ(session.text(), std::string("Xbc"));
    CHECK_EQ(session.caret().column, size_t(1));
    session.type("0");
    session.type("3~");
    CHECK_EQ(session.text(), std::string("xBC"));
}

TEST(joinsLines) {
    Session session("one\n   two\nthree");
    session.type("J");
    CHECK_EQ(session.text(), std::string("one two\nthree"));
    session.type("J");
    CHECK_EQ(session.text(), std::string("one two three"));
}

TEST(textObjects) {
    Session session("call(foo, bar) + \"quoted text\"", {0, 6});
    session.type("di(");
    CHECK_EQ(session.text(), std::string("call() + \"quoted text\""));
    Session quoted("x = \"hello world\";", {0, 8});
    quoted.type("ci\"bye<Esc>");
    CHECK_EQ(quoted.text(), std::string("x = \"bye\";"));
    Session word("alpha beta gamma", {0, 7});
    word.type("diw");
    CHECK_EQ(word.text(), std::string("alpha  gamma"));
    Session around("alpha beta gamma", {0, 7});
    around.type("daw");
    CHECK_EQ(around.text(), std::string("alpha gamma"));
}

TEST(bracketObjectsSpanLines) {
    Session session("if (x) {\n    one;\n    two;\n}", {1, 5});
    session.type("di{");
    CHECK_EQ(session.text(), std::string("if (x) {\n}"));
}

TEST(matchesBrackets) {
    Session session("f(a, (b), c)");
    session.type("f(");
    session.type("%");
    CHECK_EQ(session.caret().column, size_t(11));
    session.type("%");
    CHECK_EQ(session.caret().column, size_t(1));
}

TEST(paragraphMotions) {
    Session session("a\nb\n\nc\nd");
    session.type("}");
    CHECK_EQ(session.caret().line, size_t(2));
    session.type("}");
    CHECK_EQ(session.caret().line, size_t(4));
    session.type("{");
    CHECK_EQ(session.caret().line, size_t(2));
}

TEST(visualModeDeletesAndYanks) {
    Session session("abcdef", {0, 1});
    session.type("vlld");
    CHECK_EQ(session.text(), std::string("aef"));
    CHECK(session.engine.mode() == gw::VimMode::Normal);
    Session yank("abcdef");
    yank.type("vly$p");
    CHECK_EQ(yank.text(), std::string("abcdefab"));
}

TEST(visualModeSelectsBackwardsAndInclusively) {
    Session session("abcdef", {0, 3});
    session.type("vhd");
    CHECK_EQ(session.text(), std::string("abef"));
}

TEST(visualLineMode) {
    Session session("a\nb\nc\nd");
    session.type("Vjd");
    CHECK_EQ(session.text(), std::string("c\nd"));
    session.type("Vy");
    session.type("jp");
    CHECK_EQ(session.text(), std::string("c\nd\nc"));
}

TEST(visualTextObjects) {
    Session session("say \"hi there\" now", {0, 6});
    session.type("vi\"d");
    CHECK_EQ(session.text(), std::string("say \"\" now"));
}

TEST(visualReplace) {
    Session session("one two");
    session.type("yiwwviwp");
    CHECK_EQ(session.text(), std::string("one one"));
    session.type("0P");
    CHECK_EQ(session.text(), std::string("twoone one"));
}

TEST(shiftsLines) {
    Session session("a\nb\nc");
    session.engine.indentUnit = "  ";
    session.type(">>");
    CHECK_EQ(session.text(), std::string("  a\nb\nc"));
    session.type("2>>");
    CHECK_EQ(session.text(), std::string("    a\n  b\nc"));
    session.type("<<");
    CHECK_EQ(session.text(), std::string("  a\n  b\nc"));
}

TEST(escapeCancelsAPendingCommand) {
    Session session("abc");
    session.type("d");
    CHECK_EQ(session.engine.pending(), std::string("d"));
    session.type("<Esc>");
    CHECK_EQ(session.engine.pending(), std::string(""));
    session.type("x");
    CHECK_EQ(session.text(), std::string("bc"));
}

TEST(aFailedMotionCancelsTheOperator) {
    Session session("abc");
    session.type("dh");
    CHECK_EQ(session.text(), std::string("abc"));
    session.type("dk");
    CHECK_EQ(session.text(), std::string("abc"));
}

TEST(handlesMultiByteCharacters) {
    Session session("h\xC3\xA9llo w\xC3\xB6rld");
    session.type("l");
    CHECK_EQ(session.caret().column, size_t(1));
    session.type("l");
    CHECK_EQ(session.caret().column, size_t(3));  // past the two-byte character
    session.type("x");
    CHECK_EQ(session.text(), std::string("h\xC3\xA9lo w\xC3\xB6rld"));
    session.type("$x");
    CHECK_EQ(session.text(), std::string("h\xC3\xA9lo w\xC3\xB6rl"));
    session.type("0xx");
    CHECK_EQ(session.text(), std::string("lo w\xC3\xB6rl"));
}

TEST(emptyDocumentsAndLinesAreSafe) {
    Session session("");
    session.type("xddpPJjkhlwbe$0GgguoX<Esc>");
    CHECK(session.document.buffer().lineCount() >= 1);
    Session lines("\n\n");
    lines.type("wwbbdwddyyp}{");
    CHECK(lines.document.buffer().lineCount() >= 1);
}

TEST(mouseSelectionBecomesVisualMode) {
    Session session("abcdef");
    session.document.selection = {{0, 1}, {0, 4}};
    session.type("d");
    CHECK_EQ(session.text(), std::string("aef"));
}

TEST(startsInsertAtPastedClipboardText) {
    Session session("abc");
    std::string clipboard = "from elsewhere";
    session.engine.readClipboard = [&] { return clipboard; };
    session.engine.writeClipboard = [&](const std::string& text) { clipboard = text; };
    session.type("p");
    CHECK_EQ(session.text(), std::string("afrom elsewherebc"));
    session.type("0yl$p");
    CHECK_EQ(clipboard, std::string("a"));
}

}  // namespace

int main() {
    return harness::runAllTests();
}
