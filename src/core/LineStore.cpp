#include "LineStore.hpp"

#include <algorithm>
#include <cstring>

namespace gw {

LineStore::LineStore() {
    refs_.push_back(LineRef{0, 0});
}

LineStore LineStore::fromText(std::string&& text, size_t* crlfCount, size_t* lfCount) {
    LineStore store;
    store.refs_.clear();
    size_t crlf = 0;
    size_t lf = 0;

    const size_t size = text.size();
    // Offsets are 32 bits, so a block over 4 GB can't be indexed. Such a file is split into
    // strings of their own instead: slower and larger, but correct.
    const bool tooBigToIndex = size >= static_cast<size_t>(kOwned) - 1;

    if (!tooBigToIndex) {
        store.block_ = std::move(text);
    }
    const char* bytes = tooBigToIndex ? text.data() : store.block_.data();

    // Count the lines first, so the reference list is allocated once.
    size_t newlineCount = 0;
    for (const char* cursor = bytes; cursor < bytes + size;) {
        const char* found = static_cast<const char*>(std::memchr(cursor, '\n', static_cast<size_t>(bytes + size - cursor)));
        if (found == nullptr) {
            break;
        }
        ++newlineCount;
        cursor = found + 1;
    }
    store.refs_.reserve(newlineCount + 1);

    size_t lineStart = 0;
    while (lineStart <= size) {
        const char* found = nullptr;
        if (lineStart < size) {
            found = static_cast<const char*>(std::memchr(bytes + lineStart, '\n', size - lineStart));
        }
        size_t lineEnd = found != nullptr ? static_cast<size_t>(found - bytes) : size;
        size_t contentEnd = lineEnd;
        if (found != nullptr) {
            if (contentEnd > lineStart && bytes[contentEnd - 1] == '\r') {
                --contentEnd;
                ++crlf;
            } else {
                ++lf;
            }
        }
        if (tooBigToIndex) {
            store.refs_.push_back(LineRef{store.takeSlot(std::string(bytes + lineStart, contentEnd - lineStart)), kOwned});
        } else {
            store.refs_.push_back(LineRef{static_cast<uint32_t>(lineStart), static_cast<uint32_t>(contentEnd - lineStart)});
        }
        if (found == nullptr) {
            break;
        }
        lineStart = lineEnd + 1;
    }
    if (crlfCount != nullptr) {
        *crlfCount = crlf;
    }
    if (lfCount != nullptr) {
        *lfCount = lf;
    }
    return store;
}

uint32_t LineStore::takeSlot(std::string&& text) {
    if (!freeSlots_.empty()) {
        uint32_t slot = freeSlots_.back();
        freeSlots_.pop_back();
        owned_[slot] = std::move(text);
        return slot;
    }
    owned_.push_back(std::move(text));
    return static_cast<uint32_t>(owned_.size() - 1);
}

std::string& LineStore::edit(size_t index) {
    LineRef& ref = refs_[index];
    if (ref.length != kOwned) {
        std::string copy(block_.data() + ref.offset, ref.length);
        uint32_t slot = takeSlot(std::move(copy));
        // takeSlot may have grown owned_, but `ref` points into refs_, which it doesn't touch.
        ref = LineRef{slot, kOwned};
    }
    return owned_[ref.offset];
}

void LineStore::releaseRefs(size_t first, size_t last) {
    for (size_t index = first; index < last; ++index) {
        const LineRef ref = refs_[index];
        if (ref.length == kOwned) {
            std::string().swap(owned_[ref.offset]);  // give the memory back
            freeSlots_.push_back(ref.offset);
        }
    }
}

void LineStore::insertOwned(size_t index, std::vector<std::string>&& lines) {
    std::vector<LineRef> added;
    added.reserve(lines.size());
    for (std::string& line : lines) {
        added.push_back(LineRef{takeSlot(std::move(line)), kOwned});
    }
    refs_.insert(refs_.begin() + static_cast<long>(index), added.begin(), added.end());
}

void LineStore::erase(size_t first, size_t last) {
    if (first >= last) {
        return;
    }
    releaseRefs(first, last);
    refs_.erase(refs_.begin() + static_cast<long>(first), refs_.begin() + static_cast<long>(last));
    if (refs_.empty()) {
        refs_.push_back(LineRef{0, 0});  // a document always has a line
    }
}

size_t LineStore::totalBytes() const {
    size_t total = 0;
    for (const LineRef& ref : refs_) {
        total += ref.length == kOwned ? owned_[ref.offset].size() : ref.length;
    }
    return total;
}

size_t LineStore::memoryBytes() const {
    size_t total = block_.capacity() + refs_.capacity() * sizeof(LineRef) + owned_.size() * sizeof(std::string) +
                   freeSlots_.capacity() * sizeof(uint32_t);
    for (const std::string& line : owned_) {
        if (line.capacity() > sizeof(std::string)) {
            total += line.capacity();  // heap memory beyond the string object itself
        }
    }
    return total;
}

}  // namespace gw
