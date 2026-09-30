#pragma once

#include <cstddef>
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

/// Reads snippet syntax as language servers send it: $1, ${1}, ${1:default}, ${1|one,two|},
/// $0, $name, ${name:default} and the escapes \$, \} and \\. `indent` is added after each
/// line break in the text so a multi-line snippet lines up with the line it is inserted on.
/// Variables such as $TM_FILENAME are not known here and give their default, or nothing.
ParsedSnippet parseSnippet(std::string_view snippet, std::string_view indent = {});

}  // namespace gw
