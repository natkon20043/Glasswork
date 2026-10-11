#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

namespace gw::search {

struct Query {
    std::string pattern;
    bool caseSensitive = false;
    /// "cat" finds "cat" but not "concatenate".
    bool wholeWord = false;
    /// Oniguruma / Ruby syntax.
    bool useRegex = false;
};

/// One line with a match, for a results list.
struct LineHit {
    /// From zero.
    size_t line = 0;
    /// Leading spaces removed and long lines cut.
    std::string text;
    /// (start, length) byte offsets of matches within `text`.
    std::vector<std::pair<uint32_t, uint32_t>> ranges;
    /// Byte column of the first match in the original line.
    size_t column = 0;
};

struct FileResult {
    /// Relative to the search root.
    std::string path;
    std::vector<LineHit> hits;
    /// More matching lines than are listed.
    bool truncated = false;
    size_t matchCount = 0;
};

struct SearchOptions {
    std::string root;
    /// Relative to `root`.
    std::vector<std::string> files;
    /// Comma-separated wildcards. A file is searched if it matches an include (when given) and no
    /// exclude. A pattern without "/" matches the file name; with "/", the whole relative path.
    std::string include;
    std::string exclude;
    size_t maxFileBytes = 64 * 1024 * 1024;
    size_t maxHitsPerFile = 200;
    size_t maxTotalHits = 20000;
    /// 0: one per core.
    unsigned threads = 0;
};

struct SearchSummary {
    size_t filesSearched = 0;
    size_t filesWithMatches = 0;
    size_t matchingLines = 0;
    /// Hit a limit or was cancelled.
    bool stoppedEarly = false;
    double seconds = 0;
};

/// A query compiled once and run over many texts. Thread-safe.
class Matcher {
public:
    // ---- Constructors and destructor
    explicit Matcher(const Query& query);
    ~Matcher();
    Matcher(const Matcher&) = delete;
    Matcher& operator=(const Matcher&) = delete;

    // ---- Getters
    /// False when the pattern is empty or the regex doesn't compile.
    bool valid() const { return valid_; }
    const std::string& error() const { return error_; }
    const Query& query() const { return query_; }

    // ---- Matching
    /// In order, without overlaps.
    void forEachInLine(std::string_view line, const std::function<void(size_t start, size_t length)>& found) const;
    /// Once per matching line of `data` (lines separated by "\n", counted from zero). `found` returns false to stop.
    void forEachMatchingLine(std::string_view data,
                             const std::function<bool(size_t line, size_t lineStart, size_t lineLength)>& found) const;

    // ---- Replacing
    /// Regex: "$1".."$9" are capture groups and "$&" the whole match. Otherwise used as is.
    std::string expand(std::string_view line, size_t start, size_t length, std::string_view replacement) const;
    /// `text` may span lines. `count` receives the number of replacements.
    std::string replaceAll(std::string_view text, std::string_view replacement, size_t* count = nullptr) const;

private:
    struct Implementation;

    // ---- Private variables
    Query query_;
    bool valid_ = false;
    std::string error_;
    std::unique_ptr<Implementation> implementation_;
};

/// `onFile` is called from worker threads, one at a time, for each file with matches. Set `cancel` to
/// stop early. Binary files are skipped.
SearchSummary searchFiles(const SearchOptions& options, const Matcher& matcher, const std::atomic<bool>* cancel,
                          const std::function<void(FileResult&&)>& onFile);

bool passesFilters(std::string_view path, const std::vector<std::string>& includes, const std::vector<std::string>& excludes);
/// "a, b,c" -> {"a", "b", "c"}
std::vector<std::string> splitPatterns(std::string_view text);

}  // namespace gw::search
