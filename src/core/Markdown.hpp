#pragma once

#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace gw::markdown {

/// How a run of text is styled. Values combine (bold + italic).
enum SpanStyle : uint8_t {
    kPlain = 0,
    kBold = 1,
    kItalic = 2,
    kCode = 4,
    kStrike = 8,
    kLink = 16,
};

/// A run of text with one style. Links carry their address.
struct Span {
    std::string text;
    uint8_t style = kPlain;
    std::string url;
};

using Spans = std::vector<Span>;

struct Block {
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

    /// Heading: 1…6. ListItem: nesting depth starting at 0.
    int level = 0;

    /// ListItem: numbered lists carry the number the item was written with.
    bool ordered = false;
    int number = 0;

    /// CodeBlock: the language written after the opening fence (may be empty), the code,
    /// and whether the closing fence has arrived yet (false while a reply is streaming).
    std::string language;
    std::string code;
    bool closed = true;

    /// Table: rows of cells; the first row is the header when `hasHeader` is set.
    std::vector<std::vector<Spans>> rows;
    bool hasHeader = false;
    /// Per column: 'l', 'c' or 'r'.
    std::string alignments;
};

/// Reads Markdown as chat replies use it: headings, paragraphs, bullet and numbered lists,
/// block quotes, fenced code, tables, rules, and bold / italic / `code` / ~~strike~~ /
/// [links](url) inside text. Never fails: text that isn't valid Markdown, or that stops in
/// the middle of a construct (as streaming text does), comes out as plain text.
std::vector<Block> parse(std::string_view text);

/// Reads inline formatting only (no blocks).
Spans parseInline(std::string_view text);

/// The text of spans without any formatting.
std::string plainText(const Spans& spans);

}  // namespace gw::markdown
