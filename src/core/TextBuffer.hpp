#pragma once

#include "LineStore.hpp"

#include <compare>
#include <cstddef>
#include <string>
#include <string_view>
#include <vector>

namespace gw {

struct Position {
    size_t line = 0;
    /// UTF-8 byte offset within the line; the UI converts to UTF-16 for display.
    size_t column = 0;
    auto operator<=>(const Position&) const = default;
};

struct Range {
    Position start;
    Position end;

    bool empty() const { return start == end; }
    Range normalized() const { return start <= end ? *this : Range{end, start}; }
};

/// The text as a list of lines without their endings, stored in a LineStore.
class TextBuffer {
public:
    // ---- Constructors
    TextBuffer();
    explicit TextBuffer(std::string_view text);
    explicit TextBuffer(const char* text) : TextBuffer(std::string_view(text)) {}
    /// Takes the text over without copying (used when opening a file).
    explicit TextBuffer(std::string&& text);

    // ---- Getters
    size_t lineCount() const { return lines_.size(); }
    /// Valid until the buffer next changes.
    std::string_view line(size_t index) const { return lines_.view(index); }
    Position end() const { return {lines_.size() - 1, lines_.view(lines_.size() - 1).size()}; }
    /// About `text().size()` without building the text.
    size_t byteSize() const { return lines_.totalBytes() + lines_.size(); }
    size_t memoryBytes() const { return lines_.memoryBytes(); }
    bool usesCRLF() const { return crlf_; }
    /// Joined with the file's original line ending.
    std::string text() const;
    std::string text(Range range) const;

    // ---- Editing
    /// Returns the position just after the inserted text.
    Position insert(Position at, std::string_view text);
    void erase(Range range);

    // ---- Navigation (UTF-8 aware, crossing lines)
    /// Snaps into the buffer and onto a character boundary.
    Position clamp(Position position) const;
    Position nextCharacter(Position position) const;
    Position previousCharacter(Position position) const;
    Position nextWordEnd(Position position) const;
    Position previousWordStart(Position position) const;
    /// The identifier around a position (double-click selection).
    Range wordAt(Position position) const;
    /// Column of the first non-whitespace character.
    size_t indentEnd(size_t line) const;

private:
    // ---- Private variables
    LineStore lines_;
    bool crlf_ = false;
};

/// Byte offset of the UTF-8 character boundary at or before `column`.
size_t floorToCharacter(std::string_view line, size_t column);
bool isWordByte(unsigned char byte);

}  // namespace gw
