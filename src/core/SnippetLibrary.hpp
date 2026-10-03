#pragma once

#include <filesystem>
#include <map>
#include <mutex>
#include <string>
#include <string_view>
#include <vector>

namespace gw {

/// One snippet from a VS Code snippet file: typing `prefix` offers `body`.
struct SnippetDefinition {
    std::string name;         // the key in the file ("For Loop")
    std::string prefix;       // what is typed to get it ("for")
    std::string body;         // the snippet text, lines joined with \n, in snippet syntax
    std::string description;
    /// Languages it applies to when the file is not for one language (`"scope": "js,ts"`);
    /// empty means every language.
    std::vector<std::string> scopes;
};

/// Reads a VS Code snippet file (JSON with comments). A snippet with several prefixes becomes
/// one definition per prefix. Entries without a prefix or body are skipped.
std::vector<SnippetDefinition> parseSnippetFile(std::string_view text);

/// Where snippets come from and which ones apply to a language: files contributed by
/// extensions (`contributes.snippets`) and the user's own, read when first needed.
class SnippetLibrary {
public:
    /// A file whose snippets belong to `language`; an empty language means a global file whose
    /// entries say which languages they apply to themselves.
    void addSource(const std::string& language, const std::filesystem::path& file);
    void clear();

    /// Every snippet that applies to the language.
    std::vector<SnippetDefinition> forLanguage(const std::string& language);

private:
    struct Source {
        std::string language;
        std::filesystem::path file;
    };
    std::mutex mutex_;
    std::vector<Source> sources_;
    std::map<std::string, std::vector<SnippetDefinition>> parsed_;  // by file path
};

}  // namespace gw
