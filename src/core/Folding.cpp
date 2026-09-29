#include "Folding.hpp"

#include <algorithm>

namespace gw {

namespace {

constexpr size_t kBlankLookAhead = 500;

/// Indentation of a line in columns, or -1 if the line is blank.
long indentOf(const TextBuffer& buffer, size_t line, size_t tabSize) {
    const std::string& text = buffer.line(line);
    size_t column = 0;
    for (char character : text) {
        if (character == ' ') {
            ++column;
        } else if (character == '\t') {
            column += tabSize - (column % tabSize);
        } else {
            return static_cast<long>(column);
        }
    }
    return -1;
}

}  // namespace

bool isFoldable(const TextBuffer& buffer, size_t line, size_t tabSize) {
    long indent = indentOf(buffer, line, tabSize);
    if (indent < 0) {
        return false;
    }
    size_t limit = std::min(buffer.lineCount(), line + 1 + kBlankLookAhead);
    for (size_t next = line + 1; next < limit; ++next) {
        long nextIndent = indentOf(buffer, next, tabSize);
        if (nextIndent < 0) {
            continue;
        }
        return nextIndent > indent;
    }
    return false;
}

size_t foldEnd(const TextBuffer& buffer, size_t line, size_t tabSize) {
    long indent = indentOf(buffer, line, tabSize);
    if (indent < 0) {
        return line;
    }
    size_t last = line;
    for (size_t next = line + 1; next < buffer.lineCount(); ++next) {
        long nextIndent = indentOf(buffer, next, tabSize);
        if (nextIndent < 0) {
            continue;  // blank lines inside the block are hidden with it
        }
        if (nextIndent <= indent) {
            break;
        }
        last = next;
    }
    return last;
}

bool FoldSet::isFoldHeader(size_t line) const {
    auto found = std::lower_bound(folds_.begin(), folds_.end(), line,
                                  [](const Fold& fold, size_t value) { return fold.first < value; });
    return found != folds_.end() && found->first == line;
}

const Fold* FoldSet::foldContaining(size_t line) const {
    // The last fold that starts at or before the line.
    auto after = std::upper_bound(folds_.begin(), folds_.end(), line,
                                  [](size_t value, const Fold& fold) { return value < fold.first; });
    if (after == folds_.begin()) {
        return nullptr;
    }
    const Fold& candidate = *(after - 1);
    return line <= candidate.last ? &candidate : nullptr;
}

bool FoldSet::isHidden(size_t line) const {
    const Fold* fold = foldContaining(line);
    return fold != nullptr && line > fold->first;
}

void FoldSet::fold(size_t first, size_t last) {
    if (last <= first) {
        return;
    }
    // A bigger fold that already contains this one wins.
    for (const Fold& existing : folds_) {
        if (existing.first <= first && existing.last >= last && !(existing.first == first && existing.last == last)) {
            if (existing.first < first) {
                return;
            }
        }
    }
    std::vector<Fold> kept;
    for (const Fold& existing : folds_) {
        bool inside = existing.first >= first && existing.last <= last;
        if (!inside) {
            kept.push_back(existing);
        }
    }
    kept.push_back(Fold{first, last});
    std::sort(kept.begin(), kept.end(), [](const Fold& a, const Fold& b) { return a.first < b.first; });
    folds_ = std::move(kept);
}

void FoldSet::unfold(size_t first) {
    folds_.erase(std::remove_if(folds_.begin(), folds_.end(), [first](const Fold& fold) { return fold.first == first; }),
                 folds_.end());
}

bool FoldSet::unfoldContaining(size_t line) {
    size_t before = folds_.size();
    folds_.erase(std::remove_if(folds_.begin(), folds_.end(),
                                [line](const Fold& fold) { return line >= fold.first && line <= fold.last; }),
                 folds_.end());
    return folds_.size() != before;
}

bool FoldSet::unfoldHiding(size_t line) {
    size_t before = folds_.size();
    folds_.erase(std::remove_if(folds_.begin(), folds_.end(),
                                [line](const Fold& fold) { return line > fold.first && line <= fold.last; }),
                 folds_.end());
    return folds_.size() != before;
}

void FoldSet::adjustForEdit(size_t firstLine, size_t lastLine, long lineDelta) {
    std::vector<Fold> result;
    for (Fold fold : folds_) {
        if (fold.last < firstLine) {
            result.push_back(fold);  // above the edit
            continue;
        }
        bool touched = fold.first <= lastLine && fold.last >= firstLine;
        if (touched) {
            continue;  // the edit changed lines the fold hides or heads: open it
        }
        // Below the edit: move with the lines.
        long first = static_cast<long>(fold.first) + lineDelta;
        long last = static_cast<long>(fold.last) + lineDelta;
        if (first < 0 || last < first) {
            continue;
        }
        result.push_back(Fold{static_cast<size_t>(first), static_cast<size_t>(last)});
    }
    folds_ = std::move(result);
}

}  // namespace gw
