#pragma once

#include <cstdint>
#include <deque>
#include <functional>
#include <string>
#include <string_view>
#include <vector>

namespace gw::term {

/// A colour as a terminal program asks for it: the default, one of 256 palette entries, or
/// a full RGB value. Packed in one number so a cell stays small.
struct TermColor {
    uint32_t packed = 0;

    static TermColor defaultColor() { return TermColor{0}; }
    static TermColor indexed(uint8_t index) { return TermColor{(1u << 24) | index}; }
    static TermColor rgb(uint8_t red, uint8_t green, uint8_t blue) {
        return TermColor{(2u << 24) | (static_cast<uint32_t>(red) << 16) | (static_cast<uint32_t>(green) << 8) | blue};
    }

    bool isDefault() const { return (packed >> 24) == 0; }
    bool isIndexed() const { return (packed >> 24) == 1; }
    bool isRgb() const { return (packed >> 24) == 2; }
    uint8_t index() const { return static_cast<uint8_t>(packed & 0xFF); }
    uint8_t red() const { return static_cast<uint8_t>((packed >> 16) & 0xFF); }
    uint8_t green() const { return static_cast<uint8_t>((packed >> 8) & 0xFF); }
    uint8_t blue() const { return static_cast<uint8_t>(packed & 0xFF); }
    bool operator==(const TermColor&) const = default;
};

/// Text attributes a cell can have. Combine with |.
enum Attribute : uint16_t {
    kBold = 1 << 0,
    kDim = 1 << 1,
    kItalic = 1 << 2,
    kUnderline = 1 << 3,
    kBlink = 1 << 4,
    kInverse = 1 << 5,
    kHidden = 1 << 6,
    kStrike = 1 << 7,
    kWideStart = 1 << 8,  // the first half of a double-width character
    kWideEnd = 1 << 9,    // the empty second half
};

struct Cell {
    uint32_t character = ' ';
    TermColor foreground;
    TermColor background;
    uint16_t attributes = 0;

    bool isBlank() const {
        return character == ' ' && foreground.isDefault() && background.isDefault() && (attributes & ~kWideEnd) == 0;
    }
    bool operator==(const Cell&) const = default;
};

/// One line of the screen or of the history above it.
struct Row {
    std::vector<Cell> cells;
    /// True if the text continued from this line onto the next (it was wrapped, not ended).
    bool wrapped = false;
    /// Changes every time the row changes, so a view can keep its drawing of an unchanged row.
    uint64_t revision = 0;
};

/// What mouse events, if any, the running program has asked to receive.
enum class MouseMode { None, Press, PressRelease, Drag, Motion };

/// The state of a terminal window: a grid of cells, a cursor, colours, history, and the
/// modes programs switch with escape sequences. Feed it what the program prints with
/// `write`; read the cells back to draw them. It also produces the replies some programs
/// wait for (cursor position, device attributes) through `onReply`.
///
/// Understands enough of xterm to run shells, ls, git, vim, less, htop, tmux and the like:
/// cursor movement, erasing, scrolling regions, 16 / 256 / true colours, the alternate screen,
/// bracketed paste, mouse reporting modes, tab stops, wide characters, and line drawing.
class Screen {
public:
    Screen(int columns, int rows, size_t historyLimit = 10000);

    // ---- Input from the program
    void write(std::string_view bytes);

    // ---- Size
    void resize(int columns, int rows);
    int columns() const { return columns_; }
    int rows() const { return rows_; }

    // ---- Reading the grid
    /// Lines of history above the screen.
    size_t historyCount() const { return history_.size(); }
    /// Row `index`: 0 … rows-1 is the visible screen, -1 is the newest history line, -2 the
    /// one before, and so on down to -historyCount().
    const Row& row(long index) const;
    /// The cell at a column of a row, blank if the row is shorter than that.
    Cell cellAt(long rowIndex, int column) const;

    int cursorRow() const { return cursorRow_; }
    int cursorColumn() const { return cursorColumn_; }
    bool cursorVisible() const { return cursorVisible_; }
    bool onAlternateScreen() const { return usingAlternate_; }

    // ---- Modes that change how the app should behave
    bool applicationCursorKeys() const { return applicationCursorKeys_; }
    bool bracketedPaste() const { return bracketedPaste_; }
    bool focusReporting() const { return focusReporting_; }
    MouseMode mouseMode() const { return mouseMode_; }
    bool mouseSgr() const { return mouseSgr_; }

    const std::string& title() const { return title_; }
    /// The folder the shell last reported (OSC 7), or empty.
    const std::string& workingDirectory() const { return workingDirectory_; }

    /// The colours the terminal shows for "default", reported when a program asks (OSC 10/11).
    void setDefaultColors(TermColor foreground, TermColor background);

    /// Text of a range of the screen and history: (row, column) to (row, column) inclusive
    /// of the start, exclusive of the end. Trailing blanks on a line are dropped; lines that
    /// were wrapped are joined.
    std::string textInRange(long startRow, int startColumn, long endRow, int endColumn) const;

    // ---- Callbacks
    /// Bytes the terminal wants to send back to the program.
    std::function<void(const std::string&)> onReply;
    std::function<void()> onBell;
    std::function<void(const std::string&)> onTitleChange;
    std::function<void(const std::string&)> onDirectoryChange;

    /// Increases when anything visible changed.
    uint64_t revision() const { return revision_; }

private:
    enum class ParserState {
        Ground,
        Escape,
        EscapeIntermediate,  // ESC ( ) # etc. waiting for the final byte
        CsiEntry,
        CsiParameter,
        CsiIntermediate,
        Osc,
        OscEscape,        // saw ESC inside an OSC (the start of ST)
        IgnoredString,    // DCS, SOS, PM, APC: skipped up to ST
        IgnoredStringEscape,
    };

    struct Charset {
        char designation = 'B';  // 'B' is ASCII, '0' is DEC line drawing
    };

    struct SavedCursor {
        int row = 0;
        int column = 0;
        Cell pen;
        bool pendingWrap = false;
        bool originMode = false;
        char charset0 = 'B';
        char charset1 = 'B';
        int activeCharset = 0;
    };

    struct Grid {
        std::vector<Row> rows;
    };

    // ---- Bytes to characters
    void feed(uint8_t byte);
    void handleGround(uint8_t byte);
    void handleControl(uint8_t byte);
    void printCharacter(uint32_t codePoint);
    void handleEscapeFinal(uint8_t byte);
    void handleCsiFinal(uint8_t byte);
    void handleOsc();

    // ---- Editing the grid
    Row& liveRow(int index) { return grid_.rows[static_cast<size_t>(index)]; }
    void touch(Row& row);
    Cell blankCell() const;
    void ensureWidth(Row& row, int columns);
    void putCell(int row, int column, const Cell& cell);
    void eraseCells(int row, int fromColumn, int toColumn);  // [from, to)
    void eraseRows(int fromRow, int toRow);                  // [from, to)
    void lineFeed();
    void reverseLineFeed();
    /// Scrolls the region up. Lines leaving the top of the whole screen become history, unless
    /// `keepHistory` is false (deleting lines is not scrolling).
    void scrollUp(int count, bool keepHistory = true);
    void scrollDown(int count);
    void insertLines(int count);
    void deleteLines(int count);
    void insertCharacters(int count);
    void deleteCharacters(int count);
    void moveCursor(int row, int column);
    void setScrollRegion(int top, int bottom);
    void saveCursor();
    void restoreCursor();
    void switchScreen(bool alternate, bool clearAlternate, bool saveRestoreCursor);
    void reset();
    void applyGraphicRendition();
    void setMode(bool enable, bool priv);
    void reportDeviceStatus(int kind, bool priv);
    void tabForward(int count);
    void tabBackward(int count);

    int parameter(size_t index, int fallback) const;
    static int characterWidth(uint32_t codePoint);
    uint32_t translateCharset(uint32_t codePoint) const;
    void reply(const std::string& bytes);

    // ---- State
    int columns_;
    int rows_;
    size_t historyLimit_;
    std::deque<Row> history_;
    Grid grid_;
    Grid savedPrimary_;  // the normal screen while the alternate one is in use
    bool usingAlternate_ = false;

    int cursorRow_ = 0;
    int cursorColumn_ = 0;
    bool pendingWrap_ = false;
    bool cursorVisible_ = true;
    Cell pen_;  // colours and attributes for new text
    int scrollTop_ = 0;
    int scrollBottom_;
    std::vector<bool> tabStops_;
    SavedCursor saved_;
    SavedCursor savedForAlternate_;
    char charsets_[2] = {'B', 'B'};
    int activeCharset_ = 0;

    bool autoWrap_ = true;
    bool originMode_ = false;
    bool insertMode_ = false;
    bool applicationCursorKeys_ = false;
    bool bracketedPaste_ = false;
    bool focusReporting_ = false;
    bool newlineMode_ = false;
    MouseMode mouseMode_ = MouseMode::None;
    bool mouseSgr_ = false;

    std::string title_;
    std::string workingDirectory_;
    TermColor defaultForeground_ = TermColor::rgb(0xD4, 0xD4, 0xD4);
    TermColor defaultBackground_ = TermColor::rgb(0x1E, 0x1E, 0x1E);

    // ---- Parser
    ParserState state_ = ParserState::Ground;
    std::vector<int> parameters_;
    std::vector<bool> subParameter_;  // per parameter: was it separated from the last by ":"?
    bool subNext_ = false;
    int currentParameter_ = -1;
    char privateMarker_ = 0;          // "?", ">", "=" or "<" right after "ESC [", or 0
    char intermediate_ = 0;
    std::string oscBuffer_;
    uint32_t utf8Code_ = 0;
    int utf8Remaining_ = 0;
    uint32_t lastPrinted_ = 0;
    uint64_t revision_ = 1;
    uint64_t nextRowRevision_ = 1;
    Row emptyRow_;
};

}  // namespace gw::term
