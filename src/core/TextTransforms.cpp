#include "TextTransforms.hpp"

#include <algorithm>
#include <cctype>
#include <unordered_set>
#include <vector>

namespace gw {

namespace {

char asciiUpper(char c) {
    return static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
}

char asciiLower(char c) {
    return static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
}

bool isAsciiLetterOrDigit(char c) {
    return std::isalnum(static_cast<unsigned char>(c)) != 0;
}

/// The text split at '\n'. `endsWithBreak` says whether the last line break ended the text.
std::vector<std::string_view> splitLines(std::string_view text, bool& endsWithBreak) {
    endsWithBreak = !text.empty() && text.back() == '\n';
    if (endsWithBreak) {
        text.remove_suffix(1);
    }
    std::vector<std::string_view> lines;
    size_t start = 0;
    for (;;) {
        size_t end = text.find('\n', start);
        if (end == std::string_view::npos) {
            lines.push_back(text.substr(start));
            break;
        }
        lines.push_back(text.substr(start, end - start));
        start = end + 1;
    }
    return lines;
}

std::string joinWithBreaks(const std::vector<std::string_view>& lines, bool endsWithBreak) {
    std::string result;
    for (size_t index = 0; index < lines.size(); ++index) {
        if (index > 0) {
            result += '\n';
        }
        result.append(lines[index]);
    }
    if (endsWithBreak) {
        result += '\n';
    }
    return result;
}

std::string lowerCopy(std::string_view text) {
    std::string result(text);
    std::transform(result.begin(), result.end(), result.begin(), asciiLower);
    return result;
}

}  // namespace

std::string upperCaseText(std::string_view text) {
    std::string result(text);
    std::transform(result.begin(), result.end(), result.begin(), asciiUpper);
    return result;
}

std::string lowerCaseText(std::string_view text) {
    return lowerCopy(text);
}

std::string titleCaseText(std::string_view text) {
    std::string result(text);
    bool atWordStart = true;
    for (char& c : result) {
        if (isAsciiLetterOrDigit(c)) {
            c = atWordStart ? asciiUpper(c) : asciiLower(c);
            atWordStart = false;
        } else if (c != '\'') {
            atWordStart = true;  // an apostrophe stays inside a word: "don't"
        }
    }
    return result;
}

std::string sortLinesText(std::string_view text, bool descending, bool ignoreCase) {
    bool endsWithBreak = false;
    std::vector<std::string_view> lines = splitLines(text, endsWithBreak);
    std::stable_sort(lines.begin(), lines.end(), [&](std::string_view a, std::string_view b) {
        int order = 0;
        if (ignoreCase) {
            order = lowerCopy(a).compare(lowerCopy(b));
        } else {
            order = a.compare(b);
        }
        return descending ? order > 0 : order < 0;
    });
    return joinWithBreaks(lines, endsWithBreak);
}

std::string uniqueLinesText(std::string_view text) {
    bool endsWithBreak = false;
    std::vector<std::string_view> lines = splitLines(text, endsWithBreak);
    std::unordered_set<std::string_view> seen;
    std::vector<std::string_view> kept;
    for (std::string_view line : lines) {
        if (seen.insert(line).second) {
            kept.push_back(line);
        }
    }
    return joinWithBreaks(kept, endsWithBreak);
}

std::string joinLinesText(std::string_view text) {
    bool endsWithBreak = false;
    std::vector<std::string_view> lines = splitLines(text, endsWithBreak);
    std::string result;
    for (size_t index = 0; index < lines.size(); ++index) {
        std::string_view line = lines[index];
        if (index > 0) {
            size_t firstText = line.find_first_not_of(" \t");
            line = firstText == std::string_view::npos ? std::string_view() : line.substr(firstText);
            if (!line.empty() && !result.empty() && result.back() != ' ' && result.back() != '\t') {
                result += ' ';
            }
        }
        result.append(line);
    }
    if (endsWithBreak) {
        result += '\n';
    }
    return result;
}

}  // namespace gw
