#pragma once

#include "Document.hpp"

#include <functional>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace gw {

enum class VimMode { Normal, Insert, Visual, VisualLine, Command };

/// Things Vim asks the window to do because the editor can't: the find bar has the search.
enum class VimAction { Search, SearchBackward, SearchNext, SearchPrevious };

namespace vim_detail {

/// One typed command: [count] [operator] [count] motion-or-command, such as "2d3w".
struct Command {
    int count1 = 0;       // 0: none typed
    int count2 = 0;
    std::string op;       // "d", "c", "y", ">" or "<"; empty for a plain command
    std::string key;      // the motion or command: "w", "gg", "fx", "iw", "p"...
    bool doubled = false; // dd, cc, yy, >>, <<
};

/// Where a motion goes, and how an operator should treat the text it crosses.
struct Motion {
    Position target;
    bool inclusive = false;  // the character at `target` is part of what an operator acts on
    bool linewise = false;
    std::optional<Range> object;  // a text object: the characters it covers (end excluded)
};

/// What an operator acts on: characters (end excluded) or whole lines (start.line..end.line).
struct Region {
    Range range;
    bool linewise = false;
};

}  // namespace vim_detail

/// Vim's modal editing for one editor: normal, insert, visual and visual-line modes with counts,
/// motions, operators (d c y > <), text objects, registers (one, shared with the clipboard),
/// repeat (.) and undo. No pixels: it reads and edits a Document, so it can be tested alone.
///
/// Insert mode is the editor's own typing; the engine only watches for Escape there.
class VimEngine {
public:
    VimMode mode() const { return mode_; }
    bool inVisualMode() const { return mode_ == VimMode::Visual || mode_ == VimMode::VisualLine; }

    /// "NORMAL", "INSERT", "VISUAL", "V-LINE" or "COMMAND", for the status bar.
    std::string modeName() const;
    /// Keys typed so far in a command that isn't finished, such as "2d" (or ":wq" on the command
    /// line), or the error from the last ":" command until the next key.
    std::string pending() const;

    /// Where the block cursor is drawn. Normally the caret; in visual modes the selection's
    /// caret is one past the character the cursor is on.
    Position cursor(const Document& document) const;

    /// Handles one key typed in the editor: a character as typed, or "\x1b" (Escape), "\x12"
    /// (Ctrl-R), "\r" (Return) or "\x7f" (Backspace). Returns false when the editor should treat
    /// the key as ordinary typing, which is what insert mode is.
    bool handleKey(Document& document, std::string_view key);

    /// Goes back to normal mode and forgets a command in progress (a different file, or Vim
    /// turned off). `document` is the one the engine was editing, if it is still alive.
    void reset(Document* document);

    /// What one indent step is, for > and <.
    std::string indentUnit = "    ";
    /// The register is shared with the system clipboard when these are set.
    std::function<std::string()> readClipboard;
    std::function<void(const std::string&)> writeClipboard;
    std::function<void(VimAction)> onAction;
    /// A ":" command the engine doesn't do itself (:w, :q, :wq and the like), without the colon.
    /// Returns an error message to show, or an empty string when it worked.
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
    using Command = vim_detail::Command;
    using Motion = vim_detail::Motion;
    using Region = vim_detail::Region;

    // Keys and modes
    void execute(Document& document, const Command& command, const std::vector<std::string>& keys);
    void executeNormal(Document& document, const Command& command);
    void executeVisual(Document& document, const Command& command);
    void syncWithDocument(Document& document);
    void beginInsert(Document& document, int count);
    void leaveInsert(Document& document);
    void exitVisual(Document& document);
    void showVisual(Document& document);

    // The ":" command line
    void handleCommandLineKey(Document& document, std::string_view key);
    std::string runCommandLine(Document& document, const std::string& line);
    std::string substitute(Document& document, size_t first, size_t last, std::string_view text);

    // Motions and operators
    std::optional<Motion> motionFor(Document& document, const std::string& key, int count, bool hasCount,
                                    Position from, bool forOperator);
    bool runOperator(Document& document, const Command& command);
    void applyOperator(Document& document, const std::string& op, const Region& region, Position from);
    Region visualRegion(const Document& document) const;

    // Edits
    void deleteRegion(Document& document, const Region& region);
    void put(Document& document, bool before, int count);
    void joinLines(Document& document, int count);
    void replaceCharacters(Document& document, const std::string& with, int count);
    void changeCase(Document& document, const Region& region, int mode);
    void shiftLines(Document& document, size_t first, size_t last, bool right);
    void yank(const std::string& text, bool linewise);
    Register registerForPaste();

    // State
    VimMode mode_ = VimMode::Normal;
    std::vector<std::string> keys_;
    std::string commandLine_;
    std::string message_;
    size_t visualFirstLine_ = 0;  // the lines that were selected when ":" was typed in visual mode
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
    struct Find {
        char kind = 0;
        std::string character;
    } lastFind_;
};

}  // namespace gw
