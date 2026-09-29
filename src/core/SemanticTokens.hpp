#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace gw {

/// One token from a language server's semantic highlighting: a stretch of a line that the server
/// knows the real meaning of (a type, a function, a macro…).
struct SemanticToken {
    uint32_t line = 0;
    uint32_t startUnit = 0;    // UTF-16 units from the start of the line
    uint32_t lengthUnits = 0;
    uint32_t type = 0;         // index into SemanticTokenSet::typeNames
    uint32_t modifiers = 0;    // bit set over SemanticTokenSet::modifierNames
};

/// All the tokens of one file, sorted by position, with the names the server gave its numbers.
struct SemanticTokenSet {
    std::vector<SemanticToken> tokens;
    std::vector<std::string> typeNames;
    std::vector<std::string> modifierNames;
};

/// Decodes the `data` array of a semanticTokens response: five numbers per token, each position
/// relative to the previous token. Malformed data ends the list early rather than failing.
std::vector<SemanticToken> decodeSemanticTokens(const std::vector<uint32_t>& data);

/// The TextMate scope whose theme colour a token kind should get ("function" → entity.name.function),
/// or an empty string for kinds the TextMate grammar already colours well (keywords, strings,
/// comments) or that would fight with per-name colouring (plain variables, parameters, properties).
std::string scopeForSemanticType(const std::string& typeName, const std::vector<std::string>& modifiers);

/// Adjusts tokens after an edit: tokens on the edited lines go (until the server sends new ones),
/// later ones move with their lines. `firstLine`..`lastLineBefore` are the lines the edit replaced,
/// numbered before the edit, and `lineDelta` lines were added.
void adjustSemanticTokensForEdit(std::vector<SemanticToken>& tokens, size_t firstLine, size_t lastLineBefore, long lineDelta);

}  // namespace gw
