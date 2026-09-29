#include "Document.hpp"

#include <algorithm>
#include <fcntl.h>
#include <fstream>
#include <sstream>
#include <sys/stat.h>
#include <unistd.h>

namespace gw {

Position endOfInsertion(Position start, std::string_view text) {
    size_t newlines = static_cast<size_t>(std::count(text.begin(), text.end(), '\n'));
    if (newlines == 0) return {start.line, start.column + text.size()};
    size_t lastBreak = text.rfind('\n');
    return {start.line + newlines, text.size() - lastBreak - 1};
}

namespace {

/// Reads a whole file with a single allocation. Returns false if it can't be read.
bool readWholeFile(const std::filesystem::path& path, std::string& contents) {
    int descriptor = ::open(path.c_str(), O_RDONLY);
    if (descriptor < 0) {
        return false;
    }
    struct stat info;
    if (fstat(descriptor, &info) != 0) {
        ::close(descriptor);
        return false;
    }
    contents.resize(static_cast<size_t>(info.st_size));
    size_t total = 0;
    while (total < contents.size()) {
        ssize_t count = ::read(descriptor, contents.data() + total, contents.size() - total);
        if (count <= 0) {
            break;
        }
        total += static_cast<size_t>(count);
    }
    ::close(descriptor);
    contents.resize(total);
    return true;
}

}  // namespace

std::optional<Document> Document::open(const std::filesystem::path& path, std::string* error) {
    std::string contents;
    if (!readWholeFile(path, contents)) {
        if (error) *error = "Couldn't open " + path.string();
        return std::nullopt;
    }
    Document document;
    document.buffer_ = TextBuffer(contents);
    document.path_ = path;
    document.rememberDiskState();
    return document;
}

Document Document::readOnlyText(std::string text, std::string title) {
    Document document;
    document.buffer_ = TextBuffer(text);
    document.title = std::move(title);
    document.readOnly = true;
    return document;
}

void Document::rememberDiskState() {
    diskModifiedNanoseconds_ = 0;
    diskSize_ = -1;
    if (!path_) {
        return;
    }
    struct stat info;
    if (stat(path_->c_str(), &info) == 0) {
        diskModifiedNanoseconds_ = static_cast<long long>(info.st_mtimespec.tv_sec) * 1000000000LL + info.st_mtimespec.tv_nsec;
        diskSize_ = static_cast<long long>(info.st_size);
    }
}

bool Document::fileChangedOnDisk() const {
    if (!path_ || diskSize_ < 0) {
        return false;
    }
    struct stat info;
    if (stat(path_->c_str(), &info) != 0) {
        return false;  // deleted or unreadable: not something we can reload
    }
    long long modified = static_cast<long long>(info.st_mtimespec.tv_sec) * 1000000000LL + info.st_mtimespec.tv_nsec;
    return modified != diskModifiedNanoseconds_ || static_cast<long long>(info.st_size) != diskSize_;
}

Document::ReloadResult Document::reloadFromDisk(std::string* error) {
    if (!path_) {
        if (error) *error = "This document has no file.";
        return ReloadResult::Failed;
    }
    std::string contents;
    if (!readWholeFile(*path_, contents)) {
        if (error) *error = "Couldn't read " + path_->string();
        return ReloadResult::Failed;
    }

    TextBuffer fresh(contents);
    const size_t oldCount = buffer_.lineCount();
    const size_t newCount = fresh.lineCount();

    // Find the lines at the start and end that are the same, and replace only what's between.
    size_t prefix = 0;
    while (prefix < oldCount && prefix < newCount && buffer_.line(prefix) == fresh.line(prefix)) {
        ++prefix;
    }
    bool sameLines = prefix == oldCount && prefix == newCount;
    if (sameLines) {
        rememberDiskState();
        savedVersion_ = version_;
        return ReloadResult::Unchanged;
    }
    size_t suffix = 0;
    while (suffix < oldCount - prefix && suffix < newCount - prefix &&
           buffer_.line(oldCount - 1 - suffix) == fresh.line(newCount - 1 - suffix)) {
        ++suffix;
    }

    // Work out which part of the old text to replace, and with what. Three cases, depending
    // on whether the two versions share lines at the start and at the end.
    Position oldStart;
    Position oldEnd;
    std::string replacement;
    if (suffix > 0) {
        // Lines survive after the changed part: replace whole lines, breaks included.
        oldStart = Position{prefix, 0};
        oldEnd = Position{oldCount - suffix, 0};
        for (size_t line = prefix; line < newCount - suffix; ++line) {
            replacement += fresh.line(line);
            replacement += '\n';
        }
    } else if (prefix > 0) {
        // Only the start survives: start from the end of the last shared line.
        oldStart = Position{prefix - 1, buffer_.line(prefix - 1).size()};
        oldEnd = buffer_.end();
        for (size_t line = prefix; line < newCount; ++line) {
            replacement += '\n';
            replacement += fresh.line(line);
        }
    } else {
        // Nothing is shared: replace everything.
        oldStart = Position{0, 0};
        oldEnd = buffer_.end();
        for (size_t line = 0; line < newCount; ++line) {
            if (line > 0) {
                replacement += '\n';
            }
            replacement += fresh.line(line);
        }
    }

    reloadedFirstLine = prefix;
    reloadedLineCount = newCount - suffix - prefix;
    Selection keep = selection;
    replace({oldStart, oldEnd}, replacement);
    selection = {buffer_.clamp(keep.anchor), buffer_.clamp(keep.caret)};

    rememberDiskState();
    savedVersion_ = version_;
    return ReloadResult::Reloaded;
}

bool Document::save(std::string* error) {
    if (!path_) {
        if (error) *error = "This document has no file yet.";
        return false;
    }
    return saveAs(*path_, error);
}

bool Document::saveAs(const std::filesystem::path& path, std::string* error) {
    // Write to a temporary file and rename, so a failed save never truncates the original.
    std::filesystem::path temporary = path;
    temporary += ".glasswork-save";
    {
        std::ofstream file(temporary, std::ios::binary | std::ios::trunc);
        if (!file) {
            if (error) *error = "Couldn't write " + path.string();
            return false;
        }
        std::string text = buffer_.text();
        file.write(text.data(), static_cast<std::streamsize>(text.size()));
        if (!file) {
            if (error) *error = "Couldn't write " + path.string();
            return false;
        }
    }
    std::error_code code;
    std::filesystem::rename(temporary, path, code);
    if (code) {
        if (error) *error = code.message();
        return false;
    }
    path_ = path;
    savedVersion_ = version_;
    rememberDiskState();
    return true;
}

void Document::movedTo(const std::filesystem::path& path) {
    path_ = path;
    rememberDiskState();
}

std::string Document::displayName() const {
    if (!title.empty()) {
        return title;
    }
    return path_ ? path_->filename().string() : std::string("Untitled");
}

Position Document::apply(Position at, const std::string& removed, const std::string& inserted) {
    Position removedEnd = endOfInsertion(at, removed);
    long lineDelta = static_cast<long>(std::count(inserted.begin(), inserted.end(), '\n')) -
                     static_cast<long>(std::count(removed.begin(), removed.end(), '\n'));
    buffer_.erase({at, removedEnd});
    Position end = buffer_.insert(at, inserted);
    ++version_;
    for (Selection& extra : extraSelections) {
        extra.anchor = positionAfterEdit(extra.anchor, at, removedEnd, end);
        extra.caret = positionAfterEdit(extra.caret, at, removedEnd, end);
    }
    notify(at.line, lineDelta, end.line);
    return end;
}

Position positionAfterEdit(Position p, Position at, Position removedEnd, Position end) {
    if (p <= at) {
        return p;  // before the edit (or right at its start): unchanged
    }
    if (p < removedEnd) {
        return end;  // inside the text that was replaced
    }
    if (p.line == removedEnd.line) {
        return Position{end.line, end.column + (p.column - removedEnd.column)};
    }
    return Position{p.line + end.line - removedEnd.line, p.column};
}

void Document::notify(size_t firstLine, long lineDelta, size_t lastLine) {
    if (onChange) onChange(Change{firstLine, lineDelta, lastLine});
}

Position Document::replace(Range range, std::string_view text, bool coalesceTyping) {
    if (readOnly) {
        return selection.caret;
    }
    range = range.normalized();
    range.start = buffer_.clamp(range.start);
    range.end = buffer_.clamp(range.end);

    Edit edit;
    edit.at = range.start;
    edit.removed = buffer_.text(range);
    edit.inserted = std::string(text);
    edit.selectionBefore = selection;
    edit.time = std::chrono::steady_clock::now();
    edit.typing = coalesceTyping && groupDepth_ == 0;
    edit.group = groupDepth_ > 0 ? currentGroup_ : 0;

    Position end = apply(edit.at, edit.removed, edit.inserted);
    selection = {end, end};
    preferredX.reset();
    edit.selectionAfter = selection;
    redoStack_.clear();

    // Merge a run of typed characters (no line breaks, no pauses) into one undo step.
    if (coalesceTyping && groupDepth_ == 0 && !undoStack_.empty()) {
        Edit& last = undoStack_.back();
        bool continues = last.typing && edit.removed.empty() && last.removed.empty() &&
                         endOfInsertion(last.at, last.inserted) == edit.at &&
                         edit.inserted.find('\n') == std::string::npos &&
                         edit.time - last.time < std::chrono::seconds(2);
        if (continues) {
            last.inserted += edit.inserted;
            last.selectionAfter = edit.selectionAfter;
            last.time = edit.time;
            return end;
        }
    }
    undoStack_.push_back(std::move(edit));
    return end;
}

void Document::typeText(std::string_view text) {
    bool typing = selection.empty() && text.find('\n') == std::string_view::npos;
    replace(selection.range(), text, typing);
}

void Document::deleteSelectionOr(Range fallback) {
    replace(selection.empty() ? fallback : selection.range(), "");
}

void Document::beginUndoGroup() {
    if (groupDepth_ == 0) {
        currentGroup_ = nextGroup_++;
    }
    ++groupDepth_;
}

void Document::endUndoGroup() {
    if (groupDepth_ > 0) {
        --groupDepth_;
    }
}

bool Document::undo() {
    if (readOnly || undoStack_.empty()) return false;
    // A group comes off together: keep going while the edits belong to the same one.
    uint64_t group = undoStack_.back().group;
    do {
        Edit edit = std::move(undoStack_.back());
        undoStack_.pop_back();
        apply(edit.at, edit.inserted, edit.removed);
        selection = edit.selectionBefore;
        extraSelections.clear();
        redoStack_.push_back(std::move(edit));
    } while (group != 0 && !undoStack_.empty() && undoStack_.back().group == group);
    preferredX.reset();
    return true;
}

bool Document::redo() {
    if (readOnly || redoStack_.empty()) return false;
    uint64_t group = redoStack_.back().group;
    do {
        Edit edit = std::move(redoStack_.back());
        redoStack_.pop_back();
        apply(edit.at, edit.removed, edit.inserted);
        selection = edit.selectionAfter;
        extraSelections.clear();
        edit.typing = false;  // never merge new typing into a redone step
        undoStack_.push_back(std::move(edit));
    } while (group != 0 && !redoStack_.empty() && redoStack_.back().group == group);
    preferredX.reset();
    return true;
}

}  // namespace gw
