#include "ProjectSearch.hpp"

#include <oniguruma.h>

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cstring>
#include <fcntl.h>
#include <fnmatch.h>
#include <mutex>
#include <sys/mman.h>
#include <sys/stat.h>
#include <thread>
#include <unistd.h>

namespace gw::search {

namespace {

// ---------------------------------------------------------------------------
// Small helpers

bool isWordCharacter(unsigned char c) {
    return std::isalnum(c) != 0 || c == '_' || c >= 0x80;
}

unsigned char foldCase(unsigned char c) {
    if (c >= 'A' && c <= 'Z') {
        return static_cast<unsigned char>(c - 'A' + 'a');
    }
    return c;
}

/// Roughly how common each byte is in source code (0 = very common). Searching starts from the
/// rarest byte of the pattern, which lets memchr skip almost everything.
int commonness(unsigned char c) {
    static const char* order = " etaoinsrhldcumfpgwybvkxjqz_(){}.;=/*\n\t,\"'<>:0123456789-+&|!";
    static int table[256];
    static bool ready = false;
    if (!ready) {
        for (int& value : table) {
            value = 1000;
        }
        int rank = 0;
        for (const char* p = order; *p != '\0'; ++p) {
            unsigned char lower = static_cast<unsigned char>(*p);
            table[lower] = rank;
            unsigned char upper = lower;
            if (lower >= 'a' && lower <= 'z') {
                upper = static_cast<unsigned char>(lower - 'a' + 'A');
                table[upper] = rank + 12;  // capitals are rarer than their lower-case forms
            }
            ++rank;
        }
        ready = true;
    }
    return table[c];
}

/// The start of the line containing `position`.
size_t lineStartBefore(const char* data, size_t position) {
    while (position > 0 && data[position - 1] != '\n') {
        --position;
    }
    return position;
}

size_t lineEndAfter(const char* data, size_t size, size_t position) {
    const void* newline = position < size ? std::memchr(data + position, '\n', size - position) : nullptr;
    return newline == nullptr ? size : static_cast<size_t>(static_cast<const char*>(newline) - data);
}

}  // namespace

// ---------------------------------------------------------------------------
// Matcher

struct Matcher::Implementation {
    // ---- literal search
    std::string needle;  // lower-cased when the search ignores case
    bool caseSensitive = true;
    size_t rarestIndex = 0;
    bool useMemchr = true;
    size_t skip[256];  // Horspool skip distances, for case-insensitive search

    // ---- regular expression search
    regex_t* regex = nullptr;

    ~Implementation() {
        if (regex != nullptr) {
            onig_free(regex);
        }
    }

    bool isRegex() const { return regex != nullptr; }

    /// The first occurrence of the needle at or after `from`, or npos.
    size_t findLiteral(const char* data, size_t size, size_t from) const {
        const size_t length = needle.size();
        if (length == 0 || size < length || from > size - length) {
            return std::string::npos;
        }
        if (useMemchr) {
            const unsigned char anchor = static_cast<unsigned char>(needle[rarestIndex]);
            size_t start = from;
            while (start + length <= size) {
                size_t remaining = size - length + 1 - start;
                const void* hit = std::memchr(data + start + rarestIndex, anchor, remaining);
                if (hit == nullptr) {
                    return std::string::npos;
                }
                size_t candidate = static_cast<size_t>(static_cast<const char*>(hit) - data) - rarestIndex;
                if (std::memcmp(data + candidate, needle.data(), length) == 0) {
                    return candidate;
                }
                start = candidate + 1;
            }
            return std::string::npos;
        }

        // Case-insensitive: Horspool with the text folded on the fly.
        size_t position = from;
        const unsigned char last = static_cast<unsigned char>(needle[length - 1]);
        while (position + length <= size) {
            unsigned char tail = foldCase(static_cast<unsigned char>(data[position + length - 1]));
            if (tail == last) {
                size_t index = 0;
                while (index + 1 < length && foldCase(static_cast<unsigned char>(data[position + index])) ==
                                                 static_cast<unsigned char>(needle[index])) {
                    ++index;
                }
                if (index + 1 == length) {
                    return position;
                }
            }
            position += skip[tail];
        }
        return std::string::npos;
    }
};

Matcher::Matcher(const Query& query) : query_(query), implementation_(std::make_unique<Implementation>()) {
    if (query.pattern.empty()) {
        error_ = "Nothing to search for.";
        return;
    }
    Implementation& impl = *implementation_;

    if (query.useRegex) {
        static std::once_flag once;
        std::call_once(once, [] {
            OnigEncoding encodings[] = {ONIG_ENCODING_UTF8};
            onig_initialize(encodings, 1);
        });
        std::string source = query.pattern;
        if (query.wholeWord) {
            source = "(?<!\\w)(?:" + source + ")(?!\\w)";
        }
        OnigOptionType options = ONIG_OPTION_CAPTURE_GROUP;
        if (!query.caseSensitive) {
            options |= ONIG_OPTION_IGNORECASE;
        }
        OnigErrorInfo info;
        auto* begin = reinterpret_cast<const OnigUChar*>(source.data());
        int result = onig_new(&impl.regex, begin, begin + source.size(), options, ONIG_ENCODING_UTF8, ONIG_SYNTAX_RUBY, &info);
        if (result != ONIG_NORMAL) {
            OnigUChar message[ONIG_MAX_ERROR_MESSAGE_LEN];
            onig_error_code_to_str(message, result, &info);
            error_ = reinterpret_cast<const char*>(message);
            impl.regex = nullptr;
            return;
        }
        valid_ = true;
        return;
    }

    impl.caseSensitive = query.caseSensitive;
    impl.needle = query.pattern;
    if (!query.caseSensitive) {
        for (char& c : impl.needle) {
            c = static_cast<char>(foldCase(static_cast<unsigned char>(c)));
        }
    }

    // Pick the rarest byte to search for. Case-insensitive searches can only use memchr when
    // that byte has no other case.
    size_t rarest = 0;
    for (size_t index = 1; index < impl.needle.size(); ++index) {
        if (commonness(static_cast<unsigned char>(impl.needle[index])) > commonness(static_cast<unsigned char>(impl.needle[rarest]))) {
            rarest = index;
        }
    }
    impl.rarestIndex = rarest;
    unsigned char rarestByte = static_cast<unsigned char>(impl.needle[rarest]);
    bool hasOtherCase = std::isalpha(rarestByte) != 0;
    impl.useMemchr = query.caseSensitive || !hasOtherCase;

    // Horspool skip table.
    for (size_t& value : impl.skip) {
        value = impl.needle.size();
    }
    for (size_t index = 0; index + 1 < impl.needle.size(); ++index) {
        impl.skip[static_cast<unsigned char>(impl.needle[index])] = impl.needle.size() - 1 - index;
    }
    valid_ = true;
}

Matcher::~Matcher() = default;

void Matcher::forEachInLine(std::string_view line, const std::function<void(size_t, size_t)>& found) const {
    if (!valid_) {
        return;
    }
    const Implementation& impl = *implementation_;

    if (impl.isRegex()) {
        OnigRegion* region = onig_region_new();
        const OnigUChar* begin = reinterpret_cast<const OnigUChar*>(line.data());
        const OnigUChar* end = begin + line.size();
        size_t position = 0;
        while (position <= line.size()) {
            int result = onig_search(impl.regex, begin, end, begin + position, end, region, ONIG_OPTION_NONE);
            if (result < 0) {
                break;
            }
            size_t start = static_cast<size_t>(region->beg[0]);
            size_t stop = static_cast<size_t>(region->end[0]);
            if (stop == start) {
                position = start + 1;  // empty matches aren't useful here
                continue;
            }
            found(start, stop - start);
            position = stop;
        }
        onig_region_free(region, 1);
        return;
    }

    size_t position = 0;
    const size_t length = impl.needle.size();
    while (true) {
        size_t hit = impl.findLiteral(line.data(), line.size(), position);
        if (hit == std::string::npos) {
            return;
        }
        bool wordStart = hit == 0 || !isWordCharacter(static_cast<unsigned char>(line[hit - 1]));
        bool wordEnd = hit + length >= line.size() || !isWordCharacter(static_cast<unsigned char>(line[hit + length]));
        if (!query_.wholeWord || (wordStart && wordEnd)) {
            found(hit, length);
            position = hit + length;
        } else {
            position = hit + 1;
        }
    }
}

void Matcher::forEachMatchingLine(std::string_view data,
                                  const std::function<bool(size_t, size_t, size_t)>& found) const {
    if (!valid_) {
        return;
    }
    const Implementation& impl = *implementation_;
    const char* bytes = data.data();
    const size_t size = data.size();

    // Line numbers are counted lazily: only the newlines between one hit and the next.
    size_t countedTo = 0;
    size_t lineNumber = 0;
    auto lineNumberAt = [&](size_t lineStart) {
        for (size_t index = countedTo; index < lineStart;) {
            const void* newline = std::memchr(bytes + index, '\n', lineStart - index);
            if (newline == nullptr) {
                break;
            }
            ++lineNumber;
            index = static_cast<size_t>(static_cast<const char*>(newline) - bytes) + 1;
        }
        countedTo = lineStart;
        return lineNumber;
    };

    if (impl.isRegex()) {
        OnigRegion* region = onig_region_new();
        const OnigUChar* begin = reinterpret_cast<const OnigUChar*>(bytes);
        const OnigUChar* end = begin + size;
        size_t position = 0;
        while (position <= size) {
            int result = onig_search(impl.regex, begin, end, begin + position, end, region, ONIG_OPTION_NONE);
            if (result < 0) {
                break;
            }
            size_t start = static_cast<size_t>(region->beg[0]);
            if (region->end[0] == region->beg[0]) {
                position = start + 1;
                continue;
            }
            size_t lineStart = lineStartBefore(bytes, start);
            size_t lineEnd = lineEndAfter(bytes, size, start);
            if (!found(lineNumberAt(lineStart), lineStart, lineEnd - lineStart)) {
                break;
            }
            position = lineEnd + 1;
        }
        onig_region_free(region, 1);
        return;
    }

    size_t position = 0;
    const size_t length = impl.needle.size();
    while (position < size) {
        size_t hit = impl.findLiteral(bytes, size, position);
        if (hit == std::string::npos) {
            return;
        }
        if (query_.wholeWord) {
            bool wordStart = hit == 0 || !isWordCharacter(static_cast<unsigned char>(bytes[hit - 1]));
            bool wordEnd = hit + length >= size || !isWordCharacter(static_cast<unsigned char>(bytes[hit + length]));
            if (!wordStart || !wordEnd) {
                position = hit + 1;
                continue;
            }
        }
        size_t lineStart = lineStartBefore(bytes, hit);
        size_t lineEnd = lineEndAfter(bytes, size, hit);
        if (!found(lineNumberAt(lineStart), lineStart, lineEnd - lineStart)) {
            return;
        }
        position = lineEnd + 1;
    }
}

std::string Matcher::expand(std::string_view line, size_t start, size_t length, std::string_view replacement) const {
    if (!valid_ || !implementation_->isRegex()) {
        return std::string(replacement);
    }
    // Run the pattern again at exactly this spot to get its capture groups.
    OnigRegion* region = onig_region_new();
    const OnigUChar* begin = reinterpret_cast<const OnigUChar*>(line.data());
    const OnigUChar* end = begin + line.size();
    int result = onig_match(implementation_->regex, begin, end, begin + start, region, ONIG_OPTION_NONE);

    std::string output;
    for (size_t index = 0; index < replacement.size(); ++index) {
        char c = replacement[index];
        if (c != '$' || index + 1 >= replacement.size()) {
            output += c;
            continue;
        }
        char next = replacement[index + 1];
        if (next == '$') {
            output += '$';
            ++index;
        } else if (next == '&') {
            output.append(line.substr(start, length));
            ++index;
        } else if (next >= '0' && next <= '9') {
            int group = next - '0';
            if (result >= 0 && group < region->num_regs && region->beg[group] >= 0) {
                output.append(line.substr(static_cast<size_t>(region->beg[group]),
                                          static_cast<size_t>(region->end[group] - region->beg[group])));
            }
            ++index;
        } else {
            output += c;
        }
    }
    onig_region_free(region, 1);
    return output;
}

std::string Matcher::replaceAll(std::string_view text, std::string_view replacement, size_t* count) const {
    size_t replaced = 0;
    std::string output;
    output.reserve(text.size());
    size_t lineStart = 0;
    while (lineStart <= text.size()) {
        size_t newline = text.find('\n', lineStart);
        size_t lineEnd = newline == std::string_view::npos ? text.size() : newline;
        std::string_view line = text.substr(lineStart, lineEnd - lineStart);

        size_t copied = 0;
        forEachInLine(line, [&](size_t start, size_t length) {
            output.append(line.substr(copied, start - copied));
            output += expand(line, start, length, replacement);
            copied = start + length;
            ++replaced;
        });
        output.append(line.substr(copied));

        if (newline == std::string_view::npos) {
            break;
        }
        output += '\n';
        lineStart = newline + 1;
    }
    if (count != nullptr) {
        *count = replaced;
    }
    return output;
}

// ---------------------------------------------------------------------------
// Filters

std::vector<std::string> splitPatterns(std::string_view text) {
    std::vector<std::string> patterns;
    size_t start = 0;
    while (start <= text.size()) {
        size_t comma = text.find(',', start);
        size_t end = comma == std::string_view::npos ? text.size() : comma;
        std::string_view piece = text.substr(start, end - start);
        while (!piece.empty() && piece.front() == ' ') {
            piece.remove_prefix(1);
        }
        while (!piece.empty() && piece.back() == ' ') {
            piece.remove_suffix(1);
        }
        if (!piece.empty()) {
            patterns.emplace_back(piece);
        }
        if (comma == std::string_view::npos) {
            break;
        }
        start = comma + 1;
    }
    return patterns;
}

namespace {

bool matchesPattern(std::string_view path, const std::string& pattern) {
    std::string glob = pattern;
    // "src/" or "src" folder shorthand: everything below it.
    if (!glob.empty() && glob.back() == '/') {
        glob += "**";
    }
    bool hasSlash = glob.find('/') != std::string::npos;
    std::string_view subject = path;
    if (!hasSlash) {
        size_t slash = path.rfind('/');
        subject = slash == std::string_view::npos ? path : path.substr(slash + 1);
    }
    std::string subjectText(subject);
    if (fnmatch(glob.c_str(), subjectText.c_str(), 0) == 0) {
        return true;
    }
    // A bare folder name ("build", "node_modules") excludes that folder wherever it is.
    if (!hasSlash && glob.find_first_of("*?[") == std::string::npos) {
        std::string folder = "/" + glob + "/";
        std::string wrapped = "/" + std::string(path);
        return wrapped.find(folder) != std::string::npos;
    }
    if (hasSlash && glob.find_first_of("*?[") == std::string::npos) {
        return path.substr(0, glob.size()) == glob && (path.size() == glob.size() || path[glob.size()] == '/');
    }
    return false;
}

}  // namespace

bool passesFilters(std::string_view path, const std::vector<std::string>& includes, const std::vector<std::string>& excludes) {
    if (!includes.empty()) {
        bool any = false;
        for (const std::string& pattern : includes) {
            if (matchesPattern(path, pattern)) {
                any = true;
                break;
            }
        }
        if (!any) {
            return false;
        }
    }
    for (const std::string& pattern : excludes) {
        if (matchesPattern(path, pattern)) {
            return false;
        }
    }
    return true;
}

// ---------------------------------------------------------------------------
// Searching files

namespace {

/// A view of a file's bytes, either read into a reusable buffer (small files) or mapped.
class FileBytes {
public:
    ~FileBytes() { release(); }

    /// Opens `path`. Returns false if it can't be read or is empty.
    bool open(const std::string& path, size_t maxBytes, std::vector<char>& scratch) {
        release();
        int descriptor = ::open(path.c_str(), O_RDONLY);
        if (descriptor < 0) {
            return false;
        }
        struct stat info;
        if (fstat(descriptor, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size <= 0 ||
            static_cast<size_t>(info.st_size) > maxBytes) {
            ::close(descriptor);
            return false;
        }
        size_ = static_cast<size_t>(info.st_size);
        if (size_ <= 256 * 1024) {
            if (scratch.size() < size_) {
                scratch.resize(std::max<size_t>(size_, 64 * 1024));
            }
            size_t total = 0;
            while (total < size_) {
                ssize_t count = ::read(descriptor, scratch.data() + total, size_ - total);
                if (count <= 0) {
                    break;
                }
                total += static_cast<size_t>(count);
            }
            ::close(descriptor);
            size_ = total;
            data_ = scratch.data();
            return size_ > 0;
        }
        void* mapped = mmap(nullptr, size_, PROT_READ, MAP_PRIVATE, descriptor, 0);
        ::close(descriptor);
        if (mapped == MAP_FAILED) {
            return false;
        }
        madvise(mapped, size_, MADV_SEQUENTIAL);
        mapping_ = mapped;
        data_ = static_cast<const char*>(mapped);
        return true;
    }

    const char* data() const { return data_; }
    size_t size() const { return size_; }

private:
    void release() {
        if (mapping_ != nullptr) {
            munmap(mapping_, size_);
        }
        mapping_ = nullptr;
        data_ = nullptr;
        size_ = 0;
    }

    void* mapping_ = nullptr;
    const char* data_ = nullptr;
    size_t size_ = 0;
};

/// Text files don't have NUL bytes; binary ones almost always do near the start.
bool looksBinary(const char* data, size_t size) {
    size_t check = std::min<size_t>(size, 8192);
    return std::memchr(data, '\0', check) != nullptr;
}

size_t floorToCharacter(std::string_view text, size_t position) {
    while (position > 0 && position < text.size() && (static_cast<unsigned char>(text[position]) & 0xC0) == 0x80) {
        --position;
    }
    return position;
}

/// Builds the list entry for one matching line: trimmed, cut to a sensible length, with the
/// match positions inside it.
LineHit makeHit(const Matcher& matcher, size_t lineNumber, std::string_view line) {
    LineHit hit;
    hit.line = lineNumber;

    if (!line.empty() && line.back() == '\r') {
        line.remove_suffix(1);
    }
    std::vector<std::pair<size_t, size_t>> matches;
    matcher.forEachInLine(line, [&matches](size_t start, size_t length) { matches.emplace_back(start, length); });
    hit.column = matches.empty() ? 0 : matches.front().first;

    size_t begin = 0;
    while (begin < line.size() && (line[begin] == ' ' || line[begin] == '\t')) {
        ++begin;
    }
    const size_t window = 240;
    bool cutStart = false;
    if (!matches.empty() && matches.front().first > begin + window - 60) {
        begin = floorToCharacter(line, matches.front().first - 40);
        cutStart = true;
    }
    size_t end = std::min(line.size(), begin + window);
    end = floorToCharacter(line, end);
    bool cutEnd = end < line.size();

    std::string prefix = cutStart ? "…" : "";
    hit.text = prefix + std::string(line.substr(begin, end - begin)) + (cutEnd ? "…" : "");
    for (const auto& [start, length] : matches) {
        if (start < begin || start >= end) {
            continue;
        }
        size_t clipped = std::min(length, end - start);
        hit.ranges.emplace_back(static_cast<uint32_t>(start - begin + prefix.size()), static_cast<uint32_t>(clipped));
    }
    return hit;
}

}  // namespace

SearchSummary searchFiles(const SearchOptions& options, const Matcher& matcher, const std::atomic<bool>* cancel,
                          const std::function<void(FileResult&&)>& onFile) {
    auto begin = std::chrono::steady_clock::now();
    SearchSummary summary;
    if (!matcher.valid()) {
        return summary;
    }

    std::vector<std::string> includes = splitPatterns(options.include);
    std::vector<std::string> excludes = splitPatterns(options.exclude);
    std::vector<const std::string*> files;
    files.reserve(options.files.size());
    for (const std::string& path : options.files) {
        if (passesFilters(path, includes, excludes)) {
            files.push_back(&path);
        }
    }

    std::atomic<size_t> nextFile{0};
    std::atomic<size_t> searched{0};
    std::atomic<size_t> withMatches{0};
    std::atomic<size_t> totalHits{0};
    std::atomic<bool> stop{false};
    std::mutex resultMutex;

    auto worker = [&]() {
        std::vector<char> scratch;
        FileBytes bytes;
        while (!stop.load(std::memory_order_relaxed)) {
            if (cancel != nullptr && cancel->load(std::memory_order_relaxed)) {
                stop.store(true);
                break;
            }
            size_t index = nextFile.fetch_add(1, std::memory_order_relaxed);
            if (index >= files.size()) {
                break;
            }
            const std::string& relative = *files[index];
            std::string full = options.root.empty() ? relative : options.root + "/" + relative;
            if (!bytes.open(full, options.maxFileBytes, scratch)) {
                continue;
            }
            searched.fetch_add(1, std::memory_order_relaxed);
            if (looksBinary(bytes.data(), bytes.size())) {
                continue;
            }

            FileResult result;
            result.path = relative;
            std::string_view data(bytes.data(), bytes.size());
            matcher.forEachMatchingLine(data, [&](size_t lineNumber, size_t lineStart, size_t lineLength) {
                ++result.matchCount;
                if (result.hits.size() >= options.maxHitsPerFile) {
                    result.truncated = true;
                    return true;  // keep counting lines, but stop building previews
                }
                result.hits.push_back(makeHit(matcher, lineNumber, data.substr(lineStart, lineLength)));
                return true;
            });
            if (result.matchCount == 0) {
                continue;
            }
            withMatches.fetch_add(1, std::memory_order_relaxed);
            size_t total = totalHits.fetch_add(result.matchCount, std::memory_order_relaxed) + result.matchCount;
            if (total >= options.maxTotalHits) {
                stop.store(true);
            }
            std::lock_guard<std::mutex> lock(resultMutex);
            onFile(std::move(result));
        }
    };

    unsigned threadCount = options.threads;
    if (threadCount == 0) {
        threadCount = std::max(1u, std::thread::hardware_concurrency());
    }
    threadCount = static_cast<unsigned>(std::min<size_t>(threadCount, std::max<size_t>(1, files.size() / 8 + 1)));
    std::vector<std::thread> threads;
    for (unsigned index = 1; index < threadCount; ++index) {
        threads.emplace_back(worker);
    }
    worker();
    for (std::thread& thread : threads) {
        thread.join();
    }

    summary.filesSearched = searched.load();
    summary.filesWithMatches = withMatches.load();
    summary.matchingLines = totalHits.load();
    summary.stoppedEarly = stop.load();
    summary.seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - begin).count();
    return summary;
}

}  // namespace gw::search
