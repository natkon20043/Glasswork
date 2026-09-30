#include "SelectionExpand.hpp"

#include <algorithm>
#include <optional>
#include <vector>

namespace gw {

namespace {

/// Most characters looked at in each direction, so a huge file stays quick.
constexpr size_t kScanLimit = 300000;

bool isOpener(char c) { return c == '(' || c == '[' || c == '{'; }
bool isCloser(char c) { return c == ')' || c == ']' || c == '}'; }

char partnerOf(char c) {
    switch (c) {
        case '(': return ')';
        case '[': return ']';
        case '{': return '}';
        case ')': return '(';
        case ']': return '[';
        case '}': return '{';
        default: return 0;
    }
}

bool contains(const Range& outer, const Range& inner) {
    return !(inner.start < outer.start) && !(outer.end < inner.end);
}

bool isBigger(const Range& candidate, const Range& current) {
    bool sameSize = candidate.start == current.start && candidate.end == current.end;
    return contains(candidate, current) && !sameSize;
}

/// The brackets closest around the range, as the positions of the opener and the closer.
std::optional<std::pair<Position, Position>> surroundingBrackets(const TextBuffer& buffer, Range range) {
    // Backwards from the start of the range for an opener nobody closed.
    std::vector<char> closersSeen;
    std::optional<Position> opener;
    char openerByte = 0;
    size_t scanned = 0;
    long line = static_cast<long>(range.start.line);
    long column = static_cast<long>(range.start.column) - 1;
    while (line >= 0 && !opener && scanned < kScanLimit) {
        std::string_view text = buffer.line(static_cast<size_t>(line));
        if (column >= static_cast<long>(text.size())) {
            column = static_cast<long>(text.size()) - 1;
        }
        for (; column >= 0; --column, ++scanned) {
            char c = text[static_cast<size_t>(column)];
            if (isCloser(c)) {
                closersSeen.push_back(c);
            } else if (isOpener(c)) {
                if (!closersSeen.empty() && closersSeen.back() == partnerOf(c)) {
                    closersSeen.pop_back();
                } else if (closersSeen.empty()) {
                    opener = Position{static_cast<size_t>(line), static_cast<size_t>(column)};
                    openerByte = c;
                    break;
                }
            }
        }
        --line;
        column = line >= 0 ? static_cast<long>(buffer.line(static_cast<size_t>(line)).size()) - 1 : -1;
    }
    if (!opener) {
        return std::nullopt;
    }

    // Forwards from the end of the range for the closer that matches it.
    std::vector<char> openersSeen;
    scanned = 0;
    size_t forwardLine = range.end.line;
    size_t forwardColumn = range.end.column;
    while (forwardLine < buffer.lineCount() && scanned < kScanLimit) {
        std::string_view text = buffer.line(forwardLine);
        for (size_t index = forwardColumn; index < text.size(); ++index, ++scanned) {
            char c = text[index];
            if (isOpener(c)) {
                openersSeen.push_back(c);
            } else if (isCloser(c)) {
                if (!openersSeen.empty() && openersSeen.back() == partnerOf(c)) {
                    openersSeen.pop_back();
                } else if (openersSeen.empty() && c == partnerOf(openerByte)) {
                    return std::make_pair(*opener, Position{forwardLine, index});
                } else if (openersSeen.empty()) {
                    return std::nullopt;  // brackets that don't pair up
                }
            }
        }
        ++forwardLine;
        forwardColumn = 0;
    }
    return std::nullopt;
}

std::optional<Range> wordAround(const TextBuffer& buffer, Position at) {
    std::string_view text = buffer.line(at.line);
    size_t start = std::min(at.column, text.size());
    size_t end = start;
    while (start > 0 && isWordByte(static_cast<unsigned char>(text[start - 1]))) --start;
    while (end < text.size() && isWordByte(static_cast<unsigned char>(text[end]))) ++end;
    if (start == end) {
        return std::nullopt;
    }
    return Range{{at.line, start}, {at.line, end}};
}

}  // namespace

Range expandedSelection(const TextBuffer& buffer, Range current) {
    current = current.normalized();

    std::vector<Range> candidates;

    if (current.start == current.end) {
        if (auto word = wordAround(buffer, current.start)) {
            candidates.push_back(*word);
        }
    }
    if (auto brackets = surroundingBrackets(buffer, current)) {
        Position opener = brackets->first;
        Position closer = brackets->second;
        candidates.push_back(Range{{opener.line, opener.column + 1}, closer});           // inside the brackets
        candidates.push_back(Range{opener, {closer.line, closer.column + 1}});           // and the brackets
    }
    // The line, without its indentation.
    {
        std::string_view text = buffer.line(current.start.line);
        size_t indent = text.find_first_not_of(" \t");
        if (indent == std::string_view::npos) {
            indent = text.size();
        }
        candidates.push_back(Range{{current.start.line, indent}, {current.end.line, buffer.line(current.end.line).size()}});
    }
    // Whole lines, then everything.
    candidates.push_back(Range{{current.start.line, 0}, {current.end.line, buffer.line(current.end.line).size()}});
    candidates.push_back(Range{{0, 0}, buffer.end()});

    // The smallest candidate that is bigger than what is selected now.
    std::optional<Range> best;
    for (const Range& candidate : candidates) {
        if (!isBigger(candidate, current)) {
            continue;
        }
        if (!best || isBigger(*best, candidate)) {
            best = candidate;
        }
    }
    return best ? *best : current;
}

}  // namespace gw
