#include "FileBytes.hpp"

#include <atomic>
#include <fcntl.h>
#include <sys/clonefile.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

namespace gw {

namespace {

bool readAll(int descriptor, size_t size, std::string& contents) {
    contents.resize(size);
    size_t total = 0;
    while (total < size) {
        ssize_t count = ::read(descriptor, contents.data() + total, size - total);
        if (count < 0) {
            return false;
        }
        if (count == 0) {
            break;  // the file got shorter since we measured it
        }
        total += static_cast<size_t>(count);
    }
    contents.resize(total);
    return true;
}

/// A name in the temporary folder that nothing else uses.
std::filesystem::path uniqueClonePath() {
    static std::atomic<unsigned> counter{0};
    std::error_code error;
    std::filesystem::path folder = std::filesystem::temp_directory_path(error);
    std::string name = "glasswork-open-" + std::to_string(getpid()) + "-" + std::to_string(counter++);
    return folder / name;
}

/// Clones the open file and maps the clone. The clone is unlinked right away: the mapping keeps
/// it alive, and nothing is left behind if we crash. Returns nullptr if any step fails.
void* mapPrivateClone(int descriptor, size_t size) {
    std::filesystem::path clonePath = uniqueClonePath();
    if (fclonefileat(descriptor, AT_FDCWD, clonePath.c_str(), 0) != 0) {
        return nullptr;
    }
    int cloneDescriptor = ::open(clonePath.c_str(), O_RDONLY);
    ::unlink(clonePath.c_str());
    if (cloneDescriptor < 0) {
        return nullptr;
    }

    // The clone is a snapshot, so its size is final; use it rather than the earlier stat.
    struct stat info;
    bool sameSize = fstat(cloneDescriptor, &info) == 0 && static_cast<size_t>(info.st_size) == size;
    void* mapped = MAP_FAILED;
    if (sameSize) {
        mapped = mmap(nullptr, size, PROT_READ, MAP_PRIVATE, cloneDescriptor, 0);
        if (mapped != MAP_FAILED) {
            madvise(mapped, size, MADV_WILLNEED);
        }
    }
    ::close(cloneDescriptor);
    if (mapped == MAP_FAILED) {
        return nullptr;
    }
    return mapped;
}

}  // namespace

FileBytes::FileBytes(std::string&& text) : owned_(std::move(text)) {}

FileBytes::FileBytes(FileBytes&& other) noexcept
    : owned_(std::move(other.owned_)), mapping_(other.mapping_), mappingSize_(other.mappingSize_) {
    other.mapping_ = nullptr;
    other.mappingSize_ = 0;
}

FileBytes& FileBytes::operator=(FileBytes&& other) noexcept {
    if (this != &other) {
        release();
        owned_ = std::move(other.owned_);
        mapping_ = other.mapping_;
        mappingSize_ = other.mappingSize_;
        other.mapping_ = nullptr;
        other.mappingSize_ = 0;
    }
    return *this;
}

FileBytes::~FileBytes() {
    release();
}

void FileBytes::release() {
    if (mapping_ != nullptr) {
        munmap(mapping_, mappingSize_);
    }
    mapping_ = nullptr;
    mappingSize_ = 0;
    owned_.clear();
}

std::optional<FileBytes> FileBytes::load(const std::filesystem::path& path, size_t smallestMappedFile) {
    int descriptor = ::open(path.c_str(), O_RDONLY);
    if (descriptor < 0) {
        return std::nullopt;
    }
    struct stat info;
    if (fstat(descriptor, &info) != 0) {
        ::close(descriptor);
        return std::nullopt;
    }
    size_t size = static_cast<size_t>(info.st_size);

    FileBytes bytes;
    bool regularFile = S_ISREG(info.st_mode);
    if (regularFile && size >= smallestMappedFile) {
        void* mapped = mapPrivateClone(descriptor, size);
        if (mapped != nullptr) {
            ::close(descriptor);
            bytes.mapping_ = mapped;
            bytes.mappingSize_ = size;
            return bytes;
        }
    }

    bool read = readAll(descriptor, size, bytes.owned_);
    ::close(descriptor);
    if (!read) {
        return std::nullopt;
    }
    return bytes;
}

}  // namespace gw
