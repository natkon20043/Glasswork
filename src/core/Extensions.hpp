#pragma once

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
    std::vector<std::string> extensions;  // ".cpp"
    std::vector<std::string> filenames;   // "Makefile"
    std::vector<std::string> aliases;     // "C++"
    std::filesystem::path configuration;  // language-configuration.json
};

struct GrammarInfo {
    std::string language;  // may be empty for grammars only used via includes
    std::string scopeName;
    std::filesystem::path path;
};

struct ThemeInfo {
    std::string label;
    std::string uiTheme;  // "vs-dark", "vs", "hc-black", "hc-light"
    std::filesystem::path path;
    std::string extensionId;

    bool dark() const { return uiTheme == "vs-dark" || uiTheme == "hc-black"; }
};

/// Editing rules from a language's `language-configuration.json`.
struct LanguageConfiguration {
    std::string lineComment;
    std::pair<std::string, std::string> blockComment;
    std::vector<std::pair<std::string, std::string>> autoClosingPairs;
};

/// A VS Code extension unpacked on disk. Only its declarative contributions are used:
/// languages, TextMate grammars, colour themes and language configurations.
struct Extension {
    std::string id;  // "publisher.name"
    std::string displayName;
    std::string description;
    std::string version;
    std::filesystem::path root;
    std::vector<LanguageInfo> languages;
    std::vector<GrammarInfo> grammars;
    std::vector<ThemeInfo> themes;
};

class ExtensionManager {
public:
    explicit ExtensionManager(std::filesystem::path directory);

    /// Re-reads every installed extension.
    void scan();

    const std::filesystem::path& directory() const { return directory_; }
    const std::vector<Extension>& extensions() const { return extensions_; }
    bool isInstalled(const std::string& id) const;

    std::optional<std::string> languageForFile(const std::filesystem::path& path) const;
    /// A readable name for a language id ("cpp" → "C++").
    std::string languageName(const std::string& id) const;
    const GrammarInfo* grammarForLanguage(const std::string& language) const;
    const GrammarInfo* grammarForScope(const std::string& scopeName) const;
    std::vector<ThemeInfo> themes() const;
    LanguageConfiguration configuration(const std::string& language) const;

    struct InstallResult {
        bool ok = false;
        std::string message;
        std::string id;
        std::string version;
    };
    /// Downloads the latest version of `id` ("publisher.name") from Open VSX and unpacks it
    /// into `directory`, replacing older versions. Blocks on the network: call it off the
    /// main thread, then `scan()`.
    static InstallResult installFromOpenVSX(const std::string& id, const std::filesystem::path& directory);
    bool uninstall(const std::string& id);

private:
    std::filesystem::path directory_;
    std::vector<Extension> extensions_;
    std::map<std::string, LanguageInfo> languages_;  // merged across extensions
    std::map<std::string, GrammarInfo> grammarsByScope_;
    std::map<std::string, std::string> scopeByLanguage_;
};

/// Loads grammars on demand by scope name, so grammars can include each other (C++ pulls in
/// the Doxygen grammar, Markdown pulls in every fenced language, and so on).
class GrammarRegistry {
public:
    explicit GrammarRegistry(const ExtensionManager& extensions) : extensions_(extensions) {}

    tm::Grammar* forScope(const std::string& scopeName);
    tm::Grammar* forLanguage(const std::string& language);
    /// Forgets loaded grammars (after installing or removing extensions).
    void clear();

private:
    const ExtensionManager& extensions_;
    std::recursive_mutex mutex_;
    std::map<std::string, std::unique_ptr<tm::Grammar>> loaded_;
    std::set<std::string> failed_;
};

}  // namespace gw
