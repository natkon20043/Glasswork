#pragma once

#include "Snippet.hpp"
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
    Range range() const { return Range{anchor, caret}.normalized(); }
    bool empty() const { return anchor == caret; }

    Position anchor;
    Position caret;
};

/// Lines from `firstLine` on were touched; `lineDelta` lines were added (negative: removed).
struct Change {
    size_t firstLine;
    long lineDelta;
    size_t lastLine;
};

/// One edit as language servers expect it. Columns are UTF-16 units, measured on the text as it
/// was just before this edit.
struct SyncEdit {
    size_t startLine = 0;
    size_t startUnits = 0;
    size_t endLine = 0;
    size_t endUnits = 0;
    std::string text;
};

/// A text buffer plus file path, selection, undo history and a dirty flag. No fonts or pixels.
class Document {
public:
    // Disk reload: file on disk -> Unchanged (same text), Reloaded (text replaced), Failed (unreadable).
    enum class ReloadResult { Unchanged, Reloaded, Failed };

    struct SnippetSession {
        /// Tab order; the last stop is the final caret. A stop with several ranges is mirrored.
        std::vector<std::vector<Range>> stops;
        size_t current = 0;
        Range whole;
    };

    // ---- Constructors
    Document() = default;
    static std::optional<Document> open(const std::filesystem::path& path, std::string* error = nullptr);
    static Document readOnlyText(std::string text, std::string title);

    // ---- Saving and disk state
    bool save(std::string* error = nullptr);
    bool saveAs(const std::filesystem::path& path, std::string* error = nullptr);
    void movedTo(const std::filesystem::path& path);
    bool fileChangedOnDisk() const;
    void acknowledgeDiskChange() { rememberDiskState(); }
    /// Replaces only the differing lines, as one undoable edit.
    ReloadResult reloadFromDisk(std::string* error = nullptr);

    // ---- Editing
    /// Every edit goes through here. Line breaks in `text` are changed to the file's own.
    /// Returns the position after the inserted text.
    Position replace(Range range, std::string_view text, bool coalesceTyping = false);
    /// For edits that rewrite lines already in the range (indent, change case, move or sort
    /// lines): the first "\n" in `text` gets the range's first break, the second its second, and
    /// so on, so lines whose text doesn't change keep their "\n" or "\r\n". Extra breaks follow the file.
    Position replaceKeepingBreaks(Range range, std::string_view text);
    void typeText(std::string_view text);
    void deleteSelectionOr(Range fallback);

    // ---- Undo and redo
    bool undo();
    bool redo();
    bool canUndo() const { return !undoStack_.empty(); }
    bool canRedo() const { return !redoStack_.empty(); }
    /// Groups nest; everything between begin and end undoes as one step.
    void beginUndoGroup();
    void endUndoGroup();

    // ---- Language server sync
    void recordSyncEdits(bool on);
    /// Edits since the last call, oldest first. Empty optional: too much changed, send the whole text.
    std::optional<std::vector<SyncEdit>> takeSyncEdits();

    // ---- Snippets
    bool snippetActive() const { return !snippet_.stops.empty(); }
    /// `start` is where the snippet's first character was inserted.
    void startSnippet(Position start, const ParsedSnippet& snippet);
    /// Returns false (and ends the session) when there is no stop to jump to.
    bool jumpSnippetStop(int direction);
    void endSnippet();

    // ---- Getters
    const TextBuffer& buffer() const { return buffer_; }
    const std::optional<std::filesystem::path>& path() const { return path_; }
    std::string displayName() const;
    bool isDirty() const { return version_ != savedVersion_; }
    uint64_t version() const { return version_; }

    // ---- Variables
    std::string title;
    bool readOnly = false;
    std::string languageId;
    Selection selection;
    /// Multi-cursor carets; they follow every edit. Undo and redo clear them.
    std::vector<Selection> extraSelections;
    /// Zero-based lines with a breakpoint; they move with the text.
    std::set<size_t> breakpointLines;
    /// Wanted caret column when moving up/down, in view points. Reset by horizontal moves and edits.
    std::optional<double> preferredX;
    /// First changed line and line count after a reload.
    size_t reloadedFirstLine = 0;
    size_t reloadedLineCount = 0;
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

    // ---- Private functions
    /// `replace` without changing the breaks in `text` (reloading keeps the disk's bytes).
    Position replaceExactly(Range range, std::string&& text, bool coalesceTyping = false);
    Position apply(Position at, const std::string& removed, const std::string& inserted);
    void recordSyncEdit(Position at, Position removedEnd, const std::string& inserted);
    void notify(size_t firstLine, long lineDelta, size_t lastLine);
    void rememberDiskState();
    void selectSnippetStop(size_t index);
    void followEditInSnippet(Position at, Position removedEnd, Position end);

    // ---- Private variables
    bool recordingSyncEdits_ = false;
    bool syncEditsOverflowed_ = false;
    std::vector<SyncEdit> syncEdits_;
    size_t syncEditBytes_ = 0;
    SnippetSession snippet_;
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

Position endOfInsertion(Position start, std::string_view text);

/// Earlier positions stay; later ones move with the text that replaced `at`..`removedEnd` and now ends at `end`.
Position positionAfterEdit(Position p, Position at, Position removedEnd, Position end);

}  // namespace gw
