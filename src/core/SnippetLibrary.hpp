#pragma once

#include <filesystem>
#include <map>
#include <mutex>
#include <string>
#include <string_view>
#include <vector>

namespace gw {

/// Typing `prefix` offers `body`.
struct SnippetDefinition {
    /// The key in the file ("For Loop").
    std::string name;
    /// "for"
    std::string prefix;
    /// Snippet syntax, lines joined with \n.
    std::string body;
    std::string description;
    /// Languages from `"scope": "js,ts"` in a global file; empty means every language.
    std::vector<std::string> scopes;
};

/// One definition per prefix. Entries without a prefix or body are skipped.
std::vector<SnippetDefinition> parseSnippetFile(std::string_view text);

/// Snippet files from extensions and the user, read when first needed.
class SnippetLibrary {
public:
    // ---- Sources
    /// An empty language means a global file whose entries name their own languages.
    void addSource(const std::string& language, const std::filesystem::path& file);
    void clear();

    // ---- Lookup
    std::vector<SnippetDefinition> forLanguage(const std::string& language);

private:
    struct Source {
        std::string language;
        std::filesystem::path file;
    };

    // ---- Private variables
    std::mutex mutex_;
    std::vector<Source> sources_;
    // By file path.
    std::map<std::string, std::vector<SnippetDefinition>> parsed_;
};

}  // namespace gw
