#pragma once

#include <filesystem>
#include <map>
#include <optional>
#include <string>

namespace gw {

/// A VS Code file icon theme: maps file names, extensions, language ids and folder names to SVGs
/// through definition ids. A `light` section overrides the tables for light color themes.
class IconTheme {
public:
    // ---- Constructors
    /// Icon paths in the JSON are relative to `file`.
    static std::optional<IconTheme> load(const std::filesystem::path& file);

    // ---- Lookup
    /// Tries exact name, then the longest matching extension ("test.js" before "js"), then language,
    /// then the default file icon. Empty if none.
    std::filesystem::path iconForFile(const std::string& filename, const std::string& languageId, bool lightTheme) const;
    /// `root` is the project folder itself.
    std::filesystem::path iconForFolder(const std::string& name, bool expanded, bool root, bool lightTheme) const;

    // ---- Getters
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

    // ---- Private functions
    std::filesystem::path pathForDefinition(const std::string& id) const;
    const Tables& tablesFor(bool lightTheme) const;

    // ---- Private variables
    std::map<std::string, std::filesystem::path> definitions_;
    Tables dark_;
    Tables light_;
    bool hasLight_ = false;
    bool hidesExplorerArrows_ = false;
};

}  // namespace gw
