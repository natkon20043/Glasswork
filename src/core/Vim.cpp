#include "Vim.hpp"

#include <algorithm>
#include <cctype>

namespace gw {

using vim_detail::Command;
using vim_detail::Motion;
using vim_detail::Region;

namespace {

constexpr size_t kEndOfLine = static_cast<size_t>(-1);
const std::string kEscape = "\x1b";

// ---- Characters and lines

size_t lastCharStart(std::string_view line) {
    return line.empty() ? 0 : floorToCharacter(line, line.size() - 1);
}

/// The column of the character after the one at `column` (the line's end if there is none).
size_t nextColumn(std::string_view line, size_t column) {
    if (column >= line.size()) {
        return line.size();
    }
    ++column;
    while (column < line.size() && (static_cast<unsigned char>(line[column]) & 0xC0) == 0x80) {
        ++column;
    }
    return column;
}

size_t previousColumn(std::string_view line, size_t column) {
    return column == 0 ? 0 : floorToCharacter(line, column - 1);
}

size_t characterIndex(std::string_view line, size_t column) {
    size_t index = 0;
    for (size_t at = 0; at < column && at < line.size(); at = nextColumn(line, at)) {
        ++index;
    }
    return index;
}

size_t columnOfCharacter(std::string_view line, size_t index) {
    size_t column = 0;
    while (index > 0 && column < line.size()) {
        column = nextColumn(line, column);
        --index;
    }
    return column;
}

/// 0 blank (or a line end), 1 a word character, 2 punctuation. With `big` (W, B, E) everything
/// that isn't blank is one kind.
int classAt(std::string_view line, size_t column, bool big) {
    if (column >= line.size()) {
        return 0;
    }
    unsigned char byte = static_cast<unsigned char>(line[column]);
    if (byte == ' ' || byte == '\t' || byte == '\r') {
        return 0;
    }
    if (big) {
        return 1;
    }
    return isWordByte(byte) ? 1 : 2;
}

int classAt(const TextBuffer& buffer, Position at, bool big) {
    return classAt(buffer.line(at.line), at.column, big);
}

bool isEmptyLine(const TextBuffer& buffer, Position at) {
    return buffer.line(at.line).empty();
}

/// The first character of the line that isn't a blank (the last one on a blank line).
size_t firstNonBlank(const TextBuffer& buffer, size_t line) {
    std::string_view text = buffer.line(line);
    size_t column = buffer.indentEnd(line);
    return column >= text.size() ? lastCharStart(text) : column;
}

/// One character forward. The end of a line counts as a position (the line break), so words end
/// there. False at the end of the document.
bool stepForward(const TextBuffer& buffer, Position& at) {
    std::string_view line = buffer.line(at.line);
    if (at.column < line.size()) {
        at.column = nextColumn(line, at.column);
        return true;
    }
    if (at.line + 1 < buffer.lineCount()) {
        ++at.line;
        at.column = 0;
        return true;
    }
    return false;
}

bool stepBackward(const TextBuffer& buffer, Position& at) {
    if (at.column > 0) {
        at.column = previousColumn(buffer.line(at.line), at.column);
        return true;
    }
    if (at.line > 0) {
        --at.line;
        at.column = buffer.line(at.line).size();
        return true;
    }
    return false;
}

Position lastCharacter(const TextBuffer& buffer) {
    size_t line = buffer.lineCount() - 1;
    return {line, lastCharStart(buffer.line(line))};
}

// ---- Word motions

/// w and W: the start of the next word. An empty line counts as a word.
Position wordForward(const TextBuffer& buffer, Position at, bool big) {
    int kind = classAt(buffer, at, big);
    if (kind != 0) {
        while (classAt(buffer, at, big) == kind) {
            if (!stepForward(buffer, at)) {
                return buffer.end();
            }
        }
    } else if (!stepForward(buffer, at)) {
        return buffer.end();
    }
    while (!isEmptyLine(buffer, at) && classAt(buffer, at, big) == 0) {
        if (!stepForward(buffer, at)) {
            return buffer.end();
        }
    }
    return at;
}

/// e and E: the last character of the word (the next one if already on its last character).
Position wordEndForward(const TextBuffer& buffer, Position at, bool big) {
    Position start = at;
    if (!stepForward(buffer, at)) {
        return start;
    }
    while (classAt(buffer, at, big) == 0) {
        if (!stepForward(buffer, at)) {
            return lastCharacter(buffer);
        }
    }
    int kind = classAt(buffer, at, big);
    while (true) {
        Position next = at;
        if (!stepForward(buffer, next) || classAt(buffer, next, big) != kind) {
            return at;
        }
        at = next;
    }
}

/// b and B: the start of this word, or of the one before it.
Position wordBackward(const TextBuffer& buffer, Position at, bool big) {
    Position start = at;
    if (!stepBackward(buffer, at)) {
        return start;
    }
    while (classAt(buffer, at, big) == 0) {
        if (isEmptyLine(buffer, at)) {
            return at;
        }
        if (!stepBackward(buffer, at)) {
            return {0, 0};
        }
    }
    int kind = classAt(buffer, at, big);
    while (true) {
        Position before = at;
        if (!stepBackward(buffer, before) || classAt(buffer, before, big) != kind) {
            return at;
        }
        at = before;
    }
}

/// The last character of the run of one kind that `at` is in.
Position endOfRun(const TextBuffer& buffer, Position at, bool big) {
    int kind = classAt(buffer, at, big);
    std::string_view line = buffer.line(at.line);
    while (true) {
        size_t next = nextColumn(line, at.column);
        if (next >= line.size() || classAt(line, next, big) != kind) {
            return at;
        }
        at.column = next;
    }
}

// ---- Searching in a line, brackets and paragraphs

/// f F t T: where the `count`th `character` is on the line. `skipAdjacent` is for repeating t and
/// T, which would otherwise stay where they are.
std::optional<Position> findInLine(const TextBuffer& buffer, Position from, char kind, const std::string& character,
                                   int count, bool skipAdjacent) {
    std::string_view line = buffer.line(from.line);
    bool forward = kind == 'f' || kind == 't';
    bool before = kind == 't' || kind == 'T';
    size_t column = from.column;
    if (before && skipAdjacent) {
        column = forward ? nextColumn(line, column) : previousColumn(line, column);
    }
    for (int found = 0; found < count; ++found) {
        if (forward) {
            size_t start = nextColumn(line, column);
            size_t hit = start > line.size() ? std::string_view::npos : line.find(character, start);
            if (hit == std::string_view::npos) {
                return std::nullopt;
            }
            column = hit;
        } else {
            if (column == 0) {
                return std::nullopt;
            }
            size_t hit = line.rfind(character, previousColumn(line, column));
            if (hit == std::string_view::npos) {
                return std::nullopt;
            }
            column = hit;
        }
    }
    if (before) {
        column = forward ? previousColumn(line, column) : nextColumn(line, column);
    }
    return Position{from.line, column};
}

char byteAt(const TextBuffer& buffer, Position at) {
    std::string_view line = buffer.line(at.line);
    return at.column < line.size() ? line[at.column] : '\0';
}

bool isOpenBracket(char c) { return c == '(' || c == '[' || c == '{'; }
bool isCloseBracket(char c) { return c == ')' || c == ']' || c == '}'; }

char partnerOf(char c) {
    switch (c) {
        case '(': return ')';
        case '[': return ']';
        case '{': return '}';
        case ')': return '(';
        case ']': return '[';
        case '}': return '{';
        default: return '\0';
    }
}

/// %: the bracket that pairs with the first one at or after the cursor on its line.
std::optional<Position> matchingBracket(const TextBuffer& buffer, Position from) {
    std::string_view line = buffer.line(from.line);
    size_t column = from.column;
    while (column < line.size() && !isOpenBracket(line[column]) && !isCloseBracket(line[column])) {
        ++column;
    }
    if (column >= line.size()) {
        return std::nullopt;
    }
    Position at{from.line, column};
    char start = line[column];
    char partner = partnerOf(start);
    bool forward = isOpenBracket(start);
    int depth = 0;
    while (true) {
        char c = byteAt(buffer, at);
        if (c == start) {
            ++depth;
        } else if (c == partner) {
            --depth;
            if (depth == 0) {
                return at;
            }
        }
        if (!(forward ? stepForward(buffer, at) : stepBackward(buffer, at))) {
            return std::nullopt;
        }
    }
}

// ---- Text objects

/// iw and aw (and iW, aW): the word under the cursor, with the blanks after it (or before it,
/// when there are none after) for "around".
Range wordObject(const TextBuffer& buffer, Position at, bool big, bool around) {
    std::string_view line = buffer.line(at.line);
    if (line.empty()) {
        return {at, at};
    }
    size_t column = std::min(at.column, lastCharStart(line));
    int kind = classAt(line, column, big);
    size_t start = column;
    while (start > 0 && classAt(line, previousColumn(line, start), big) == kind) {
        start = previousColumn(line, start);
    }
    size_t end = column;
    while (end < line.size() && classAt(line, end, big) == kind) {
        end = nextColumn(line, end);
    }
    if (around) {
        if (kind != 0) {
            size_t blanksEnd = end;
            while (blanksEnd < line.size() && classAt(line, blanksEnd, big) == 0) {
                blanksEnd = nextColumn(line, blanksEnd);
            }
            if (blanksEnd > end) {
                end = blanksEnd;
            } else {
                while (start > 0 && classAt(line, previousColumn(line, start), big) == 0) {
                    start = previousColumn(line, start);
                }
            }
        } else {
            int following = classAt(line, end, big);
            while (end < line.size() && following != 0 && classAt(line, end, big) == following) {
                end = nextColumn(line, end);
            }
        }
    }
    return {{at.line, start}, {at.line, end}};
}

/// i" a" i' a' i` a`: the quoted text around or after the cursor, on its line.
std::optional<Range> quoteObject(const TextBuffer& buffer, Position at, char quote, bool around) {
    std::string_view line = buffer.line(at.line);
    std::vector<size_t> quotes;
    for (size_t column = 0; column < line.size(); ++column) {
        if (line[column] == '\\') {
            ++column;
        } else if (line[column] == quote) {
            quotes.push_back(column);
        }
    }
    for (size_t index = 0; index + 1 < quotes.size(); index += 2) {
        size_t open = quotes[index];
        size_t close = quotes[index + 1];
        if (close < at.column) {
            continue;  // the pair is behind the cursor
        }
        if (around) {
            return Range{{at.line, open}, {at.line, close + 1}};
        }
        return Range{{at.line, open + 1}, {at.line, close}};
    }
    return std::nullopt;
}

/// i( a( i{ a{ i[ a[ and i< a<: the text between the brackets around the cursor, which may span lines.
std::optional<Range> bracketObject(const TextBuffer& buffer, Position at, char open, char close, bool around) {
    Position openAt = at;
    int depth = 0;
    bool found = false;
    while (true) {
        char c = byteAt(buffer, openAt);
        if (c == close && openAt != at) {
            ++depth;
        } else if (c == open) {
            if (depth == 0) {
                found = true;
                break;
            }
            --depth;
        }
        if (!stepBackward(buffer, openAt)) {
            break;
        }
    }
    if (!found) {
        return std::nullopt;
    }

    Position closeAt = openAt;
    depth = 0;
    found = false;
    while (stepForward(buffer, closeAt)) {
        char c = byteAt(buffer, closeAt);
        if (c == open) {
            ++depth;
        } else if (c == close) {
            if (depth == 0) {
                found = true;
                break;
            }
            --depth;
        }
    }
    if (!found) {
        return std::nullopt;
    }

    if (around) {
        return Range{openAt, {closeAt.line, closeAt.column + 1}};
    }
    Position start{openAt.line, openAt.column + 1};
    Position end = closeAt;
    // A block written on its own lines: the text inside starts on the line after the opener and
    // stops before the closer's line, so deleting it leaves the brackets where they were.
    if (start.column >= buffer.line(start.line).size() && start.line < end.line) {
        start = {start.line + 1, 0};
        if (end.column <= buffer.indentEnd(end.line)) {
            end = {end.line, 0};
        }
    }
    return Range{start, end};
}

std::optional<Range> textObject(const TextBuffer& buffer, Position at, const std::string& key) {
    bool around = key[0] == 'a';
    char what = key[1];
    switch (what) {
        case 'w': return wordObject(buffer, at, false, around);
        case 'W': return wordObject(buffer, at, true, around);
        case '"':
        case '\'':
        case '`': return quoteObject(buffer, at, what, around);
        case '(':
        case ')':
        case 'b': return bracketObject(buffer, at, '(', ')', around);
        case '{':
        case '}':
        case 'B': return bracketObject(buffer, at, '{', '}', around);
        case '[':
        case ']': return bracketObject(buffer, at, '[', ']', around);
        case '<':
        case '>': return bracketObject(buffer, at, '<', '>', around);
        default: return std::nullopt;
    }
}

// ---- Turning typed keys into commands

enum class Parse { Incomplete, Invalid, Complete };

bool isDigitKey(const std::string& key) { return key.size() == 1 && key[0] >= '0' && key[0] <= '9'; }

bool isOperatorKey(const std::string& key) {
    return key == "d" || key == "c" || key == "y" || key == ">" || key == "<";
}

Parse parseKeys(const std::vector<std::string>& keys, bool visual, Command& command) {
    size_t index = 0;
    // A "0" starts a motion unless a count is already being typed.
    auto readCount = [&](int& count) {
        while (index < keys.size() && isDigitKey(keys[index]) && !(keys[index] == "0" && count == 0)) {
            count = std::min(count * 10 + (keys[index][0] - '0'), 99999);
            ++index;
        }
    };

    readCount(command.count1);
    if (index == keys.size()) {
        return Parse::Incomplete;
    }
    bool hasOperator = !visual && isOperatorKey(keys[index]);
    if (hasOperator) {
        command.op = keys[index++];
        readCount(command.count2);
        if (index == keys.size()) {
            return Parse::Incomplete;
        }
        if (keys[index] == command.op) {
            command.doubled = true;
            return index + 1 == keys.size() ? Parse::Complete : Parse::Invalid;
        }
    }

    // The motion or command: one key, or a key that waits for one more (f then the character).
    const std::string& lead = keys[index];
    bool objectsAllowed = hasOperator || visual;
    bool needsMore = lead == "f" || lead == "F" || lead == "t" || lead == "T" || lead == "r" || lead == "g" ||
                     (objectsAllowed && (lead == "i" || lead == "a"));
    size_t length = needsMore ? 2 : 1;
    if (index + length > keys.size()) {
        return Parse::Incomplete;
    }
    if (index + length < keys.size()) {
        return Parse::Invalid;
    }
    for (size_t at = index; at < keys.size(); ++at) {
        command.key += keys[at];
    }
    return Parse::Complete;
}

// ---- Regions

Region regionFor(const TextBuffer& buffer, Position from, const Motion& motion) {
    if (motion.object) {
        return {*motion.object, false};
    }
    if (motion.linewise) {
        size_t first = std::min(from.line, motion.target.line);
        size_t last = std::max(from.line, motion.target.line);
        return {{{first, 0}, {last, 0}}, true};
    }
    Position start = std::min(from, motion.target);
    Position end = std::max(from, motion.target);
    if (motion.inclusive) {
        end.column = nextColumn(buffer.line(end.line), end.column);
    } else if (end.column == 0 && end.line > start.line) {
        // A motion that stops at the start of a line stops at the end of the one before instead,
        // and when it starts at the front of its line it takes whole lines.
        --end.line;
        end.column = buffer.line(end.line).size();
        if (start.column <= buffer.indentEnd(start.line)) {
            return {{{start.line, 0}, {end.line, 0}}, true};
        }
    }
    return {{start, end}, false};
}

std::string linesText(const TextBuffer& buffer, size_t first, size_t last) {
    std::string text;
    for (size_t line = first; line <= last; ++line) {
        text.append(buffer.line(line));
        text += '\n';
    }
    return text;
}

void setCaret(Document& document, Position at) {
    at = document.buffer().clamp(at);
    document.selection = {at, at};
    document.extraSelections.clear();
    document.preferredX.reset();
}

/// In normal mode the caret rests on a character, never past the last one.
Position restingPlace(const TextBuffer& buffer, Position at) {
    at = buffer.clamp(at);
    at.column = std::min(at.column, lastCharStart(buffer.line(at.line)));
    return at;
}

}  // namespace

// ---- Status

std::string VimEngine::modeName() const {
    switch (mode_) {
        case VimMode::Insert: return "INSERT";
        case VimMode::Visual: return "VISUAL";
        case VimMode::VisualLine: return "V-LINE";
        case VimMode::Normal: break;
    }
    return "NORMAL";
}

std::string VimEngine::pending() const {
    std::string text;
    for (const std::string& key : keys_) {
        text += key;
    }
    return text;
}

Position VimEngine::cursor(const Document& document) const {
    return inVisualMode() ? cursor_ : document.selection.caret;
}

void VimEngine::reset(Document* document) {
    if (groupOpen_ && document != nullptr) {
        document->endUndoGroup();
    }
    groupOpen_ = false;
    mode_ = VimMode::Normal;
    keys_.clear();
    desiredColumn_.reset();
}

// ---- Keys

bool VimEngine::handleKey(Document& document, std::string_view key) {
    if (mode_ == VimMode::Insert) {
        if (key == kEscape) {
            leaveInsert(document);
            return true;
        }
        return false;
    }

    syncWithDocument(document);
    if (key == kEscape) {
        keys_.clear();
        if (inVisualMode()) {
            exitVisual(document);
        }
        return true;
    }

    keys_.emplace_back(key);
    Command command;
    Parse state = parseKeys(keys_, inVisualMode(), command);
    if (state == Parse::Incomplete) {
        return true;
    }
    std::vector<std::string> keys = std::move(keys_);
    keys_.clear();
    if (state == Parse::Complete) {
        execute(document, command, keys);
    }
    return true;
}

/// The mouse or arrow keys may have moved things since the last key.
void VimEngine::syncWithDocument(Document& document) {
    if (inVisualMode()) {
        bool unchanged = document.selection.anchor == shownSelection_.anchor && document.selection.caret == shownSelection_.caret;
        if (!unchanged) {
            mode_ = VimMode::Normal;  // something else changed the selection: visual mode is over
        }
    }
    if (mode_ == VimMode::Normal && !document.selection.empty()) {
        // Text selected with the mouse: carry on as a visual selection.
        const TextBuffer& buffer = document.buffer();
        Selection selection = document.selection;
        anchor_ = selection.anchor;
        cursor_ = selection.caret;
        if (selection.caret > selection.anchor) {
            cursor_ = {selection.caret.line, previousColumn(buffer.line(selection.caret.line), selection.caret.column)};
        }
        mode_ = VimMode::Visual;
        showVisual(document);
        return;
    }
    if (mode_ == VimMode::Normal) {
        setCaret(document, restingPlace(document.buffer(), document.selection.caret));
    }
}

void VimEngine::execute(Document& document, const Command& command, const std::vector<std::string>& keys) {
    commandChanges_ = false;
    insertKeys_ = keys;
    bool fromVisualMode = inVisualMode();
    document.beginUndoGroup();
    if (fromVisualMode) {
        executeVisual(document, command);
    } else {
        executeNormal(document, command);
    }
    if (mode_ == VimMode::Insert) {
        groupOpen_ = true;  // typing joins this command, so one undo takes back both
    } else {
        document.endUndoGroup();
        if (mode_ == VimMode::Normal) {
            setCaret(document, restingPlace(document.buffer(), document.selection.caret));
        }
        if (commandChanges_ && !replaying_ && !fromVisualMode) {
            lastChange_ = {keys, ""};  // "." repeats it (a change made in visual mode isn't repeated)
        }
    }
}

void VimEngine::beginInsert(Document& document, int count) {
    mode_ = VimMode::Insert;
    insertStart_ = document.selection.caret;
    insertCount_ = count;
    commandChanges_ = true;
}

void VimEngine::leaveInsert(Document& document) {
    const TextBuffer& buffer = document.buffer();
    Position caret = document.selection.caret;
    std::string inserted;
    if (insertStart_ <= caret && insertStart_.line < buffer.lineCount()) {
        inserted = buffer.text({insertStart_, caret});
    }
    for (int repeat = 1; repeat < insertCount_ && !inserted.empty(); ++repeat) {
        Position end = document.selection.caret;
        document.replace({end, end}, inserted);
    }

    mode_ = VimMode::Normal;
    caret = document.selection.caret;
    caret.column = previousColumn(buffer.line(caret.line), caret.column);
    setCaret(document, caret);
    if (groupOpen_) {
        document.endUndoGroup();
        groupOpen_ = false;
    }
    if (!replaying_) {
        lastChange_ = {insertKeys_, inserted};
    }
}

void VimEngine::showVisual(Document& document) {
    const TextBuffer& buffer = document.buffer();
    Position low = std::min(anchor_, cursor_);
    Position high = std::max(anchor_, cursor_);
    Position from, to;
    if (mode_ == VimMode::VisualLine) {
        from = {low.line, 0};
        to = {high.line, buffer.line(high.line).size()};
    } else {
        from = low;
        to = {high.line, nextColumn(buffer.line(high.line), high.column)};
    }
    bool backward = cursor_ < anchor_;
    document.selection = backward ? Selection{to, from} : Selection{from, to};
    document.extraSelections.clear();
    document.preferredX.reset();
    shownSelection_ = document.selection;
}

void VimEngine::exitVisual(Document& document) {
    mode_ = VimMode::Normal;
    setCaret(document, restingPlace(document.buffer(), cursor_));
}

// ---- Registers

void VimEngine::yank(const std::string& text, bool linewise) {
    register_ = {text, linewise};
    clipboardMirror_ = text;
    if (writeClipboard) {
        writeClipboard(text);
    }
}

VimEngine::Register VimEngine::registerForPaste() {
    if (readClipboard) {
        std::string clipboard = readClipboard();
        if (!clipboard.empty() && clipboard != clipboardMirror_) {
            return {clipboard, false};  // something was copied elsewhere since the last yank
        }
    }
    return register_;
}

// ---- Motions

std::optional<Motion> VimEngine::motionFor(Document& document, const std::string& key, int count, bool hasCount,
                                           Position from, bool forOperator) {
    const TextBuffer& buffer = document.buffer();
    std::string_view line = buffer.line(from.line);
    size_t lastLine = buffer.lineCount() - 1;
    Motion motion;
    motion.target = from;

    auto toLine = [&](size_t target, bool linewise) -> Motion {
        Motion result;
        result.target = {target, firstNonBlank(buffer, target)};
        result.linewise = linewise;
        return result;
    };

    if (key == "h" || key == "\x7f") {
        for (int step = 0; step < count && motion.target.column > 0; ++step) {
            motion.target.column = previousColumn(line, motion.target.column);
        }
        return motion.target == from ? std::nullopt : std::optional<Motion>(motion);
    }
    if (key == "l" || key == " ") {
        size_t limit = forOperator ? line.size() : lastCharStart(line);
        for (int step = 0; step < count; ++step) {
            size_t next = nextColumn(line, motion.target.column);
            if (motion.target.column >= limit || next > limit) {
                break;
            }
            motion.target.column = next;
        }
        return motion.target == from ? std::nullopt : std::optional<Motion>(motion);
    }
    if (key == "j" || key == "k") {
        bool down = key == "j";
        if ((down && from.line >= lastLine) || (!down && from.line == 0)) {
            return std::nullopt;
        }
        size_t target = down ? std::min(lastLine, from.line + static_cast<size_t>(count))
                             : from.line - std::min(from.line, static_cast<size_t>(count));
        if (!desiredColumn_) {
            desiredColumn_ = characterIndex(line, from.column);
        }
        std::string_view targetLine = buffer.line(target);
        size_t column = *desiredColumn_ == kEndOfLine ? lastCharStart(targetLine) : columnOfCharacter(targetLine, *desiredColumn_);
        motion.target = {target, std::min(column, lastCharStart(targetLine))};
        motion.linewise = true;
        return motion;
    }
    if (key == "0") {
        motion.target.column = 0;
        return motion;
    }
    if (key == "^") {
        motion.target.column = firstNonBlank(buffer, from.line);
        return motion;
    }
    if (key == "$") {
        size_t target = from.line + static_cast<size_t>(count - 1);
        if (target > lastLine) {
            return std::nullopt;
        }
        motion.target = {target, lastCharStart(buffer.line(target))};
        motion.inclusive = true;
        desiredColumn_ = kEndOfLine;
        return motion;
    }
    if (key == "+" || key == "\r" || key == "-" || key == "_") {
        size_t distance = key == "_" ? static_cast<size_t>(count - 1) : static_cast<size_t>(count);
        bool up = key == "-";
        if ((up && from.line < distance) || (!up && from.line + distance > lastLine) || (distance == 0 && up)) {
            return std::nullopt;
        }
        return toLine(up ? from.line - distance : from.line + distance, true);
    }
    if (key == "gg") {
        return toLine(hasCount ? std::min(lastLine, static_cast<size_t>(count - 1)) : 0, true);
    }
    if (key == "G") {
        return toLine(hasCount ? std::min(lastLine, static_cast<size_t>(count - 1)) : lastLine, true);
    }
    if (key == "w" || key == "W") {
        bool big = key == "W";
        Position at = from;
        for (int step = 0; step < count; ++step) {
            at = wordForward(buffer, at, big);
        }
        if (forOperator && at.line > from.line) {
            // "dw" on the last word of a line stops at the line's end, not on the next line.
            Position back = at;
            while (stepBackward(buffer, back) && (back.line > from.line || back.column > from.column) &&
                   classAt(buffer, back, big) == 0) {
            }
            if (back.line == from.line) {
                at = {back.line, nextColumn(buffer.line(back.line), back.column)};
            } else {
                at = {from.line, line.size()};
            }
            at = std::max(at, from);
        }
        motion.target = at;
        return motion;
    }
    if (key == "b" || key == "B") {
        for (int step = 0; step < count; ++step) {
            motion.target = wordBackward(buffer, motion.target, key == "B");
        }
        return motion.target == from ? std::nullopt : std::optional<Motion>(motion);
    }
    if (key == "e" || key == "E") {
        for (int step = 0; step < count; ++step) {
            motion.target = wordEndForward(buffer, motion.target, key == "E");
        }
        motion.inclusive = true;
        return motion;
    }
    if ((key[0] == 'f' || key[0] == 'F' || key[0] == 't' || key[0] == 'T') && key.size() > 1) {
        lastFind_ = {key[0], key.substr(1)};
        std::optional<Position> found = findInLine(buffer, from, key[0], lastFind_.character, count, false);
        if (!found) {
            return std::nullopt;
        }
        motion.target = *found;
        motion.inclusive = key[0] == 'f' || key[0] == 't';
        return motion;
    }
    if ((key == ";" || key == ",") && lastFind_.kind != 0) {
        char kind = lastFind_.kind;
        if (key == ",") {
            kind = std::isupper(static_cast<unsigned char>(kind)) ? static_cast<char>(std::tolower(kind))
                                                                  : static_cast<char>(std::toupper(kind));
        }
        std::optional<Position> found = findInLine(buffer, from, kind, lastFind_.character, count, true);
        if (!found) {
            return std::nullopt;
        }
        motion.target = *found;
        motion.inclusive = kind == 'f' || kind == 't';
        return motion;
    }
    if (key == "%") {
        std::optional<Position> match = matchingBracket(buffer, from);
        if (!match) {
            return std::nullopt;
        }
        motion.target = *match;
        motion.inclusive = true;
        return motion;
    }
    if (key == "}" || key == "{") {
        bool down = key == "}";
        size_t at = from.line;
        for (int step = 0; step < count; ++step) {
            while ((down ? at < lastLine : at > 0) && buffer.line(at).empty()) {
                at = down ? at + 1 : at - 1;
            }
            while ((down ? at < lastLine : at > 0) && !buffer.line(at).empty()) {
                at = down ? at + 1 : at - 1;
            }
        }
        bool atEnd = down && at == lastLine && !buffer.line(at).empty();
        motion.target = atEnd ? Position{at, buffer.line(at).size()} : Position{at, 0};
        return motion.target == from ? std::nullopt : std::optional<Motion>(motion);
    }
    if (key.size() == 2 && (key[0] == 'i' || key[0] == 'a')) {
        std::optional<Range> object = textObject(buffer, from, key);
        if (!object) {
            return std::nullopt;
        }
        motion.object = *object;
        return motion;
    }
    return std::nullopt;
}

// ---- Edits

void VimEngine::deleteRegion(Document& document, const Region& region) {
    const TextBuffer& buffer = document.buffer();
    commandChanges_ = true;
    if (!region.linewise) {
        document.replace(region.range, "");
        setCaret(document, region.range.start);
        return;
    }
    size_t first = region.range.start.line;
    size_t last = region.range.end.line;
    if (last + 1 < buffer.lineCount()) {
        document.replace({{first, 0}, {last + 1, 0}}, "");
    } else if (first > 0) {
        document.replace({{first - 1, buffer.line(first - 1).size()}, {last, buffer.line(last).size()}}, "");
        --first;
    } else {
        document.replace({{0, 0}, buffer.end()}, "");
    }
    first = std::min(first, document.buffer().lineCount() - 1);
    setCaret(document, {first, firstNonBlank(document.buffer(), first)});
}

void VimEngine::applyOperator(Document& document, const std::string& op, const Region& region, Position from) {
    const TextBuffer& buffer = document.buffer();
    bool linewise = region.linewise;
    std::string text = linewise ? linesText(buffer, region.range.start.line, region.range.end.line)
                                : buffer.text(region.range);

    if (op == "y") {
        if (!text.empty()) {
            yank(text, linewise);
        }
        Position at = region.range.start;
        if (linewise) {
            // Yanking lines leaves the cursor in its column (on the first line of them).
            at = {region.range.start.line, std::min(from.column, lastCharStart(buffer.line(region.range.start.line)))};
        }
        setCaret(document, at);
        return;
    }
    if (op == "d") {
        if (!text.empty()) {
            yank(text, linewise);
        }
        deleteRegion(document, region);
        return;
    }
    if (op == "c") {
        yank(text, linewise);
        commandChanges_ = true;
        if (linewise) {
            size_t first = region.range.start.line;
            size_t last = region.range.end.line;
            size_t indent = buffer.indentEnd(first);  // the indent stays, so the new text lines up
            document.replace({{first, indent}, {last, buffer.line(last).size()}}, "");
            setCaret(document, {first, std::min(indent, document.buffer().line(first).size())});
        } else {
            document.replace(region.range, "");
            setCaret(document, region.range.start);
        }
        beginInsert(document, 1);
        return;
    }
    if (op == ">" || op == "<") {
        size_t first = region.range.start.line;
        size_t last = region.range.end.line;
        if (!linewise && region.range.end.column == 0 && last > first) {
            --last;
        }
        shiftLines(document, first, last, op == ">");
        setCaret(document, {first, firstNonBlank(document.buffer(), first)});
    }
}

bool VimEngine::runOperator(Document& document, const Command& command) {
    const TextBuffer& buffer = document.buffer();
    int count = std::max(1, command.count1) * std::max(1, command.count2);
    bool hasCount = command.count1 > 0 || command.count2 > 0;
    Position from = document.selection.caret;
    Region region;

    if (command.doubled) {
        size_t last = std::min(buffer.lineCount() - 1, from.line + static_cast<size_t>(count) - 1);
        region = {{{from.line, 0}, {last, 0}}, true};
    } else {
        std::optional<Motion> motion;
        bool changingWord = command.op == "c" && (command.key == "w" || command.key == "W") && classAt(buffer, from, command.key == "W") != 0;
        if (changingWord) {
            // "cw" changes to the end of the word, like "ce", and keeps the blanks after it.
            bool big = command.key == "W";
            Motion word;
            word.target = endOfRun(buffer, from, big);
            for (int step = 1; step < count; ++step) {
                word.target = wordEndForward(buffer, word.target, big);
            }
            word.inclusive = true;
            motion = word;
        } else {
            motion = motionFor(document, command.key, count, hasCount, from, true);
        }
        if (!motion) {
            return false;
        }
        region = regionFor(buffer, from, *motion);
    }
    applyOperator(document, command.op, region, from);
    return true;
}

void VimEngine::put(Document& document, bool before, int count) {
    Register content = registerForPaste();
    if (content.text.empty()) {
        return;
    }
    commandChanges_ = true;
    const TextBuffer& buffer = document.buffer();
    Position caret = document.selection.caret;
    std::string text;
    for (int copy = 0; copy < count; ++copy) {
        text += content.text;
    }

    if (content.linewise) {
        size_t newLine = caret.line;
        if (before) {
            document.replace({{caret.line, 0}, {caret.line, 0}}, text);
        } else {
            Position end{caret.line, buffer.line(caret.line).size()};
            text.pop_back();  // the line break after the last line comes from the line already there
            document.replace({end, end}, "\n" + text);
            newLine = caret.line + 1;
        }
        setCaret(document, {newLine, firstNonBlank(document.buffer(), newLine)});
        return;
    }

    std::string_view line = buffer.line(caret.line);
    size_t column = before || line.empty() ? caret.column : nextColumn(line, caret.column);
    Position start{caret.line, column};
    Position end = document.replace({start, start}, text);
    if (text.find('\n') == std::string::npos) {
        setCaret(document, {end.line, previousColumn(document.buffer().line(end.line), end.column)});
    } else {
        setCaret(document, start);
    }
}

void VimEngine::joinLines(Document& document, int count) {
    commandChanges_ = true;
    int joins = std::max(1, count - 1);
    Position at = document.selection.caret;
    for (int step = 0; step < joins; ++step) {
        const TextBuffer& buffer = document.buffer();
        size_t line = document.selection.caret.line;
        if (line + 1 >= buffer.lineCount()) {
            break;
        }
        std::string_view current = buffer.line(line);
        std::string_view next = buffer.line(line + 1);
        size_t nextStart = buffer.indentEnd(line + 1);
        std::string_view rest = next.substr(nextStart);
        bool needsSpace = !current.empty() && current.back() != ' ' && current.back() != '\t' && !rest.empty() && rest.front() != ')';
        at = {line, current.size()};
        document.replace({{line, current.size()}, {line + 1, nextStart}}, needsSpace ? " " : "");
        document.selection = {at, at};
    }
    setCaret(document, at);
}

void VimEngine::replaceCharacters(Document& document, const std::string& with, int count) {
    const TextBuffer& buffer = document.buffer();
    Position caret = document.selection.caret;
    std::string_view line = buffer.line(caret.line);
    size_t end = caret.column;
    for (int step = 0; step < count; ++step) {
        if (end >= line.size()) {
            return;  // not enough characters on the line: nothing changes
        }
        end = nextColumn(line, end);
    }
    std::string text;
    for (int step = 0; step < count; ++step) {
        text += with;
    }
    commandChanges_ = true;
    document.replace({caret, {caret.line, end}}, text);
    setCaret(document, {caret.line, caret.column + text.size() - with.size()});
}

/// `mode`: 0 toggle, 1 lower case, 2 upper case. Letters only, as plain ASCII.
void VimEngine::changeCase(Document& document, const Region& region, int mode) {
    const TextBuffer& buffer = document.buffer();
    commandChanges_ = true;
    Position start = region.linewise ? Position{region.range.start.line, 0} : region.range.start;
    Position end = region.linewise ? Position{region.range.end.line, buffer.line(region.range.end.line).size()} : region.range.end;
    std::string text = buffer.text({start, end});
    for (char& c : text) {
        unsigned char byte = static_cast<unsigned char>(c);
        bool lower = std::islower(byte);
        bool upper = std::isupper(byte);
        if ((mode == 0 && lower) || (mode == 2 && lower)) {
            c = static_cast<char>(std::toupper(byte));
        } else if ((mode == 0 && upper) || (mode == 1 && upper)) {
            c = static_cast<char>(std::tolower(byte));
        }
    }
    document.replace({start, end}, text);
    setCaret(document, start);
}

void VimEngine::shiftLines(Document& document, size_t first, size_t last, bool right) {
    commandChanges_ = true;
    last = std::min(last, document.buffer().lineCount() - 1);
    for (size_t line = first; line <= last; ++line) {
        std::string_view text = document.buffer().line(line);
        if (right) {
            if (!text.empty()) {
                document.replace({{line, 0}, {line, 0}}, indentUnit);
            }
            continue;
        }
        size_t remove = 0;
        if (!text.empty() && text[0] == '\t') {
            remove = 1;
        } else {
            while (remove < indentUnit.size() && remove < text.size() && text[remove] == ' ') {
                ++remove;
            }
        }
        if (remove > 0) {
            document.replace({{line, 0}, {line, remove}}, "");
        }
    }
}

// ---- Normal mode commands

void VimEngine::executeNormal(Document& document, const Command& command) {
    const TextBuffer& buffer = document.buffer();
    const std::string& key = command.key;
    int count = std::max(1, command.count1);
    bool hasCount = command.count1 > 0;
    Position caret = document.selection.caret;
    std::string_view line = buffer.line(caret.line);

    if (!command.op.empty()) {
        runOperator(document, command);
        return;
    }

    // Commands that are an operator and a motion, written short.
    auto operate = [&](const char* op, const char* motion, bool doubled = false) {
        Command expanded;
        expanded.count1 = command.count1;
        expanded.op = op;
        expanded.key = motion;
        expanded.doubled = doubled;
        return runOperator(document, expanded);
    };

    if (key == "i") {
        beginInsert(document, count);
    } else if (key == "a") {
        setCaret(document, {caret.line, nextColumn(line, caret.column)});
        beginInsert(document, count);
    } else if (key == "I") {
        setCaret(document, {caret.line, buffer.indentEnd(caret.line)});
        beginInsert(document, count);
    } else if (key == "A") {
        setCaret(document, {caret.line, line.size()});
        beginInsert(document, count);
    } else if (key == "o") {
        std::string indent(line.substr(0, buffer.indentEnd(caret.line)));
        Position end{caret.line, line.size()};
        setCaret(document, document.replace({end, end}, "\n" + indent));
        beginInsert(document, 1);
    } else if (key == "O") {
        std::string indent(line.substr(0, buffer.indentEnd(caret.line)));
        document.replace({{caret.line, 0}, {caret.line, 0}}, indent + "\n");
        setCaret(document, {caret.line, indent.size()});
        beginInsert(document, 1);
    } else if (key == "x") {
        operate("d", "l");
    } else if (key == "X") {
        operate("d", "h");
    } else if (key == "D") {
        operate("d", "$");
    } else if (key == "C" || key == "s") {
        if (line.empty() || !operate("c", key == "C" ? "$" : "l")) {
            beginInsert(document, 1);
        }
    } else if (key == "S") {
        operate("c", "", true);
    } else if (key == "Y") {
        operate("y", "", true);
    } else if (key == "p" || key == "P") {
        put(document, key == "P", count);
    } else if (key == "u" || key == "\x12") {
        for (int step = 0; step < count; ++step) {
            if (!(key == "u" ? document.undo() : document.redo())) {
                break;
            }
        }
    } else if (key == ".") {
        Change change = lastChange_;
        replaying_ = true;
        for (const std::string& replayed : change.keys) {
            handleKey(document, replayed);
        }
        if (mode_ == VimMode::Insert) {
            Position at = document.selection.caret;
            if (!change.inserted.empty()) {
                document.replace({at, at}, change.inserted);
            }
            leaveInsert(document);
        }
        replaying_ = false;
        commandChanges_ = false;  // repeating isn't itself something to repeat
    } else if (key == "J") {
        joinLines(document, count);
    } else if (key.size() == 2 && key[0] == 'r') {
        replaceCharacters(document, key.substr(1), count);
    } else if (key == "~") {
        Position end = caret;
        for (int step = 0; step < count; ++step) {
            end.column = nextColumn(line, end.column);
        }
        if (end.column > caret.column) {
            changeCase(document, {{caret, end}, false}, 0);
            setCaret(document, restingPlace(document.buffer(), end));
        }
    } else if (key == "v" || key == "V") {
        mode_ = key == "v" ? VimMode::Visual : VimMode::VisualLine;
        anchor_ = cursor_ = caret;
        showVisual(document);
    } else if (key == "/" || key == "?" || key == "n" || key == "N") {
        if (onAction) {
            onAction(key == "/" ? VimAction::Search : key == "?" ? VimAction::SearchBackward : key == "n" ? VimAction::SearchNext : VimAction::SearchPrevious);
        }
    } else {
        std::optional<Motion> motion = motionFor(document, key, count, hasCount, caret, false);
        bool vertical = key == "j" || key == "k";
        if (!vertical && key != "$") {
            desiredColumn_.reset();
        }
        if (motion) {
            Position target = motion->object ? motion->object->start : motion->target;
            setCaret(document, restingPlace(buffer, target));
        }
    }
    if (key != "j" && key != "k" && key != "$") {
        desiredColumn_.reset();
    }
}

// ---- Visual mode commands

VimEngine::Region VimEngine::visualRegion(const Document& document) const {
    Position low = std::min(anchor_, cursor_);
    Position high = std::max(anchor_, cursor_);
    if (mode_ == VimMode::VisualLine) {
        return {{{low.line, 0}, {high.line, 0}}, true};
    }
    high.column = nextColumn(document.buffer().line(high.line), high.column);
    return {{low, high}, false};
}

void VimEngine::executeVisual(Document& document, const Command& command) {
    const TextBuffer& buffer = document.buffer();
    const std::string& key = command.key;
    int count = std::max(1, command.count1);
    bool hasCount = command.count1 > 0;
    Region region = visualRegion(document);
    Position low = region.range.start;

    // Operators act on the selection and end visual mode.
    auto finishWith = [&](const char* op, Region target) {
        mode_ = VimMode::Normal;
        applyOperator(document, op, target, low);
    };
    auto asLines = [&]() { return Region{{{region.range.start.line, 0}, {std::max(anchor_, cursor_).line, 0}}, true}; };

    if (key == "v" || key == "V") {
        VimMode wanted = key == "v" ? VimMode::Visual : VimMode::VisualLine;
        if (mode_ == wanted) {
            exitVisual(document);
        } else {
            mode_ = wanted;
            showVisual(document);
        }
    } else if (key == "o" || key == "O") {
        std::swap(anchor_, cursor_);
        showVisual(document);
    } else if (key == "d" || key == "x") {
        finishWith("d", region);
    } else if (key == "X" || key == "D") {
        finishWith("d", asLines());
    } else if (key == "y") {
        finishWith("y", region);
    } else if (key == "Y") {
        finishWith("y", asLines());
    } else if (key == "c" || key == "s") {
        finishWith("c", region);
    } else if (key == "C" || key == "S" || key == "R") {
        finishWith("c", asLines());
    } else if (key == ">" || key == "<") {
        finishWith(key.c_str(), region);
    } else if (key == "J") {
        mode_ = VimMode::Normal;
        size_t lines = std::max<size_t>(2, region.range.end.line - region.range.start.line + 1);
        setCaret(document, region.range.start);
        joinLines(document, static_cast<int>(lines));
    } else if (key == "~" || key == "u" || key == "U") {
        mode_ = VimMode::Normal;
        changeCase(document, region, key == "~" ? 0 : key == "u" ? 1 : 2);
    } else if (key.size() == 2 && key[0] == 'r') {
        mode_ = VimMode::Normal;
        std::string text = region.linewise ? linesText(buffer, region.range.start.line, region.range.end.line)
                                           : buffer.text(region.range);
        std::string filled;
        for (size_t at = 0; at < text.size(); at = nextColumn(text, at)) {
            filled += text[at] == '\n' ? std::string("\n") : key.substr(1);
        }
        if (region.linewise) {
            filled.pop_back();
            document.replace({{region.range.start.line, 0}, {region.range.end.line, buffer.line(region.range.end.line).size()}}, filled);
        } else {
            document.replace(region.range, filled);
        }
        commandChanges_ = true;
        setCaret(document, low);
    } else if (key == "p" || key == "P") {
        // The selection is replaced by the register, and what it held goes into the register.
        Register replacement = registerForPaste();
        std::string removed = region.linewise ? linesText(buffer, region.range.start.line, region.range.end.line)
                                              : buffer.text(region.range);
        bool removedLinewise = region.linewise;
        mode_ = VimMode::Normal;
        if (!replacement.text.empty()) {
            if (!replacement.linewise && !region.linewise) {
                document.replace(region.range, replacement.text);
                setCaret(document, restingPlace(document.buffer(), {low.line, low.column + replacement.text.size() - 1}));
                commandChanges_ = true;
            } else {
                register_ = replacement;
                clipboardMirror_ = replacement.text;
                deleteRegion(document, region);
                bool atEnd = removedLinewise && region.range.end.line >= document.buffer().lineCount();
                put(document, !atEnd && removedLinewise, 1);
            }
            yank(removed, removedLinewise);
        }
    } else if (key == "/" || key == "?" || key == "n" || key == "N") {
        if (onAction) {
            onAction(key == "/" ? VimAction::Search : key == "?" ? VimAction::SearchBackward : key == "n" ? VimAction::SearchNext : VimAction::SearchPrevious);
        }
    } else {
        std::optional<Motion> motion = motionFor(document, key, count, hasCount, cursor_, false);
        if (key != "j" && key != "k" && key != "$") {
            desiredColumn_.reset();
        }
        if (motion && motion->object) {
            // A text object selects it: iw, a", i( and the like.
            anchor_ = motion->object->start;
            Position end = motion->object->end;
            cursor_ = end.column == 0 && end.line > anchor_.line
                          ? Position{end.line - 1, lastCharStart(buffer.line(end.line - 1))}
                          : Position{end.line, previousColumn(buffer.line(end.line), end.column)};
            if (mode_ == VimMode::VisualLine) {
                mode_ = VimMode::Visual;
            }
        } else if (motion) {
            cursor_ = restingPlace(buffer, motion->target);
        }
        showVisual(document);
    }
}

}  // namespace gw
