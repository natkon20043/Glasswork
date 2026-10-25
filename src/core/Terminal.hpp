#pragma once

#include <cstdint>
#include <deque>
#include <functional>
#include <string>
#include <string_view>
#include <vector>

namespace gw::term {

// SGR escape codes from the program -> bit flags OR-ed into Cell::attributes.
enum Attribute : uint16_t {
    kBold = 1 << 0,
    kDim = 1 << 1,
    kItalic = 1 << 2,
    kUnderline = 1 << 3,
    kBlink = 1 << 4,
    kInverse = 1 << 5,
    kHidden = 1 << 6,
    kStrike = 1 << 7,
    kWideStart = 1 << 8,
    kWideEnd = 1 << 9,
};

// Mode-setting escape sequences from the program -> which mouse events the view must send back as bytes.
enum class MouseMode { None, Press, PressRelease, Drag, Motion };

/// Default, one of 256 palette entries, or full RGB, packed in one number to keep cells small.
struct TermColor {
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

    uint32_t packed = 0;
};

struct Cell {
    bool isBlank() const {
        return character == ' ' && foreground.isDefault() && background.isDefault() && (attributes & ~kWideEnd) == 0;
    }
    bool operator==(const Cell&) const = default;

    uint32_t character = ' ';
    TermColor foreground;
    TermColor background;
    uint16_t attributes = 0;
};

/// One line of the screen or of the history above it.
struct Row {
    std::vector<Cell> cells;
    /// True if the text continued onto the next line (wrapped, not ended).
    bool wrapped = false;
    /// Changes whenever the row changes, so a view can reuse its drawing of an unchanged row.
    uint64_t revision = 0;
};

/// Terminal state: cell grid, cursor, colors, history and escape-sequence modes. Feed it program
/// output with `write`; read cells back to draw. Replies programs wait for go out through `onReply`.
class Screen {
public:
    // ---- Constructors
    Screen(int columns, int rows, size_t historyLimit = 10000);

    // ---- Input and size
    void write(std::string_view bytes);
    void resize(int columns, int rows);

    // ---- Setters
    /// Colors reported when a program asks for "default" (OSC 10/11).
    void setDefaultColors(TermColor foreground, TermColor background);

    // ---- Grid getters
    int columns() const { return columns_; }
    int rows() const { return rows_; }
    size_t historyCount() const { return history_.size(); }
    /// 0..rows-1 is the visible screen; -1 is the newest history line, down to -historyCount().
    const Row& row(long index) const;
    /// Blank if the row is shorter than `column`.
    Cell cellAt(long rowIndex, int column) const;
    /// Start inclusive, end exclusive. Trailing blanks dropped; wrapped lines joined.
    std::string textInRange(long startRow, int startColumn, long endRow, int endColumn) const;

    // ---- Cursor getters
    int cursorRow() const { return cursorRow_; }
    int cursorColumn() const { return cursorColumn_; }
    bool cursorVisible() const { return cursorVisible_; }

    // ---- Mode getters
    bool onAlternateScreen() const { return usingAlternate_; }
    bool applicationCursorKeys() const { return applicationCursorKeys_; }
    bool bracketedPaste() const { return bracketedPaste_; }
    bool focusReporting() const { return focusReporting_; }
    MouseMode mouseMode() const { return mouseMode_; }
    bool mouseSgr() const { return mouseSgr_; }

    // ---- Info getters
    const std::string& title() const { return title_; }
    /// Folder the shell last reported (OSC 7), or empty.
    const std::string& workingDirectory() const { return workingDirectory_; }
    /// Increases whenever anything visible changed.
    uint64_t revision() const { return revision_; }

    // ---- Callbacks
    /// Bytes to send back to the program.
    std::function<void(const std::string&)> onReply;
    std::function<void()> onBell;
    std::function<void(const std::string&)> onTitleChange;
    std::function<void(const std::string&)> onDirectoryChange;

private:
    // Program bytes -> which part of an escape sequence the parser is inside.
    enum class ParserState {
        Ground,
        Escape,
        EscapeIntermediate,
        CsiEntry,
        CsiParameter,
        CsiIntermediate,
        Osc,
        OscEscape,
        IgnoredString,
        IgnoredStringEscape,
    };

    struct Charset {
        /// 'B' ASCII, '0' DEC line drawing.
        char designation = 'B';
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

    // ---- Parsing
    void feed(uint8_t byte);
    void handleGround(uint8_t byte);
    void handleControl(uint8_t byte);
    void handleEscapeFinal(uint8_t byte);
    void handleCsiFinal(uint8_t byte);
    void handleOsc();
    void printCharacter(uint32_t codePoint);
    /// Number from the sequence being parsed, or `fallback` when omitted.
    int parameter(size_t index, int fallback) const;

    // ---- Cells and rows
    Row& liveRow(int index) { return grid_.rows[static_cast<size_t>(index)]; }
    void touch(Row& row);
    Cell blankCell() const;
    void ensureWidth(Row& row, int columns);
    void putCell(int row, int column, const Cell& cell);
    /// Both ranges are [from, to).
    void eraseCells(int row, int fromColumn, int toColumn);
    void eraseRows(int fromRow, int toRow);
    void insertCharacters(int count);
    void deleteCharacters(int count);
    void insertLines(int count);
    void deleteLines(int count);

    // ---- Cursor and scrolling
    void lineFeed();
    void reverseLineFeed();
    /// Lines leaving the top of the whole screen become history unless `keepHistory` is false.
    void scrollUp(int count, bool keepHistory = true);
    void scrollDown(int count);
    void moveCursor(int row, int column);
    void setScrollRegion(int top, int bottom);
    void saveCursor();
    void restoreCursor();
    void tabForward(int count);
    void tabBackward(int count);

    // ---- Modes and state
    void switchScreen(bool alternate, bool clearAlternate, bool saveRestoreCursor);
    void reset();
    void applyGraphicRendition();
    /// `priv` is true for the "?" kind.
    void setMode(bool enable, bool priv);
    void reportDeviceStatus(int kind, bool priv);
    static int characterWidth(uint32_t codePoint);
    uint32_t translateCharset(uint32_t codePoint) const;
    void reply(const std::string& bytes);

    // ---- Private variables
    int columns_;
    int rows_;
    size_t historyLimit_;
    std::deque<Row> history_;
    Grid grid_;
    Grid savedPrimary_;
    bool usingAlternate_ = false;

    int cursorRow_ = 0;
    int cursorColumn_ = 0;
    bool pendingWrap_ = false;
    bool cursorVisible_ = true;
    Cell pen_;
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

    ParserState state_ = ParserState::Ground;
    std::vector<int> parameters_;
    // Per parameter: was it separated from the previous one by ":"?
    std::vector<bool> subParameter_;
    bool subNext_ = false;
    int currentParameter_ = -1;
    // "?", ">", "=" or "<" right after "ESC [", else 0.
    char privateMarker_ = 0;
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
