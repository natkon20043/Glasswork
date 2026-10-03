#pragma once

#include <filesystem>
#include <map>
#include <optional>
#include <string>

namespace gw {

/// A VS Code file icon theme: which SVG to show for a file or folder. Themes name icons by
/// definition ids; `iconDefinitions` says which file each id is, and tables map file names,
/// extensions, language ids and folder names to those ids. A `light` section overrides the tables
/// for light colour themes.
class IconTheme {
public:
    /// Reads a theme's JSON file. Icon paths in it are relative to that file.
    static std::optional<IconTheme> load(const std::filesystem::path& file);

    /// The SVG for a file: its exact name, then its extension (the longest that matches: for
    /// "a.test.js", "test.js" before "js"), then its language, then the theme's default file icon.
    /// Empty when the theme has none for it.
    std::filesystem::path iconForFile(const std::string& filename, const std::string& languageId, bool lightTheme) const;
    /// The SVG for a folder by name (when open or closed), or the theme's folder icon; `root` is
    /// the project folder itself.
    std::filesystem::path iconForFolder(const std::string& name, bool expanded, bool root, bool lightTheme) const;

    /// Whether the theme asks for the explorer's disclosure arrows to be hidden.
    bool hidesExplorerArrows() const { return hidesExplorerArrows_; }

private:
    struct Tables {
        std::map<std::string, std::string> fileNames;
        std::map<std::string, std::string> fileExtensions;
        std::map<std::string, std::string> languageIds;
        std::map<std::string, std::string> folderNames;
        std::map<std::string, std::string> folderNamesExpanded;
        std::map<std::string, std::string> rootFolderNames;
        std::map<std::string, std::string> rootFolderNamesExpanded;
        std::string file;
        std::string folder;
        std::string folderExpanded;
        std::string rootFolder;
        std::string rootFolderExpanded;
    };

    std::filesystem::path pathForDefinition(const std::string& id) const;
    const Tables& tablesFor(bool lightTheme) const;

    std::map<std::string, std::filesystem::path> definitions_;
    Tables dark_;
    Tables light_;
    bool hasLight_ = false;
    bool hidesExplorerArrows_ = false;
};

}  // namespace gw
