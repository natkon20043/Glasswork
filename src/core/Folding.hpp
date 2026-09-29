#pragma once

#include "TextBuffer.hpp"

#include <cstddef>
#include <vector>

namespace gw {

/// Code folding by indentation: a line can fold when the next non-blank line is indented
/// more than it; folding hides that block, up to (not including) the next line at the same
/// or a smaller indentation. Works for every language, including Python and YAML.

/// True if the line starts a block that can be folded.
bool isFoldable(const TextBuffer& buffer, size_t line, size_t tabSize);

/// The last line hidden when `line` is folded, or `line` itself if it can't fold.
size_t foldEnd(const TextBuffer& buffer, size_t line, size_t tabSize);

/// The blocks folded now. A fold keeps its first line visible and hides the lines after it,
/// through `last`.
struct Fold {
    size_t first = 0;
    size_t last = 0;
};

class FoldSet {
public:
    bool empty() const { return folds_.empty(); }
    const std::vector<Fold>& all() const { return folds_; }

    /// True if `line` is the visible first line of a fold.
    bool isFoldHeader(size_t line) const;
    /// True if `line` is hidden inside a fold.
    bool isHidden(size_t line) const;
    /// The fold that hides `line`, or that starts on it; null if none.
    const Fold* foldContaining(size_t line) const;

    /// Adds a fold. Folds inside it are absorbed; a fold that already covers it makes this a no-op.
    void fold(size_t first, size_t last);
    /// Removes the fold that starts on `first`.
    void unfold(size_t first);
    /// Removes every fold that hides `line` (or starts on it). Returns true if any went.
    bool unfoldContaining(size_t line);
    /// Like unfoldContaining, but a fold that only starts on `line` stays: used to reveal a
    /// line that is inside a fold without opening the fold the line heads.
    bool unfoldHiding(size_t line);
    void clear() { folds_.clear(); }

    /// Keeps folds in step with an edit that touched lines `firstLine`..`lastLine` (after the
    /// edit) and added `lineDelta` lines (negative if lines went). Folds the edit touched
    /// open up; folds below it move.
    void adjustForEdit(size_t firstLine, size_t lastLine, long lineDelta);

private:
    std::vector<Fold> folds_;  // sorted, never overlapping
};

}  // namespace gw
