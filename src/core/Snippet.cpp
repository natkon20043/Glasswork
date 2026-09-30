#include "Snippet.hpp"

#include <cctype>
#include <map>

namespace gw {

namespace {

/// One piece of a snippet: literal text, or a numbered tab stop with optional default content.
struct Node {
    bool isTabStop = false;
    std::string text;
    int number = 0;
    std::vector<Node> children;
};

bool isNameStart(char c) {
    return std::isalpha(static_cast<unsigned char>(c)) != 0 || c == '_';
}

bool isNameCharacter(char c) {
    return std::isalnum(static_cast<unsigned char>(c)) != 0 || c == '_';
}

bool isDigit(char c) {
    return std::isdigit(static_cast<unsigned char>(c)) != 0;
}

void appendText(std::vector<Node>& nodes, std::string_view text) {
    if (text.empty()) {
        return;
    }
    if (nodes.empty() || nodes.back().isTabStop) {
        nodes.push_back(Node{});
    }
    nodes.back().text.append(text);
}

class Parser {
public:
    explicit Parser(std::string_view source) : source_(source) {}

    std::vector<Node> parseAll() { return parseSequence(false); }

private:
    bool atEnd() const { return position_ >= source_.size(); }
    char current() const { return source_[position_]; }

    int readNumber() {
        int number = 0;
        while (!atEnd() && isDigit(current())) {
            number = number * 10 + (current() - '0');
            ++position_;
        }
        return number;
    }

    std::string readName() {
        size_t start = position_;
        while (!atEnd() && isNameCharacter(current())) {
            ++position_;
        }
        return std::string(source_.substr(start, position_ - start));
    }

    /// Reads nodes up to the end, or up to a closing brace when inside ${...}.
    std::vector<Node> parseSequence(bool insideBraces) {
        std::vector<Node> nodes;
        while (!atEnd()) {
            char c = current();
            if (insideBraces && c == '}') {
                break;
            }
            if (c == '\\' && position_ + 1 < source_.size()) {
                char next = source_[position_ + 1];
                if (next == '$' || next == '}' || next == '\\') {
                    appendText(nodes, std::string_view(&source_[position_ + 1], 1));
                    position_ += 2;
                    continue;
                }
            }
            if (c == '$') {
                parseDollar(nodes);
                continue;
            }
            appendText(nodes, std::string_view(&source_[position_], 1));
            ++position_;
        }
        return nodes;
    }

    void addTabStop(std::vector<Node>& nodes, int number, std::vector<Node> children) {
        Node node;
        node.isTabStop = true;
        node.number = number;
        node.children = std::move(children);
        nodes.push_back(std::move(node));
    }

    /// Reads the closing brace of a ${...} if it is next.
    void skipClosingBrace() {
        if (!atEnd() && current() == '}') {
            ++position_;
        }
    }

    /// Skips to just after the matching close brace, for parts that are not supported.
    void skipToClosingBrace() {
        int depth = 1;
        while (!atEnd() && depth > 0) {
            if (current() == '{') {
                ++depth;
            } else if (current() == '}') {
                --depth;
            }
            ++position_;
        }
    }

    void parseDollar(std::vector<Node>& nodes) {
        // current() is the '$'
        if (position_ + 1 >= source_.size()) {
            appendText(nodes, "$");
            ++position_;
            return;
        }
        char next = source_[position_ + 1];
        if (isDigit(next)) {
            ++position_;
            addTabStop(nodes, readNumber(), {});
            return;
        }
        if (isNameStart(next)) {
            ++position_;
            readName();  // a variable we do not know: nothing to insert
            return;
        }
        if (next != '{') {
            appendText(nodes, "$");
            ++position_;
            return;
        }

        position_ += 2;  // past "${"
        if (atEnd()) {
            return;
        }
        if (isDigit(current())) {
            int number = readNumber();
            parseAfterNumber(nodes, number);
            return;
        }
        if (isNameStart(current())) {
            readName();
            if (!atEnd() && current() == ':') {
                ++position_;
                std::vector<Node> fallback = parseSequence(true);
                skipClosingBrace();
                for (Node& node : fallback) {
                    nodes.push_back(std::move(node));
                }
                return;
            }
            skipToClosingBrace();  // ${name}, ${name/regex/format/}: nothing to insert
            return;
        }
        skipToClosingBrace();
    }

    /// After "${1": the rest of the placeholder.
    void parseAfterNumber(std::vector<Node>& nodes, int number) {
        if (atEnd()) {
            addTabStop(nodes, number, {});
            return;
        }
        char c = current();
        if (c == ':') {
            ++position_;
            std::vector<Node> content = parseSequence(true);
            skipClosingBrace();
            addTabStop(nodes, number, std::move(content));
            return;
        }
        if (c == '|') {
            ++position_;
            std::string firstChoice;
            bool readingFirst = true;
            while (!atEnd() && !(current() == '|' && position_ + 1 < source_.size() && source_[position_ + 1] == '}')) {
                if (current() == '\\' && position_ + 1 < source_.size()) {
                    if (readingFirst) firstChoice += source_[position_ + 1];
                    position_ += 2;
                    continue;
                }
                if (current() == ',') {
                    readingFirst = false;
                } else if (readingFirst) {
                    firstChoice += current();
                }
                ++position_;
            }
            if (!atEnd()) {
                position_ += 2;  // past "|}"
            }
            std::vector<Node> content;
            appendText(content, firstChoice);
            addTabStop(nodes, number, std::move(content));
            return;
        }
        skipClosingBrace();
        addTabStop(nodes, number, {});
    }

    std::string_view source_;
    size_t position_ = 0;
};

/// Builds the final text and the spans of each tab stop from the parsed pieces.
class Builder {
public:
    explicit Builder(std::string_view indent) : indent_(indent) {}

    ParsedSnippet build(const std::vector<Node>& nodes) {
        // A mirror written as plain $1 shows the text of the placeholder ${1:text}, wherever
        // that is in the snippet, so the defaults are collected first.
        collectDefaults(nodes);
        emit(nodes);

        ParsedSnippet result;
        result.text = std::move(text_);
        for (auto& [number, spans] : spans_) {
            if (number != 0) {
                result.stops.push_back(std::move(spans));
            }
        }
        auto finalStop = spans_.find(0);
        if (finalStop != spans_.end()) {
            result.stops.push_back(std::move(finalStop->second));
        } else {
            result.stops.push_back({SnippetSpan{result.text.size(), 0}});
        }
        return result;
    }

private:
    void collectDefaults(const std::vector<Node>& nodes) {
        for (const Node& node : nodes) {
            if (!node.isTabStop || node.children.empty()) {
                continue;
            }
            if (defaults_.find(node.number) == defaults_.end()) {
                defaults_[node.number] = plainText(node.children);
            }
            collectDefaults(node.children);
        }
    }

    std::string plainText(const std::vector<Node>& nodes) {
        std::string result;
        for (const Node& node : nodes) {
            if (!node.isTabStop) {
                result += node.text;
            } else if (!node.children.empty()) {
                result += plainText(node.children);
            } else {
                auto found = defaults_.find(node.number);
                if (found != defaults_.end()) {
                    result += found->second;
                }
            }
        }
        return result;
    }

    void appendWithIndent(const std::string& literal) {
        for (char c : literal) {
            text_ += c;
            if (c == '\n') {
                text_ += indent_;
            }
        }
    }

    void emit(const std::vector<Node>& nodes) {
        for (const Node& node : nodes) {
            if (!node.isTabStop) {
                appendWithIndent(node.text);
                continue;
            }
            size_t start = text_.size();
            if (!node.children.empty()) {
                emit(node.children);
            } else {
                auto found = defaults_.find(node.number);
                if (found != defaults_.end()) {
                    appendWithIndent(found->second);
                }
            }
            spans_[node.number].push_back(SnippetSpan{start, text_.size() - start});
        }
    }

    std::string indent_;
    std::string text_;
    std::map<int, std::string> defaults_;
    std::map<int, std::vector<SnippetSpan>> spans_;
};

}  // namespace

bool ParsedSnippet::hasOnlyFinalStop() const {
    return stops.size() == 1 && stops[0].size() == 1 && stops[0][0].length == 0 &&
           stops[0][0].offset == text.size();
}

ParsedSnippet parseSnippet(std::string_view snippet, std::string_view indent) {
    Parser parser(snippet);
    std::vector<Node> nodes = parser.parseAll();
    Builder builder(indent);
    return builder.build(nodes);
}

}  // namespace gw
