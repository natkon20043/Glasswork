#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace gw {

/// A stretch of a line whose real meaning (type, function, macro...) the language server knows.
struct SemanticToken {
    uint32_t line = 0;
    /// UTF-16 units from the line start.
    uint32_t startUnit = 0;
    uint32_t lengthUnits = 0;
    /// Index into SemanticTokenSet::typeNames.
    uint32_t type = 0;
    /// Bit set over SemanticTokenSet::modifierNames.
    uint32_t modifiers = 0;
};

/// Tokens of one file sorted by position, with the names the server gave its numbers.
struct SemanticTokenSet {
    std::vector<SemanticToken> tokens;
    std::vector<std::string> typeNames;
    std::vector<std::string> modifierNames;
};

/// Five numbers per token, each position relative to the previous token. Malformed data ends the list early.
std::vector<SemanticToken> decodeSemanticTokens(const std::vector<uint32_t>& data);

/// "function" -> entity.name.function. Empty for kinds the grammar already colors well or that
/// would fight per-name coloring (variables, parameters, properties).
std::string scopeForSemanticType(const std::string& typeName, const std::vector<std::string>& modifiers);

/// Tokens on edited lines go until the server sends new ones; later ones move with their lines.
/// `firstLine`..`lastLineBefore` are the replaced lines numbered before the edit.
void adjustSemanticTokensForEdit(std::vector<SemanticToken>& tokens, size_t firstLine, size_t lastLineBefore, long lineDelta);

}  // namespace gw
