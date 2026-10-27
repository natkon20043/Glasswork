#pragma once

#include "LineStore.hpp"

#include <compare>
#include <cstddef>
#include <string>
#include <string_view>
#include <vector>

namespace gw {

struct Position {
    auto operator<=>(const Position&) const = default;

    size_t line = 0;
    /// UTF-8 byte offset within the line; the UI converts to UTF-16 for display.
    size_t column = 0;
};

struct Range {
    bool empty() const { return start == end; }
    Range normalized() const {
        if (start <= end) {
            return *this;
        }
        return Range{end, start};
    }

    Position start;
    Position end;
};

/// The text as a list of lines, stored in a LineStore. Each line keeps the break that followed
/// it in the file ("\n" or "\r\n"), so the bytes come back exactly as they were read.
class TextBuffer {
public:
    // ---- Constructors
    TextBuffer();
    explicit TextBuffer(std::string_view text);
    explicit TextBuffer(const char* text) : TextBuffer(std::string_view(text)) {}
    /// Takes the text over without copying.
    explicit TextBuffer(std::string&& text);
    /// Used when opening a file: the lines point into the file's bytes.
    explicit TextBuffer(FileBytes&& bytes);

    // ---- Setters
    void setUsesCRLF(bool crlf) { crlf_ = crlf; }

    // ---- Getters
    size_t lineCount() const { return lines_.size(); }
    /// Valid until the buffer next changes.
    std::string_view line(size_t index) const { return lines_.view(index); }
    Position end() const { return {lines_.size() - 1, lines_.view(lines_.size() - 1).size()}; }
    /// About `text().size()` without building the text.
    size_t byteSize() const { return lines_.totalBytes() + lines_.size(); }
    size_t memoryBytes() const { return lines_.memoryBytes(); }
    /// The break new lines get: whichever the file used most.
    bool usesCRLF() const { return crlf_; }
    /// "\r\n" or "\n", or "" for the last line.
    std::string_view lineBreak(size_t index) const {
        if (index + 1 >= lines_.size()) {
            return {};
        }
        if (lines_.breakIsCRLF(index)) {
            return "\r\n";
        }
        return "\n";
    }
    /// The file's bytes: every line followed by its own break.
    std::string text() const;
    /// Hands the file's bytes to `write` piece by piece, without building one big string.
    template <typename Write>
    void forEachPiece(Write&& write) const {
        for (size_t index = 0; index < lines_.size(); ++index) {
            write(lines_.view(index));
            write(lineBreak(index));
        }
    }
    /// Lines joined with "\n" (for the clipboard, Vim registers and the like).
    std::string text(Range range) const;
    /// Lines joined with their own breaks, so inserting it again restores the exact bytes.
    std::string rawText(Range range) const;
    bool isMapped() const { return lines_.isMapped(); }

    // ---- Editing
    /// "\r\n" in `text` becomes a CRLF break and a lone "\n" an LF one.
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
    // ---- Private functions
    std::string textBetween(Range range, bool ownBreaks) const;

    // ---- Private variables
    LineStore lines_;
    bool crlf_ = false;
};

/// Byte offset of the UTF-8 character boundary at or before `column`.
size_t floorToCharacter(std::string_view line, size_t column);
/// `text` with every "\n" and "\r\n" changed to the one break given.
std::string withLineBreaks(std::string_view text, bool crlf);
/// `text` with every byte that isn't part of valid UTF-8 replaced by U+FFFD.
std::string withValidUtf8(std::string_view text);
bool isWordByte(unsigned char byte);

}  // namespace gw
