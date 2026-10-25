#include "Snippet.hpp"

#include <cctype>
#include <cstdio>
#include <chrono>
#include <ctime>
#include <filesystem>
#include <map>
#include <random>

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
    Parser(std::string_view source, const SnippetVariables* variables) : source_(source), variables_(variables) {}

    std::vector<Node> parseAll() { return parseSequence(false); }

private:
    bool atEnd() const { return position_ >= source_.size(); }
    char current() const { return source_[position_]; }

    int readNumber() {
        // Tab stop numbers are small; a longer run of digits is read whole but kept in range.
        const int largest = 100000;
        int number = 0;
        while (!atEnd() && isDigit(current())) {
            if (number < largest) {
                number = number * 10 + (current() - '0');
            }
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
            std::string name = readName();
            if (const std::string* value = lookup(name)) {
                appendText(nodes, *value);  // a known variable: its value; an unknown one gives nothing
            }
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
            std::string name = readName();
            const std::string* value = lookup(name);
            if (!atEnd() && current() == ':') {
                ++position_;
                std::vector<Node> fallback = parseSequence(true);
                skipClosingBrace();
                if (value != nullptr) {
                    appendText(nodes, *value);  // the variable is known: its value, not the default
                    return;
                }
                for (Node& node : fallback) {
                    nodes.push_back(std::move(node));
                }
                return;
            }
            skipToClosingBrace();  // ${name} or ${name/regex/format/} (the transform is not applied)
            if (value != nullptr) {
                appendText(nodes, *value);
            }
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
                    if (readingFirst) {
                        firstChoice += source_[position_ + 1];
                    }
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

    const std::string* lookup(const std::string& name) const {
        if (variables_ == nullptr) {
            return nullptr;
        }
        auto found = variables_->find(name);
        if (found == variables_->end()) {
            return nullptr;
        }
        return &found->second;
    }

    std::string_view source_;
    const SnippetVariables* variables_ = nullptr;
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

SnippetVariables standardSnippetVariables(const std::string& filePath, const std::string& workspaceFolder) {
    namespace fs = std::filesystem;
    SnippetVariables variables;
    if (!filePath.empty()) {
        fs::path path(filePath);
        variables["TM_FILENAME"] = path.filename().string();
        variables["TM_FILENAME_BASE"] = path.stem().string();
        variables["TM_DIRECTORY"] = path.parent_path().string();
        variables["TM_FILEPATH"] = filePath;
        std::string relative = filePath;
        if (!workspaceFolder.empty() && filePath.rfind(workspaceFolder + "/", 0) == 0) {
            relative = filePath.substr(workspaceFolder.size() + 1);
        }
        variables["RELATIVE_FILEPATH"] = relative;
    }
    if (!workspaceFolder.empty()) {
        variables["WORKSPACE_FOLDER"] = workspaceFolder;
        variables["WORKSPACE_NAME"] = fs::path(workspaceFolder).filename().string();
    }

    std::time_t now = std::time(nullptr);
    std::tm local = {};
    localtime_r(&now, &local);  // (the thread-safe form: plain localtime can return null and shares one buffer)
    auto formatted = [&](const char* format) {
        char buffer[64];
        size_t length = std::strftime(buffer, sizeof(buffer), format, &local);
        return std::string(buffer, length);  // length 0 on failure: never read an unfilled buffer
    };
    variables["CURRENT_YEAR"] = formatted("%Y");
    variables["CURRENT_YEAR_SHORT"] = formatted("%y");
    variables["CURRENT_MONTH"] = formatted("%m");
    variables["CURRENT_MONTH_NAME"] = formatted("%B");
    variables["CURRENT_MONTH_NAME_SHORT"] = formatted("%b");
    variables["CURRENT_DATE"] = formatted("%d");
    variables["CURRENT_DAY_NAME"] = formatted("%A");
    variables["CURRENT_DAY_NAME_SHORT"] = formatted("%a");
    variables["CURRENT_HOUR"] = formatted("%H");
    variables["CURRENT_MINUTE"] = formatted("%M");
    variables["CURRENT_SECOND"] = formatted("%S");
    variables["CURRENT_SECONDS_UNIX"] = std::to_string(static_cast<long long>(now));

    // A random version-4 UUID.
    static std::mt19937_64 generator{std::random_device{}()};
    unsigned long long high = generator();
    unsigned long long low = generator();
    high = (high & 0xFFFFFFFFFFFF0FFFULL) | 0x0000000000004000ULL;
    low = (low & 0x3FFFFFFFFFFFFFFFULL) | 0x8000000000000000ULL;
    char uuid[40];
    std::snprintf(uuid, sizeof(uuid), "%08llx-%04llx-%04llx-%04llx-%012llx", high >> 32, (high >> 16) & 0xFFFF, high & 0xFFFF,
                  low >> 48, low & 0xFFFFFFFFFFFFULL);
    variables["UUID"] = uuid;
    return variables;
}

ParsedSnippet parseSnippet(std::string_view snippet, std::string_view indent, const SnippetVariables* variables) {
    Parser parser(snippet, variables);
    std::vector<Node> nodes = parser.parseAll();
    Builder builder(indent);
    return builder.build(nodes);
}

}  // namespace gw
