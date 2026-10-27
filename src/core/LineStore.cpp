#include "LineStore.hpp"

#include <algorithm>
#include <cstring>
#include <optional>
#include <thread>

namespace gw {

LineStore::LineStore() {
    refs_.push_back(LineRef{0, 0});
}

LineStore LineStore::fromText(std::string&& text, size_t* crlfCount, size_t* lfCount) {
    return fromBytes(FileBytes(std::move(text)), crlfCount, lfCount);
}

namespace {

/// One stretch of the file that one thread splits into lines.
struct Chunk {
    size_t begin = 0;
    size_t end = 0;
    size_t newlineCount = 0;
    /// Position of its last '\n', if it has one.
    std::optional<size_t> lastNewline;
    /// Where the line that ends at its first '\n' starts (maybe in an earlier chunk).
    size_t firstLineStart = 0;
    /// Index in the line list of that line.
    size_t firstLineIndex = 0;
    size_t crlfCount = 0;
};

/// Big files are split by several threads at once, one stretch each. When the bytes are
/// mapped, this also has the disk read several parts of the file at the same time.
std::vector<Chunk> makeChunks(size_t size) {
    const size_t bytesPerThread = 2 * 1024 * 1024;
    size_t threadCount = std::min<size_t>(std::thread::hardware_concurrency(), 8);
    threadCount = std::max<size_t>(1, std::min(threadCount, size / bytesPerThread));
    std::vector<Chunk> chunks(threadCount);
    size_t chunkSize = size / threadCount;
    for (size_t index = 0; index < threadCount; ++index) {
        chunks[index].begin = index * chunkSize;
        chunks[index].end = size;
        if (index + 1 < threadCount) {
            chunks[index].end = (index + 1) * chunkSize;
        }
    }
    return chunks;
}

template <typename Work>
void forEachChunkInParallel(std::vector<Chunk>& chunks, Work work) {
    if (chunks.size() == 1) {
        work(chunks[0]);
        return;
    }
    std::vector<std::thread> threads;
    for (Chunk& chunk : chunks) {
        threads.emplace_back([&work, &chunk]() { work(chunk); });
    }
    for (std::thread& thread : threads) {
        thread.join();
    }
}

/// Calls `found` with the position of every '\n' in the chunk, in order.
template <typename Found>
void forEachNewline(const char* data, const Chunk& chunk, Found found) {
    const char* cursor = data + chunk.begin;
    const char* stop = data + chunk.end;
    while (cursor < stop) {
        const void* match = std::memchr(cursor, '\n', static_cast<size_t>(stop - cursor));
        if (match == nullptr) {
            return;
        }
        const char* newline = static_cast<const char*>(match);
        found(static_cast<size_t>(newline - data));
        cursor = newline + 1;
    }
}

}  // namespace

LineStore LineStore::fromBytes(FileBytes&& bytes, size_t* crlfCount, size_t* lfCount) {
    const size_t size = bytes.size();
    // Offsets are 32 bits, so a file over 4 GB can't be indexed. Such a file is split into
    // strings of their own instead: slower and larger, but correct.
    if (size >= static_cast<size_t>(kOwned)) {
        return fromBytesTooBigToIndex(bytes, crlfCount, lfCount);
    }

    LineStore store;
    store.bytes_ = std::move(bytes);
    const char* data = store.bytes_.data();

    // First pass: count each chunk's lines, so the line list is allocated once at its exact
    // size and every thread knows where in it to write.
    std::vector<Chunk> chunks = makeChunks(size);
    forEachChunkInParallel(chunks, [data](Chunk& chunk) {
        forEachNewline(data, chunk, [&chunk](size_t newline) {
            ++chunk.newlineCount;
            chunk.lastNewline = newline;
        });
    });
    size_t lineCount = 0;
    size_t lineStart = 0;
    for (Chunk& chunk : chunks) {
        chunk.firstLineIndex = lineCount;
        chunk.firstLineStart = lineStart;
        lineCount += chunk.newlineCount;
        if (chunk.lastNewline) {
            lineStart = *chunk.lastNewline + 1;
        }
    }
    store.refs_.resize(lineCount + 1);

    // Second pass: every newline ends a line. The '\r' of a CRLF break stays in the file bytes
    // just past the line, which is how breakIsCRLF finds it.
    LineRef* refs = store.refs_.data();
    forEachChunkInParallel(chunks, [data, refs](Chunk& chunk) {
        size_t start = chunk.firstLineStart;
        size_t index = chunk.firstLineIndex;
        forEachNewline(data, chunk, [&](size_t newline) {
            size_t contentEnd = newline;
            if (contentEnd > start && data[contentEnd - 1] == '\r') {
                --contentEnd;
                ++chunk.crlfCount;
            }
            refs[index] = LineRef{static_cast<uint32_t>(start), static_cast<uint32_t>(contentEnd - start)};
            ++index;
            start = newline + 1;
        });
    });
    // Whatever follows the last newline is the final line.
    refs[lineCount] = LineRef{static_cast<uint32_t>(lineStart), static_cast<uint32_t>(size - lineStart)};

    size_t crlf = 0;
    for (const Chunk& chunk : chunks) {
        crlf += chunk.crlfCount;
    }
    if (crlfCount != nullptr) {
        *crlfCount = crlf;
    }
    if (lfCount != nullptr) {
        *lfCount = lineCount - crlf;
    }
    return store;
}

LineStore LineStore::fromBytesTooBigToIndex(const FileBytes& bytes, size_t* crlfCount, size_t* lfCount) {
    LineStore store;
    store.refs_.clear();
    size_t crlf = 0;
    size_t lf = 0;
    const char* data = bytes.data();
    const size_t size = bytes.size();
    Chunk whole;
    whole.end = size;

    size_t lineStart = 0;
    forEachNewline(data, whole, [&](size_t newline) {
        size_t contentEnd = newline;
        bool breakIsCRLF = contentEnd > lineStart && data[contentEnd - 1] == '\r';
        if (breakIsCRLF) {
            --contentEnd;
            ++crlf;
        } else {
            ++lf;
        }
        uint32_t slot = store.takeSlot(OwnedLine{std::string(data + lineStart, contentEnd - lineStart), breakIsCRLF});
        store.refs_.push_back(LineRef{slot, kOwned});
        lineStart = newline + 1;
    });
    uint32_t slot = store.takeSlot(OwnedLine{std::string(data + lineStart, size - lineStart), false});
    store.refs_.push_back(LineRef{slot, kOwned});

    if (crlfCount != nullptr) {
        *crlfCount = crlf;
    }
    if (lfCount != nullptr) {
        *lfCount = lf;
    }
    return store;
}

uint32_t LineStore::takeSlot(OwnedLine&& line) {
    if (!freeSlots_.empty()) {
        uint32_t slot = freeSlots_.back();
        freeSlots_.pop_back();
        owned_[slot] = std::move(line);
        return slot;
    }
    owned_.push_back(std::move(line));
    return static_cast<uint32_t>(owned_.size() - 1);
}

std::string& LineStore::edit(size_t index) {
    LineRef& ref = refs_[index];
    if (ref.length != kOwned) {
        OwnedLine copy{std::string(bytes_.data() + ref.offset, ref.length), breakIsCRLF(index)};
        uint32_t slot = takeSlot(std::move(copy));
        // takeSlot may have grown owned_, but `ref` points into refs_, which it doesn't touch.
        ref = LineRef{slot, kOwned};
    }
    return owned_[ref.offset].text;
}

void LineStore::setBreakIsCRLF(size_t index, bool crlf) {
    edit(index);
    owned_[refs_[index].offset].breakIsCRLF = crlf;
}

void LineStore::releaseRefs(size_t first, size_t last) {
    for (size_t index = first; index < last; ++index) {
        const LineRef ref = refs_[index];
        if (ref.length == kOwned) {
            std::string().swap(owned_[ref.offset].text);  // give the memory back
            freeSlots_.push_back(ref.offset);
        }
    }
}

void LineStore::insertOwned(size_t index, std::vector<OwnedLine>&& lines) {
    std::vector<LineRef> added;
    added.reserve(lines.size());
    for (OwnedLine& line : lines) {
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
        total += ref.length == kOwned ? owned_[ref.offset].text.size() : ref.length;
    }
    return total;
}

size_t LineStore::memoryBytes() const {
    size_t total = bytes_.heapBytes() + refs_.capacity() * sizeof(LineRef) + owned_.size() * sizeof(OwnedLine) +
                   freeSlots_.capacity() * sizeof(uint32_t);
    for (const OwnedLine& line : owned_) {
        if (line.text.capacity() > sizeof(std::string)) {
            total += line.text.capacity();  // heap memory beyond the string object itself
        }
    }
    return total;
}

}  // namespace gw
