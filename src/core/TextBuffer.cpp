#include "TextBuffer.hpp"

#include <algorithm>
#include <cctype>

namespace gw {

namespace {

bool isContinuationByte(unsigned char byte) { return (byte & 0xC0) == 0x80; }

}  // namespace

bool isWordByte(unsigned char byte) {
    // ASCII letters, digits and underscore, plus any non-ASCII byte so identifiers in other
    // scripts count as words.
    return std::isalnum(byte) || byte == '_' || byte >= 0x80;
}

size_t floorToCharacter(std::string_view line, size_t column) {
    column = std::min(column, line.size());
    while (column > 0 && column < line.size() && isContinuationByte(static_cast<unsigned char>(line[column]))) {
        --column;
    }
    return column;
}

namespace {

/// How many bytes the valid UTF-8 character at `index` takes, or 0 if it isn't one: a stray
/// continuation byte, a cut-off sequence, an overlong form, a surrogate or past U+10FFFF.
size_t validCharacterLength(std::string_view text, size_t index) {
    unsigned char lead = static_cast<unsigned char>(text[index]);
    if (lead < 0x80) {
        return 1;
    }
    size_t length = 0;
    uint32_t codePoint = 0;
    uint32_t smallest = 0;
    if (lead >= 0xC2 && lead <= 0xDF) {
        length = 2;
        codePoint = lead & 0x1F;
        smallest = 0x80;
    } else if (lead >= 0xE0 && lead <= 0xEF) {
        length = 3;
        codePoint = lead & 0x0F;
        smallest = 0x800;
    } else if (lead >= 0xF0 && lead <= 0xF4) {
        length = 4;
        codePoint = lead & 0x07;
        smallest = 0x10000;
    } else {
        return 0;
    }
    if (index + length > text.size()) {
        return 0;
    }
    for (size_t offset = 1; offset < length; ++offset) {
        unsigned char next = static_cast<unsigned char>(text[index + offset]);
        if (!isContinuationByte(next)) {
            return 0;
        }
        codePoint = (codePoint << 6) | (next & 0x3F);
    }
    bool overlong = codePoint < smallest;
    bool surrogate = codePoint >= 0xD800 && codePoint <= 0xDFFF;
    if (overlong || surrogate || codePoint > 0x10FFFF) {
        return 0;
    }
    return length;
}

}  // namespace

std::string withValidUtf8(std::string_view text) {
    std::string result;
    result.reserve(text.size());
    size_t index = 0;
    while (index < text.size()) {
        size_t length = validCharacterLength(text, index);
        if (length == 0) {
            result += "\xEF\xBF\xBD";  // U+FFFD, the replacement character
            ++index;
            continue;
        }
        result.append(text, index, length);
        index += length;
    }
    return result;
}

TextBuffer::TextBuffer() = default;

TextBuffer::TextBuffer(std::string_view text) : TextBuffer(std::string(text)) {}

TextBuffer::TextBuffer(std::string&& text) {
    size_t crlfCount = 0;
    size_t lfCount = 0;
    lines_ = LineStore::fromText(std::move(text), &crlfCount, &lfCount);
    crlf_ = crlfCount > lfCount;
}

std::string TextBuffer::text() const {
    const char* eol = crlf_ ? "\r\n" : "\n";
    std::string result;
    size_t total = 0;
    for (size_t index = 0; index < lines_.size(); ++index) {
        total += lines_.view(index).size() + 2;
    }
    result.reserve(total);
    for (size_t index = 0; index < lines_.size(); ++index) {
        if (index > 0) {
            result += eol;
        }
        result += lines_.view(index);
    }
    return result;
}

std::string TextBuffer::text(Range range) const {
    range = range.normalized();
    Position start = clamp(range.start), end = clamp(range.end);
    if (start.line == end.line) {
        return std::string(lines_.view(start.line).substr(start.column, end.column - start.column));
    }
    std::string result(lines_.view(start.line).substr(start.column));
    for (size_t line = start.line + 1; line < end.line; ++line) {
        result += '\n';
        result += lines_.view(line);
    }
    result += '\n';
    result += lines_.view(end.line).substr(0, end.column);
    return result;
}

Position TextBuffer::insert(Position at, std::string_view text) {
    at = clamp(at);
    std::string& first = lines_.edit(at.line);
    std::string tail = first.substr(at.column);
    first.erase(at.column);

    // Split the inserted text into lines, dropping any '\r' that precedes a newline.
    std::vector<std::string> pieces;
    size_t start = 0;
    for (size_t index = 0; index <= text.size(); ++index) {
        if (index == text.size() || text[index] == '\n') {
            size_t end = index;
            if (index < text.size() && end > start && text[end - 1] == '\r') {
                --end;
            }
            pieces.emplace_back(text.substr(start, end - start));
            start = index + 1;
        }
    }

    first += pieces[0];
    if (pieces.size() == 1) {
        size_t column = first.size();
        first += tail;
        return {at.line, column};
    }
    std::vector<std::string> added(pieces.begin() + 1, pieces.end());
    size_t column = added.back().size();
    added.back() += tail;
    size_t addedCount = added.size();
    lines_.insertOwned(at.line + 1, std::move(added));
    return {at.line + addedCount, column};
}

void TextBuffer::erase(Range range) {
    range = range.normalized();
    Position start = clamp(range.start), end = clamp(range.end);
    if (start == end) {
        return;
    }
    if (start.line == end.line) {
        lines_.edit(start.line).erase(start.column, end.column - start.column);
        return;
    }
    // Keep what follows the erased range on its last line; it moves onto the first line.
    // (A copy: editing the first line may move the strings a view would point into.)
    std::string keptTail(lines_.view(end.line).substr(end.column));
    std::string& firstLine = lines_.edit(start.line);
    firstLine.erase(start.column);
    firstLine += keptTail;
    lines_.erase(start.line + 1, end.line + 1);
}

Position TextBuffer::clamp(Position position) const {
    position.line = std::min(position.line, lines_.size() - 1);
    position.column = floorToCharacter(lines_.view(position.line), position.column);
    return position;
}

Position TextBuffer::nextCharacter(Position position) const {
    position = clamp(position);
    std::string_view text = lines_.view(position.line);
    if (position.column >= text.size()) {
        return position.line + 1 < lines_.size() ? Position{position.line + 1, 0} : position;
    }
    size_t column = position.column + 1;
    while (column < text.size() && isContinuationByte(static_cast<unsigned char>(text[column]))) {
        ++column;
    }
    return {position.line, column};
}

Position TextBuffer::previousCharacter(Position position) const {
    position = clamp(position);
    if (position.column == 0) {
        return position.line > 0 ? Position{position.line - 1, lines_.view(position.line - 1).size()} : position;
    }
    std::string_view text = lines_.view(position.line);
    size_t column = position.column - 1;
    while (column > 0 && isContinuationByte(static_cast<unsigned char>(text[column]))) {
        --column;
    }
    return {position.line, column};
}

Position TextBuffer::nextWordEnd(Position position) const {
    position = clamp(position);
    std::string_view text = lines_.view(position.line);
    if (position.column >= text.size()) {
        return nextCharacter(position);
    }
    size_t column = position.column;
    while (column < text.size() && !isWordByte(static_cast<unsigned char>(text[column]))) {
        ++column;
    }
    while (column < text.size() && isWordByte(static_cast<unsigned char>(text[column]))) {
        ++column;
    }
    return {position.line, column};
}

Position TextBuffer::previousWordStart(Position position) const {
    position = clamp(position);
    if (position.column == 0) {
        return previousCharacter(position);
    }
    std::string_view text = lines_.view(position.line);
    size_t column = position.column;
    while (column > 0 && !isWordByte(static_cast<unsigned char>(text[column - 1]))) {
        --column;
    }
    while (column > 0 && isWordByte(static_cast<unsigned char>(text[column - 1]))) {
        --column;
    }
    return {position.line, column};
}

Range TextBuffer::wordAt(Position position) const {
    position = clamp(position);
    std::string_view text = lines_.view(position.line);
    size_t start = position.column, end = position.column;
    while (start > 0 && isWordByte(static_cast<unsigned char>(text[start - 1]))) {
        --start;
    }
    while (end < text.size() && isWordByte(static_cast<unsigned char>(text[end]))) {
        ++end;
    }
    if (start == end && end < text.size()) {
        end = nextCharacter(position).column; // a lone symbol
    }
    return {{position.line, start}, {position.line, end}};
}

size_t TextBuffer::indentEnd(size_t line) const {
    std::string_view text = lines_.view(std::min(line, lines_.size() - 1));
    size_t column = 0;
    while (column < text.size() && (text[column] == ' ' || text[column] == '\t')) {
        ++column;
    }
    return column;
}

}  // namespace gw
