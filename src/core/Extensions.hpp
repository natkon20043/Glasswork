#pragma once

#include "IconTheme.hpp"
#include "SnippetLibrary.hpp"
#include "textmate/Grammar.hpp"

#include <filesystem>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <set>
#include <string>
#include <vector>

namespace gw {

struct LanguageInfo {
    std::string id;
    /// ".cpp"
    std::vector<std::string> extensions;
    /// "Makefile"
    std::vector<std::string> filenames;
    /// "C++"
    std::vector<std::string> aliases;
    /// language-configuration.json
    std::filesystem::path configuration;
};

struct GrammarInfo {
    /// Empty for grammars only reached through includes.
    std::string language;
    std::string scopeName;
    std::filesystem::path path;
};

struct ThemeInfo {
    std::string label;
    /// "vs-dark", "vs", "hc-black" or "hc-light".
    std::string uiTheme;
    std::filesystem::path path;
    std::string extensionId;

    bool dark() const { return uiTheme == "vs-dark" || uiTheme == "hc-black"; }
};

struct IconThemeInfo {
    std::string id;
    std::string label;
    std::filesystem::path path;
    std::string extensionId;
};

/// Editing rules from `language-configuration.json`.
struct LanguageConfiguration {
    std::string lineComment;
    std::pair<std::string, std::string> blockComment;
    std::vector<std::pair<std::string, std::string>> autoClosingPairs;
};

/// A VS Code extension unpacked on disk, with its declarative contributions.
struct Extension {
    /// "publisher.name"
    std::string id;
    std::string displayName;
    std::string description;
    std::string version;
    std::filesystem::path root;
    /// package.json with "%key%" strings filled from package.nls.json, as JSON text.
    std::string manifestJson;
    /// Has a `main` entry, not only declarative contributions.
    bool hasCode = false;
    std::vector<LanguageInfo> languages;
    std::vector<GrammarInfo> grammars;
    std::vector<ThemeInfo> themes;
    std::vector<IconThemeInfo> iconThemes;
    /// `contributes.keybindings` as a JSON array, empty if none.
    std::string keybindingsJson;
    /// Language id and snippet file.
    std::vector<std::pair<std::string, std::filesystem::path>> snippets;
};

class ExtensionManager {
public:
    struct InstallResult {
        bool ok = false;
        std::string message;
        std::string id;
        std::string version;
    };

    struct MarketplaceEntry {
        /// "publisher.name"
        std::string id;
        std::string displayName;
        std::string description;
        std::string version;
        std::string publisher;
        long downloads = 0;
        /// 0 when nobody has rated it.
        double rating = 0;
        std::string iconURL;
    };

    // ---- Constructors
    explicit ExtensionManager(std::filesystem::path directory);

    // ---- Scanning
    /// Re-reads every installed extension. Disabled ones are listed but contribute nothing.
    void scan();

    // ---- Installing (blocks on the network: call off the main thread, then scan())
    /// Downloads the latest `id` from Open VSX into `directory`, replacing older versions.
    static InstallResult installFromOpenVSX(const std::string& id, const std::filesystem::path& directory);
    bool uninstall(const std::string& id);

    // ---- Marketplace search (blocks on the network)
    /// Most downloaded first for an empty query. On failure the list is empty and `error` says why.
    static std::vector<MarketplaceEntry> searchOpenVSX(const std::string& query, size_t limit, std::string* error = nullptr);
    /// Split out so it can be tested without the network.
    static std::vector<MarketplaceEntry> parseSearchResults(const std::string& json);

    // ---- Setters
    void setDisabled(std::set<std::string> ids) { disabledIds_ = std::move(ids); }
    /// Folder of `<language>.json` and `*.code-snippets` files. Set before scan().
    void setUserSnippetsDirectory(std::filesystem::path directory) { userSnippets_ = std::move(directory); }

    // ---- Getters
    const std::filesystem::path& directory() const { return directory_; }
    const std::vector<Extension>& extensions() const { return extensions_; }
    const std::vector<Extension>& disabledExtensions() const { return disabled_; }
    bool isInstalled(const std::string& id) const;
    SnippetLibrary& snippets() { return snippetLibrary_; }
    std::vector<ThemeInfo> themes() const;
    std::vector<IconThemeInfo> iconThemes() const;
    /// All extensions' `contributes.keybindings` joined into one JSON array.
    std::string contributedKeybindingsJson() const;

    // ---- Language lookup
    std::optional<std::string> languageForFile(const std::filesystem::path& path) const;
    /// "cpp" -> "C++"
    std::string languageName(const std::string& id) const;
    const GrammarInfo* grammarForLanguage(const std::string& language) const;
    const GrammarInfo* grammarForScope(const std::string& scopeName) const;
    LanguageConfiguration configuration(const std::string& language) const;

private:
    /// The language for the file's own name, without trying the ".in" template rule.
    std::optional<std::string> languageForExactFile(const std::filesystem::path& path) const;

    // ---- Private variables
    std::filesystem::path directory_;
    std::filesystem::path userSnippets_;
    SnippetLibrary snippetLibrary_;
    std::vector<Extension> extensions_;
    std::vector<Extension> disabled_;
    std::set<std::string> disabledIds_;
    // Merged across extensions.
    std::map<std::string, LanguageInfo> languages_;
    std::map<std::string, GrammarInfo> grammarsByScope_;
    std::map<std::string, std::string> scopeByLanguage_;
};

/// Loads grammars on demand by scope name so grammars can include each other.
class GrammarRegistry {
public:
    // ---- Constructors
    explicit GrammarRegistry(const ExtensionManager& extensions) : extensions_(extensions) {}

    // ---- Lookup
    tm::Grammar* forScope(const std::string& scopeName);
    tm::Grammar* forLanguage(const std::string& language);

    // ---- Maintenance
    /// Call after installing or removing extensions.
    void clear();

private:
    // ---- Private variables
    const ExtensionManager& extensions_;
    std::recursive_mutex mutex_;
    std::map<std::string, std::unique_ptr<tm::Grammar>> loaded_;
    std::set<std::string> failed_;
};

}  // namespace gw
