#include "IconTheme.hpp"

#include "Jsonc.hpp"
#include "JsonText.hpp"

#include <algorithm>
#include <fstream>
#include <sstream>

namespace gw {

namespace {

using json = nlohmann::json;

std::string lowerCase(std::string text) {
    for (char& character : text) {
        character = static_cast<char>(std::tolower(static_cast<unsigned char>(character)));
    }
    return text;
}

std::map<std::string, std::string> readTable(const json& object, const char* name) {
    std::map<std::string, std::string> table;
    if (object.contains(name) && object[name].is_object()) {
        for (const auto& [key, value] : object[name].items()) {
            if (value.is_string()) {
                table[key] = value.get<std::string>();
            }
        }
    }
    return table;
}

}  // namespace

std::optional<IconTheme> IconTheme::load(const std::filesystem::path& file) {
    std::ifstream input(file);
    if (!input) {
        return std::nullopt;
    }
    std::stringstream text;
    text << input.rdbuf();
    json theme = parseJsonc(text.str());
    if (!theme.is_object() || !theme.contains("iconDefinitions") || !theme["iconDefinitions"].is_object()) {
        return std::nullopt;
    }

    IconTheme result;
    std::filesystem::path base = file.parent_path();
    for (const auto& [id, definition] : theme["iconDefinitions"].items()) {
        if (definition.is_object() && definition.contains("iconPath") && definition["iconPath"].is_string()) {
            // Only SVG and image files can be drawn; icon fonts are not supported.
            result.definitions_[id] = (base / definition["iconPath"].get<std::string>()).lexically_normal();
        }
    }

    auto fillTables = [&](const json& source, Tables& tables) {
        tables.fileNames = readTable(source, "fileNames");
        tables.fileExtensions = readTable(source, "fileExtensions");
        tables.languageIds = readTable(source, "languageIds");
        tables.folderNames = readTable(source, "folderNames");
        tables.folderNamesExpanded = readTable(source, "folderNamesExpanded");
        tables.rootFolderNames = readTable(source, "rootFolderNames");
        tables.rootFolderNamesExpanded = readTable(source, "rootFolderNamesExpanded");
        tables.file = stringOr(source, "file");
        tables.folder = stringOr(source, "folder");
        tables.folderExpanded = stringOr(source, "folderExpanded");
        tables.rootFolder = stringOr(source, "rootFolder");
        tables.rootFolderExpanded = stringOr(source, "rootFolderExpanded");
    };
    fillTables(theme, result.dark_);
    if (theme.contains("light") && theme["light"].is_object()) {
        result.hasLight_ = true;
        fillTables(theme["light"], result.light_);
    }
    if (theme.contains("hidesExplorerArrows") && theme["hidesExplorerArrows"].is_boolean()) {
        result.hidesExplorerArrows_ = theme["hidesExplorerArrows"].get<bool>();
    }
    return result;
}

std::filesystem::path IconTheme::pathForDefinition(const std::string& id) const {
    auto found = definitions_.find(id);
    if (found == definitions_.end()) {
        return std::filesystem::path();
    }
    return found->second;
}

const IconTheme::Tables& IconTheme::tablesFor(bool lightTheme) const {
    return lightTheme && hasLight_ ? light_ : dark_;
}

std::filesystem::path IconTheme::iconForFile(const std::string& filename, const std::string& languageId, bool lightTheme) const {
    const Tables& light = tablesFor(lightTheme);
    std::string name = lowerCase(filename);

    // The light section only adds to the dark one: a name it doesn't mention falls back to it.
    auto lookup = [&](const std::map<std::string, std::string> Tables::*table, const std::string& key) -> std::filesystem::path {
        if (lightTheme && hasLight_) {
            auto found = (light_.*table).find(key);
            if (found != (light_.*table).end()) {
                std::filesystem::path path = pathForDefinition(found->second);
                if (!path.empty()) {
                    return path;
                }
            }
        }
        auto found = (dark_.*table).find(key);
        if (found == (dark_.*table).end()) {
            return std::filesystem::path();
        }
        return pathForDefinition(found->second);
    };

    if (std::filesystem::path path = lookup(&Tables::fileNames, name); !path.empty()) {
        return path;
    }
    // Extensions, the longest first: "a.test.js" tries "test.js" and then "js".
    for (size_t dot = name.find('.'); dot != std::string::npos; dot = name.find('.', dot + 1)) {
        std::string extension = name.substr(dot + 1);
        if (extension.empty()) {
            continue;
        }
        if (std::filesystem::path path = lookup(&Tables::fileExtensions, extension); !path.empty()) {
            return path;
        }
    }
    if (!languageId.empty()) {
        if (std::filesystem::path path = lookup(&Tables::languageIds, languageId); !path.empty()) {
            return path;
        }
    }
    std::string fallback = light.file;
    if (fallback.empty()) {
        fallback = dark_.file;
    }
    return pathForDefinition(fallback);
}

std::filesystem::path IconTheme::iconForFolder(const std::string& name, bool expanded, bool root, bool lightTheme) const {
    std::string key = lowerCase(name);
    auto lookup = [&](const std::map<std::string, std::string> Tables::*table) -> std::filesystem::path {
        if (lightTheme && hasLight_) {
            auto found = (light_.*table).find(key);
            if (found != (light_.*table).end()) {
                std::filesystem::path path = pathForDefinition(found->second);
                if (!path.empty()) {
                    return path;
                }
            }
        }
        auto found = (dark_.*table).find(key);
        if (found == (dark_.*table).end()) {
            return std::filesystem::path();
        }
        return pathForDefinition(found->second);
    };

    // Tables of icons for particular folder names, open or closed.
    auto rootNames = &Tables::rootFolderNames;
    auto names = &Tables::folderNames;
    auto rootIcon = &Tables::rootFolder;
    auto icon = &Tables::folder;
    if (expanded) {
        rootNames = &Tables::rootFolderNamesExpanded;
        names = &Tables::folderNamesExpanded;
        rootIcon = &Tables::rootFolderExpanded;
        icon = &Tables::folderExpanded;
    }

    std::filesystem::path byName;
    if (root) {
        byName = lookup(rootNames);
    }
    if (byName.empty()) {
        byName = lookup(names);
    }
    if (!byName.empty()) {
        return byName;
    }
    const Tables& chosen = tablesFor(lightTheme);
    auto pick = [&](const std::string Tables::*field) {
        const std::string& fromLight = chosen.*field;
        if (!fromLight.empty()) {
            return fromLight;
        }
        return dark_.*field;
    };
    std::string id;
    if (root) {
        id = pick(rootIcon);
    }
    if (id.empty()) {
        id = pick(icon);
    }
    if (id.empty()) {
        id = pick(&Tables::folder);  // a theme with no open-folder icon uses the closed one
    }
    return pathForDefinition(id);
}

}  // namespace gw
