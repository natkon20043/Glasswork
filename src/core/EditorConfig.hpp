#pragma once

#include <filesystem>
#include <optional>
#include <string>
#include <string_view>

namespace gw {

/// What .editorconfig says about one file; unmentioned options stay unset.
struct EditorConfigResult {
    // ---- Getters
    std::optional<int> columnsPerIndent() const {
        if (indentSize) {
            return indentSize;
        }
        return tabWidth;
    }

    // ---- Variables
    std::optional<bool> useTabs;
    std::optional<int> indentSize;
    std::optional<int> tabWidth;
    /// "lf", "crlf" or "cr".
    std::optional<std::string> endOfLine;
    std::optional<bool> trimTrailingWhitespace;
    std::optional<bool> insertFinalNewline;
};

// ---- Reading

/// Walks up from the file's folder (stopping at `root = true`); closer files and later sections win.
EditorConfigResult editorConfigFor(const std::filesystem::path& file);

/// Applies one .editorconfig's text located in `configFolder`. Returns true if it declares itself root.
bool applyEditorConfigText(std::string_view text, const std::filesystem::path& configFolder,
                           const std::filesystem::path& file, EditorConfigResult& result);

/// `relativePath` uses forward slashes; patterns like "*.{js,py}" or "lib/**.js".
bool editorConfigGlobMatches(const std::string& pattern, const std::string& relativePath);

}  // namespace gw
