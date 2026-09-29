#include "Extensions.hpp"

#include "Jsonc.hpp"

#include <curl/curl.h>
#include <nlohmann/json.hpp>

#include <algorithm>
#include <fstream>
#include <spawn.h>
#include <sstream>
#include <sys/wait.h>

extern char** environ;

namespace gw {

using nlohmann::json;
namespace fs = std::filesystem;

namespace {

std::optional<std::string> readFile(const fs::path& path) {
    std::ifstream file(path, std::ios::binary);
    if (!file) return std::nullopt;
    std::ostringstream contents;
    contents << file.rdbuf();
    return contents.str();
}

json readJson(const fs::path& path) {
    auto text = readFile(path);
    if (!text) return json();
    return parseJsonc(*text);
}

std::string lowercase(std::string text) {
    std::transform(text.begin(), text.end(), text.begin(), [](unsigned char c) { return std::tolower(c); });
    return text;
}

/// Labels like "%displayName%" are looked up in the extension's package.nls.json.
std::string localize(const json& value, const json& strings) {
    if (!value.is_string()) return "";
    std::string text = value.get<std::string>();
    if (text.size() > 2 && text.front() == '%' && text.back() == '%' && strings.is_object()) {
        auto found = strings.find(text.substr(1, text.size() - 2));
        if (found != strings.end()) {
            if (found->is_string()) return found->get<std::string>();
            if (found->is_object() && found->contains("message")) return (*found)["message"].get<std::string>();
        }
    }
    return text;
}

std::vector<std::string> stringList(const json& value) {
    std::vector<std::string> list;
    if (!value.is_array()) return list;
    for (const auto& item : value) {
        if (item.is_string()) list.push_back(item.get<std::string>());
    }
    return list;
}

std::optional<Extension> readExtension(const fs::path& root) {
    json manifest = readJson(root / "package.json");
    if (!manifest.is_object()) return std::nullopt;
    json strings = readJson(root / "package.nls.json");

    Extension extension;
    extension.root = root;
    extension.id = manifest.value("publisher", "unknown") + "." + manifest.value("name", root.filename().string());
    extension.version = manifest.value("version", "");
    extension.displayName = manifest.contains("displayName") ? localize(manifest["displayName"], strings) : extension.id;
    extension.description = manifest.contains("description") ? localize(manifest["description"], strings) : "";

    const json contributes = manifest.value("contributes", json::object());
    for (const auto& language : contributes.value("languages", json::array())) {
        if (!language.is_object() || !language.contains("id")) continue;
        LanguageInfo info;
        info.id = language["id"].get<std::string>();
        info.extensions = stringList(language.value("extensions", json::array()));
        info.filenames = stringList(language.value("filenames", json::array()));
        info.aliases = stringList(language.value("aliases", json::array()));
        if (language.contains("configuration") && language["configuration"].is_string()) {
            info.configuration = root / language["configuration"].get<std::string>();
        }
        extension.languages.push_back(std::move(info));
    }
    for (const auto& grammar : contributes.value("grammars", json::array())) {
        if (!grammar.is_object() || !grammar.contains("scopeName") || !grammar.contains("path")) continue;
        GrammarInfo info;
        info.language = grammar.value("language", "");
        info.scopeName = grammar["scopeName"].get<std::string>();
        info.path = root / grammar["path"].get<std::string>();
        extension.grammars.push_back(std::move(info));
    }
    for (const auto& theme : contributes.value("themes", json::array())) {
        if (!theme.is_object() || !theme.contains("path")) continue;
        ThemeInfo info;
        info.label = theme.contains("label") ? localize(theme["label"], strings) : theme.value("id", "Theme");
        info.uiTheme = theme.value("uiTheme", "vs-dark");
        info.path = root / theme["path"].get<std::string>();
        info.extensionId = extension.id;
        extension.themes.push_back(std::move(info));
    }
    return extension;
}

// MARK: Networking

size_t appendToString(char* data, size_t size, size_t count, void* target) {
    static_cast<std::string*>(target)->append(data, size * count);
    return size * count;
}

size_t appendToFile(char* data, size_t size, size_t count, void* target) {
    static_cast<std::ofstream*>(target)->write(data, static_cast<std::streamsize>(size * count));
    return size * count;
}

/// GETs `url`; writes to `file` if given, else returns the body. Empty optional on failure.
std::optional<std::string> httpGet(const std::string& url, std::ofstream* file = nullptr, std::string* error = nullptr) {
    static std::once_flag once;
    std::call_once(once, [] { curl_global_init(CURL_GLOBAL_DEFAULT); });
    CURL* curl = curl_easy_init();
    if (!curl) return std::nullopt;
    std::string body;
    curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(curl, CURLOPT_USERAGENT, "Glasswork/0.1 (+https://open-vsx.org)");
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 15L);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 180L);
    if (file) {
        curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, appendToFile);
        curl_easy_setopt(curl, CURLOPT_WRITEDATA, file);
    } else {
        curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, appendToString);
        curl_easy_setopt(curl, CURLOPT_WRITEDATA, &body);
    }
    CURLcode result = curl_easy_perform(curl);
    long status = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);
    curl_easy_cleanup(curl);
    if (result != CURLE_OK) {
        if (error) *error = curl_easy_strerror(result);
        return std::nullopt;
    }
    if (status < 200 || status >= 300) {
        if (error) *error = "HTTP " + std::to_string(status);
        return std::nullopt;
    }
    return body;
}

/// Unzips with macOS's own `ditto` (a .vsix is a zip archive).
bool unzip(const fs::path& archive, const fs::path& destination) {
    std::string archivePath = archive.string(), destinationPath = destination.string();
    const char* arguments[] = {"/usr/bin/ditto", "-x", "-k", archivePath.c_str(), destinationPath.c_str(), nullptr};
    pid_t process;
    if (posix_spawn(&process, "/usr/bin/ditto", nullptr, nullptr, const_cast<char* const*>(arguments), environ) != 0) {
        return false;
    }
    int status = 0;
    waitpid(process, &status, 0);
    return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

}  // namespace

ExtensionManager::ExtensionManager(fs::path directory) : directory_(std::move(directory)) {
    std::error_code ignored;
    fs::create_directories(directory_, ignored);
}

void ExtensionManager::scan() {
    extensions_.clear();
    languages_.clear();
    grammarsByScope_.clear();
    scopeByLanguage_.clear();

    std::error_code code;
    std::vector<fs::path> roots;
    for (const auto& entry : fs::directory_iterator(directory_, code)) {
        if (entry.is_directory() && fs::exists(entry.path() / "package.json")) roots.push_back(entry.path());
    }
    std::sort(roots.begin(), roots.end());
    for (const auto& root : roots) {
        auto extension = readExtension(root);
        if (!extension) continue;
        for (const auto& language : extension->languages) {
            // Several extensions may describe one language; merge what they add.
            LanguageInfo& merged = languages_[language.id];
            merged.id = language.id;
            merged.extensions.insert(merged.extensions.end(), language.extensions.begin(), language.extensions.end());
            merged.filenames.insert(merged.filenames.end(), language.filenames.begin(), language.filenames.end());
            if (merged.aliases.empty()) merged.aliases = language.aliases;
            if (merged.configuration.empty()) merged.configuration = language.configuration;
        }
        for (const auto& grammar : extension->grammars) {
            grammarsByScope_[grammar.scopeName] = grammar;
            if (!grammar.language.empty()) scopeByLanguage_[grammar.language] = grammar.scopeName;
        }
        extensions_.push_back(std::move(*extension));
    }
}

bool ExtensionManager::isInstalled(const std::string& id) const {
    return std::any_of(extensions_.begin(), extensions_.end(), [&](const Extension& e) { return e.id == id; });
}

std::optional<std::string> ExtensionManager::languageForFile(const fs::path& path) const {
    std::string filename = path.filename().string();
    std::string lower = lowercase(filename);
    for (const auto& [id, language] : languages_) {
        for (const auto& name : language.filenames) {
            if (name == filename) return id;
        }
    }
    // Longest matching extension wins (".d.ts" over ".ts").
    std::optional<std::string> best;
    size_t bestLength = 0;
    for (const auto& [id, language] : languages_) {
        for (const auto& extension : language.extensions) {
            std::string suffix = lowercase(extension);
            if (suffix.size() > bestLength && lower.size() >= suffix.size() &&
                lower.compare(lower.size() - suffix.size(), suffix.size(), suffix) == 0) {
                best = id;
                bestLength = suffix.size();
            }
        }
    }
    return best;
}

std::string ExtensionManager::languageName(const std::string& id) const {
    auto found = languages_.find(id);
    if (found != languages_.end() && !found->second.aliases.empty()) return found->second.aliases.front();
    return id.empty() ? "Plain Text" : id;
}

const GrammarInfo* ExtensionManager::grammarForLanguage(const std::string& language) const {
    auto scope = scopeByLanguage_.find(language);
    return scope == scopeByLanguage_.end() ? nullptr : grammarForScope(scope->second);
}

const GrammarInfo* ExtensionManager::grammarForScope(const std::string& scopeName) const {
    auto found = grammarsByScope_.find(scopeName);
    return found == grammarsByScope_.end() ? nullptr : &found->second;
}

std::vector<ThemeInfo> ExtensionManager::themes() const {
    std::vector<ThemeInfo> themes;
    for (const auto& extension : extensions_) themes.insert(themes.end(), extension.themes.begin(), extension.themes.end());
    return themes;
}

LanguageConfiguration ExtensionManager::configuration(const std::string& language) const {
    LanguageConfiguration configuration;
    auto found = languages_.find(language);
    if (found == languages_.end() || found->second.configuration.empty()) return configuration;
    json document = readJson(found->second.configuration);
    if (!document.is_object()) return configuration;

    if (document.contains("comments") && document["comments"].is_object()) {
        const json& comments = document["comments"];
        if (comments.contains("lineComment") && comments["lineComment"].is_string()) {
            configuration.lineComment = comments["lineComment"].get<std::string>();
        }
        if (comments.contains("blockComment") && comments["blockComment"].is_array() && comments["blockComment"].size() == 2) {
            configuration.blockComment = {comments["blockComment"][0].get<std::string>(),
                                          comments["blockComment"][1].get<std::string>()};
        }
    }
    for (const auto& pair : document.value("autoClosingPairs", json::array())) {
        if (pair.is_array() && pair.size() == 2 && pair[0].is_string() && pair[1].is_string()) {
            configuration.autoClosingPairs.emplace_back(pair[0].get<std::string>(), pair[1].get<std::string>());
        } else if (pair.is_object() && pair.contains("open") && pair.contains("close")) {
            configuration.autoClosingPairs.emplace_back(pair["open"].get<std::string>(), pair["close"].get<std::string>());
        }
    }
    return configuration;
}

ExtensionManager::InstallResult ExtensionManager::installFromOpenVSX(const std::string& id, const fs::path& directory) {
    InstallResult result;
    result.id = id;
    auto dot = id.find('.');
    if (dot == std::string::npos || dot == 0 || dot + 1 == id.size()) {
        result.message = "Extension IDs look like publisher.name (for example vscode.cpp).";
        return result;
    }
    std::string publisher = id.substr(0, dot), name = id.substr(dot + 1);

    std::string error;
    auto metadata = httpGet("https://open-vsx.org/api/" + publisher + "/" + name + "/latest", nullptr, &error);
    if (!metadata) {
        result.message = error == "HTTP 404" ? id + " isn't on Open VSX." : "Couldn't reach Open VSX (" + error + ").";
        return result;
    }
    json info = json::parse(*metadata, nullptr, false);
    if (!info.is_object() || !info.contains("files") || !info["files"].contains("download")) {
        result.message = "Open VSX didn't return a download for " + id + ".";
        return result;
    }
    result.version = info.value("version", "");
    std::string url = info["files"]["download"].get<std::string>();

    fs::path work = fs::temp_directory_path() / ("glasswork-install-" + id);
    std::error_code code;
    fs::remove_all(work, code);
    fs::create_directories(work, code);
    fs::path archive = work / "extension.vsix";
    {
        std::ofstream file(archive, std::ios::binary);
        if (!httpGet(url, &file, &error)) {
            result.message = "Download failed (" + error + ").";
            return result;
        }
    }
    fs::path unpacked = work / "unpacked";
    if (!unzip(archive, unpacked) || !fs::exists(unpacked / "extension" / "package.json")) {
        result.message = "That download isn't a valid VS Code extension.";
        return result;
    }

    // Replace any installed version of the same extension.
    for (const auto& entry : fs::directory_iterator(directory, code)) {
        std::string folder = entry.path().filename().string();
        if (folder.rfind(id + "-", 0) == 0) fs::remove_all(entry.path(), code);
    }
    fs::path destination = directory / (id + "-" + result.version);
    fs::rename(unpacked / "extension", destination, code);
    if (code) {
        result.message = "Couldn't install: " + code.message();
        return result;
    }
    fs::remove_all(work, code);
    result.ok = true;
    result.message = "Installed " + id + " " + result.version + ".";
    return result;
}

bool ExtensionManager::uninstall(const std::string& id) {
    bool removed = false;
    for (const auto& extension : extensions_) {
        if (extension.id != id) continue;
        std::error_code code;
        fs::remove_all(extension.root, code);
        removed = !code;
    }
    scan();
    return removed;
}

// MARK: GrammarRegistry

tm::Grammar* GrammarRegistry::forScope(const std::string& scopeName) {
    std::lock_guard lock(mutex_);
    if (auto found = loaded_.find(scopeName); found != loaded_.end()) return found->second.get();
    if (failed_.count(scopeName)) return nullptr;
    const GrammarInfo* info = extensions_.grammarForScope(scopeName);
    if (!info) {
        failed_.insert(scopeName);
        return nullptr;
    }
    auto grammar = tm::Grammar::load(info->path, [this](const std::string& scope) { return forScope(scope); });
    if (!grammar) {
        failed_.insert(scopeName);
        return nullptr;
    }
    return loaded_.emplace(scopeName, std::move(grammar)).first->second.get();
}

tm::Grammar* GrammarRegistry::forLanguage(const std::string& language) {
    const GrammarInfo* info = extensions_.grammarForLanguage(language);
    return info ? forScope(info->scopeName) : nullptr;
}

void GrammarRegistry::clear() {
    std::lock_guard lock(mutex_);
    loaded_.clear();
    failed_.clear();
}

}  // namespace gw
