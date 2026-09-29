#pragma once

#include <cstddef>
#include <string>
#include <string_view>
#include <vector>

namespace gw {

/// One contiguous difference between two versions of a text. Lines are counted from zero.
/// `oldCount` lines starting at `oldStart` in the old text were replaced by `newCount`
/// lines starting at `newStart` in the new text. Either count may be zero (a pure
/// insertion or a pure deletion).
struct DiffHunk {
    size_t oldStart = 0;
    size_t oldCount = 0;
    size_t newStart = 0;
    size_t newCount = 0;
};

/// How the editor's gutter marks a changed region of the new text.
enum class LineChangeKind {
    Added,     // new lines that have no counterpart in the old text
    Modified,  // lines that replace old lines
    Removed,   // old lines were deleted here (a marker between two lines)
};

struct LineChange {
    LineChangeKind kind = LineChangeKind::Added;
    /// First affected line of the new text. For `Removed` this is the line just below the
    /// deleted lines (which may equal the line count when the end of the file was deleted).
    size_t firstLine = 0;
    /// Number of lines in the new text that are marked. Zero for `Removed`.
    size_t lineCount = 0;
};

/// Compares two texts line by line and returns the differing regions in order. Uses the
/// Myers diff after trimming the common start and end, so small edits to big files are
/// cheap. If the two texts differ so much that an exact diff would be slow, the whole
/// differing middle is reported as one replaced region.
std::vector<DiffHunk> diffLines(const std::vector<std::string_view>& oldLines,
                                const std::vector<std::string_view>& newLines);

/// Splits text into lines (without their line endings; "\r\n" and "\n" both count). The
/// views point into `text`, which must outlive them. A trailing newline does not create
/// an extra empty line, so "a\nb\n" has two lines.
std::vector<std::string_view> splitLines(std::string_view text);

/// Turns hunks into the marks the gutter draws.
std::vector<LineChange> gutterChanges(const std::vector<DiffHunk>& hunks);

/// Builds a unified-diff patch for one hunk, suitable for `git apply` (used to stage or
/// revert a single hunk). `path` is relative to the repository root.
std::string patchForHunk(const std::string& path, const std::vector<std::string_view>& oldLines,
                         const std::vector<std::string_view>& newLines, const DiffHunk& hunk);

}  // namespace gw
