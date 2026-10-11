#include "SnippetLibrary.hpp"

#include "Jsonc.hpp"
#include "JsonText.hpp"

#include <fstream>
#include <sstream>

namespace gw {

namespace {

using json = nlohmann::json;

std::vector<std::string> splitScopes(const std::string& text) {
    std::vector<std::string> scopes;
    std::string current;
    for (char character : text) {
        if (character == ',') {
            if (!current.empty()) scopes.push_back(current);
            current.clear();
        } else if (character != ' ') {
            current += character;
        }
    }
    if (!current.empty()) scopes.push_back(current);
    return scopes;
}

std::string joinedBody(const json& body) {
    if (body.is_string()) {
        return body.get<std::string>();
    }
    std::string text;
    if (body.is_array()) {
        bool first = true;
        for (const json& line : body) {
            if (!line.is_string()) continue;
            if (!first) text += '\n';
            text += line.get<std::string>();
            first = false;
        }
    }
    return text;
}

}  // namespace

std::vector<SnippetDefinition> parseSnippetFile(std::string_view text) {
    std::vector<SnippetDefinition> definitions;
    json file = parseJsonc(std::string(text));
    if (!file.is_object()) {
        return definitions;
    }
    for (const auto& [name, entry] : file.items()) {
        if (!entry.is_object() || !entry.contains("prefix") || !entry.contains("body")) {
            continue;
        }
        std::string body = joinedBody(entry["body"]);
        if (body.empty()) {
            continue;
        }
        std::vector<std::string> prefixes;
        if (entry["prefix"].is_string()) {
            prefixes.push_back(entry["prefix"].get<std::string>());
        } else if (entry["prefix"].is_array()) {
            for (const json& prefix : entry["prefix"]) {
                if (prefix.is_string()) prefixes.push_back(prefix.get<std::string>());
            }
        }
        std::string description = stringOr(entry, "description", name);
        std::vector<std::string> scopes;
        if (entry.contains("scope") && entry["scope"].is_string()) {
            scopes = splitScopes(entry["scope"].get<std::string>());
        }
        for (const std::string& prefix : prefixes) {
            if (prefix.empty()) continue;
            SnippetDefinition definition;
            definition.name = name;
            definition.prefix = prefix;
            definition.body = body;
            definition.description = description;
            definition.scopes = scopes;
            definitions.push_back(std::move(definition));
        }
    }
    return definitions;
}

void SnippetLibrary::addSource(const std::string& language, const std::filesystem::path& file) {
    std::lock_guard<std::mutex> lock(mutex_);
    sources_.push_back(Source{language, file});
}

void SnippetLibrary::clear() {
    std::lock_guard<std::mutex> lock(mutex_);
    sources_.clear();
    parsed_.clear();
}

std::vector<SnippetDefinition> SnippetLibrary::forLanguage(const std::string& language) {
    std::lock_guard<std::mutex> lock(mutex_);
    std::vector<SnippetDefinition> result;
    for (const Source& source : sources_) {
        bool isForThisLanguage = !source.language.empty() && source.language == language;
        bool isGlobal = source.language.empty();
        if (!isForThisLanguage && !isGlobal) {
            continue;
        }
        std::string key = source.file.string();
        auto found = parsed_.find(key);
        if (found == parsed_.end()) {
            std::ifstream input(source.file);
            std::stringstream text;
            text << input.rdbuf();
            found = parsed_.emplace(key, parseSnippetFile(text.str())).first;
        }
        for (const SnippetDefinition& definition : found->second) {
            bool applies = isForThisLanguage || definition.scopes.empty();
            for (const std::string& scope : definition.scopes) {
                if (scope == language) applies = true;
            }
            if (applies) {
                result.push_back(definition);
            }
        }
    }
    return result;
}

}  // namespace gw
