#pragma once

#include <cstddef>
#include <cstdint>
#include <deque>
#include <string>
#include <string_view>
#include <vector>

namespace gw {

/// The lines of a document, stored compactly.
///
/// A file's text is kept as one block of bytes. Each line is just a small reference into that
/// block (where it starts and how long it is), so a file with 600,000 lines costs about 5 MB of
/// bookkeeping instead of 600,000 separate strings. A line is copied into a string of its own only
/// when it is edited; the untouched rest of the file keeps pointing into the block.
///
/// A view returned by `view()` stays valid until that same line is changed or removed.
class LineStore {
public:
    /// One line: where it is. A line still in the file block has an offset into it. An edited line
    /// has `length == kOwned` and the offset is its slot in `owned_`.
    struct LineRef {
        uint32_t offset;
        uint32_t length;
    };
    static constexpr uint32_t kOwned = 0xFFFFFFFFu;

    /// A store with one empty line.
    LineStore();

    /// Splits `text` into lines at every '\n' (a '\r' just before it is dropped) and takes over
    /// its memory as the block the lines point into. The number of line endings that were "\r\n"
    /// and that were plain "\n" are reported for the caller to decide which the file uses.
    static LineStore fromText(std::string&& text, size_t* crlfCount, size_t* lfCount);

    size_t size() const { return refs_.size(); }

    std::string_view view(size_t index) const {
        const LineRef ref = refs_[index];
        if (ref.length == kOwned) {
            return owned_[ref.offset];
        }
        return std::string_view(block_.data() + ref.offset, ref.length);
    }

    /// The line as a string you may change. The line is copied out of the file block first.
    std::string& edit(size_t index);

    /// Adds lines (as strings of their own) before line `index`.
    void insertOwned(size_t index, std::vector<std::string>&& lines);
    /// Removes lines `first` up to (not including) `last`.
    void erase(size_t first, size_t last);

    /// Bytes of memory used: the file block, the references and the edited lines.
    size_t memoryBytes() const;
    /// Lines that have been edited and now own their text.
    size_t editedLineCount() const { return owned_.size() - freeSlots_.size(); }

private:
    uint32_t takeSlot(std::string&& text);
    void releaseRefs(size_t first, size_t last);

    std::string block_;                  // the file's bytes, in one piece
    std::vector<LineRef> refs_;          // one per line
    // Lines that were edited or inserted. A deque, so adding one never moves the others: a view
    // of one line stays valid while a different line is edited.
    std::deque<std::string> owned_;
    std::vector<uint32_t> freeSlots_;    // unused places in owned_
};

// The point of the design is its size: a line costs exactly this much bookkeeping.
static_assert(sizeof(LineStore::LineRef) == 8, "a line reference should be two 32-bit numbers");
static_assert(sizeof(LineStore::LineRef) * 8 == 64, "and fit in a single 64-bit word");

}  // namespace gw
