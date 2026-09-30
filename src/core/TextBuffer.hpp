#pragma once

#include "LineStore.hpp"

#include <compare>
#include <cstddef>
#include <string>
#include <string_view>
#include <vector>

namespace gw {

/// A place in the text. `column` is a UTF-8 byte offset within the line, which is what the
/// TextMate engine and the buffer work in; the UI converts to UTF-16 for display.
struct Position {
    size_t line = 0;
    size_t column = 0;
    auto operator<=>(const Position&) const = default;
};

struct Range {
    Position start;
    Position end;

    bool empty() const { return start == end; }
    Range normalized() const { return start <= end ? *this : Range{end, start}; }
};

/// The document's text as a list of lines (without their line endings). Line-based storage
/// matches how syntax highlighting and rendering work and keeps edits local. The lines live in a
/// LineStore, which keeps the file's bytes in one block and copies a line out only when it is edited.
class TextBuffer {
public:
    TextBuffer();
    explicit TextBuffer(std::string_view text);
    explicit TextBuffer(const char* text) : TextBuffer(std::string_view(text)) {}
    /// Takes the text over without copying it (what opening a file uses).
    explicit TextBuffer(std::string&& text);

    size_t lineCount() const { return lines_.size(); }
    /// A line without its ending. The view stays valid until the buffer is next changed.
    std::string_view line(size_t index) const { return lines_.view(index); }
    Position end() const { return {lines_.size() - 1, lines_.view(lines_.size() - 1).size()}; }
    /// The text's size in bytes (about what `text().size()` would be) without building the text.
    size_t byteSize() const { return lines_.totalBytes() + lines_.size(); }
    /// Bytes of memory the text takes, for measuring.
    size_t memoryBytes() const { return lines_.memoryBytes(); }

    /// Whole text, joined with the file's original line ending.
    std::string text() const;
    std::string text(Range range) const;
    bool usesCRLF() const { return crlf_; }

    /// Inserts `text` (which may contain newlines) and returns the position just after it.
    Position insert(Position at, std::string_view text);
    void erase(Range range);

    /// Snaps a position into the buffer and onto a UTF-8 character boundary.
    Position clamp(Position position) const;

    // Navigation, all UTF-8 aware and crossing line boundaries.
    Position nextCharacter(Position position) const;
    Position previousCharacter(Position position) const;
    Position nextWordEnd(Position position) const;
    Position previousWordStart(Position position) const;
    /// The word (identifier) around a position, for double-click selection.
    Range wordAt(Position position) const;
    /// Column of the first non-whitespace character on the line.
    size_t indentEnd(size_t line) const;

private:
    LineStore lines_;
    bool crlf_ = false;
};

/// Byte offset of the UTF-8 character boundary at or before `column`.
size_t floorToCharacter(std::string_view line, size_t column);
bool isWordByte(unsigned char byte);

}  // namespace gw
