#pragma once

#include "Document.hpp"

#include <functional>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace gw {

// Keys typed -> the mode the engine is in, which decides what the next key means.
enum class VimMode { Normal, Insert, Visual, VisualLine, Command };

// "/", "?", "n" or "N" -> what the window's find bar should do (the engine has no search of its own).
enum class VimAction { Search, SearchBackward, SearchNext, SearchPrevious };

namespace vim_detail {

/// One typed command: [count] [operator] [count] motion-or-command, such as "2d3w".
struct Command {
    /// 0: none typed.
    int count1 = 0;
    int count2 = 0;
    /// "d", "c", "y", ">" or "<"; empty for a plain command.
    std::string op;
    /// The motion or command: "w", "gg", "fx", "iw", "p"...
    std::string key;
    /// dd, cc, yy, >>, <<.
    bool doubled = false;
};

/// Where a motion goes, and how an operator should treat the text it crosses.
struct Motion {
    Position target;
    /// The character at `target` is part of what an operator acts on.
    bool inclusive = false;
    bool linewise = false;
    /// A text object: the characters it covers (end excluded).
    std::optional<Range> object;
};

/// What an operator acts on: characters (end excluded) or whole lines (start.line..end.line).
struct Region {
    Range range;
    bool linewise = false;
};

}  // namespace vim_detail

/// Vim's modal editing for one editor: modes, counts, motions, operators (d c y > <), text objects,
/// one register shared with the clipboard, repeat (.) and undo. It reads and edits a Document and
/// draws nothing, so it can be tested alone. Insert mode is the editor's own typing.
class VimEngine {
public:
    // ---- Keys
    /// A character as typed, or "\x1b" (Escape), "\x12" (Ctrl-R), "\r" (Return) or "\x7f" (Backspace).
    /// False when the editor should treat the key as ordinary typing (insert mode).
    bool handleKey(Document& document, std::string_view key);
    /// Back to normal mode, forgetting a command in progress. `document` may be null.
    void reset(Document* document);

    // ---- Getters
    VimMode mode() const { return mode_; }
    bool inVisualMode() const { return mode_ == VimMode::Visual || mode_ == VimMode::VisualLine; }
    /// "NORMAL", "INSERT", "VISUAL", "V-LINE" or "COMMAND".
    std::string modeName() const;
    /// An unfinished command ("2d", ":wq"), or the last ":" command's error until the next key.
    std::string pending() const;
    /// Where the block cursor is drawn: one before the selection's caret in visual modes.
    Position cursor(const Document& document) const;

    // ---- Variables
    /// One indent step, for > and <.
    std::string indentUnit = "    ";
    std::function<std::string()> readClipboard;
    std::function<void(const std::string&)> writeClipboard;
    std::function<void(VimAction)> onAction;
    /// A ":" command the engine doesn't do itself (:w, :q...), without the colon. Returns an error, or "".
    std::function<std::string(const std::string&)> onCommand;

private:
    struct Register {
        std::string text;
        bool linewise = false;
    };
    struct Change {
        std::vector<std::string> keys;
        std::string inserted;
    };
    struct Find {
        char kind = 0;
        std::string character;
    };
    using Command = vim_detail::Command;
    using Motion = vim_detail::Motion;
    using Region = vim_detail::Region;

    // ---- Keys and modes
    void execute(Document& document, const Command& command, const std::vector<std::string>& keys);
    void executeNormal(Document& document, const Command& command);
    void executeVisual(Document& document, const Command& command);
    void syncWithDocument(Document& document);
    void beginInsert(Document& document, int count);
    void leaveInsert(Document& document);
    void exitVisual(Document& document);
    void showVisual(Document& document);

    // ---- The ":" command line
    void handleCommandLineKey(Document& document, std::string_view key);
    std::string runCommandLine(Document& document, const std::string& line);
    std::string substitute(Document& document, size_t first, size_t last, std::string_view text);

    // ---- Motions and operators
    std::optional<Motion> motionFor(Document& document, const std::string& key, int count, bool hasCount,
                                    Position from, bool forOperator);
    bool runOperator(Document& document, const Command& command);
    void applyOperator(Document& document, const std::string& op, const Region& region, Position from);
    Region visualRegion(const Document& document) const;

    // ---- Edits
    void deleteRegion(Document& document, const Region& region);
    void put(Document& document, bool before, int count);
    void joinLines(Document& document, int count);
    void replaceCharacters(Document& document, const std::string& with, int count);
    void changeCase(Document& document, const Region& region, int mode);
    void shiftLines(Document& document, size_t first, size_t last, bool right);
    void yank(const std::string& text, bool linewise);
    Register registerForPaste();

    // ---- Private variables
    VimMode mode_ = VimMode::Normal;
    std::vector<std::string> keys_;
    std::string commandLine_;
    std::string message_;
    /// The lines that were selected when ":" was typed in visual mode.
    size_t visualFirstLine_ = 0;
    size_t visualLastLine_ = 0;
    Position anchor_;
    Position cursor_;
    Selection shownSelection_;
    std::optional<size_t> desiredColumn_;
    Register register_;
    std::string clipboardMirror_;
    Position insertStart_;
    int insertCount_ = 1;
    bool groupOpen_ = false;
    bool commandChanges_ = false;
    bool replaying_ = false;
    std::vector<std::string> insertKeys_;
    Change lastChange_;
    Find lastFind_;
};

}  // namespace gw
