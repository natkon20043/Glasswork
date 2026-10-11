#pragma once

#include <cstddef>
#include <map>
#include <string>
#include <string_view>
#include <vector>

namespace gw {

/// Bytes from the start of the snippet text.
struct SnippetSpan {
    size_t offset = 0;
    size_t length = 0;
};

/// Snippet text plus the places Tab visits.
struct ParsedSnippet {
    bool hasOnlyFinalStop() const;

    std::string text;
    /// In Tab order ($1, $2... then $0). A stop has several spans when the number repeats; they mirror
    /// each other. The last stop is the final caret (the text end if there is no $0).
    std::vector<std::vector<SnippetSpan>> stops;
};

/// Variable name without the dollar sign (TM_FILENAME, CURRENT_YEAR) -> its value.
using SnippetVariables = std::map<std::string, std::string>;

/// File and clock variables only (TM_FILENAME, TM_DIRECTORY, WORKSPACE_NAME, CURRENT_*, UUID...).
/// `filePath` and `workspaceFolder` may be empty. The caller adds editor ones (TM_SELECTED_TEXT, CLIPBOARD...).
SnippetVariables standardSnippetVariables(const std::string& filePath, const std::string& workspaceFolder);

/// Reads $1, ${1}, ${1:default}, ${1|one,two|}, $0, $name, ${name:default} and the escapes \$, \} \\.
/// `indent` follows each line break so multi-line snippets line up. Unknown variables give their default or nothing.
ParsedSnippet parseSnippet(std::string_view snippet, std::string_view indent = {}, const SnippetVariables* variables = nullptr);

}  // namespace gw
