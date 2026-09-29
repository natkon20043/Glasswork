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

size_t floorToCharacter(const std::string& line, size_t column) {
    column = std::min(column, line.size());
    while (column > 0 && column < line.size() && isContinuationByte(static_cast<unsigned char>(line[column]))) {
        --column;
    }
    return column;
}

TextBuffer::TextBuffer() : lines_{std::string()} {}

TextBuffer::TextBuffer(std::string_view text) {
    size_t crlfCount = 0, lfCount = 0;
    size_t start = 0;
    for (size_t index = 0; index < text.size(); ++index) {
        if (text[index] != '\n') continue;
        size_t end = index;
        if (end > start && text[end - 1] == '\r') {
            --end;
            ++crlfCount;
        } else {
            ++lfCount;
        }
        lines_.emplace_back(text.substr(start, end - start));
        start = index + 1;
    }
    lines_.emplace_back(text.substr(start));
    crlf_ = crlfCount > lfCount;
}

std::string TextBuffer::text() const {
    const char* eol = crlf_ ? "\r\n" : "\n";
    std::string result;
    size_t total = 0;
    for (const auto& line : lines_) total += line.size() + 2;
    result.reserve(total);
    for (size_t index = 0; index < lines_.size(); ++index) {
        if (index > 0) result += eol;
        result += lines_[index];
    }
    return result;
}

std::string TextBuffer::text(Range range) const {
    range = range.normalized();
    Position start = clamp(range.start), end = clamp(range.end);
    if (start.line == end.line) return lines_[start.line].substr(start.column, end.column - start.column);
    std::string result = lines_[start.line].substr(start.column);
    for (size_t line = start.line + 1; line < end.line; ++line) {
        result += '\n';
        result += lines_[line];
    }
    result += '\n';
    result += lines_[end.line].substr(0, end.column);
    return result;
}

Position TextBuffer::insert(Position at, std::string_view text) {
    at = clamp(at);
    std::string& first = lines_[at.line];
    std::string tail = first.substr(at.column);
    first.erase(at.column);

    // Split the inserted text into lines, dropping any '\r' that precedes a newline.
    std::vector<std::string> pieces;
    size_t start = 0;
    for (size_t index = 0; index <= text.size(); ++index) {
        if (index == text.size() || text[index] == '\n') {
            size_t end = index;
            if (index < text.size() && end > start && text[end - 1] == '\r') --end;
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
    lines_.insert(lines_.begin() + static_cast<long>(at.line) + 1, added.begin(), added.end());
    return {at.line + added.size(), column};
}

void TextBuffer::erase(Range range) {
    range = range.normalized();
    Position start = clamp(range.start), end = clamp(range.end);
    if (start == end) return;
    if (start.line == end.line) {
        lines_[start.line].erase(start.column, end.column - start.column);
        return;
    }
    lines_[start.line].erase(start.column);
    lines_[start.line] += lines_[end.line].substr(end.column);
    lines_.erase(lines_.begin() + static_cast<long>(start.line) + 1, lines_.begin() + static_cast<long>(end.line) + 1);
}

Position TextBuffer::clamp(Position position) const {
    position.line = std::min(position.line, lines_.size() - 1);
    position.column = floorToCharacter(lines_[position.line], position.column);
    return position;
}

Position TextBuffer::nextCharacter(Position position) const {
    position = clamp(position);
    const std::string& text = lines_[position.line];
    if (position.column >= text.size()) {
        return position.line + 1 < lines_.size() ? Position{position.line + 1, 0} : position;
    }
    size_t column = position.column + 1;
    while (column < text.size() && isContinuationByte(static_cast<unsigned char>(text[column]))) ++column;
    return {position.line, column};
}

Position TextBuffer::previousCharacter(Position position) const {
    position = clamp(position);
    if (position.column == 0) {
        return position.line > 0 ? Position{position.line - 1, lines_[position.line - 1].size()} : position;
    }
    const std::string& text = lines_[position.line];
    size_t column = position.column - 1;
    while (column > 0 && isContinuationByte(static_cast<unsigned char>(text[column]))) --column;
    return {position.line, column};
}

Position TextBuffer::nextWordEnd(Position position) const {
    position = clamp(position);
    const std::string& text = lines_[position.line];
    if (position.column >= text.size()) return nextCharacter(position);
    size_t column = position.column;
    while (column < text.size() && !isWordByte(static_cast<unsigned char>(text[column]))) ++column;
    while (column < text.size() && isWordByte(static_cast<unsigned char>(text[column]))) ++column;
    return {position.line, column};
}

Position TextBuffer::previousWordStart(Position position) const {
    position = clamp(position);
    if (position.column == 0) return previousCharacter(position);
    const std::string& text = lines_[position.line];
    size_t column = position.column;
    while (column > 0 && !isWordByte(static_cast<unsigned char>(text[column - 1]))) --column;
    while (column > 0 && isWordByte(static_cast<unsigned char>(text[column - 1]))) --column;
    return {position.line, column};
}

Range TextBuffer::wordAt(Position position) const {
    position = clamp(position);
    const std::string& text = lines_[position.line];
    size_t start = position.column, end = position.column;
    while (start > 0 && isWordByte(static_cast<unsigned char>(text[start - 1]))) --start;
    while (end < text.size() && isWordByte(static_cast<unsigned char>(text[end]))) ++end;
    if (start == end && end < text.size()) end = nextCharacter(position).column;  // a lone symbol
    return {{position.line, start}, {position.line, end}};
}

size_t TextBuffer::indentEnd(size_t line) const {
    const std::string& text = lines_[std::min(line, lines_.size() - 1)];
    size_t column = 0;
    while (column < text.size() && (text[column] == ' ' || text[column] == '\t')) ++column;
    return column;
}

}  // namespace gw
