#include "Markdown.hpp"

#include <algorithm>
#include <cctype>

namespace gw::markdown {

namespace {

// ---------------------------------------------------------------------------
// Character helpers

bool isSpace(char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

bool isAlphanumeric(char c) {
    return std::isalnum(static_cast<unsigned char>(c)) != 0 || static_cast<unsigned char>(c) >= 0x80;
}

bool isPunctuation(char c) {
    return std::ispunct(static_cast<unsigned char>(c)) != 0;
}

std::string_view trimmed(std::string_view text) {
    size_t start = 0;
    while (start < text.size() && isSpace(text[start])) {
        ++start;
    }
    size_t end = text.size();
    while (end > start && isSpace(text[end - 1])) {
        --end;
    }
    return text.substr(start, end - start);
}

// ---------------------------------------------------------------------------
// Inline formatting

/// Adds `text` to the last span if it is styled the same, otherwise starts a new span.
void appendText(Spans& spans, const std::string& text, uint8_t style, const std::string& url) {
    if (text.empty()) {
        return;
    }
    if (!spans.empty() && spans.back().style == style && spans.back().url == url) {
        spans.back().text += text;
        return;
    }
    Span span;
    span.text = text;
    span.style = style;
    span.url = url;
    spans.push_back(std::move(span));
}

size_t countRun(std::string_view text, size_t position, char c) {
    size_t end = position;
    while (end < text.size() && text[end] == c) {
        ++end;
    }
    return end - position;
}

/// The position just past the code span that starts at `position` (a run of backticks), or
/// npos if the span is never closed. `contentStart` and `contentEnd` get the text between.
size_t findCodeSpanEnd(std::string_view text, size_t position, size_t& contentStart, size_t& contentEnd) {
    size_t ticks = countRun(text, position, '`');
    size_t search = position + ticks;
    while (search < text.size()) {
        size_t next = text.find('`', search);
        if (next == std::string_view::npos) {
            return std::string_view::npos;
        }
        size_t run = countRun(text, next, '`');
        if (run == ticks) {
            contentStart = position + ticks;
            contentEnd = next;
            return next + run;
        }
        search = next + run;
    }
    return std::string_view::npos;
}

/// Finds where the emphasis that opened at `openEnd` closes: a run of exactly `length`
/// delimiter characters, right after a non-space. Code spans and escapes are skipped.
/// Returns npos when there is no closing run.
size_t findClosingRun(std::string_view text, size_t openEnd, char delimiter, size_t length) {
    size_t index = openEnd;
    while (index < text.size()) {
        char c = text[index];
        if (c == '\\' && index + 1 < text.size()) {
            index += 2;
            continue;
        }
        if (c == '`') {
            size_t contentStart = 0;
            size_t contentEnd = 0;
            size_t end = findCodeSpanEnd(text, index, contentStart, contentEnd);
            index = end == std::string_view::npos ? index + countRun(text, index, '`') : end;
            continue;
        }
        if (c != delimiter) {
            ++index;
            continue;
        }
        size_t run = countRun(text, index, delimiter);
        bool afterContent = index > openEnd && !isSpace(text[index - 1]);
        bool rightLength = run == length;
        bool wordEnds = true;
        if (delimiter == '_') {
            // An underscore inside a word (snake_case) does not close emphasis.
            wordEnds = index + run >= text.size() || !isAlphanumeric(text[index + run]);
        }
        if (afterContent && rightLength && wordEnds) {
            return index;
        }
        index += run;
    }
    return std::string_view::npos;
}

/// Reads "[label](address)" starting at `position` (which holds "["). On success gives the
/// label and address and the position after the closing parenthesis.
bool readLink(std::string_view text, size_t position, std::string_view& label, std::string& url, size_t& end) {
    int depth = 0;
    size_t close = std::string_view::npos;
    for (size_t index = position; index < text.size(); ++index) {
        if (text[index] == '\\') {
            ++index;
            continue;
        }
        if (text[index] == '[') {
            ++depth;
        } else if (text[index] == ']') {
            --depth;
            if (depth == 0) {
                close = index;
                break;
            }
        }
    }
    if (close == std::string_view::npos || close + 1 >= text.size() || text[close + 1] != '(') {
        return false;
    }
    int parentheses = 0;
    size_t closeParenthesis = std::string_view::npos;
    for (size_t index = close + 1; index < text.size(); ++index) {
        if (text[index] == '(') {
            ++parentheses;
        } else if (text[index] == ')') {
            --parentheses;
            if (parentheses == 0) {
                closeParenthesis = index;
                break;
            }
        }
    }
    if (closeParenthesis == std::string_view::npos) {
        return false;
    }
    std::string_view target = trimmed(text.substr(close + 2, closeParenthesis - close - 2));
    // A title after the address ("url \"title\"") is dropped.
    size_t space = target.find(' ');
    if (space != std::string_view::npos) {
        target = target.substr(0, space);
    }
    if (!target.empty() && target.front() == '<' && target.back() == '>') {
        target = target.substr(1, target.size() - 2);
    }
    if (target.empty()) {
        return false;
    }
    label = text.substr(position + 1, close - position - 1);
    url = std::string(target);
    end = closeParenthesis + 1;
    return true;
}

bool startsWith(std::string_view text, size_t position, std::string_view prefix) {
    return text.size() - position >= prefix.size() && text.compare(position, prefix.size(), prefix) == 0;
}

Spans parseStyled(std::string_view text, uint8_t inherited, const std::string& inheritedUrl);

/// Appends the spans of `inner` (already styled) to `out`.
void appendSpans(Spans& out, const Spans& inner) {
    for (const Span& span : inner) {
        appendText(out, span.text, span.style, span.url);
    }
}

Spans parseStyled(std::string_view text, uint8_t inherited, const std::string& inheritedUrl) {
    Spans out;
    std::string plain;
    auto flush = [&]() {
        appendText(out, plain, inherited, inheritedUrl);
        plain.clear();
    };

    size_t index = 0;
    while (index < text.size()) {
        char c = text[index];

        // Backslash escapes: \* \_ \` and so on.
        if (c == '\\' && index + 1 < text.size() && isPunctuation(text[index + 1])) {
            plain += text[index + 1];
            index += 2;
            continue;
        }

        // Code.
        if (c == '`') {
            size_t contentStart = 0;
            size_t contentEnd = 0;
            size_t end = findCodeSpanEnd(text, index, contentStart, contentEnd);
            if (end != std::string_view::npos) {
                flush();
                std::string code(text.substr(contentStart, contentEnd - contentStart));
                if (code.size() >= 2 && code.front() == ' ' && code.back() == ' ') {
                    code = code.substr(1, code.size() - 2);
                }
                appendText(out, code, static_cast<uint8_t>(inherited | kCode), inheritedUrl);
                index = end;
                continue;
            }
            size_t ticks = countRun(text, index, '`');
            plain.append(ticks, '`');
            index += ticks;
            continue;
        }

        // Bold, italic and strike-through.
        if (c == '*' || c == '_' || c == '~') {
            size_t run = countRun(text, index, c);
            size_t length = std::min<size_t>(run, 3);
            bool validLength = c == '~' ? run == 2 : run <= 3;
            bool nextIsContent = index + run < text.size() && !isSpace(text[index + run]);
            bool startsWord = true;
            if (c == '_') {
                startsWord = index == 0 || !isAlphanumeric(text[index - 1]);
            }
            if (validLength && nextIsContent && startsWord) {
                size_t close = findClosingRun(text, index + run, c, length);
                if (close != std::string_view::npos) {
                    uint8_t style = inherited;
                    if (c == '~') {
                        style |= kStrike;
                    } else if (length == 1) {
                        style |= kItalic;
                    } else if (length == 2) {
                        style |= kBold;
                    } else {
                        style |= kBold | kItalic;
                    }
                    flush();
                    appendSpans(out, parseStyled(text.substr(index + length, close - index - length), style, inheritedUrl));
                    index = close + length;
                    continue;
                }
            }
            plain.append(run, c);
            index += run;
            continue;
        }

        // Links.
        if (c == '[') {
            std::string_view label;
            std::string url;
            size_t end = 0;
            if (readLink(text, index, label, url, end)) {
                flush();
                appendSpans(out, parseStyled(label, static_cast<uint8_t>(inherited | kLink), url));
                index = end;
                continue;
            }
        }

        // Bare web addresses.
        bool atWordStart = index == 0 || isSpace(text[index - 1]) || text[index - 1] == '(' || text[index - 1] == '<';
        if (c == 'h' && atWordStart && (startsWith(text, index, "https://") || startsWith(text, index, "http://"))) {
            size_t end = index;
            while (end < text.size() && !isSpace(text[end]) && text[end] != '<' && text[end] != '>' && text[end] != '"') {
                ++end;
            }
            // Trailing punctuation belongs to the sentence, not the address.
            while (end > index && std::string_view(".,;:!?)'").find(text[end - 1]) != std::string_view::npos) {
                bool unbalancedParenthesis = text[end - 1] == ')' &&
                                             std::count(text.begin() + static_cast<long>(index), text.begin() + static_cast<long>(end), '(') >=
                                                 std::count(text.begin() + static_cast<long>(index), text.begin() + static_cast<long>(end), ')');
                if (text[end - 1] == ')' && unbalancedParenthesis) {
                    break;
                }
                --end;
            }
            if (end > index + 8) {
                flush();
                std::string address(text.substr(index, end - index));
                appendText(out, address, static_cast<uint8_t>(inherited | kLink), address);
                index = end;
                continue;
            }
        }

        plain += c;
        ++index;
    }
    flush();
    return out;
}

// ---------------------------------------------------------------------------
// Blocks

std::string_view leftTrimmed(std::string_view text) {
    size_t start = 0;
    while (start < text.size() && (text[start] == ' ' || text[start] == '\t')) {
        ++start;
    }
    return text.substr(start);
}

std::vector<std::string_view> splitIntoLines(std::string_view text) {
    std::vector<std::string_view> lines;
    size_t start = 0;
    while (start <= text.size()) {
        size_t end = text.find('\n', start);
        if (end == std::string_view::npos) {
            end = text.size();
        }
        size_t lineEnd = end;
        if (lineEnd > start && text[lineEnd - 1] == '\r') {
            --lineEnd;
        }
        lines.push_back(text.substr(start, lineEnd - start));
        if (end == text.size()) {
            break;
        }
        start = end + 1;
    }
    return lines;
}

size_t leadingSpaces(std::string_view line) {
    size_t columns = 0;
    for (char c : line) {
        if (c == ' ') {
            ++columns;
        } else if (c == '\t') {
            columns += 4;
        } else {
            break;
        }
    }
    return columns;
}

bool isBlank(std::string_view line) {
    return trimmed(line).empty();
}

/// An opening code fence: three or more backticks or tildes, then optionally a language.
bool readFenceStart(std::string_view line, char& fenceCharacter, size_t& fenceLength, std::string& language, size_t& indent) {
    indent = leadingSpaces(line);
    std::string_view rest = trimmed(line);
    if (rest.size() < 3 || (rest[0] != '`' && rest[0] != '~')) {
        return false;
    }
    size_t run = countRun(rest, 0, rest[0]);
    if (run < 3) {
        return false;
    }
    std::string_view info = trimmed(rest.substr(run));
    if (rest[0] == '`' && info.find('`') != std::string_view::npos) {
        return false;  // "```code```" on one line is inline code
    }
    fenceCharacter = rest[0];
    fenceLength = run;
    size_t space = info.find(' ');
    language = std::string(space == std::string_view::npos ? info : info.substr(0, space));
    return true;
}

bool isFenceEnd(std::string_view line, char fenceCharacter, size_t fenceLength) {
    std::string_view rest = trimmed(line);
    if (rest.size() < fenceLength) {
        return false;
    }
    return countRun(rest, 0, fenceCharacter) >= fenceLength && countRun(rest, 0, fenceCharacter) == rest.size();
}

bool isRule(std::string_view line) {
    std::string_view rest = trimmed(line);
    if (rest.size() < 3 || (rest[0] != '-' && rest[0] != '*' && rest[0] != '_')) {
        return false;
    }
    char c = rest[0];
    size_t count = 0;
    for (char character : rest) {
        if (character == c) {
            ++count;
        } else if (!isSpace(character)) {
            return false;
        }
    }
    return count >= 3;
}

bool readHeading(std::string_view line, int& level, std::string_view& text) {
    if (leadingSpaces(line) > 3) {
        return false;
    }
    std::string_view rest = trimmed(line);
    size_t hashes = countRun(rest, 0, '#');
    if (hashes == 0 || hashes > 6) {
        return false;
    }
    if (hashes < rest.size() && rest[hashes] != ' ' && rest[hashes] != '\t') {
        return false;
    }
    std::string_view content = trimmed(rest.substr(hashes));
    // Closing hashes ("## Title ##") are decoration.
    while (!content.empty() && content.back() == '#') {
        content.remove_suffix(1);
    }
    level = static_cast<int>(hashes);
    text = trimmed(content);
    return true;
}

struct ListMarker {
    size_t indent = 0;
    bool ordered = false;
    int number = 0;
    size_t contentColumn = 0;
    std::string_view text;
};

bool readListItem(std::string_view line, ListMarker& marker) {
    size_t indent = leadingSpaces(line);
    size_t position = 0;
    while (position < line.size() && (line[position] == ' ' || line[position] == '\t')) {
        ++position;
    }
    if (position >= line.size()) {
        return false;
    }
    char c = line[position];
    size_t markerEnd = position;
    bool ordered = false;
    int number = 0;
    if (c == '-' || c == '*' || c == '+') {
        markerEnd = position + 1;
    } else if (std::isdigit(static_cast<unsigned char>(c))) {
        size_t digits = 0;
        while (markerEnd < line.size() && std::isdigit(static_cast<unsigned char>(line[markerEnd])) && digits < 9) {
            number = number * 10 + (line[markerEnd] - '0');
            ++markerEnd;
            ++digits;
        }
        if (markerEnd >= line.size() || (line[markerEnd] != '.' && line[markerEnd] != ')')) {
            return false;
        }
        ++markerEnd;
        ordered = true;
    } else {
        return false;
    }
    if (markerEnd < line.size() && line[markerEnd] != ' ' && line[markerEnd] != '\t') {
        return false;  // "**bold**" or "-x" is not a list item
    }
    marker.indent = indent;
    marker.ordered = ordered;
    marker.number = number;
    marker.contentColumn = indent + (markerEnd - position) + 1;
    marker.text = trimmed(line.substr(markerEnd));
    return true;
}

bool isQuoteLine(std::string_view line) {
    return leadingSpaces(line) <= 3 && trimmed(line).rfind('>', 0) == 0;
}

std::string_view stripQuoteMarker(std::string_view line) {
    std::string_view rest = trimmed(line);
    while (!rest.empty() && rest[0] == '>') {
        rest.remove_prefix(1);
        if (!rest.empty() && rest[0] == ' ') {
            rest.remove_prefix(1);
        }
    }
    return rest;
}

/// The cells of a table row: "| a | b |" gives {"a", "b"}.
std::vector<std::string> splitTableRow(std::string_view line) {
    std::string_view rest = trimmed(line);
    if (!rest.empty() && rest.front() == '|') {
        rest.remove_prefix(1);
    }
    if (!rest.empty() && rest.back() == '|' && (rest.size() < 2 || rest[rest.size() - 2] != '\\')) {
        rest.remove_suffix(1);
    }
    std::vector<std::string> cells;
    std::string cell;
    for (size_t index = 0; index < rest.size(); ++index) {
        if (rest[index] == '\\' && index + 1 < rest.size() && rest[index + 1] == '|') {
            cell += '|';
            ++index;
        } else if (rest[index] == '|') {
            cells.push_back(std::string(trimmed(cell)));
            cell.clear();
        } else {
            cell += rest[index];
        }
    }
    cells.push_back(std::string(trimmed(cell)));
    return cells;
}

/// A line like "|---|:--:|--:|" that sits under a table's header.
bool readTableSeparator(std::string_view line, std::string& alignments) {
    if (line.find('-') == std::string_view::npos) {
        return false;
    }
    std::vector<std::string> cells = splitTableRow(line);
    if (cells.empty()) {
        return false;
    }
    alignments.clear();
    for (const std::string& cell : cells) {
        if (cell.empty()) {
            return false;
        }
        bool left = cell.front() == ':';
        bool right = cell.back() == ':';
        for (char c : cell) {
            if (c != '-' && c != ':') {
                return false;
            }
        }
        alignments += left && right ? 'c' : (right ? 'r' : 'l');
    }
    return true;
}

bool startsBlock(std::string_view line) {
    char fenceCharacter;
    size_t fenceLength;
    size_t indent;
    std::string language;
    int level;
    std::string_view heading;
    ListMarker marker;
    return readFenceStart(line, fenceCharacter, fenceLength, language, indent) || readHeading(line, level, heading) ||
           isRule(line) || isQuoteLine(line) || readListItem(line, marker);
}

}  // namespace

// ---------------------------------------------------------------------------
// Public

Spans parseInline(std::string_view text) {
    return parseStyled(text, kPlain, std::string());
}

std::string plainText(const Spans& spans) {
    std::string text;
    for (const Span& span : spans) {
        text += span.text;
    }
    return text;
}

std::vector<Block> parse(std::string_view text) {
    std::vector<Block> blocks;
    std::vector<std::string_view> lines = splitIntoLines(text);
    size_t index = 0;

    // Indentation of the list items currently open, to work out how deep an item is.
    std::vector<size_t> listIndents;

    while (index < lines.size()) {
        std::string_view line = lines[index];

        // Fenced code.
        char fenceCharacter = 0;
        size_t fenceLength = 0;
        size_t fenceIndent = 0;
        std::string language;
        if (readFenceStart(line, fenceCharacter, fenceLength, language, fenceIndent)) {
            Block block;
            block.kind = Block::Kind::CodeBlock;
            block.language = language;
            block.closed = false;
            ++index;
            bool first = true;
            while (index < lines.size()) {
                if (isFenceEnd(lines[index], fenceCharacter, fenceLength)) {
                    block.closed = true;
                    ++index;
                    break;
                }
                // Code inside an indented list item loses that indentation.
                std::string_view codeLine = lines[index];
                size_t remove = std::min(fenceIndent, leadingSpaces(codeLine));
                size_t removed = 0;
                size_t position = 0;
                while (position < codeLine.size() && removed < remove && codeLine[position] == ' ') {
                    ++position;
                    ++removed;
                }
                if (!first) {
                    block.code += '\n';
                }
                block.code += codeLine.substr(position);
                first = false;
                ++index;
            }
            blocks.push_back(std::move(block));
            listIndents.clear();
            continue;
        }

        if (isBlank(line)) {
            ++index;
            continue;
        }

        // Headings.
        int level = 0;
        std::string_view headingText;
        if (readHeading(line, level, headingText)) {
            Block block;
            block.kind = Block::Kind::Heading;
            block.level = level;
            block.spans = parseInline(headingText);
            blocks.push_back(std::move(block));
            listIndents.clear();
            ++index;
            continue;
        }

        if (isRule(line)) {
            Block block;
            block.kind = Block::Kind::Rule;
            blocks.push_back(std::move(block));
            listIndents.clear();
            ++index;
            continue;
        }

        // Tables: a row with pipes, then a separator row.
        std::string alignments;
        if (line.find('|') != std::string_view::npos && index + 1 < lines.size() && readTableSeparator(lines[index + 1], alignments)) {
            std::vector<std::string> header = splitTableRow(line);
            if (header.size() == alignments.size() || header.size() > 1) {
                Block block;
                block.kind = Block::Kind::Table;
                block.hasHeader = true;
                block.alignments = alignments;
                std::vector<Spans> headerCells;
                for (const std::string& cell : header) {
                    headerCells.push_back(parseInline(cell));
                }
                block.rows.push_back(std::move(headerCells));
                index += 2;
                while (index < lines.size() && !isBlank(lines[index]) && lines[index].find('|') != std::string_view::npos) {
                    std::vector<Spans> cells;
                    for (const std::string& cell : splitTableRow(lines[index])) {
                        cells.push_back(parseInline(cell));
                    }
                    block.rows.push_back(std::move(cells));
                    ++index;
                }
                blocks.push_back(std::move(block));
                listIndents.clear();
                continue;
            }
        }

        // Block quotes: consecutive ">" lines; a blank ">" line starts a new paragraph.
        if (isQuoteLine(line)) {
            std::string paragraph;
            auto finish = [&]() {
                if (paragraph.empty()) {
                    return;
                }
                Block block;
                block.kind = Block::Kind::Quote;
                block.spans = parseInline(paragraph);
                blocks.push_back(std::move(block));
                paragraph.clear();
            };
            while (index < lines.size() && isQuoteLine(lines[index])) {
                std::string_view content = stripQuoteMarker(lines[index]);
                if (content.empty()) {
                    finish();
                } else {
                    if (!paragraph.empty()) {
                        paragraph += ' ';
                    }
                    paragraph += std::string(content);
                }
                ++index;
            }
            finish();
            listIndents.clear();
            continue;
        }

        // List items.
        ListMarker marker;
        if (readListItem(line, marker)) {
            while (!listIndents.empty() && listIndents.back() > marker.indent) {
                listIndents.pop_back();
            }
            if (listIndents.empty() || listIndents.back() < marker.indent) {
                listIndents.push_back(marker.indent);
            }
            Block block;
            block.kind = Block::Kind::ListItem;
            block.level = static_cast<int>(listIndents.size()) - 1;
            block.ordered = marker.ordered;
            block.number = marker.number;
            std::string content(marker.text);
            ++index;
            // Lines that continue the item without starting anything new.
            while (index < lines.size() && !isBlank(lines[index]) && !startsBlock(lines[index]) &&
                   leadingSpaces(lines[index]) >= marker.indent) {
                content += ' ';
                content += std::string(trimmed(lines[index]));
                ++index;
            }
            block.spans = parseInline(content);
            blocks.push_back(std::move(block));
            continue;
        }

        // A paragraph runs until a blank line or the start of another block.
        // Trailing spaces stay for now: two of them at the end of a line mean a line break.
        std::string paragraph(leftTrimmed(line));
        ++index;
        while (index < lines.size() && !isBlank(lines[index]) && !startsBlock(lines[index])) {
            std::string_view next = lines[index];
            bool hardBreak = paragraph.size() >= 2 && paragraph.compare(paragraph.size() - 2, 2, "  ") == 0;
            bool backslashBreak = !paragraph.empty() && paragraph.back() == '\\';
            if (hardBreak || backslashBreak) {
                if (backslashBreak) {
                    paragraph.pop_back();
                }
                while (!paragraph.empty() && paragraph.back() == ' ') {
                    paragraph.pop_back();
                }
                paragraph += '\n';
            } else {
                paragraph += ' ';
            }
            paragraph += std::string(leftTrimmed(next));
            ++index;
        }
        Block block;
        block.kind = Block::Kind::Paragraph;
        block.spans = parseInline(trimmed(paragraph));
        blocks.push_back(std::move(block));
        listIndents.clear();
    }
    return blocks;
}

}  // namespace gw::markdown
