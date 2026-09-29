// End-to-end check against real VS Code extensions: installs the C++ grammar and default
// themes from Open VSX into a scratch folder, then highlights some C++.
//
//   glasswork_smoke [extensions-folder]

#include "Extensions.hpp"
#include "Theme.hpp"
#include "textmate/Tokenizer.hpp"

#include <chrono>
#include <cstdio>
#include <filesystem>
#include <string>
#include <vector>

int main(int argc, char** argv) {
    namespace fs = std::filesystem;
    fs::path folder = argc > 1 ? fs::path(argv[1]) : fs::temp_directory_path() / "glasswork-smoke-extensions";
    fs::create_directories(folder);

    for (const char* id : {"vscode.cpp", "vscode.theme-defaults"}) {
        auto result = gw::ExtensionManager::installFromOpenVSX(id, folder);
        std::printf("%s: %s\n", id, result.message.c_str());
        if (!result.ok) return 1;
    }

    gw::ExtensionManager extensions(folder);
    extensions.scan();
    auto language = extensions.languageForFile("main.cpp");
    std::printf("main.cpp → %s (%s)\n", language ? language->c_str() : "?",
                language ? extensions.languageName(*language).c_str() : "?");

    gw::GrammarRegistry grammars(extensions);
    gw::tm::Grammar* grammar = language ? grammars.forLanguage(*language) : nullptr;
    if (!grammar) {
        std::printf("no C++ grammar\n");
        return 1;
    }

    const gw::ThemeInfo* darkModern = nullptr;
    auto themes = extensions.themes();
    for (const auto& theme : themes) {
        std::printf("theme: %s (%s)\n", theme.label.c_str(), theme.uiTheme.c_str());
        if (theme.label.find("Dark Modern") != std::string::npos) darkModern = &theme;
    }
    if (!darkModern) {
        std::printf("no Dark Modern theme\n");
        return 1;
    }
    std::string error;
    auto theme = gw::Theme::load(darkModern->path, darkModern->dark(), &error);
    if (!theme) {
        std::printf("theme failed: %s\n", error.c_str());
        return 1;
    }

    std::vector<std::string> lines = {
        "#include <vector>",
        "/* A block comment",
        "   spanning lines */",
        "template <typename T>",
        "int sum(const std::vector<T>& values) {",
        "    int total = 0; // running total",
        "    for (auto v : values) total += v;",
        "    return total * 2 + 0x1F;",
        "}",
        "auto s = R\"(raw \"string\")\";",
    };
    auto start = std::chrono::steady_clock::now();
    gw::tm::State state = gw::tm::initialState(*grammar);
    for (const auto& line : lines) {
        auto result = gw::tm::tokenizeLine(*grammar, line, state);
        state = result.state;
        std::printf("\n%s\n", line.c_str());
        for (const auto& token : result.tokens) {
            auto style = theme->styleFor(token.scopes);
            std::string text = line.substr(token.start, token.end - token.start);
            if (text.find_first_not_of(' ') == std::string::npos) continue;
            std::printf("  %-22s #%06X  %s\n", ("'" + text + "'").c_str(), style.foreground >> 8,
                        token.scopes ? token.scopes->name.c_str() : "");
        }
    }
    auto elapsed = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
    std::printf("\ntokenized %zu lines in %.1f ms (first run includes grammar loading)\n", lines.size(), elapsed);
    return 0;
}
