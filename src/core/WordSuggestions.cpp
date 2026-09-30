#include "WordSuggestions.hpp"

#include <algorithm>
#include <cctype>
#include <unordered_map>

namespace gw {

namespace {

bool startsWith(std::string_view word, std::string_view prefix, bool ignoreCase) {
    if (word.size() < prefix.size()) {
        return false;
    }
    for (size_t index = 0; index < prefix.size(); ++index) {
        unsigned char wordByte = static_cast<unsigned char>(word[index]);
        unsigned char prefixByte = static_cast<unsigned char>(prefix[index]);
        if (ignoreCase) {
            wordByte = static_cast<unsigned char>(std::tolower(wordByte));
            prefixByte = static_cast<unsigned char>(std::tolower(prefixByte));
        }
        if (wordByte != prefixByte) {
            return false;
        }
    }
    return true;
}

bool hasUpperCase(std::string_view text) {
    return std::any_of(text.begin(), text.end(), [](char c) { return std::isupper(static_cast<unsigned char>(c)) != 0; });
}

}  // namespace

std::vector<std::string> wordSuggestions(const TextBuffer& buffer, std::string_view prefix, Position caret,
                                         size_t maxResults, size_t lineRadius) {
    bool ignoreCase = !hasUpperCase(prefix);
    size_t firstLine = caret.line > lineRadius ? caret.line - lineRadius : 0;
    size_t lastLine = std::min(buffer.lineCount(), caret.line + lineRadius + 1);

    std::unordered_map<std::string, size_t> counts;
    for (size_t lineIndex = firstLine; lineIndex < lastLine; ++lineIndex) {
        std::string_view line = buffer.line(lineIndex);
        size_t position = 0;
        while (position < line.size()) {
            while (position < line.size() && !isWordByte(static_cast<unsigned char>(line[position]))) {
                ++position;
            }
            size_t start = position;
            while (position < line.size() && isWordByte(static_cast<unsigned char>(line[position]))) {
                ++position;
            }
            if (position == start) {
                continue;
            }
            std::string_view word = line.substr(start, position - start);
            bool isWordBeingTyped = lineIndex == caret.line && position == caret.column;
            if (isWordBeingTyped || word.size() <= prefix.size() || word.size() < 3) {
                continue;
            }
            if (!startsWith(word, prefix, ignoreCase)) {
                continue;
            }
            ++counts[std::string(word)];
        }
    }

    std::vector<std::pair<std::string, size_t>> ranked(counts.begin(), counts.end());
    std::sort(ranked.begin(), ranked.end(), [](const auto& a, const auto& b) {
        if (a.second != b.second) {
            return a.second > b.second;
        }
        return a.first < b.first;
    });
    std::vector<std::string> result;
    for (const auto& entry : ranked) {
        if (result.size() >= maxResults) {
            break;
        }
        result.push_back(entry.first);
    }
    return result;
}

}  // namespace gw
