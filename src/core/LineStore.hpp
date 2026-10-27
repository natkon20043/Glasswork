#pragma once

#include "FileBytes.hpp"

#include <cstddef>
#include <cstdint>
#include <deque>
#include <string>
#include <string_view>
#include <vector>

namespace gw {

/// Lines of a document stored as references into the file's bytes. A line is copied into its
/// own string only when edited. A `view()` stays valid until that same line changes or is removed.
/// Every line knows whether the break after it is "\r\n" or "\n", so a file with mixed endings
/// saves byte for byte: an unedited line reads it from the file, an edited one stores it.
class LineStore {
public:
    /// Offset into the file bytes, or (when `length == kOwned`) a slot in `owned_`.
    struct LineRef {
        uint32_t offset;
        uint32_t length;
    };
    struct OwnedLine {
        std::string text;
        bool breakIsCRLF = false;
    };
    static constexpr uint32_t kOwned = 0xFFFFFFFFu;

    // ---- Constructors
    LineStore();
    /// Splits at '\n' (a '\r' before it belongs to the break, not the line).
    /// Reports how many breaks were "\r\n" and how many plain "\n".
    static LineStore fromBytes(FileBytes&& bytes, size_t* crlfCount, size_t* lfCount);
    static LineStore fromText(std::string&& text, size_t* crlfCount, size_t* lfCount);

    // ---- Getters
    size_t size() const { return refs_.size(); }
    std::string_view view(size_t index) const {
        const LineRef ref = refs_[index];
        if (ref.length == kOwned) {
            return owned_[ref.offset].text;
        }
        return std::string_view(bytes_.data() + ref.offset, ref.length);
    }
    /// The break after the line. Meaningless for the last line, which has none.
    bool breakIsCRLF(size_t index) const {
        const LineRef ref = refs_[index];
        if (ref.length == kOwned) {
            return owned_[ref.offset].breakIsCRLF;
        }
        size_t afterLine = static_cast<size_t>(ref.offset) + ref.length;
        return afterLine < bytes_.size() && bytes_.data()[afterLine] == '\r';
    }
    /// Bytes of text, excluding line endings.
    size_t totalBytes() const;
    size_t memoryBytes() const;
    size_t editedLineCount() const { return owned_.size() - freeSlots_.size(); }
    bool isMapped() const { return bytes_.isMapped(); }

    // ---- Editing
    /// Copies the line out of the file bytes first.
    std::string& edit(size_t index);
    /// Copies the line out of the file bytes first, like `edit`.
    void setBreakIsCRLF(size_t index, bool crlf);
    void insertOwned(size_t index, std::vector<OwnedLine>&& lines);
    /// Removes lines `first` up to (not including) `last`.
    void erase(size_t first, size_t last);

private:
    // ---- Private functions
    static LineStore fromBytesTooBigToIndex(const FileBytes& bytes, size_t* crlfCount, size_t* lfCount);
    uint32_t takeSlot(OwnedLine&& line);
    void releaseRefs(size_t first, size_t last);

    // ---- Private variables
    FileBytes bytes_;
    std::vector<LineRef> refs_;
    // A deque so adding a line never moves the others and views stay valid.
    std::deque<OwnedLine> owned_;
    std::vector<uint32_t> freeSlots_;
};

static_assert(sizeof(LineStore::LineRef) == 8, "a line reference should be two 32-bit numbers");
static_assert(sizeof(LineStore::LineRef) * 8 == 64, "and fit in a single 64-bit word");

}  // namespace gw
