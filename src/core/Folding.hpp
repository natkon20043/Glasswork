#pragma once

#include "TextBuffer.hpp"

#include <cstddef>
#include <vector>

namespace gw {

/// Folding is by indentation: a line folds when the next non-blank line is indented more, hiding
/// the block up to (not including) the next line at the same or smaller indentation.

/// A fold keeps `first` visible and hides the lines after it through `last`.
struct Fold {
    size_t first = 0;
    size_t last = 0;
};

bool isFoldable(const TextBuffer& buffer, size_t line, size_t tabSize);

/// Last line hidden when `line` folds, or `line` itself if it can't.
size_t foldEnd(const TextBuffer& buffer, size_t line, size_t tabSize);

class FoldSet {
public:
    // ---- Folding
    /// Folds inside the new one are absorbed; if one already covers it, nothing happens.
    void fold(size_t first, size_t last);
    void unfold(size_t first);
    /// Removes every fold hiding or starting on `line`. Returns true if any went.
    bool unfoldContaining(size_t line);
    /// Like unfoldContaining, but a fold that only starts on `line` stays.
    bool unfoldHiding(size_t line);
    void clear() { folds_.clear(); }

    // ---- Edits
    /// Folds the edit touched open up; folds below it move by `lineDelta`.
    void adjustForEdit(size_t firstLine, size_t lastLine, long lineDelta);

    // ---- Getters
    bool empty() const { return folds_.empty(); }
    const std::vector<Fold>& all() const { return folds_; }
    bool isFoldHeader(size_t line) const;
    bool isHidden(size_t line) const;
    /// The fold hiding or starting on `line`, or null.
    const Fold* foldContaining(size_t line) const;

private:
    // ---- Private variables
    // Sorted, never overlapping.
    std::vector<Fold> folds_;
};

}  // namespace gw
