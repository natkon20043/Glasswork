#include "SemanticTokens.hpp"

#include <algorithm>

namespace gw {

std::vector<SemanticToken> decodeSemanticTokens(const std::vector<uint32_t>& data) {
    std::vector<SemanticToken> tokens;
    tokens.reserve(data.size() / 5);
    uint32_t line = 0;
    uint32_t start = 0;
    for (size_t index = 0; index + 4 < data.size(); index += 5) {
        uint32_t deltaLine = data[index];
        uint32_t deltaStart = data[index + 1];
        if (deltaLine > 0) {
            line += deltaLine;
            start = deltaStart;
        } else {
            start += deltaStart;
        }
        SemanticToken token;
        token.line = line;
        token.startUnit = start;
        token.lengthUnits = data[index + 2];
        token.type = data[index + 3];
        token.modifiers = data[index + 4];
        tokens.push_back(token);
    }
    return tokens;
}

std::string scopeForSemanticType(const std::string& typeName, const std::vector<std::string>& modifiers) {
    (void)modifiers;
    if (typeName == "namespace") return "entity.name.namespace";
    if (typeName == "class") return "entity.name.type.class";
    if (typeName == "struct" || typeName == "type" || typeName == "interface" || typeName == "typeParameter" ||
        typeName == "concept") {
        return "entity.name.type";
    }
    if (typeName == "enum") return "entity.name.type.enum";
    if (typeName == "function" || typeName == "method") return "entity.name.function";
    if (typeName == "macro") return "entity.name.function.preprocessor";
    if (typeName == "enumMember") return "variable.other.enummember";
    if (typeName == "decorator") return "entity.name.function.decorator";
    if (typeName == "event") return "entity.name.function";
    return std::string();
}

void adjustSemanticTokensForEdit(std::vector<SemanticToken>& tokens, size_t firstLine, size_t lastLineBefore, long lineDelta) {
    auto byLine = [](const SemanticToken& token, size_t line) { return token.line < line; };
    auto begin = std::lower_bound(tokens.begin(), tokens.end(), firstLine, byLine);
    auto end = std::lower_bound(begin, tokens.end(), lastLineBefore + 1, byLine);
    end = tokens.erase(begin, end);
    if (lineDelta == 0) {
        return;
    }
    size_t position = static_cast<size_t>(end - tokens.begin());
    for (size_t index = position; index < tokens.size(); ++index) {
        long moved = static_cast<long>(tokens[index].line) + lineDelta;
        tokens[index].line = static_cast<uint32_t>(std::max(0L, moved));
    }
}

}  // namespace gw
