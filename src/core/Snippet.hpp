#pragma once

#include <cstddef>
#include <map>
#include <string>
#include <string_view>
#include <vector>

namespace gw {

/// A stretch of a snippet's text, counted in bytes from the start of that text.
struct SnippetSpan {
    size_t offset = 0;
    size_t length = 0;
};

/// A snippet turned into plain text plus the places Tab visits.
struct ParsedSnippet {
    std::string text;
    /// The tab stops in the order Tab visits them ($1, $2, ... and $0 last). Each stop is a
    /// list of spans because the same number can appear more than once; those spans mirror
    /// each other. The last stop is always the final caret position, which is the end of the
    /// text when the snippet has no $0 of its own.
    std::vector<std::vector<SnippetSpan>> stops;

    /// True when the snippet only has its final caret position, so nothing needs to be
    /// selected or jumped to.
    bool hasOnlyFinalStop() const;
};

/// Values for snippet variables such as TM_FILENAME or CURRENT_YEAR (without the dollar sign).
using SnippetVariables = std::map<std::string, std::string>;

/// The variables that depend only on the file and the clock: TM_FILENAME, TM_FILENAME_BASE,
/// TM_DIRECTORY, TM_FILEPATH, RELATIVE_FILEPATH, WORKSPACE_NAME, WORKSPACE_FOLDER, CURRENT_YEAR,
/// CURRENT_YEAR_SHORT, CURRENT_MONTH, CURRENT_MONTH_NAME(_SHORT), CURRENT_DATE,
/// CURRENT_DAY_NAME(_SHORT), CURRENT_HOUR, CURRENT_MINUTE, CURRENT_SECOND, CURRENT_SECONDS_UNIX
/// and UUID. `filePath` may be empty (an unsaved file) and so may `workspaceFolder`. The caller
/// adds the ones that come from the editor (TM_SELECTED_TEXT, CLIPBOARD, TM_CURRENT_LINE…).
SnippetVariables standardSnippetVariables(const std::string& filePath, const std::string& workspaceFolder);

/// Reads snippet syntax as language servers send it: $1, ${1}, ${1:default}, ${1|one,two|},
/// $0, $name, ${name:default} and the escapes \$, \} and \\. `indent` is added after each
/// line break in the text so a multi-line snippet lines up with the line it is inserted on.
/// A variable found in `variables` is replaced by its value; one that is not gives its default
/// (`${name:default}`), or nothing.
ParsedSnippet parseSnippet(std::string_view snippet, std::string_view indent = {}, const SnippetVariables* variables = nullptr);

}  // namespace gw
