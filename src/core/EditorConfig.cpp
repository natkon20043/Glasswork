#include "EditorConfig.hpp"

#include <algorithm>
#include <cctype>
#include <fstream>
#include <regex>
#include <sstream>
#include <vector>

namespace gw {

namespace {

std::string trimmed(std::string_view text) {
    size_t start = 0;
    size_t end = text.size();
    while (start < end && std::isspace(static_cast<unsigned char>(text[start]))) {
        ++start;
    }
    while (end > start && std::isspace(static_cast<unsigned char>(text[end - 1]))) {
        --end;
    }
    return std::string(text.substr(start, end - start));
}

std::string lowered(std::string text) {
    std::transform(text.begin(), text.end(), text.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return text;
}

void appendEscaped(std::string& regex, char c) {
    static const std::string special = "\\^$.|?*+()[]{}";
    if (special.find(c) != std::string::npos) {
        regex += '\\';
    }
    regex += c;
}

/// Splits "a,b,{c,d}" on commas that are not inside nested braces.
std::vector<std::string> splitAlternatives(const std::string& text) {
    std::vector<std::string> parts;
    std::string current;
    int depth = 0;
    for (char c : text) {
        if (c == '{') ++depth;
        if (c == '}') --depth;
        if (c == ',' && depth == 0) {
            parts.push_back(current);
            current.clear();
        } else {
            current += c;
        }
    }
    parts.push_back(current);
    return parts;
}

std::string globToRegex(const std::string& glob);

/// The regex for the text inside braces: alternatives, or a numeric range like 1..3.
std::string braceToRegex(const std::string& inside, bool& ok) {
    ok = true;
    size_t dots = inside.find("..");
    if (dots != std::string::npos && inside.find(',') == std::string::npos) {
        try {
            int from = std::stoi(inside.substr(0, dots));
            int to = std::stoi(inside.substr(dots + 2));
            if (from <= to && to - from <= 200) {
                std::string result = "(?:";
                for (int value = from; value <= to; ++value) {
                    if (value > from) result += "|";
                    result += std::to_string(value);
                }
                return result + ")";
            }
        } catch (const std::exception&) {
        }
        ok = false;
        return std::string();
    }
    std::vector<std::string> parts = splitAlternatives(inside);
    if (parts.size() < 2) {
        ok = false;  // "{x}" with no comma is literal
        return std::string();
    }
    std::string result = "(?:";
    for (size_t index = 0; index < parts.size(); ++index) {
        if (index > 0) result += "|";
        result += globToRegex(parts[index]);
    }
    return result + ")";
}

std::string globToRegex(const std::string& glob) {
    std::string regex;
    for (size_t i = 0; i < glob.size(); ++i) {
        char c = glob[i];
        if (c == '*') {
            if (i + 1 < glob.size() && glob[i + 1] == '*') {
                regex += ".*";
                ++i;
            } else {
                regex += "[^/]*";
            }
        } else if (c == '?') {
            regex += "[^/]";
        } else if (c == '[') {
            size_t close = glob.find(']', i + 1);
            if (close == std::string::npos) {
                regex += "\\[";
            } else {
                std::string set = glob.substr(i + 1, close - i - 1);
                regex += "[";
                if (!set.empty() && set[0] == '!') {
                    regex += "^";
                    set.erase(0, 1);
                }
                for (char member : set) {
                    if (member == '\\' || member == '[') regex += '\\';
                    regex += member;
                }
                regex += "]";
                i = close;
            }
        } else if (c == '{') {
            // Find the matching close brace.
            int depth = 0;
            size_t close = std::string::npos;
            for (size_t j = i; j < glob.size(); ++j) {
                if (glob[j] == '{') ++depth;
                if (glob[j] == '}' && --depth == 0) {
                    close = j;
                    break;
                }
            }
            bool ok = false;
            std::string alternative;
            if (close != std::string::npos) {
                alternative = braceToRegex(glob.substr(i + 1, close - i - 1), ok);
            }
            if (ok) {
                regex += alternative;
                i = close;
            } else {
                regex += "\\{";
            }
        } else if (c == '\\' && i + 1 < glob.size()) {
            appendEscaped(regex, glob[++i]);
        } else {
            appendEscaped(regex, c);
        }
    }
    return regex;
}

std::optional<bool> parseBool(const std::string& value) {
    if (value == "true") return true;
    if (value == "false") return false;
    return std::nullopt;
}

void applyProperty(const std::string& key, const std::string& rawValue, EditorConfigResult& result) {
    std::string value = lowered(rawValue);
    if (value == "unset") {
        // "unset" removes what an earlier file or section said.
        if (key == "indent_style") result.useTabs.reset();
        else if (key == "indent_size") result.indentSize.reset();
        else if (key == "tab_width") result.tabWidth.reset();
        else if (key == "end_of_line") result.endOfLine.reset();
        else if (key == "trim_trailing_whitespace") result.trimTrailingWhitespace.reset();
        else if (key == "insert_final_newline") result.insertFinalNewline.reset();
        return;
    }
    if (key == "indent_style") {
        if (value == "tab") result.useTabs = true;
        else if (value == "space") result.useTabs = false;
    } else if (key == "indent_size") {
        if (value == "tab") {
            // "tab" means: use tab_width for the size.
            result.indentSize.reset();
        } else {
            try {
                int size = std::stoi(value);
                if (size > 0 && size <= 32) result.indentSize = size;
            } catch (const std::exception&) {
            }
        }
    } else if (key == "tab_width") {
        try {
            int size = std::stoi(value);
            if (size > 0 && size <= 32) result.tabWidth = size;
        } catch (const std::exception&) {
        }
    } else if (key == "end_of_line") {
        if (value == "lf" || value == "crlf" || value == "cr") result.endOfLine = value;
    } else if (key == "trim_trailing_whitespace") {
        result.trimTrailingWhitespace = parseBool(value);
    } else if (key == "insert_final_newline") {
        result.insertFinalNewline = parseBool(value);
    }
}

}  // namespace

bool editorConfigGlobMatches(const std::string& pattern, const std::string& relativePath) {
    std::string glob = pattern;
    bool anchored = glob.find('/') != std::string::npos;
    if (!glob.empty() && glob[0] == '/') {
        glob.erase(0, 1);
    }
    std::string expression = globToRegex(glob);
    if (!anchored) {
        expression = "(?:.*/)?" + expression;  // a bare pattern matches the name at any depth
    }
    try {
        return std::regex_match(relativePath, std::regex(expression));
    } catch (const std::regex_error&) {
        return false;
    }
}

bool applyEditorConfigText(std::string_view text, const std::filesystem::path& configFolder,
                           const std::filesystem::path& file, EditorConfigResult& result) {
    std::error_code error;
    std::filesystem::path relative = std::filesystem::relative(file, configFolder, error);
    std::string relativePath = error ? file.string() : relative.generic_string();

    bool isRoot = false;
    bool sectionMatches = false;
    bool inSection = false;
    std::istringstream input{std::string(text)};
    std::string line;
    while (std::getline(input, line)) {
        std::string content = trimmed(line);
        if (content.empty() || content[0] == '#' || content[0] == ';') {
            continue;
        }
        if (content[0] == '[' && content.back() == ']') {
            inSection = true;
            sectionMatches = editorConfigGlobMatches(content.substr(1, content.size() - 2), relativePath);
            continue;
        }
        size_t equals = content.find('=');
        if (equals == std::string::npos) {
            continue;
        }
        std::string key = lowered(trimmed(content.substr(0, equals)));
        std::string value = trimmed(content.substr(equals + 1));
        if (!inSection) {
            if (key == "root" && lowered(value) == "true") isRoot = true;
            continue;
        }
        if (sectionMatches) {
            applyProperty(key, value, result);
        }
    }
    return isRoot;
}

EditorConfigResult editorConfigFor(const std::filesystem::path& file) {
    // Collect the folders from the file's own up to the top, then apply the farthest first.
    std::vector<std::pair<std::filesystem::path, std::string>> configs;
    std::filesystem::path folder = file.parent_path();
    while (!folder.empty()) {
        std::filesystem::path candidate = folder / ".editorconfig";
        std::error_code error;
        if (std::filesystem::is_regular_file(candidate, error)) {
            std::ifstream stream(candidate, std::ios::binary);
            std::stringstream contents;
            contents << stream.rdbuf();
            std::string text = contents.str();
            // Is this one the root? Then nothing above it counts.
            EditorConfigResult scratch;
            bool isRoot = applyEditorConfigText(text, folder, file, scratch);
            configs.push_back({folder, std::move(text)});
            if (isRoot) {
                break;
            }
        }
        std::filesystem::path parent = folder.parent_path();
        if (parent == folder) {
            break;
        }
        folder = parent;
    }
    EditorConfigResult result;
    for (auto entry = configs.rbegin(); entry != configs.rend(); ++entry) {
        applyEditorConfigText(entry->second, entry->first, file, result);
    }
    return result;
}

}  // namespace gw
