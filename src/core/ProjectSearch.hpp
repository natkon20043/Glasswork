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

/// What to look for.
struct Query {
    std::string pattern;
    bool caseSensitive = false;
    /// Only match whole words: "cat" finds "cat" but not "concatenate".
    bool wholeWord = false;
    /// Read the pattern as a regular expression (Oniguruma / Ruby syntax).
    bool useRegex = false;
};

/// Compiles a query once so it can be run over many texts quickly. Safe to use from several
/// threads at the same time.
class Matcher {
public:
    explicit Matcher(const Query& query);
    ~Matcher();
    Matcher(const Matcher&) = delete;
    Matcher& operator=(const Matcher&) = delete;

    /// False when the pattern is empty or (for a regular expression) doesn't compile.
    bool valid() const { return valid_; }
    const std::string& error() const { return error_; }
    const Query& query() const { return query_; }

    /// Calls `found` for every match inside one line, in order, without overlaps.
    void forEachInLine(std::string_view line, const std::function<void(size_t start, size_t length)>& found) const;

    /// Calls `found` for each line of `data` that contains a match (once per line, however
    /// many matches it has). Stops early when `found` returns false. Line numbers count
    /// from zero. `data` may hold many lines separated by "\n".
    void forEachMatchingLine(std::string_view data,
                             const std::function<bool(size_t line, size_t lineStart, size_t lineLength)>& found) const;

    /// The text that replaces one match. For a regular expression, "$1" … "$9" stand for
    /// capture groups and "$&" for the whole match; otherwise the text is used as it is.
    std::string expand(std::string_view line, size_t start, size_t length, std::string_view replacement) const;

    /// Replaces every match in `text` (which may span lines). Returns the new text and, if
    /// asked, how many replacements were made.
    std::string replaceAll(std::string_view text, std::string_view replacement, size_t* count = nullptr) const;

private:
    struct Implementation;
    Query query_;
    bool valid_ = false;
    std::string error_;
    std::unique_ptr<Implementation> implementation_;
};

/// One line with a match, for showing in a results list.
struct LineHit {
    size_t line = 0;  // from zero
    /// The line's text with leading spaces removed and long lines cut, and where the
    /// matches are within that text (byte offsets).
    std::string text;
    std::vector<std::pair<uint32_t, uint32_t>> ranges;  // (start, length)
    /// Byte column of the first match in the original line, for jumping to it.
    size_t column = 0;
};

struct FileResult {
    std::string path;  // relative to the search root
    std::vector<LineHit> hits;
    /// True if the file had more matching lines than are listed.
    bool truncated = false;
    size_t matchCount = 0;
};

struct SearchOptions {
    std::string root;
    /// Files to search, relative to `root`.
    std::vector<std::string> files;
    /// Comma-separated wildcard patterns; a file is searched only if it matches one of the
    /// "include" patterns (when given) and none of the "exclude" ones. A pattern without "/"
    /// is compared with the file name, one with "/" with the whole relative path.
    std::string include;
    std::string exclude;
    /// Files larger than this are skipped.
    size_t maxFileBytes = 64 * 1024 * 1024;
    size_t maxHitsPerFile = 200;
    /// Stop after this many matching lines in total.
    size_t maxTotalHits = 20000;
    /// Number of threads; 0 means one per core.
    unsigned threads = 0;
};

struct SearchSummary {
    size_t filesSearched = 0;
    size_t filesWithMatches = 0;
    size_t matchingLines = 0;
    bool stoppedEarly = false;  // hit the limit or was cancelled
    double seconds = 0;
};

/// Searches many files at once. `onFile` is called (from worker threads, one call at a time)
/// for every file that has matches. Set `cancel` to stop early. Binary files are skipped.
SearchSummary searchFiles(const SearchOptions& options, const Matcher& matcher, const std::atomic<bool>* cancel,
                          const std::function<void(FileResult&&)>& onFile);

/// True if `path` passes the include and exclude patterns.
bool passesFilters(std::string_view path, const std::vector<std::string>& includes, const std::vector<std::string>& excludes);
/// Splits "a, b,c" into {"a", "b", "c"}.
std::vector<std::string> splitPatterns(std::string_view text);

}  // namespace gw::search
