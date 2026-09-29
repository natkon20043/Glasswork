// Tests for the Markdown reader that draws Claude's replies.

#include "TestHarness.hpp"

#include "Markdown.hpp"

namespace {

using gw::markdown::Block;
using gw::markdown::Spans;

/// Describes spans as text for easy comparing: plain text as is, **bold**, *italic*,
/// `code`, ~strike~, and [link](url).
std::string describe(const Spans& spans) {
    std::string text;
    for (const gw::markdown::Span& span : spans) {
        std::string piece = span.text;
        if (span.style & gw::markdown::kCode) {
            piece = "`" + piece + "`";
        }
        if (span.style & gw::markdown::kItalic) {
            piece = "*" + piece + "*";
        }
        if (span.style & gw::markdown::kBold) {
            piece = "**" + piece + "**";
        }
        if (span.style & gw::markdown::kStrike) {
            piece = "~" + piece + "~";
        }
        if (span.style & gw::markdown::kLink) {
            piece = "[" + piece + "](" + span.url + ")";
        }
        text += piece;
    }
    return text;
}

TEST(inlineFormattingIsRecognised) {
    CHECK_EQ(describe(gw::markdown::parseInline("plain text")), std::string("plain text"));
    CHECK_EQ(describe(gw::markdown::parseInline("a **bold** word")), std::string("a **bold** word"));
    CHECK_EQ(describe(gw::markdown::parseInline("an *italic* word")), std::string("an *italic* word"));
    CHECK_EQ(describe(gw::markdown::parseInline("an _italic_ word")), std::string("an *italic* word"));
    CHECK_EQ(describe(gw::markdown::parseInline("use `std::vector` here")), std::string("use `std::vector` here"));
    CHECK_EQ(describe(gw::markdown::parseInline("~~gone~~")), std::string("~gone~"));
    CHECK_EQ(describe(gw::markdown::parseInline("***both***")), std::string("***both***"));
    CHECK_EQ(describe(gw::markdown::parseInline("**bold with `code` inside**")), std::string("**bold with ****`code`**** inside**"));
}

TEST(inlineFormattingLeavesLookAlikesAlone) {
    CHECK_EQ(gw::markdown::plainText(gw::markdown::parseInline("2 * 3 * 4")), std::string("2 * 3 * 4"));
    CHECK_EQ(gw::markdown::plainText(gw::markdown::parseInline("snake_case_name stays")), std::string("snake_case_name stays"));
    CHECK_EQ(gw::markdown::plainText(gw::markdown::parseInline("a ** b")), std::string("a ** b"));
    CHECK_EQ(describe(gw::markdown::parseInline("**never closed")), std::string("**never closed"));
    CHECK_EQ(describe(gw::markdown::parseInline("`open code")), std::string("`open code"));
    CHECK_EQ(gw::markdown::plainText(gw::markdown::parseInline("a \\*star\\* and \\`tick\\`")), std::string("a *star* and `tick`"));
    // Formatting characters inside code are not formatting.
    CHECK_EQ(describe(gw::markdown::parseInline("`a*b*c` and *real*")), std::string("`a*b*c` and *real*"));
}

TEST(linksAreRecognised) {
    CHECK_EQ(describe(gw::markdown::parseInline("see [the docs](https://example.com/a) now")),
             std::string("see [the docs](https://example.com/a) now"));
    CHECK_EQ(describe(gw::markdown::parseInline("[**bold link**](http://x.io)")), std::string("[**bold link**](http://x.io)"));
    CHECK_EQ(describe(gw::markdown::parseInline("visit https://github.com/a/b.")), std::string("visit [https://github.com/a/b](https://github.com/a/b)."));
    CHECK_EQ(gw::markdown::plainText(gw::markdown::parseInline("[not a link] (really)")), std::string("[not a link] (really)"));
    CHECK_EQ(describe(gw::markdown::parseInline("(see https://x.org/p(1))")), std::string("(see [https://x.org/p(1)](https://x.org/p(1)))"));
}

TEST(headingsAndParagraphs) {
    std::vector<Block> blocks = gw::markdown::parse("# Title\n\nFirst line\ncontinues here.\n\n## Sub ##\nText");
    CHECK_EQ(blocks.size(), size_t(4));
    CHECK(blocks[0].kind == Block::Kind::Heading && blocks[0].level == 1);
    CHECK_EQ(describe(blocks[0].spans), std::string("Title"));
    CHECK(blocks[1].kind == Block::Kind::Paragraph);
    CHECK_EQ(describe(blocks[1].spans), std::string("First line continues here."));
    CHECK(blocks[2].kind == Block::Kind::Heading && blocks[2].level == 2);
    CHECK_EQ(describe(blocks[2].spans), std::string("Sub"));
    CHECK(blocks[3].kind == Block::Kind::Paragraph);

    // "#hashtag" is not a heading.
    std::vector<Block> hashtag = gw::markdown::parse("#hashtag");
    CHECK(hashtag[0].kind == Block::Kind::Paragraph);
}

TEST(listsKeepNestingAndNumbers) {
    std::vector<Block> blocks = gw::markdown::parse(
        "Steps:\n\n1. First\n2. Second\n   - nested a\n   - nested b\n3. Third\n\n- bullet **one**\n* bullet two\n+ bullet three");
    // paragraph, 3 numbered, 2 nested, then 3 bullets → the nested ones sit between 2 and 3.
    std::vector<Block> items;
    for (const Block& block : blocks) {
        if (block.kind == Block::Kind::ListItem) {
            items.push_back(block);
        }
    }
    CHECK_EQ(items.size(), size_t(8));
    CHECK(items[0].ordered && items[0].number == 1 && items[0].level == 0);
    CHECK(items[1].ordered && items[1].number == 2);
    CHECK(!items[2].ordered && items[2].level == 1);
    CHECK_EQ(describe(items[2].spans), std::string("nested a"));
    CHECK(items[3].level == 1);
    CHECK(items[4].ordered && items[4].number == 3 && items[4].level == 0);
    CHECK(!items[5].ordered && items[5].level == 0);
    CHECK_EQ(describe(items[5].spans), std::string("bullet **one**"));
}

TEST(listItemsContinueOnFollowingLines) {
    std::vector<Block> blocks = gw::markdown::parse("- one\n  wraps here\n- two");
    CHECK_EQ(blocks.size(), size_t(2));
    CHECK_EQ(describe(blocks[0].spans), std::string("one wraps here"));
}

TEST(codeBlocksKeepTheirTextAndLanguage) {
    std::vector<Block> blocks = gw::markdown::parse("Here:\n\n```cpp\nint main() {\n    return 0;\n}\n```\n\nDone.");
    CHECK_EQ(blocks.size(), size_t(3));
    CHECK(blocks[1].kind == Block::Kind::CodeBlock);
    CHECK_EQ(blocks[1].language, std::string("cpp"));
    CHECK_EQ(blocks[1].code, std::string("int main() {\n    return 0;\n}"));
    CHECK(blocks[1].closed);

    // Markdown inside code is left alone.
    std::vector<Block> stars = gw::markdown::parse("```\n**not bold** # not a heading\n```");
    CHECK_EQ(stars[0].code, std::string("**not bold** # not a heading"));

    // Tilde fences and longer fences.
    std::vector<Block> tilde = gw::markdown::parse("~~~python\nx = 1\n~~~");
    CHECK_EQ(tilde[0].language, std::string("python"));
    std::vector<Block> longer = gw::markdown::parse("````md\n```\ninner\n```\n````");
    CHECK_EQ(longer[0].code, std::string("```\ninner\n```"));
}

TEST(unfinishedCodeBlocksAreOpenWhileStreaming) {
    std::vector<Block> blocks = gw::markdown::parse("```swift\nlet x = 1\nlet y");
    CHECK_EQ(blocks.size(), size_t(1));
    CHECK(!blocks[0].closed);
    CHECK_EQ(blocks[0].code, std::string("let x = 1\nlet y"));
}

TEST(indentedCodeInsideListsLosesItsIndent) {
    std::vector<Block> blocks = gw::markdown::parse("1. Do this:\n\n   ```sh\n   make all\n   ```\n");
    bool found = false;
    for (const Block& block : blocks) {
        if (block.kind == Block::Kind::CodeBlock) {
            found = true;
            CHECK_EQ(block.code, std::string("make all"));
        }
    }
    CHECK(found);
}

TEST(quotesRulesAndTables) {
    std::vector<Block> quote = gw::markdown::parse("> quoted **text**\n> more\n>\n> second");
    CHECK_EQ(quote.size(), size_t(2));
    CHECK(quote[0].kind == Block::Kind::Quote);
    CHECK_EQ(describe(quote[0].spans), std::string("quoted **text** more"));

    std::vector<Block> rule = gw::markdown::parse("above\n\n---\n\nbelow");
    CHECK_EQ(rule.size(), size_t(3));
    CHECK(rule[1].kind == Block::Kind::Rule);

    std::vector<Block> table = gw::markdown::parse("| Name | Score |\n|:-----|------:|\n| Ann | **9** |\n| Bob | 7 |\n\nAfter");
    CHECK_EQ(table.size(), size_t(2));
    CHECK(table[0].kind == Block::Kind::Table);
    CHECK(table[0].hasHeader);
    CHECK_EQ(table[0].rows.size(), size_t(3));
    CHECK_EQ(table[0].alignments, std::string("lr"));
    CHECK_EQ(describe(table[0].rows[1][1]), std::string("**9**"));
    CHECK_EQ(describe(table[0].rows[2][0]), std::string("Bob"));
}

TEST(hardLineBreaksAreKept) {
    std::vector<Block> blocks = gw::markdown::parse("line one  \nline two\\\nline three");
    CHECK_EQ(blocks.size(), size_t(1));
    CHECK_EQ(gw::markdown::plainText(blocks[0].spans), std::string("line one\nline two\nline three"));
}

TEST(everyPrefixOfARealReplyParsesWithoutTrouble) {
    // Streaming shows a reply as it grows, so every prefix must be safe to read.
    const std::string reply =
        "# Plan\n\nI'll **update** `main.cpp` and *then* [check](https://example.com) it.\n\n"
        "1. Read the file\n2. Edit `foo()`:\n   ```cpp\n   int foo() { return 1; }\n   ```\n"
        "- done ~~maybe~~\n\n> note: careful\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n---\nEnd with 2 * 3 and snake_case.";
    size_t blocksSeen = 0;
    for (size_t length = 0; length <= reply.size(); ++length) {
        std::vector<Block> blocks = gw::markdown::parse(std::string_view(reply).substr(0, length));
        blocksSeen += blocks.size();
    }
    CHECK(blocksSeen > 0);
}

TEST(randomTextNeverBreaksTheReader) {
    const std::string alphabet = "ab *_`~[]()#>-|\\\n 12.:!";
    unsigned seed = 424242;
    auto next = [&seed]() {
        seed = seed * 1664525u + 1013904223u;
        return seed >> 8;
    };
    for (int round = 0; round < 3000; ++round) {
        std::string text;
        size_t length = next() % 60;
        for (size_t index = 0; index < length; ++index) {
            text += alphabet[next() % alphabet.size()];
        }
        std::vector<Block> blocks = gw::markdown::parse(text);
        (void)blocks;
    }
    CHECK(true);
}

}  // namespace

int main() {
    return harness::runAllTests();
}
