#pragma once

#include "TextBuffer.hpp"

#include <chrono>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <optional>
#include <set>
#include <string>
#include <vector>

namespace gw {

struct Selection {
    Position anchor;
    Position caret;

    Range range() const { return Range{anchor, caret}.normalized(); }
    bool empty() const { return anchor == caret; }
};

/// Describes an edit so views and the highlighter can invalidate just what changed: lines
/// from `firstLine` on were touched, and `lineDelta` lines were added (or removed if negative).
struct Change {
    size_t firstLine;
    long lineDelta;
    /// The last line (as numbered after the edit) that holds changed text.
    size_t lastLine;
};

/// A text buffer plus everything that makes it editable: file path, selection, undo history
/// and a dirty flag. Knows nothing about fonts or pixels.
class Document {
public:
    Document() = default;

    static std::optional<Document> open(const std::filesystem::path& path, std::string* error = nullptr);
    /// A document that exists only in memory and cannot be edited (a diff, command output…).
    static Document readOnlyText(std::string text, std::string title);
    bool save(std::string* error = nullptr);
    bool saveAs(const std::filesystem::path& path, std::string* error = nullptr);

    /// The file was moved or renamed on disk; from now on this document belongs to `path`.
    /// The text and undo history are untouched.
    void movedTo(const std::filesystem::path& path);

    /// Shown instead of the file name when not empty.
    std::string title;
    /// Read-only documents ignore every edit.
    bool readOnly = false;

    /// True if the file on disk is not the one we last read or wrote (someone else, such as
    /// Claude or a build step, changed it).
    bool fileChangedOnDisk() const;
    /// Treats the file on disk as seen: it stops counting as "changed", but the text is
    /// not touched. Used when the user chooses to keep their own version.
    void acknowledgeDiskChange() { rememberDiskState(); }

    enum class ReloadResult {
        Unchanged,  // the disk holds the text we already have
        Reloaded,   // the text was replaced with what is on disk
        Failed,
    };
    /// Brings in the file's current content. Only the lines that differ are replaced, as
    /// one undoable edit, so the caret, scroll position and undo history stay meaningful.
    /// The document counts as saved afterwards.
    ReloadResult reloadFromDisk(std::string* error = nullptr);
    /// After a reload: the first line that changed and how many lines it now spans, so the
    /// editor can highlight what someone else just edited.
    size_t reloadedFirstLine = 0;
    size_t reloadedLineCount = 0;

    const TextBuffer& buffer() const { return buffer_; }
    const std::optional<std::filesystem::path>& path() const { return path_; }
    std::string displayName() const;
    bool isDirty() const { return version_ != savedVersion_; }
    /// Increments on every edit; lets caches (and later the language server) spot changes.
    uint64_t version() const { return version_; }

    std::string languageId;

    Selection selection;
    /// More carets and selections besides `selection` (multi-cursor editing). They follow every
    /// edit, so a command run at one cursor keeps the others in the right place. Undo and redo
    /// clear them.
    std::vector<Selection> extraSelections;
    /// Lines (from 0) with a debugger breakpoint. They move with the text when lines are added or
    /// removed above them, and go when their own line is removed.
    std::set<size_t> breakpointLines;
    /// Column the caret wants when moving up/down, in the view's units (points). Kept here so
    /// it survives across views; set to nullopt after any horizontal movement or edit.
    std::optional<double> preferredX;

    // Editing. All edits go through `replace`, which records undo and notifies listeners.
    /// Replaces `range` with `text`; returns the position after the inserted text.
    Position replace(Range range, std::string_view text, bool coalesceTyping = false);
    /// Types over the selection, merging runs of typing into one undo step.
    void typeText(std::string_view text);
    void deleteSelectionOr(Range fallback);

    /// Edits made between beginUndoGroup() and endUndoGroup() undo (and redo) together as one
    /// step, such as Replace All. Groups may nest.
    void beginUndoGroup();
    void endUndoGroup();

    bool undo();
    bool redo();
    bool canUndo() const { return !undoStack_.empty(); }
    bool canRedo() const { return !redoStack_.empty(); }

    /// Called after every change.
    std::function<void(const Change&)> onChange;

private:
    struct Edit {
        Position at;
        std::string removed;
        std::string inserted;
        Selection selectionBefore;
        Selection selectionAfter;
        std::chrono::steady_clock::time_point time;
        bool typing = false;
        /// Edits with the same non-zero group undo together.
        uint64_t group = 0;
    };

    Position apply(Position at, const std::string& removed, const std::string& inserted);
    void notify(size_t firstLine, long lineDelta, size_t lastLine);

    /// Remembers what the file looked like when we last read or wrote it.
    void rememberDiskState();

    TextBuffer buffer_;
    std::optional<std::filesystem::path> path_;
    long long diskModifiedNanoseconds_ = 0;
    long long diskSize_ = -1;
    std::vector<Edit> undoStack_;
    std::vector<Edit> redoStack_;
    uint64_t version_ = 0;
    uint64_t savedVersion_ = 0;
    int groupDepth_ = 0;
    uint64_t currentGroup_ = 0;
    uint64_t nextGroup_ = 1;
};

/// Position just past `text` if it were inserted at `start`.
Position endOfInsertion(Position start, std::string_view text);

/// Where a position ends up after the text between `at` and `removedEnd` was replaced by text
/// that ends at `end`: earlier positions stay, later ones move with the text.
Position positionAfterEdit(Position p, Position at, Position removedEnd, Position end);

}  // namespace gw
