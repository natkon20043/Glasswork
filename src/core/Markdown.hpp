#pragma once

#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace gw::markdown {

// Inline markers in the text (**, *, `, ~~, [](url)) -> bit flags OR-ed into Span::style (bold + italic combine).
enum SpanStyle : uint8_t {
    kPlain = 0,
    kBold = 1,
    kItalic = 2,
    kCode = 4,
    kStrike = 8,
    kLink = 16,
};

struct Span {
    std::string text;
    uint8_t style = kPlain;
    /// Links only.
    std::string url;
};

using Spans = std::vector<Span>;

struct Block {
    // Markdown line syntax -> which kind of block it becomes.
    enum class Kind {
        Paragraph,
        Heading,
        ListItem,
        Quote,
        CodeBlock,
        Rule,
        Table,
    };

    Kind kind = Kind::Paragraph;

    /// Paragraph, Heading, ListItem and Quote text.
    Spans spans;

    /// Heading: 1..6. ListItem: nesting depth from 0.
    int level = 0;

    /// ListItem: numbered items keep the number they were written with.
    bool ordered = false;
    int number = 0;

    /// CodeBlock: `closed` is false while the closing fence hasn't arrived (a streaming reply).
    std::string language;
    std::string code;
    bool closed = true;

    /// Table: the first row is the header when `hasHeader` is set.
    std::vector<std::vector<Spans>> rows;
    bool hasHeader = false;
    /// Per column: 'l', 'c' or 'r'.
    std::string alignments;
};

// ---- Parsing

/// Chat-style Markdown. Never fails: invalid or half-streamed constructs come out as plain text.
std::vector<Block> parse(std::string_view text);

/// Inline formatting only, no blocks.
Spans parseInline(std::string_view text);

std::string plainText(const Spans& spans);

}  // namespace gw::markdown
