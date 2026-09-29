#include "LineDiff.hpp"

#include <algorithm>
#include <unordered_map>

namespace gw {

namespace {

/// Above this many differing lines, an exact diff would be slow and rarely useful, so the
/// changed middle of the file is reported as one replaced block instead.
constexpr int kMaxEditDistance = 2500;

/// The Myers O(ND) diff. Works on lines that were already turned into small integers so
/// comparing two lines is a single integer comparison.
///
/// Marks which old lines were deleted and which new lines were inserted. Returns false if
/// the texts differ by more than kMaxEditDistance lines.
bool myersDiff(const std::vector<int>& oldIds, const std::vector<int>& newIds, std::vector<char>& deleted,
               std::vector<char>& inserted) {
    const int oldLength = static_cast<int>(oldIds.size());
    const int newLength = static_cast<int>(newIds.size());
    const int maxDistance = std::min(kMaxEditDistance, oldLength + newLength);

    // furthest[k + offset] is the furthest x reached on diagonal k (where k = x - y).
    const int offset = maxDistance + 1;
    std::vector<int> furthest(static_cast<size_t>(2 * maxDistance + 3), 0);

    // After each round d we keep the diagonals -d..d, so we can walk back afterwards.
    std::vector<std::vector<int>> history;

    int finalDistance = -1;
    for (int distance = 0; distance <= maxDistance && finalDistance < 0; ++distance) {
        for (int diagonal = -distance; diagonal <= distance; diagonal += 2) {
            int x = 0;
            bool moveDown = false;
            if (diagonal == -distance) {
                moveDown = true;
            } else if (diagonal != distance) {
                int left = furthest[static_cast<size_t>(diagonal - 1 + offset)];
                int right = furthest[static_cast<size_t>(diagonal + 1 + offset)];
                moveDown = left < right;
            }
            if (moveDown) {
                x = furthest[static_cast<size_t>(diagonal + 1 + offset)];
            } else {
                x = furthest[static_cast<size_t>(diagonal - 1 + offset)] + 1;
            }
            int y = x - diagonal;

            // Follow the free diagonal of matching lines.
            while (x < oldLength && y < newLength && oldIds[static_cast<size_t>(x)] == newIds[static_cast<size_t>(y)]) {
                ++x;
                ++y;
            }
            furthest[static_cast<size_t>(diagonal + offset)] = x;

            if (x >= oldLength && y >= newLength) {
                finalDistance = distance;
                break;
            }
        }

        std::vector<int> snapshot(static_cast<size_t>(2 * distance + 1));
        for (int diagonal = -distance; diagonal <= distance; ++diagonal) {
            snapshot[static_cast<size_t>(diagonal + distance)] = furthest[static_cast<size_t>(diagonal + offset)];
        }
        history.push_back(std::move(snapshot));
    }

    if (finalDistance < 0) {
        return false;
    }

    // Walk back from the end of both texts to the start, recording every step that was
    // not a free diagonal move.
    int x = oldLength;
    int y = newLength;
    for (int distance = finalDistance; distance > 0; --distance) {
        const std::vector<int>& before = history[static_cast<size_t>(distance - 1)];
        const int reach = distance - 1;
        auto furthestBefore = [&](int diagonal) { return before[static_cast<size_t>(diagonal + reach)]; };

        int diagonal = x - y;
        bool cameFromAbove = false;
        if (diagonal == -distance) {
            cameFromAbove = true;
        } else if (diagonal != distance) {
            cameFromAbove = furthestBefore(diagonal - 1) < furthestBefore(diagonal + 1);
        }
        int previousDiagonal = cameFromAbove ? diagonal + 1 : diagonal - 1;
        int previousX = furthestBefore(previousDiagonal);
        int previousY = previousX - previousDiagonal;

        // Undo the free diagonal run that followed the edit.
        while (x > previousX && y > previousY) {
            --x;
            --y;
        }
        if (cameFromAbove) {
            // A new line appeared: it is new line number previousY.
            inserted[static_cast<size_t>(previousY)] = 1;
        } else {
            // An old line vanished: it is old line number previousX.
            deleted[static_cast<size_t>(previousX)] = 1;
        }
        x = previousX;
        y = previousY;
    }
    return true;
}

}  // namespace

std::vector<std::string_view> splitLines(std::string_view text) {
    std::vector<std::string_view> lines;
    size_t start = 0;
    while (start < text.size()) {
        size_t newline = text.find('\n', start);
        if (newline == std::string_view::npos) {
            lines.push_back(text.substr(start));
            break;
        }
        size_t end = newline;
        if (end > start && text[end - 1] == '\r') {
            --end;
        }
        lines.push_back(text.substr(start, end - start));
        start = newline + 1;
    }
    return lines;
}

std::vector<DiffHunk> diffLines(const std::vector<std::string_view>& oldLines,
                                const std::vector<std::string_view>& newLines) {
    std::vector<DiffHunk> hunks;

    // Most of a file is normally untouched: skip the same lines at both ends first.
    size_t prefix = 0;
    size_t shortest = std::min(oldLines.size(), newLines.size());
    while (prefix < shortest && oldLines[prefix] == newLines[prefix]) {
        ++prefix;
    }
    size_t suffix = 0;
    while (suffix < shortest - prefix && oldLines[oldLines.size() - 1 - suffix] == newLines[newLines.size() - 1 - suffix]) {
        ++suffix;
    }

    const size_t oldMiddle = oldLines.size() - prefix - suffix;
    const size_t newMiddle = newLines.size() - prefix - suffix;
    if (oldMiddle == 0 && newMiddle == 0) {
        return hunks;
    }
    if (oldMiddle == 0 || newMiddle == 0) {
        hunks.push_back({prefix, oldMiddle, prefix, newMiddle});
        return hunks;
    }

    // Give every distinct line a number.
    std::unordered_map<std::string_view, int> ids;
    ids.reserve(oldMiddle + newMiddle);
    auto idFor = [&ids](std::string_view line) {
        auto found = ids.find(line);
        if (found != ids.end()) {
            return found->second;
        }
        int fresh = static_cast<int>(ids.size());
        ids.emplace(line, fresh);
        return fresh;
    };
    std::vector<int> oldIds;
    std::vector<int> newIds;
    oldIds.reserve(oldMiddle);
    newIds.reserve(newMiddle);
    for (size_t index = 0; index < oldMiddle; ++index) {
        oldIds.push_back(idFor(oldLines[prefix + index]));
    }
    for (size_t index = 0; index < newMiddle; ++index) {
        newIds.push_back(idFor(newLines[prefix + index]));
    }

    std::vector<char> deleted(oldMiddle, 0);
    std::vector<char> inserted(newMiddle, 0);
    if (!myersDiff(oldIds, newIds, deleted, inserted)) {
        hunks.push_back({prefix, oldMiddle, prefix, newMiddle});
        return hunks;
    }

    // Group the flagged lines into hunks: runs between lines both sides still share.
    size_t oldIndex = 0;
    size_t newIndex = 0;
    while (oldIndex < oldMiddle || newIndex < newMiddle) {
        bool oldChanged = oldIndex < oldMiddle && deleted[oldIndex];
        bool newChanged = newIndex < newMiddle && inserted[newIndex];
        if (!oldChanged && !newChanged) {
            ++oldIndex;
            ++newIndex;
            continue;
        }
        DiffHunk hunk;
        hunk.oldStart = prefix + oldIndex;
        hunk.newStart = prefix + newIndex;
        while (oldIndex < oldMiddle && deleted[oldIndex]) {
            ++oldIndex;
        }
        while (newIndex < newMiddle && inserted[newIndex]) {
            ++newIndex;
        }
        hunk.oldCount = prefix + oldIndex - hunk.oldStart;
        hunk.newCount = prefix + newIndex - hunk.newStart;
        hunks.push_back(hunk);
    }
    return hunks;
}

std::vector<LineChange> gutterChanges(const std::vector<DiffHunk>& hunks) {
    std::vector<LineChange> changes;
    for (const DiffHunk& hunk : hunks) {
        if (hunk.oldCount == 0) {
            changes.push_back({LineChangeKind::Added, hunk.newStart, hunk.newCount});
            continue;
        }
        if (hunk.newCount == 0) {
            changes.push_back({LineChangeKind::Removed, hunk.newStart, 0});
            continue;
        }
        size_t replaced = std::min(hunk.oldCount, hunk.newCount);
        changes.push_back({LineChangeKind::Modified, hunk.newStart, replaced});
        if (hunk.newCount > replaced) {
            changes.push_back({LineChangeKind::Added, hunk.newStart + replaced, hunk.newCount - replaced});
        } else if (hunk.oldCount > replaced) {
            changes.push_back({LineChangeKind::Removed, hunk.newStart + replaced, 0});
        }
    }
    return changes;
}

std::string patchForHunk(const std::string& path, const std::vector<std::string_view>& oldLines,
                         const std::vector<std::string_view>& newLines, const DiffHunk& hunk) {
    std::string patch;
    patch += "diff --git a/" + path + " b/" + path + "\n";
    patch += "--- a/" + path + "\n";
    patch += "+++ b/" + path + "\n";

    // In a unified diff, a range of zero lines is numbered by the line before it.
    size_t oldNumber = hunk.oldCount == 0 ? hunk.oldStart : hunk.oldStart + 1;
    size_t newNumber = hunk.newCount == 0 ? hunk.newStart : hunk.newStart + 1;
    patch += "@@ -" + std::to_string(oldNumber) + "," + std::to_string(hunk.oldCount) + " +" +
             std::to_string(newNumber) + "," + std::to_string(hunk.newCount) + " @@\n";

    for (size_t index = 0; index < hunk.oldCount; ++index) {
        patch += "-";
        patch += oldLines[hunk.oldStart + index];
        patch += "\n";
    }
    for (size_t index = 0; index < hunk.newCount; ++index) {
        patch += "+";
        patch += newLines[hunk.newStart + index];
        patch += "\n";
    }
    return patch;
}

}  // namespace gw
