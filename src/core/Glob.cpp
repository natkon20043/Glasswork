#include "Glob.hpp"

namespace gw {

namespace {

/// Turns a glob into an ECMAScript regular expression source.
std::string regexSourceFor(const std::string& glob) {
    std::string source;
    size_t index = 0;
    int braceDepth = 0;
    while (index < glob.size()) {
        char character = glob[index];
        if (character == '*') {
            if (index + 1 < glob.size() && glob[index + 1] == '*') {
                index += 2;
                if (index < glob.size() && glob[index] == '/') {
                    ++index;
                    source += "(?:.*/)?";  // "**/" is any folders, or none
                } else {
                    source += ".*";
                }
                continue;
            }
            source += "[^/]*";
        } else if (character == '?') {
            source += "[^/]";
        } else if (character == '{') {
            ++braceDepth;
            source += "(?:";
        } else if (character == '}' && braceDepth > 0) {
            --braceDepth;
            source += ")";
        } else if (character == ',' && braceDepth > 0) {
            source += "|";
        } else if (character == '[') {
            size_t close = glob.find(']', index + 1);
            if (close == std::string::npos) {
                source += "\\[";
            } else {
                std::string body = glob.substr(index + 1, close - index - 1);
                if (!body.empty() && body[0] == '!') {
                    body[0] = '^';
                }
                source += "[" + body + "]";
                index = close;
            }
        } else if (std::string("\\^$+.()|]").find(character) != std::string::npos) {
            source += '\\';
            source += character;
        } else {
            source += character;
        }
        ++index;
    }
    return "^" + source + "$";
}

}  // namespace

GlobPattern::GlobPattern(const std::string& glob) : source_(glob) {
    matchesNameAnywhere_ = glob.find('/') == std::string::npos;
    try {
        regex_ = std::regex(regexSourceFor(glob), std::regex::ECMAScript);
    } catch (const std::regex_error&) {
        regex_ = std::regex("^$");  // a malformed glob matches nothing
    }
}

bool GlobPattern::matches(const std::string& relativePath) const {
    if (std::regex_match(relativePath, regex_)) {
        return true;
    }
    if (matchesNameAnywhere_) {
        size_t slash = relativePath.rfind('/');
        std::string name = slash == std::string::npos ? relativePath : relativePath.substr(slash + 1);
        return std::regex_match(name, regex_);
    }
    return false;
}

}  // namespace gw
