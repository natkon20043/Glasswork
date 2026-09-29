#pragma once

#include <filesystem>
#include <optional>
#include <string>
#include <string_view>

namespace gw {

/// What .editorconfig files say about one source file. Anything they don't mention stays unset.
struct EditorConfigResult {
    std::optional<bool> useTabs;        // indent_style = tab / space
    std::optional<int> indentSize;      // indent_size (a number)
    std::optional<int> tabWidth;        // tab_width
    std::optional<std::string> endOfLine;  // "lf", "crlf" or "cr"
    std::optional<bool> trimTrailingWhitespace;
    std::optional<bool> insertFinalNewline;

    /// Width a tab is drawn at, and the size of one indent level: the columns the editor should use.
    std::optional<int> columnsPerIndent() const {
        if (indentSize) return indentSize;
        return tabWidth;
    }
};

/// Looks for .editorconfig files from the file's folder upwards (stopping at one that says
/// `root = true`) and combines the sections whose pattern matches the file. Closer files and
/// later sections win.
EditorConfigResult editorConfigFor(const std::filesystem::path& file);

/// The same, from the text of one .editorconfig file that sits in `configFolder`; for tests and
/// for editorConfigFor. Returns true if the file marks itself as the root.
bool applyEditorConfigText(std::string_view text, const std::filesystem::path& configFolder,
                           const std::filesystem::path& file, EditorConfigResult& result);

/// True if `path` (relative to the .editorconfig, with forward slashes) matches an
/// .editorconfig section pattern such as "*.{js,py}" or "lib/**.js".
bool editorConfigGlobMatches(const std::string& pattern, const std::string& relativePath);

}  // namespace gw
