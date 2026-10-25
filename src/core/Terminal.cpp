#include "Terminal.hpp"
#include "CharacterWidth.hpp"

#include <algorithm>
#include <cstdio>
#include <cstdlib>

namespace gw::term {

namespace {

constexpr uint32_t kReplacementCharacter = 0xFFFD;

/// The 32 box-drawing and symbol characters programs get when they switch to DEC line drawing
/// ("ESC ( 0"): the letters "j" to "x" become corners and lines, and so on.
uint32_t lineDrawingCharacter(uint32_t codePoint) {
    switch (codePoint) {
        case '`': return 0x25C6;
        case 'a': return 0x2592;
        case 'f': return 0x00B0;
        case 'g': return 0x00B1;
        case 'j': return 0x2518;
        case 'k': return 0x2510;
        case 'l': return 0x250C;
        case 'm': return 0x2514;
        case 'n': return 0x253C;
        case 'o': return 0x23BA;
        case 'p': return 0x23BB;
        case 'q': return 0x2500;
        case 'r': return 0x23BC;
        case 's': return 0x23BD;
        case 't': return 0x251C;
        case 'u': return 0x2524;
        case 'v': return 0x2534;
        case 'w': return 0x252C;
        case 'x': return 0x2502;
        case 'y': return 0x2264;
        case 'z': return 0x2265;
        case '{': return 0x03C0;
        case '|': return 0x2260;
        case '}': return 0x00A3;
        case '~': return 0x00B7;
        default: return codePoint;
    }
}

int hexValue(char c) {
    if (c >= '0' && c <= '9') {
        return c - '0';
    }
    if (c >= 'a' && c <= 'f') {
        return c - 'a' + 10;
    }
    if (c >= 'A' && c <= 'F') {
        return c - 'A' + 10;
    }
    return -1;
}

constexpr size_t kMostParameters = 32;

/// Decodes %XX escapes in a path from a "file://" address.
std::string percentDecode(std::string_view text) {
    std::string decoded;
    for (size_t index = 0; index < text.size(); ++index) {
        bool escaped = text[index] == '%' && index + 2 < text.size() && hexValue(text[index + 1]) >= 0 &&
                       hexValue(text[index + 2]) >= 0;
        if (escaped) {
            decoded += static_cast<char>(hexValue(text[index + 1]) * 16 + hexValue(text[index + 2]));
            index += 2;
        } else {
            decoded += text[index];
        }
    }
    return decoded;
}

/// The color the standard 16-color palette entry looks like, for answering color queries.
std::string colorReply(TermColor color) {
    char buffer[64];
    std::snprintf(buffer, sizeof buffer, "rgb:%02x%02x/%02x%02x/%02x%02x", color.red(), color.red(), color.green(), color.green(),
                  color.blue(), color.blue());
    return buffer;
}

}  // namespace

// ---------------------------------------------------------------------------
// Construction and size

Screen::Screen(int columns, int rows, size_t historyLimit)
    : columns_(std::max(1, columns)), rows_(std::max(1, rows)), historyLimit_(historyLimit), scrollBottom_(std::max(1, rows) - 1) {
    grid_.rows.assign(static_cast<size_t>(rows_), Row{});
    for (Row& row : grid_.rows) {
        touch(row);
    }
    tabStops_.assign(static_cast<size_t>(columns_), false);
    for (int column = 8; column < columns_; column += 8) {
        tabStops_[static_cast<size_t>(column)] = true;
    }
}

const Row& Screen::row(long index) const {
    if (index >= 0 && index < rows_) {
        return grid_.rows[static_cast<size_t>(index)];
    }
    if (index < 0 && static_cast<size_t>(-index) <= history_.size()) {
        return history_[history_.size() - static_cast<size_t>(-index)];
    }
    return emptyRow_;
}

Cell Screen::cellAt(long rowIndex, int column) const {
    const Row& line = row(rowIndex);
    if (column >= 0 && static_cast<size_t>(column) < line.cells.size()) {
        return line.cells[static_cast<size_t>(column)];
    }
    return Cell{};
}

void Screen::setDefaultColors(TermColor foreground, TermColor background) {
    defaultForeground_ = foreground;
    defaultBackground_ = background;
}

void Screen::resize(int columns, int rows) {
    columns = std::max(1, columns);
    rows = std::max(1, rows);
    if (columns == columns_ && rows == rows_) {
        return;
    }

    auto fitColumns = [columns](std::vector<Row>& list) {
        for (Row& row : list) {
            if (row.cells.size() > static_cast<size_t>(columns)) {
                row.cells.resize(static_cast<size_t>(columns));
                // Do not leave half of a wide character at the edge.
                if (!row.cells.empty() && (row.cells.back().attributes & kWideStart)) {
                    row.cells.back() = Cell{};
                }
            }
        }
    };
    fitColumns(grid_.rows);
    fitColumns(savedPrimary_.rows);

    // Fewer rows: what the cursor pushes off the top goes to the history.
    while (static_cast<int>(grid_.rows.size()) > rows) {
        bool cursorAtBottom = cursorRow_ >= rows;
        if (cursorAtBottom && !usingAlternate_) {
            Row top = std::move(grid_.rows.front());
            while (!top.cells.empty() && top.cells.back().isBlank()) {
                top.cells.pop_back();
            }
            history_.push_back(std::move(top));
            if (history_.size() > historyLimit_) {
                history_.pop_front();
            }
        }
        if (cursorAtBottom) {
            grid_.rows.erase(grid_.rows.begin());
            --cursorRow_;
        } else {
            grid_.rows.pop_back();
        }
    }
    // More rows: bring lines back from the history, else add blank ones at the bottom.
    while (static_cast<int>(grid_.rows.size()) < rows) {
        if (!usingAlternate_ && !history_.empty()) {
            Row restored = std::move(history_.back());
            history_.pop_back();
            touch(restored);
            grid_.rows.insert(grid_.rows.begin(), std::move(restored));
            ++cursorRow_;
        } else {
            Row blank;
            touch(blank);
            grid_.rows.push_back(std::move(blank));
        }
    }
    if (!savedPrimary_.rows.empty()) {
        savedPrimary_.rows.resize(static_cast<size_t>(rows));
    }

    columns_ = columns;
    rows_ = rows;
    scrollTop_ = 0;
    scrollBottom_ = rows - 1;
    cursorRow_ = std::clamp(cursorRow_, 0, rows_ - 1);
    cursorColumn_ = std::clamp(cursorColumn_, 0, columns_ - 1);
    pendingWrap_ = false;
    tabStops_.assign(static_cast<size_t>(columns_), false);
    for (int column = 8; column < columns_; column += 8) {
        tabStops_[static_cast<size_t>(column)] = true;
    }
    for (Row& row : grid_.rows) {
        touch(row);
    }
}

// ---------------------------------------------------------------------------
// Touching and blanks

void Screen::touch(Row& row) {
    row.revision = nextRowRevision_++;
    ++revision_;
}

Cell Screen::blankCell() const {
    Cell cell;
    cell.background = pen_.background;
    return cell;
}

void Screen::ensureWidth(Row& row, int columns) {
    if (row.cells.size() < static_cast<size_t>(columns)) {
        row.cells.resize(static_cast<size_t>(columns), Cell{});
    }
}

void Screen::putCell(int rowIndex, int column, const Cell& cell) {
    Row& line = liveRow(rowIndex);
    ensureWidth(line, columns_);
    line.cells[static_cast<size_t>(column)] = cell;
    touch(line);
}

void Screen::eraseCells(int rowIndex, int from, int to) {
    from = std::clamp(from, 0, columns_);
    to = std::clamp(to, 0, columns_);
    if (to <= from) {
        return;
    }
    Row& line = liveRow(rowIndex);
    ensureWidth(line, columns_);
    // Erasing one half of a wide character removes the other half too.
    if (from > 0 && (line.cells[static_cast<size_t>(from - 1)].attributes & kWideStart)) {
        line.cells[static_cast<size_t>(from - 1)] = blankCell();
    }
    if (to < columns_ && (line.cells[static_cast<size_t>(to)].attributes & kWideEnd)) {
        line.cells[static_cast<size_t>(to)] = blankCell();
    }
    Cell blank = blankCell();
    for (int column = from; column < to; ++column) {
        line.cells[static_cast<size_t>(column)] = blank;
    }
    if (to == columns_) {
        line.wrapped = false;
    }
    touch(line);
}

void Screen::eraseRows(int from, int to) {
    for (int rowIndex = std::max(0, from); rowIndex < std::min(to, rows_); ++rowIndex) {
        Row& line = liveRow(rowIndex);
        line.cells.assign(static_cast<size_t>(columns_), blankCell());
        line.wrapped = false;
        touch(line);
    }
}

// ---------------------------------------------------------------------------
// Scrolling and cursor movement

void Screen::scrollUp(int count, bool keepHistory) {
    int height = scrollBottom_ - scrollTop_ + 1;
    count = std::min(count, height);
    if (count <= 0) {
        return;
    }
    if (keepHistory && !usingAlternate_ && scrollTop_ == 0) {
        for (int index = 0; index < count; ++index) {
            Row line = grid_.rows[static_cast<size_t>(index)];
            while (!line.cells.empty() && line.cells.back().isBlank()) {
                line.cells.pop_back();
            }
            history_.push_back(std::move(line));
            if (history_.size() > historyLimit_) {
                history_.pop_front();
            }
        }
    }
    // The rows keep their revision when they move: their content hasn't changed, so a view can
    // reuse what it drew for them.
    for (int index = scrollTop_; index + count <= scrollBottom_; ++index) {
        grid_.rows[static_cast<size_t>(index)] = std::move(grid_.rows[static_cast<size_t>(index + count)]);
    }
    ++revision_;
    eraseRows(scrollBottom_ - count + 1, scrollBottom_ + 1);
}

void Screen::scrollDown(int count) {
    int height = scrollBottom_ - scrollTop_ + 1;
    count = std::min(count, height);
    if (count <= 0) {
        return;
    }
    for (int index = scrollBottom_; index - count >= scrollTop_; --index) {
        grid_.rows[static_cast<size_t>(index)] = std::move(grid_.rows[static_cast<size_t>(index - count)]);
    }
    ++revision_;
    eraseRows(scrollTop_, scrollTop_ + count);
}

void Screen::lineFeed() {
    if (cursorRow_ == scrollBottom_) {
        scrollUp(1);
    } else if (cursorRow_ < rows_ - 1) {
        ++cursorRow_;
    }
    pendingWrap_ = false;
}

void Screen::reverseLineFeed() {
    if (cursorRow_ == scrollTop_) {
        scrollDown(1);
    } else if (cursorRow_ > 0) {
        --cursorRow_;
    }
    pendingWrap_ = false;
}

void Screen::moveCursor(int row, int column) {
    int top = originMode_ ? scrollTop_ : 0;
    int bottom = originMode_ ? scrollBottom_ : rows_ - 1;
    cursorRow_ = std::clamp(row, top, bottom);
    cursorColumn_ = std::clamp(column, 0, columns_ - 1);
    pendingWrap_ = false;
}

void Screen::setScrollRegion(int top, int bottom) {
    if (top < 0 || bottom >= rows_ || top >= bottom) {
        top = 0;
        bottom = rows_ - 1;
    }
    scrollTop_ = top;
    scrollBottom_ = bottom;
    moveCursor(originMode_ ? scrollTop_ : 0, 0);
}

void Screen::insertLines(int count) {
    if (cursorRow_ < scrollTop_ || cursorRow_ > scrollBottom_) {
        return;
    }
    int savedTop = scrollTop_;
    scrollTop_ = cursorRow_;
    scrollDown(count);
    scrollTop_ = savedTop;
    cursorColumn_ = 0;
    pendingWrap_ = false;
}

void Screen::deleteLines(int count) {
    if (cursorRow_ < scrollTop_ || cursorRow_ > scrollBottom_) {
        return;
    }
    int savedTop = scrollTop_;
    scrollTop_ = cursorRow_;
    scrollUp(count, false);  // deleted lines are not history
    scrollTop_ = savedTop;
    cursorColumn_ = 0;
    pendingWrap_ = false;
}

void Screen::insertCharacters(int count) {
    Row& line = liveRow(cursorRow_);
    ensureWidth(line, columns_);
    count = std::min(count, columns_ - cursorColumn_);
    for (int column = columns_ - 1; column - count >= cursorColumn_; --column) {
        line.cells[static_cast<size_t>(column)] = line.cells[static_cast<size_t>(column - count)];
    }
    Cell blank = blankCell();
    for (int column = cursorColumn_; column < cursorColumn_ + count; ++column) {
        line.cells[static_cast<size_t>(column)] = blank;
    }
    touch(line);
    pendingWrap_ = false;
}

void Screen::deleteCharacters(int count) {
    Row& line = liveRow(cursorRow_);
    ensureWidth(line, columns_);
    count = std::min(count, columns_ - cursorColumn_);
    for (int column = cursorColumn_; column + count < columns_; ++column) {
        line.cells[static_cast<size_t>(column)] = line.cells[static_cast<size_t>(column + count)];
    }
    Cell blank = blankCell();
    for (int column = columns_ - count; column < columns_; ++column) {
        line.cells[static_cast<size_t>(column)] = blank;
    }
    touch(line);
    pendingWrap_ = false;
}

void Screen::tabForward(int count) {
    for (int step = 0; step < count; ++step) {
        int column = cursorColumn_ + 1;
        while (column < columns_ - 1 && !tabStops_[static_cast<size_t>(column)]) {
            ++column;
        }
        cursorColumn_ = std::min(column, columns_ - 1);
    }
    pendingWrap_ = false;
}

void Screen::tabBackward(int count) {
    for (int step = 0; step < count; ++step) {
        int column = cursorColumn_ - 1;
        while (column > 0 && !tabStops_[static_cast<size_t>(column)]) {
            --column;
        }
        cursorColumn_ = std::max(column, 0);
    }
    pendingWrap_ = false;
}

void Screen::saveCursor() {
    saved_.row = cursorRow_;
    saved_.column = cursorColumn_;
    saved_.pen = pen_;
    saved_.pendingWrap = pendingWrap_;
    saved_.originMode = originMode_;
    saved_.charset0 = charsets_[0];
    saved_.charset1 = charsets_[1];
    saved_.activeCharset = activeCharset_;
}

void Screen::restoreCursor() {
    cursorRow_ = std::clamp(saved_.row, 0, rows_ - 1);
    cursorColumn_ = std::clamp(saved_.column, 0, columns_ - 1);
    pen_ = saved_.pen;
    pendingWrap_ = saved_.pendingWrap;
    originMode_ = saved_.originMode;
    charsets_[0] = saved_.charset0;
    charsets_[1] = saved_.charset1;
    activeCharset_ = saved_.activeCharset;
}

void Screen::switchScreen(bool alternate, bool clearAlternate, bool saveRestoreCursor) {
    if (alternate == usingAlternate_) {
        return;
    }
    if (alternate) {
        if (saveRestoreCursor) {
            saveCursor();
        }
        savedPrimary_.rows = std::move(grid_.rows);
        grid_.rows.assign(static_cast<size_t>(rows_), Row{});
        for (Row& line : grid_.rows) {
            line.cells.assign(static_cast<size_t>(columns_), Cell{});
            touch(line);
        }
        usingAlternate_ = true;
        (void)clearAlternate;
    } else {
        grid_.rows = std::move(savedPrimary_.rows);
        savedPrimary_.rows.clear();
        if (static_cast<int>(grid_.rows.size()) != rows_) {
            grid_.rows.resize(static_cast<size_t>(rows_));
        }
        for (Row& line : grid_.rows) {
            touch(line);
        }
        usingAlternate_ = false;
        if (saveRestoreCursor) {
            restoreCursor();
        }
    }
    scrollTop_ = 0;
    scrollBottom_ = rows_ - 1;
    pendingWrap_ = false;
}

void Screen::reset() {
    if (usingAlternate_) {
        switchScreen(false, false, false);
    }
    pen_ = Cell{};
    autoWrap_ = true;
    originMode_ = false;
    insertMode_ = false;
    newlineMode_ = false;
    applicationCursorKeys_ = false;
    bracketedPaste_ = false;
    focusReporting_ = false;
    cursorVisible_ = true;
    mouseMode_ = MouseMode::None;
    mouseSgr_ = false;
    charsets_[0] = charsets_[1] = 'B';
    activeCharset_ = 0;
    scrollTop_ = 0;
    scrollBottom_ = rows_ - 1;
    tabStops_.assign(static_cast<size_t>(columns_), false);
    for (int column = 8; column < columns_; column += 8) {
        tabStops_[static_cast<size_t>(column)] = true;
    }
    eraseRows(0, rows_);
    cursorRow_ = cursorColumn_ = 0;
    pendingWrap_ = false;
}

// ---------------------------------------------------------------------------
// Printing

int Screen::characterWidth(uint32_t c) { return codePointCells(c); }

uint32_t Screen::translateCharset(uint32_t codePoint) const {
    if (charsets_[activeCharset_] == '0' && codePoint >= 0x5F && codePoint <= 0x7E) {
        return lineDrawingCharacter(codePoint);
    }
    return codePoint;
}

void Screen::printCharacter(uint32_t codePoint) {
    codePoint = translateCharset(codePoint);
    int width = characterWidth(codePoint);
    if (width == 0) {
        return;  // combining characters are not drawn on their own
    }
    // A double-width character needs two columns; on a one-column screen it can never be shown.
    // (Without this check its second half was written one cell past the end of the row.)
    if (width == 2 && columns_ < 2) {
        return;
    }
    lastPrinted_ = codePoint;

    if (pendingWrap_ && autoWrap_) {
        liveRow(cursorRow_).wrapped = true;
        cursorColumn_ = 0;
        lineFeed();
    }
    // A wide character that does not fit in the last column moves to the next line.
    if (width == 2 && cursorColumn_ == columns_ - 1) {
        if (autoWrap_) {
            putCell(cursorRow_, cursorColumn_, blankCell());
            liveRow(cursorRow_).wrapped = true;
            cursorColumn_ = 0;
            lineFeed();
        } else {
            return;
        }
    }
    if (insertMode_) {
        insertCharacters(width);
    }

    Cell cell = pen_;
    cell.character = codePoint;
    cell.attributes &= static_cast<uint16_t>(~(kWideStart | kWideEnd));
    if (width == 2) {
        cell.attributes |= kWideStart;
    }

    // Overwriting half of a wide character blanks the other half.
    Row& line = liveRow(cursorRow_);
    ensureWidth(line, columns_);
    size_t cellIndex = static_cast<size_t>(cursorColumn_);
    if ((line.cells[cellIndex].attributes & kWideEnd) && cursorColumn_ > 0) {
        line.cells[cellIndex - 1] = blankCell();
    }
    if ((line.cells[cellIndex].attributes & kWideStart) && cellIndex + 1 < line.cells.size()) {
        line.cells[cellIndex + 1] = blankCell();
    }
    line.cells[cellIndex] = cell;
    if (width == 2 && cellIndex + 1 < line.cells.size()) {
        Cell filler = pen_;
        filler.character = ' ';
        filler.attributes = kWideEnd;
        line.cells[cellIndex + 1] = filler;
    }
    touch(line);

    cursorColumn_ += width;
    if (cursorColumn_ >= columns_) {
        cursorColumn_ = columns_ - 1;
        pendingWrap_ = autoWrap_;
    }
}

// ---------------------------------------------------------------------------
// The parser

void Screen::write(std::string_view bytes) {
    for (char c : bytes) {
        feed(static_cast<uint8_t>(c));
    }
}

void Screen::handleControl(uint8_t byte) {
    switch (byte) {
        case 0x07:
            if (onBell) {
                onBell();
            }
            break;
        case 0x08:  // backspace
            if (cursorColumn_ > 0) {
                --cursorColumn_;
            }
            pendingWrap_ = false;
            break;
        case 0x09:  // tab
            tabForward(1);
            break;
        case 0x0A:
        case 0x0B:
        case 0x0C:
            lineFeed();
            if (newlineMode_) {
                cursorColumn_ = 0;
            }
            break;
        case 0x0D:
            cursorColumn_ = 0;
            pendingWrap_ = false;
            break;
        case 0x0E:
            activeCharset_ = 1;
            break;
        case 0x0F:
            activeCharset_ = 0;
            break;
        default:
            break;
    }
}

void Screen::feed(uint8_t byte) {
    switch (state_) {
        case ParserState::Ground:
            handleGround(byte);
            return;

        case ParserState::Escape:
            if (byte == 0x1B) {
                return; // ESC ESC
            }
            if (byte < 0x20) {         // a control inside an escape sequence still acts
                handleControl(byte);
                return;
            }
            handleEscapeFinal(byte);
            return;

        case ParserState::EscapeIntermediate:
            if (byte < 0x20) {
                handleControl(byte);
                return;
            }
            if (intermediate_ == '(') {
                charsets_[0] = static_cast<char>(byte);
            } else if (intermediate_ == ')') {
                charsets_[1] = static_cast<char>(byte);
            } else if (intermediate_ == '#' && byte == '8') {
                for (int rowIndex = 0; rowIndex < rows_; ++rowIndex) {
                    Row& line = liveRow(rowIndex);
                    line.cells.assign(static_cast<size_t>(columns_), Cell{});
                    for (Cell& cell : line.cells) {
                        cell.character = 'E';
                    }
                    touch(line);
                }
            }
            state_ = ParserState::Ground;
            return;

        case ParserState::CsiEntry:
        case ParserState::CsiParameter:
        case ParserState::CsiIntermediate:
            if (byte == 0x1B) {
                state_ = ParserState::Escape;
                return;
            }
            if (byte == 0x18 || byte == 0x1A) {
                state_ = ParserState::Ground;
                return;
            }
            if (byte < 0x20) {
                handleControl(byte);
                return;
            }
            if (byte >= '0' && byte <= '9' && state_ != ParserState::CsiIntermediate) {
                if (currentParameter_ < 0) {
                    currentParameter_ = 0;
                }
                currentParameter_ = std::min(currentParameter_ * 10 + (byte - '0'), 1000000);
                state_ = ParserState::CsiParameter;
                return;
            }
            if ((byte == ';' || byte == ':') && state_ != ParserState::CsiIntermediate) {
                // No real sequence has more than a few dozen numbers; extra ones are dropped, so
                // a stream of semicolons can't grow the list without end.
                if (parameters_.size() < kMostParameters) {
                    parameters_.push_back(currentParameter_);
                    subParameter_.push_back(subNext_);
                }
                subNext_ = byte == ':';
                currentParameter_ = -1;
                state_ = ParserState::CsiParameter;
                return;
            }
            if (byte >= '<' && byte <= '?' && state_ == ParserState::CsiEntry) {
                privateMarker_ = static_cast<char>(byte);
                return;
            }
            if (byte >= 0x20 && byte <= 0x2F) {
                intermediate_ = static_cast<char>(byte);
                state_ = ParserState::CsiIntermediate;
                return;
            }
            if (byte >= 0x40 && byte <= 0x7E) {
                bool hasParameter = currentParameter_ >= 0 || !parameters_.empty();
                if (hasParameter && parameters_.size() < kMostParameters) {
                    parameters_.push_back(currentParameter_);
                    subParameter_.push_back(subNext_);
                }
                handleCsiFinal(byte);
                state_ = ParserState::Ground;
                return;
            }
            state_ = ParserState::Ground;  // malformed
            return;

        case ParserState::Osc:
            if (byte == 0x07) {
                handleOsc();
                state_ = ParserState::Ground;
            } else if (byte == 0x1B) {
                state_ = ParserState::OscEscape;
            } else if (byte == 0x18 || byte == 0x1A) {
                state_ = ParserState::Ground;
            } else if (oscBuffer_.size() < 8192) {
                oscBuffer_ += static_cast<char>(byte);
            }
            return;

        case ParserState::OscEscape:
            if (byte == '\\') {
                handleOsc();
                state_ = ParserState::Ground;
            } else {
                state_ = ParserState::Escape;
                feed(byte);
            }
            return;

        case ParserState::IgnoredString:
            if (byte == 0x1B) {
                state_ = ParserState::IgnoredStringEscape;
            } else if (byte == 0x07 || byte == 0x18 || byte == 0x1A) {
                state_ = ParserState::Ground;
            }
            return;

        case ParserState::IgnoredStringEscape:
            if (byte == '\\') {
                state_ = ParserState::Ground;
            } else {
                state_ = ParserState::IgnoredString;
            }
            return;
    }
}

void Screen::handleGround(uint8_t byte) {
    if (byte < 0x20) {
        utf8Remaining_ = 0;
        if (byte == 0x1B) {
            state_ = ParserState::Escape;
            return;
        }
        handleControl(byte);
        return;
    }
    if (byte < 0x80) {
        if (utf8Remaining_ > 0) {  // an interrupted multi-byte character
            utf8Remaining_ = 0;
            printCharacter(kReplacementCharacter);
        }
        if (byte != 0x7F) {
            printCharacter(byte);
        }
        return;
    }
    // UTF-8
    if (byte >= 0xC2 && byte <= 0xF4) {
        if (utf8Remaining_ > 0) {
            printCharacter(kReplacementCharacter);
        }
        if (byte < 0xE0) {
            utf8Code_ = byte & 0x1F;
            utf8Remaining_ = 1;
        } else if (byte < 0xF0) {
            utf8Code_ = byte & 0x0F;
            utf8Remaining_ = 2;
        } else {
            utf8Code_ = byte & 0x07;
            utf8Remaining_ = 3;
        }
        return;
    }
    if (byte >= 0x80 && byte <= 0xBF && utf8Remaining_ > 0) {
        utf8Code_ = (utf8Code_ << 6) | (byte & 0x3F);
        if (--utf8Remaining_ == 0) {
            printCharacter(utf8Code_ > 0x10FFFF ? kReplacementCharacter : utf8Code_);
        }
        return;
    }
    utf8Remaining_ = 0;
    printCharacter(kReplacementCharacter);
}

void Screen::handleEscapeFinal(uint8_t byte) {
    state_ = ParserState::Ground;
    switch (byte) {
        case '[':
            state_ = ParserState::CsiEntry;
            parameters_.clear();
            subParameter_.clear();
            currentParameter_ = -1;
            subNext_ = false;
            privateMarker_ = 0;
            intermediate_ = 0;
            break;
        case ']':
            state_ = ParserState::Osc;
            oscBuffer_.clear();
            break;
        case 'P':
        case 'X':
        case '^':
        case '_':
            state_ = ParserState::IgnoredString;
            break;
        case '(':
        case ')':
        case '*':
        case '+':
        case '#':
        case '%':
        case ' ':
            state_ = ParserState::EscapeIntermediate;
            intermediate_ = static_cast<char>(byte);
            break;
        case '7':
            saveCursor();
            break;
        case '8':
            restoreCursor();
            break;
        case 'D':
            lineFeed();
            break;
        case 'E':
            cursorColumn_ = 0;
            lineFeed();
            break;
        case 'M':
            reverseLineFeed();
            break;
        case 'H':
            tabStops_[static_cast<size_t>(cursorColumn_)] = true;
            break;
        case 'c':
            reset();
            break;
        default:
            break;  // keypad modes, locking shifts, ST…
    }
}

// ---------------------------------------------------------------------------
// Control sequences

int Screen::parameter(size_t index, int fallback) const {
    if (index >= parameters_.size() || parameters_[index] < 0) {
        return fallback;
    }
    return parameters_[index];
}

void Screen::reply(const std::string& bytes) {
    if (onReply) {
        onReply(bytes);
    }
}

void Screen::applyGraphicRendition() {
    if (parameters_.empty()) {
        pen_.foreground = TermColor::defaultColor();
        pen_.background = TermColor::defaultColor();
        pen_.attributes = 0;
        return;
    }
    for (size_t index = 0; index < parameters_.size(); ++index) {
        int code = parameters_[index] < 0 ? 0 : parameters_[index];
        switch (code) {
            case 0:
                pen_.foreground = TermColor::defaultColor();
                pen_.background = TermColor::defaultColor();
                pen_.attributes = 0;
                break;
            case 1: pen_.attributes |= kBold; break;
            case 2: pen_.attributes |= kDim; break;
            case 3: pen_.attributes |= kItalic; break;
            case 4: pen_.attributes |= kUnderline; break;
            case 5: case 6: pen_.attributes |= kBlink; break;
            case 7: pen_.attributes |= kInverse; break;
            case 8: pen_.attributes |= kHidden; break;
            case 9: pen_.attributes |= kStrike; break;
            case 21: pen_.attributes |= kUnderline; break;
            case 22: pen_.attributes &= static_cast<uint16_t>(~(kBold | kDim)); break;
            case 23: pen_.attributes &= static_cast<uint16_t>(~kItalic); break;
            case 24: pen_.attributes &= static_cast<uint16_t>(~kUnderline); break;
            case 25: pen_.attributes &= static_cast<uint16_t>(~kBlink); break;
            case 27: pen_.attributes &= static_cast<uint16_t>(~kInverse); break;
            case 28: pen_.attributes &= static_cast<uint16_t>(~kHidden); break;
            case 29: pen_.attributes &= static_cast<uint16_t>(~kStrike); break;
            case 39: pen_.foreground = TermColor::defaultColor(); break;
            case 49: pen_.background = TermColor::defaultColor(); break;
            case 38:
            case 48:
            case 58: {
                // Extended colors: 38;5;n  38;2;r;g;b  and the colon forms 38:5:n  38:2::r:g:b
                bool colon = index + 1 < parameters_.size() && subParameter_[index + 1];
                std::vector<int> values;
                size_t next = index + 1;
                if (colon) {
                    while (next < parameters_.size() && subParameter_[next]) {
                        values.push_back(parameters_[next++]);
                    }
                } else {
                    if (next < parameters_.size()) {
                        values.push_back(parameters_[next++]);
                    }
                    // 38;2;r;g;b is a true color (three more numbers), 38;5;n a palette index (one).
                    size_t need = 0;
                    if (!values.empty() && values[0] == 2) {
                        need = 3;
                    } else if (!values.empty() && values[0] == 5) {
                        need = 1;
                    }
                    for (size_t taken = 0; taken < need && next < parameters_.size(); ++taken) {
                        values.push_back(parameters_[next++]);
                    }
                }
                index = next - 1;
                TermColor color;
                bool valid = false;
                if (!values.empty() && values[0] == 5 && values.size() >= 2) {
                    color = TermColor::indexed(static_cast<uint8_t>(std::clamp(values[1], 0, 255)));
                    valid = true;
                } else if (!values.empty() && values[0] == 2 && values.size() >= 4) {
                    // With a color-space slot (38:2::r:g:b) there is one extra value.
                    size_t first = values.size() >= 5 ? values.size() - 3 : 1;
                    color = TermColor::rgb(static_cast<uint8_t>(std::clamp(values[first], 0, 255)),
                                           static_cast<uint8_t>(std::clamp(values[first + 1], 0, 255)),
                                           static_cast<uint8_t>(std::clamp(values[first + 2], 0, 255)));
                    valid = true;
                }
                if (valid && code == 38) {
                    pen_.foreground = color;
                }
                if (valid && code == 48) {
                    pen_.background = color;
                }
                break;
            }
            default:
                if (code >= 30 && code <= 37) {
                    pen_.foreground = TermColor::indexed(static_cast<uint8_t>(code - 30));
                } else if (code >= 40 && code <= 47) {
                    pen_.background = TermColor::indexed(static_cast<uint8_t>(code - 40));
                } else if (code >= 90 && code <= 97) {
                    pen_.foreground = TermColor::indexed(static_cast<uint8_t>(code - 90 + 8));
                } else if (code >= 100 && code <= 107) {
                    pen_.background = TermColor::indexed(static_cast<uint8_t>(code - 100 + 8));
                }
                break;
        }
    }
}

void Screen::setMode(bool enable, bool priv) {
    for (size_t index = 0; index < parameters_.size(); ++index) {
        int mode = parameters_[index];
        if (!priv) {
            if (mode == 4) {
                insertMode_ = enable;
            } else if (mode == 20) {
                newlineMode_ = enable;
            }
            continue;
        }
        switch (mode) {
            case 1: applicationCursorKeys_ = enable; break;
            case 6:
                originMode_ = enable;
                moveCursor(originMode_ ? scrollTop_ : 0, 0);
                break;
            case 7: autoWrap_ = enable; break;
            case 25: cursorVisible_ = enable; break;
            case 47:
            case 1047:
                switchScreen(enable, false, false);
                break;
            case 1048:
                if (enable) {
                    saveCursor();
                } else {
                    restoreCursor();
                }
                break;
            case 1049:
                switchScreen(enable, true, true);
                break;
            case 2004: bracketedPaste_ = enable; break;
            case 1004: focusReporting_ = enable; break;
            case 9: mouseMode_ = enable ? MouseMode::Press : MouseMode::None; break;
            case 1000: mouseMode_ = enable ? MouseMode::PressRelease : MouseMode::None; break;
            case 1002: mouseMode_ = enable ? MouseMode::Drag : MouseMode::None; break;
            case 1003: mouseMode_ = enable ? MouseMode::Motion : MouseMode::None; break;
            case 1006: mouseSgr_ = enable; break;
            default: break;
        }
    }
}

void Screen::reportDeviceStatus(int kind, bool priv) {
    if (kind == 5) {
        reply("\x1b[0n");
    } else if (kind == 6) {
        int row = cursorRow_ + 1 - (originMode_ ? scrollTop_ : 0);
        std::string text = std::string("\x1b[") + (priv ? "?" : "") + std::to_string(row) + ";" + std::to_string(cursorColumn_ + 1) + "R";
        reply(text);
    }
}

void Screen::handleCsiFinal(uint8_t byte) {
    ++revision_;
    auto count = [this](size_t index) { return std::max(1, parameter(index, 1)); };
    bool priv = privateMarker_ == '?';

    if (privateMarker_ == '>' && byte == 'c') {
        reply("\x1b[>1;10;0c");
        return;
    }
    if (privateMarker_ == '>' && byte == 'q') {
        reply("\x1bP>|Glasswork\x1b\\");
        return;
    }
    if (privateMarker_ != 0 && !priv) {
        return;  // other private sequences (kitty keyboard, etc.) are not supported
    }
    if (intermediate_ == ' ' && byte == 'q') {
        return;  // cursor shape
    }
    if (intermediate_ == '!' && byte == 'p') {  // soft reset
        pen_ = Cell{};
        autoWrap_ = true;
        originMode_ = false;
        insertMode_ = false;
        applicationCursorKeys_ = false;
        cursorVisible_ = true;
        scrollTop_ = 0;
        scrollBottom_ = rows_ - 1;
        return;
    }

    switch (byte) {
        case 'A': {  // cursor up
            // Moving up stops at the top margin if the cursor is inside the scroll region.
            int limit = cursorRow_ >= scrollTop_ ? scrollTop_ : 0;
            moveCursor(std::max(cursorRow_ - count(0), limit), cursorColumn_);
            break;
        }
        case 'B':  // cursor down
        case 'e': {
            int limit = cursorRow_ <= scrollBottom_ ? scrollBottom_ : rows_ - 1;
            moveCursor(std::min(cursorRow_ + count(0), limit), cursorColumn_);
            break;
        }
        case 'C':  // cursor forward
        case 'a':
            moveCursor(cursorRow_, cursorColumn_ + count(0));
            break;
        case 'D':  // cursor back
            moveCursor(cursorRow_, cursorColumn_ - count(0));
            break;
        case 'E':  // start of a line further down
            moveCursor(cursorRow_ + count(0), 0);
            break;
        case 'F':  // start of a line further up
            moveCursor(cursorRow_ - count(0), 0);
            break;
        case 'G':  // go to a column
        case '`':
            moveCursor(cursorRow_, parameter(0, 1) - 1);
            break;
        case 'H':  // go to a row and column
        case 'f':
            moveCursor((originMode_ ? scrollTop_ : 0) + parameter(0, 1) - 1, parameter(1, 1) - 1);
            break;
        case 'd':  // go to a row
            moveCursor((originMode_ ? scrollTop_ : 0) + parameter(0, 1) - 1, cursorColumn_);
            break;
        case 'I':  // tab forward
            tabForward(count(0));
            break;
        case 'Z':  // tab backward
            tabBackward(count(0));
            break;
        case 'J': {  // erase in the display: 0 below, 1 above, 2 all, 3 all including history
            int mode = parameter(0, 0);
            if (mode == 0) {
                eraseCells(cursorRow_, cursorColumn_, columns_);
                eraseRows(cursorRow_ + 1, rows_);
            } else if (mode == 1) {
                eraseRows(0, cursorRow_);
                eraseCells(cursorRow_, 0, cursorColumn_ + 1);
            } else if (mode == 2) {
                eraseRows(0, rows_);
            } else if (mode == 3) {
                history_.clear();
            }
            pendingWrap_ = false;
            break;
        }
        case 'K': {  // erase in the line: 0 to the end, 1 to the start, 2 all
            int mode = parameter(0, 0);
            if (mode == 0) {
                eraseCells(cursorRow_, cursorColumn_, columns_);
            } else if (mode == 1) {
                eraseCells(cursorRow_, 0, cursorColumn_ + 1);
            } else if (mode == 2) {
                eraseCells(cursorRow_, 0, columns_);
            }
            pendingWrap_ = false;
            break;
        }
        case 'L': insertLines(count(0)); break;
        case 'M': deleteLines(count(0)); break;
        case '@': insertCharacters(count(0)); break;
        case 'P': deleteCharacters(count(0)); break;
        case 'X':  // blank some characters without moving the rest
            eraseCells(cursorRow_, cursorColumn_, cursorColumn_ + count(0));
            break;
        case 'S':  // scroll the text up
            scrollUp(count(0));
            break;
        case 'T':  // scroll the text down
            if (parameters_.size() <= 1) {
                scrollDown(count(0));
            }
            break;
        case 'b':  // repeat the last printed character
            for (int repeat = 0; repeat < std::min(count(0), 10000); ++repeat) {
                printCharacter(lastPrinted_);
            }
            break;
        case 'c':  // "what are you?" (device attributes)
            if (parameter(0, 0) == 0) {
                reply("\x1b[?62;22c");
            }
            break;
        case 'g': {  // clear tab stops: 0 here, 3 all
            int mode = parameter(0, 0);
            if (mode == 0) {
                tabStops_[static_cast<size_t>(cursorColumn_)] = false;
            } else if (mode == 3) {
                std::fill(tabStops_.begin(), tabStops_.end(), false);
            }
            break;
        }
        case 'h':  // switch a mode on
            setMode(true, priv);
            break;
        case 'l':  // switch a mode off
            setMode(false, priv);
            break;
        case 'm':  // colors and text styles (select graphic rendition)
            applyGraphicRendition();
            break;
        case 'n':  // status report requests
            reportDeviceStatus(parameter(0, 0), priv);
            break;
        case 'r':  // set the scrolling region
            if (!priv) {
                setScrollRegion(parameter(0, 1) - 1, parameter(1, rows_) - 1);
            }
            break;
        case 's':  // save the cursor
            if (parameters_.empty()) {
                saveCursor();
            }
            break;
        case 'u':  // restore the cursor
            restoreCursor();
            break;
        case 't': {  // window reports; only the text area size (18) is answered
            int kind = parameter(0, 0);
            if (kind == 18) {
                reply("\x1b[8;" + std::to_string(rows_) + ";" + std::to_string(columns_) + "t");
            }
            break;
        }
        default:
            break;
    }
}

void Screen::handleOsc() {
    // "code;text"
    size_t semicolon = oscBuffer_.find(';');
    std::string codeText = oscBuffer_.substr(0, semicolon);
    std::string text = semicolon == std::string::npos ? std::string() : oscBuffer_.substr(semicolon + 1);
    int code = codeText.empty() ? -1 : std::atoi(codeText.c_str());

    switch (code) {
        case 0:
        case 1:
        case 2:
            title_ = text;
            if (onTitleChange) {
                onTitleChange(title_);
            }
            break;
        case 7: {
            // file://host/path
            if (text.rfind("file://", 0) == 0) {
                size_t slash = text.find('/', 7);
                if (slash != std::string::npos) {
                    workingDirectory_ = percentDecode(std::string_view(text).substr(slash));
                    if (onDirectoryChange) {
                        onDirectoryChange(workingDirectory_);
                    }
                }
            }
            break;
        }
        case 10:
        case 11:
            if (text == "?") {
                TermColor color = code == 10 ? defaultForeground_ : defaultBackground_;
                reply("\x1b]" + std::to_string(code) + ";" + colorReply(color) + "\x1b\\");
            }
            break;
        default:
            break;
    }
}

// ---------------------------------------------------------------------------
// Copying text out

std::string Screen::textInRange(long startRow, int startColumn, long endRow, int endColumn) const {
    if (endRow < startRow || (endRow == startRow && endColumn <= startColumn)) {
        return std::string();
    }
    std::string text;
    auto appendCharacter = [&text](uint32_t code) {
        if (code < 0x80) {
            text += static_cast<char>(code);
        } else if (code < 0x800) {
            text += static_cast<char>(0xC0 | (code >> 6));
            text += static_cast<char>(0x80 | (code & 0x3F));
        } else if (code < 0x10000) {
            text += static_cast<char>(0xE0 | (code >> 12));
            text += static_cast<char>(0x80 | ((code >> 6) & 0x3F));
            text += static_cast<char>(0x80 | (code & 0x3F));
        } else {
            text += static_cast<char>(0xF0 | (code >> 18));
            text += static_cast<char>(0x80 | ((code >> 12) & 0x3F));
            text += static_cast<char>(0x80 | ((code >> 6) & 0x3F));
            text += static_cast<char>(0x80 | (code & 0x3F));
        }
    };
    for (long rowIndex = startRow; rowIndex <= endRow; ++rowIndex) {
        const Row& line = row(rowIndex);
        int from = rowIndex == startRow ? std::max(0, startColumn) : 0;
        int to = rowIndex == endRow ? std::min(endColumn, columns_) : columns_;
        std::string piece;
        size_t before = text.size();
        for (int column = from; column < to; ++column) {
            if (static_cast<size_t>(column) >= line.cells.size()) {
                appendCharacter(' ');
                continue;
            }
            const Cell& cell = line.cells[static_cast<size_t>(column)];
            if (cell.attributes & kWideEnd) {
                continue;
            }
            appendCharacter(cell.character == 0 ? ' ' : cell.character);
        }
        // Trailing blanks are not text — unless the line continues onto the next.
        if (!line.wrapped || rowIndex == endRow) {
            while (text.size() > before && text.back() == ' ') {
                text.pop_back();
            }
        }
        if (rowIndex != endRow && !line.wrapped) {
            text += '\n';
        }
    }
    return text;
}

}  // namespace gw::term
