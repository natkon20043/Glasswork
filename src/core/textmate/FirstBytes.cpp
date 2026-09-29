// Works out which bytes a regular expression can start a match with, so the tokenizer can
// skip patterns that cannot match at a given spot. The analysis is deliberately generous:
// it may allow bytes that never start a match, but must never leave one out.

#include "Regex.hpp"

#include <bitset>
#include <cctype>

namespace gw::tm {

namespace {

using ByteSet = std::bitset<256>;

/// What can begin a piece of pattern: a set of bytes, and whether the piece can also match
/// nothing at all (so whatever follows it can begin the match too).
struct Start {
    ByteSet bytes;
    bool canBeEmpty = false;
};

ByteSet everything() {
    ByteSet all;
    all.set();
    return all;
}

ByteSet highBytes() {
    ByteSet high;
    for (int byte = 0x80; byte < 256; ++byte) {
        high.set(static_cast<size_t>(byte));
    }
    return high;
}

ByteSet digits() {
    ByteSet set;
    for (int c = '0'; c <= '9'; ++c) set.set(static_cast<size_t>(c));
    return set;
}

ByteSet wordBytes() {
    ByteSet set = highBytes();
    for (int c = 'a'; c <= 'z'; ++c) set.set(static_cast<size_t>(c));
    for (int c = 'A'; c <= 'Z'; ++c) set.set(static_cast<size_t>(c));
    set |= digits();
    set.set('_');
    return set;
}

ByteSet spaceBytes() {
    ByteSet set;
    for (char c : {' ', '\t', '\n', '\r', '\f', '\v'}) set.set(static_cast<unsigned char>(c));
    return set;
}

ByteSet hexBytes() {
    ByteSet set = digits();
    for (int c = 'a'; c <= 'f'; ++c) set.set(static_cast<size_t>(c));
    for (int c = 'A'; c <= 'F'; ++c) set.set(static_cast<size_t>(c));
    return set;
}

/// Adds the other-case forms of every letter in the set.
ByteSet withBothCases(ByteSet set) {
    for (int c = 'a'; c <= 'z'; ++c) {
        if (set.test(static_cast<size_t>(c))) set.set(static_cast<size_t>(c - 'a' + 'A'));
        if (set.test(static_cast<size_t>(c - 'a' + 'A'))) set.set(static_cast<size_t>(c));
    }
    return set;
}

/// The first byte of the UTF-8 encoding of a code point.
unsigned char utf8LeadByte(unsigned long codePoint) {
    if (codePoint < 0x80) return static_cast<unsigned char>(codePoint);
    if (codePoint < 0x800) return static_cast<unsigned char>(0xC0 | (codePoint >> 6));
    if (codePoint < 0x10000) return static_cast<unsigned char>(0xE0 | (codePoint >> 12));
    return static_cast<unsigned char>(0xF0 | (codePoint >> 18));
}

class Analyzer {
public:
    explicit Analyzer(const std::string& source) : source_(source) {}

    /// Returns false if the pattern uses something this analysis doesn't handle.
    bool run(Start& result) {
        result = parseAlternation();
        return !failed_ && position_ >= source_.size();
    }

private:
    const std::string& source_;
    size_t position_ = 0;
    bool failed_ = false;
    bool ignoreCase_ = false;
    bool extended_ = false;

    bool atEnd() const { return position_ >= source_.size(); }
    char peek() const { return source_[position_]; }

    /// In extended mode, whitespace and #-comments between pieces mean nothing.
    void skipExtendedSpace() {
        while (extended_ && !atEnd()) {
            char c = peek();
            if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
                ++position_;
            } else if (c == '#') {
                while (!atEnd() && peek() != '\n') ++position_;
            } else {
                break;
            }
        }
    }

    Start parseAlternation() {
        Start combined;
        bool first = true;
        bool savedIgnoreCase = ignoreCase_;
        bool savedExtended = extended_;
        while (true) {
            Start branch = parseSequence();
            if (first) {
                combined = branch;
                first = false;
            } else {
                combined.bytes |= branch.bytes;
                combined.canBeEmpty = combined.canBeEmpty || branch.canBeEmpty;
            }
            if (!atEnd() && peek() == '|') {
                ++position_;
                continue;
            }
            break;
        }
        // Flags set inside a group end with it.
        ignoreCase_ = savedIgnoreCase;
        extended_ = savedExtended;
        return combined;
    }

    Start parseSequence() {
        Start sequence;
        sequence.canBeEmpty = true;
        while (true) {
            skipExtendedSpace();
            if (atEnd() || peek() == '|' || peek() == ')') break;
            Start piece = parseQuantified();
            if (failed_) return sequence;
            if (sequence.canBeEmpty) {
                sequence.bytes |= piece.bytes;
                sequence.canBeEmpty = piece.canBeEmpty;
            }
        }
        return sequence;
    }

    Start parseQuantified() {
        Start atom = parseAtom();
        while (!failed_) {
            skipExtendedSpace();
            if (atEnd()) break;
            char c = peek();
            if (c == '*' || c == '?') {
                ++position_;
                atom.canBeEmpty = true;
            } else if (c == '+') {
                ++position_;
            } else if (c == '{') {
                // {n}, {n,}, {n,m}, {,m}: a quantifier only if it looks like one.
                size_t close = source_.find('}', position_);
                bool quantifier = close != std::string::npos && close > position_ + 1;
                bool zeroMinimum = false;
                if (quantifier) {
                    for (size_t index = position_ + 1; index < close; ++index) {
                        char q = source_[index];
                        if (!std::isdigit(static_cast<unsigned char>(q)) && q != ',') quantifier = false;
                    }
                    if (quantifier) {
                        char first = source_[position_ + 1];
                        zeroMinimum = first == ',' || (first == '0' && (source_[position_ + 2] == ',' || source_[position_ + 2] == '}'));
                    }
                }
                if (!quantifier) break;
                position_ = close + 1;
                if (zeroMinimum) atom.canBeEmpty = true;
            } else {
                break;
            }
            // Lazy (?) and possessive (+) suffixes.
            if (!atEnd() && (peek() == '?' || peek() == '+')) ++position_;
        }
        return atom;
    }

    Start single(unsigned char byte) {
        Start start;
        start.bytes.set(byte);
        if (ignoreCase_) start.bytes = withBothCases(start.bytes);
        return start;
    }

    Start setStart(ByteSet set) {
        Start start;
        start.bytes = ignoreCase_ ? withBothCases(set) : set;
        return start;
    }

    Start zeroWidth() {
        Start start;
        start.canBeEmpty = true;
        return start;
    }

    Start parseAtom() {
        char c = peek();
        ++position_;
        switch (c) {
            case '.': {
                ByteSet all = everything();
                all.reset('\n');
                return setStart(all);
            }
            case '^':
            case '$':
                return zeroWidth();
            case '[':
                return parseClass();
            case '(':
                return parseGroup();
            case '\\':
                return parseEscape();
            default:
                return single(static_cast<unsigned char>(c));
        }
    }

    Start parseEscape() {
        if (atEnd()) {
            failed_ = true;
            return Start();
        }
        char c = peek();
        ++position_;
        switch (c) {
            case 'd': return setStart(digits());
            case 'D': return setStart(~digits());
            case 'w': return setStart(wordBytes());
            case 'W': return setStart(~wordBytes());
            case 's': return setStart(spaceBytes());
            case 'S': return setStart(~spaceBytes());
            case 'h': return setStart(hexBytes());
            case 'H': return setStart(~hexBytes());
            case 'b': case 'B': case 'A': case 'z': case 'Z': case 'G': case 'K':
                return zeroWidth();
            case 'n': return single('\n');
            case 't': return single('\t');
            case 'r': return single('\r');
            case 'f': return single('\f');
            case 'v': return single('\v');
            case 'a': return single('\a');
            case 'e': return single(0x1B);
            case 'x': {
                unsigned long value = 0;
                if (!atEnd() && peek() == '{') {
                    size_t close = source_.find('}', position_);
                    if (close == std::string::npos) {
                        failed_ = true;
                        return Start();
                    }
                    value = std::strtoul(source_.substr(position_ + 1, close - position_ - 1).c_str(), nullptr, 16);
                    position_ = close + 1;
                } else {
                    size_t digitsRead = 0;
                    while (!atEnd() && digitsRead < 2 && std::isxdigit(static_cast<unsigned char>(peek()))) {
                        value = value * 16 + static_cast<unsigned long>(std::stoi(std::string(1, peek()), nullptr, 16));
                        ++position_;
                        ++digitsRead;
                    }
                }
                if (value >= 0x80) {
                    // A raw byte or a code point: allow every high byte, which covers both.
                    Start start;
                    start.bytes = highBytes();
                    return start;
                }
                return single(static_cast<unsigned char>(value));
            }
            case 'u': {
                if (source_.size() - position_ >= 4) {
                    unsigned long value = std::strtoul(source_.substr(position_, 4).c_str(), nullptr, 16);
                    position_ += 4;
                    return single(utf8LeadByte(value));
                }
                failed_ = true;
                return Start();
            }
            case 'p': case 'P': case 'k': case 'g': case 'R': case 'X': case 'N': case 'O':
                failed_ = true;  // properties, named references, newline classes: give up
                return Start();
            default:
                if (std::isdigit(static_cast<unsigned char>(c))) {
                    failed_ = true;  // back-reference: could be anything
                    return Start();
                }
                return single(static_cast<unsigned char>(c));
        }
    }

    Start parseGroup() {
        // (?...) forms
        if (!atEnd() && peek() == '?') {
            ++position_;
            if (atEnd()) {
                failed_ = true;
                return Start();
            }
            char kind = peek();
            if (kind == '#') {  // comment
                while (!atEnd() && peek() != ')') ++position_;
                if (!atEnd()) ++position_;
                return zeroWidth();
            }
            if (kind == '=' || kind == '!') {  // lookahead
                ++position_;
                parseAlternation();
                consumeClose();
                return zeroWidth();
            }
            if (kind == '<' && position_ + 1 < source_.size() && (source_[position_ + 1] == '=' || source_[position_ + 1] == '!')) {
                position_ += 2;  // lookbehind
                parseAlternation();
                consumeClose();
                return zeroWidth();
            }
            if (kind == ':' || kind == '>') {
                ++position_;
                Start inner = parseAlternation();
                consumeClose();
                return inner;
            }
            if (kind == '<' || kind == '\'' || kind == 'P') {  // named group
                if (kind == 'P') ++position_;
                char closer = source_[position_] == '\'' ? '\'' : '>';
                ++position_;
                while (!atEnd() && peek() != closer) ++position_;
                if (!atEnd()) ++position_;
                Start inner = parseAlternation();
                consumeClose();
                return inner;
            }
            // Flags: (?i) (?x-i) (?i:...) (?-mix:...)
            bool enable = true;
            bool newIgnoreCase = ignoreCase_;
            bool newExtended = extended_;
            while (!atEnd() && peek() != ')' && peek() != ':') {
                char flag = peek();
                if (flag == '-') {
                    enable = false;
                } else if (flag == 'i') {
                    newIgnoreCase = enable;
                } else if (flag == 'x') {
                    newExtended = enable;
                } else if (flag == 'm' || flag == 's' || flag == 'a' || flag == 'u' || flag == 'd' || flag == 'l') {
                    // Do not change what a match can begin with.
                } else {
                    failed_ = true;  // conditionals, absent operator, recursion…
                    return Start();
                }
                ++position_;
            }
            if (atEnd()) {
                failed_ = true;
                return Start();
            }
            if (peek() == ')') {  // (?i) applies to the rest of the enclosing group
                ++position_;
                ignoreCase_ = newIgnoreCase;
                extended_ = newExtended;
                return zeroWidth();
            }
            ++position_;  // ':' — the flags apply inside this group only
            bool savedIgnoreCase = ignoreCase_;
            bool savedExtended = extended_;
            ignoreCase_ = newIgnoreCase;
            extended_ = newExtended;
            Start inner = parseAlternation();
            ignoreCase_ = savedIgnoreCase;
            extended_ = savedExtended;
            consumeClose();
            return inner;
        }
        Start inner = parseAlternation();
        consumeClose();
        return inner;
    }

    void consumeClose() {
        if (!atEnd() && peek() == ')') {
            ++position_;
        } else {
            failed_ = true;
        }
    }

    /// A character class such as [a-z_] or [^"\\]. Nested classes and && are folded in
    /// (making the set bigger, which is safe).
    Start parseClass() {
        bool negated = false;
        if (!atEnd() && peek() == '^') {
            negated = true;
            ++position_;
        }
        ByteSet set;
        bool first = true;
        while (!atEnd()) {
            char c = peek();
            if (c == ']' && !first) {
                ++position_;
                Start start;
                ByteSet result = negated ? ~set : set;
                start.bytes = ignoreCase_ ? withBothCases(result) : result;
                // A negated class can match a whole multi-byte character.
                if (negated) start.bytes |= highBytes();
                return start;
            }
            first = false;
            if (c == '[') {
                if (position_ + 1 < source_.size() && source_[position_ + 1] == ':') {
                    size_t close = source_.find(":]", position_);
                    if (close == std::string::npos) {
                        failed_ = true;
                        return Start();
                    }
                    set |= wordBytes();  // POSIX classes: allow the generous "word" set plus punctuation
                    for (int byte = 0x21; byte < 0x7F; ++byte) set.set(static_cast<size_t>(byte));
                    set |= spaceBytes();
                    position_ = close + 2;
                    continue;
                }
                // A nested class: read it and merge it in.
                ++position_;
                Start nested = parseClass();
                set |= nested.bytes;
                continue;
            }
            if (c == '&' && position_ + 1 < source_.size() && source_[position_ + 1] == '&') {
                position_ += 2;
                continue;
            }
            ++position_;
            unsigned char low = static_cast<unsigned char>(c);
            if (c == '\\') {
                if (atEnd()) {
                    failed_ = true;
                    return Start();
                }
                char e = peek();
                ++position_;
                switch (e) {
                    case 'd': set |= digits(); continue;
                    case 'D': set |= ~digits(); continue;
                    case 'w': set |= wordBytes(); continue;
                    case 'W': set |= ~wordBytes(); continue;
                    case 's': set |= spaceBytes(); continue;
                    case 'S': set |= ~spaceBytes(); continue;
                    case 'h': set |= hexBytes(); continue;
                    case 'H': set |= ~hexBytes(); continue;
                    case 'p': case 'P':
                        set |= everything();  // properties: anything
                        while (!atEnd() && peek() != '}' && peek() != ']') ++position_;
                        if (!atEnd() && peek() == '}') ++position_;
                        continue;
                    case 'n': low = '\n'; break;
                    case 't': low = '\t'; break;
                    case 'r': low = '\r'; break;
                    case 'f': low = '\f'; break;
                    case 'v': low = '\v'; break;
                    case 'a': low = '\a'; break;
                    case 'e': low = 0x1B; break;
                    case 'x': {
                        unsigned long value = 0;
                        if (!atEnd() && peek() == '{') {
                            size_t close = source_.find('}', position_);
                            if (close == std::string::npos) {
                                failed_ = true;
                                return Start();
                            }
                            value = std::strtoul(source_.substr(position_ + 1, close - position_ - 1).c_str(), nullptr, 16);
                            position_ = close + 1;
                        } else {
                            size_t digitsRead = 0;
                            while (!atEnd() && digitsRead < 2 && std::isxdigit(static_cast<unsigned char>(peek()))) {
                                value = value * 16 + static_cast<unsigned long>(std::stoi(std::string(1, peek()), nullptr, 16));
                                ++position_;
                                ++digitsRead;
                            }
                        }
                        low = value >= 0x80 ? 0xFF : static_cast<unsigned char>(value);
                        if (value >= 0x80) {
                            set |= highBytes();
                            continue;
                        }
                        break;
                    }
                    default:
                        low = static_cast<unsigned char>(e);
                        break;
                }
            }
            if (low >= 0x80) {
                set |= highBytes();
                continue;
            }
            // A range like a-z.
            if (position_ + 1 < source_.size() && source_[position_] == '-' && source_[position_ + 1] != ']') {
                ++position_;
                unsigned char high = static_cast<unsigned char>(source_[position_]);
                ++position_;
                if (high == '\\' && !atEnd()) {
                    high = static_cast<unsigned char>(source_[position_]);
                    ++position_;
                }
                if (high >= 0x80) {
                    high = 0x7F;
                    set |= highBytes();
                }
                for (int byte = low; byte <= high; ++byte) set.set(static_cast<size_t>(byte));
                continue;
            }
            set.set(low);
        }
        failed_ = true;  // never closed
        return Start();
    }
};

}  // namespace

FirstBytes analyzeFirstBytes(const std::string& source) {
    FirstBytes result;
    Analyzer analyzer(source);
    Start start;
    if (!analyzer.run(start) || start.canBeEmpty) {
        return result;  // unrestricted
    }
    result.restricted = true;
    for (size_t byte = 0; byte < 256; ++byte) {
        result.bytes[byte] = start.bytes.test(byte);
    }
    return result;
}

}  // namespace gw::tm
