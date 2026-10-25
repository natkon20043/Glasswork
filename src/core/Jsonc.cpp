#include "Jsonc.hpp"

namespace gw {

namespace {

/// Removes commas that are directly followed (ignoring whitespace and comments) by `}` or
/// `]`. Strings and comments are copied through untouched.
std::string withoutTrailingCommas(const std::string& text) {
    std::string out;
    out.reserve(text.size());
    size_t index = 0;
    auto skipComment = [&](size_t at) -> size_t {  // returns the index just past a comment at `at`
        if (at + 1 >= text.size() || text[at] != '/') {
            return at;
        }
        if (text[at + 1] == '/') {
            size_t end = text.find('\n', at);
            return end == std::string::npos ? text.size() : end;
        }
        if (text[at + 1] == '*') {
            size_t end = text.find("*/", at + 2);
            return end == std::string::npos ? text.size() : end + 2;
        }
        return at;
    };
    while (index < text.size()) {
        char character = text[index];
        if (character == '"') {  // copy a whole string, honouring escapes
            size_t end = index + 1;
            while (end < text.size() && text[end] != '"') {
                end += text[end] == '\\' ? 2 : 1;
            }
            end = std::min(end + 1, text.size());
            out.append(text, index, end - index);
            index = end;
            continue;
        }
        if (character == '/') {
            size_t end = skipComment(index);
            if (end != index) {
                out.append(text, index, end - index);
                index = end;
                continue;
            }
        }
        if (character == ',') {
            size_t look = index + 1;
            while (look < text.size()) {
                if (std::isspace(static_cast<unsigned char>(text[look]))) {
                    ++look;
                } else if (size_t end = skipComment(look); end != look) {
                    look = end;
                } else {
                    break;
                }
            }
            if (look < text.size() && (text[look] == '}' || text[look] == ']')) {
                ++index;  // drop the trailing comma
                continue;
            }
        }
        out += character;
        ++index;
    }
    return out;
}

}  // namespace

nlohmann::json parseJsonc(const std::string& text) {
    return nlohmann::json::parse(withoutTrailingCommas(text), nullptr, /*allow_exceptions=*/false,
                                 /*ignore_comments=*/true);
}

}  // namespace gw
