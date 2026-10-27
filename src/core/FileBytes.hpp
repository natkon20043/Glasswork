#pragma once

#include <cstddef>
#include <filesystem>
#include <optional>
#include <string>

namespace gw {

/// The bytes of a file, frozen at the moment it was opened. Files are cloned (APFS copies
/// nothing until one side changes) and the private clone is memory-mapped, so other programs
/// rewriting or shortening the original can never change or crash what we hold. Tiny files,
/// and ones where a clone isn't possible (another volume, not APFS), are read instead.
class FileBytes {
public:
    /// Mapping takes a fifth of the memory of reading (1 MB file: 0.26 MB instead of 1.3 MB) and
    /// costs about 0.2 ms more to set up. Below this size the saving is only a few kilobytes.
    static constexpr size_t kSmallestMappedFile = 64 * 1024;

    // ---- Constructors
    FileBytes() = default;
    explicit FileBytes(std::string&& text);
    FileBytes(FileBytes&& other) noexcept;
    FileBytes& operator=(FileBytes&& other) noexcept;
    FileBytes(const FileBytes&) = delete;
    FileBytes& operator=(const FileBytes&) = delete;
    static std::optional<FileBytes> load(const std::filesystem::path& path, size_t smallestMappedFile = kSmallestMappedFile);

    // ---- Destructor
    ~FileBytes();

    // ---- Getters
    const char* data() const {
        if (mapping_ != nullptr) {
            return static_cast<const char*>(mapping_);
        }
        return owned_.data();
    }
    size_t size() const {
        if (mapping_ != nullptr) {
            return mappingSize_;
        }
        return owned_.size();
    }
    bool isMapped() const { return mapping_ != nullptr; }
    /// Memory we allocated. Mapped pages belong to the file and macOS can drop them under pressure.
    size_t heapBytes() const { return owned_.capacity(); }

private:
    // ---- Private functions
    void release();

    // ---- Private variables
    std::string owned_;
    void* mapping_ = nullptr;
    size_t mappingSize_ = 0;
};

}  // namespace gw
