#pragma once

#include <cstddef>
#include <string>
#include <string_view>
#include <vector>

namespace gw {

// A changed region of the new text -> the mark the editor gutter draws for it.
enum class LineChangeKind {
    Added,
    Modified,
    Removed,
};

/// Zero-based: `oldCount` lines at `oldStart` were replaced by `newCount` lines at `newStart`.
/// Either count may be zero (pure insertion or deletion).
struct DiffHunk {
    size_t oldStart = 0;
    size_t oldCount = 0;
    size_t newStart = 0;
    size_t newCount = 0;
};

struct LineChange {
    LineChangeKind kind = LineChangeKind::Added;
    /// For `Removed`, the line just below the deleted lines (may equal the line count).
    size_t firstLine = 0;
    /// Zero for `Removed`.
    size_t lineCount = 0;
};

// ---- Diffing

/// Myers diff after trimming the common start and end. If an exact diff would be slow, the whole
/// differing middle is reported as one replaced region.
std::vector<DiffHunk> diffLines(const std::vector<std::string_view>& oldLines,
                                const std::vector<std::string_view>& newLines);

/// Handles "\r\n" and "\n"; a trailing newline adds no empty line. Views point into `text`.
std::vector<std::string_view> splitLines(std::string_view text);

std::vector<LineChange> gutterChanges(const std::vector<DiffHunk>& hunks);

// ---- Patches

/// Unified-diff patch for `git apply`; `path` is relative to the repository root.
std::string patchForHunk(const std::string& path, const std::vector<std::string_view>& oldLines,
                         const std::vector<std::string_view>& newLines, const DiffHunk& hunk);

}  // namespace gw
