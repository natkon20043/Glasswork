#pragma once

#include <cstddef>
#include <cstdint>
#include <deque>
#include <string>
#include <string_view>
#include <vector>

namespace gw {

/// Lines of a document stored as references into one block of file bytes. A line is copied into
/// its own string only when edited. A `view()` stays valid until that same line changes or is removed.
class LineStore {
public:
    /// Offset into the file block, or (when `length == kOwned`) a slot in `owned_`.
    struct LineRef {
        uint32_t offset;
        uint32_t length;
    };
    static constexpr uint32_t kOwned = 0xFFFFFFFFu;

    // ---- Constructors
    LineStore();
    /// Splits at '\n' (dropping a '\r' before it) and takes over `text` as the block.
    /// Reports how many endings were "\r\n" and how many plain "\n".
    static LineStore fromText(std::string&& text, size_t* crlfCount, size_t* lfCount);

    // ---- Getters
    size_t size() const { return refs_.size(); }
    std::string_view view(size_t index) const {
        const LineRef ref = refs_[index];
        if (ref.length == kOwned) {
            return owned_[ref.offset];
        }
        return std::string_view(block_.data() + ref.offset, ref.length);
    }
    /// Bytes of text, excluding line endings.
    size_t totalBytes() const;
    size_t memoryBytes() const;
    size_t editedLineCount() const { return owned_.size() - freeSlots_.size(); }

    // ---- Editing
    /// Copies the line out of the file block first.
    std::string& edit(size_t index);
    void insertOwned(size_t index, std::vector<std::string>&& lines);
    /// Removes lines `first` up to (not including) `last`.
    void erase(size_t first, size_t last);

private:
    // ---- Private functions
    uint32_t takeSlot(std::string&& text);
    void releaseRefs(size_t first, size_t last);

    // ---- Private variables
    std::string block_;
    std::vector<LineRef> refs_;
    // A deque so adding a line never moves the others and views stay valid.
    std::deque<std::string> owned_;
    std::vector<uint32_t> freeSlots_;
};

static_assert(sizeof(LineStore::LineRef) == 8, "a line reference should be two 32-bit numbers");
static_assert(sizeof(LineStore::LineRef) * 8 == 64, "and fit in a single 64-bit word");

}  // namespace gw
