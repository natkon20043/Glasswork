// Speed measurements for the parts of Glasswork that decide how fast it feels: opening
// files, syntax highlighting, editing, searching and fuzzy matching.
//
//   glasswork_bench [corpus-folder]
//
// The corpus is a folder of C++ headers (the C++ standard library in the macOS SDK by default).
// Numbers are printed as "name ... value"; run it on a quiet machine.

#include "Document.hpp"
#include "Extensions.hpp"
#include "Fuzzy.hpp"
#include "Highlighter.hpp"
#include "LineDiff.hpp"
#include "ProjectSearch.hpp"
#include "Styling.hpp"
#include "Theme.hpp"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

namespace fs = std::filesystem;
using Clock = std::chrono::steady_clock;

namespace {

double millisecondsSince(Clock::time_point start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}

void report(const char* name, double value, const char* unit) {
    std::printf("  %-52s %10.2f %s\n", name, value, unit);
}

std::string readFile(const fs::path& path) {
    std::ifstream file(path, std::ios::binary);
    std::ostringstream contents;
    contents << file.rdbuf();
    return contents.str();
}

/// Joins the files under `folder` into one big text of about `megabytes`.
std::string buildCorpus(const fs::path& folder, size_t megabytes) {
    std::string text;
    text.reserve(megabytes * 1024 * 1024 + 1024 * 1024);
    std::vector<fs::path> files;
    for (const auto& entry : fs::recursive_directory_iterator(folder, fs::directory_options::skip_permission_denied)) {
        if (entry.is_regular_file()) {
            files.push_back(entry.path());
        }
    }
    std::sort(files.begin(), files.end());
    size_t index = 0;
    while (text.size() < megabytes * 1024 * 1024 && !files.empty()) {
        text += readFile(files[index % files.size()]);
        text += '\n';
        ++index;
        if (index > files.size() * 400) {
            break;
        }
    }
    return text;
}

}  // namespace

int main(int argc, char** argv) {
    fs::path corpusFolder = argc > 1 ? fs::path(argv[1])
                                     : fs::path("/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include/c++/v1");
    const char* home = std::getenv("HOME");
    fs::path extensionsFolder = fs::path(home ? home : ".") / "Library/Application Support/Glasswork/extensions";

    std::printf("Glasswork speed check\n\n");

    // ---- Files
    std::string corpus = buildCorpus(corpusFolder, 24);
    fs::path scratch = fs::temp_directory_path() / "glasswork-bench-corpus.cpp";
    {
        std::ofstream out(scratch, std::ios::binary);
        out << corpus;
    }
    std::printf("Corpus: %.1f MB of C++ (%s)\n\n", static_cast<double>(corpus.size()) / 1e6, corpusFolder.filename().c_str());

    std::printf("Opening a file\n");
    auto start = Clock::now();
    std::string error;
    std::optional<gw::Document> opened = gw::Document::open(scratch, &error);
    double openMilliseconds = millisecondsSince(start);
    if (!opened) {
        std::printf("could not open the corpus: %s\n", error.c_str());
        return 1;
    }
    gw::Document& document = *opened;
    report("read + split into lines", openMilliseconds, "ms");
    report("lines", static_cast<double>(document.buffer().lineCount()), "lines");
    report("throughput", static_cast<double>(corpus.size()) / 1e6 / (openMilliseconds / 1000), "MB/s");

    // ---- Highlighting
    gw::ExtensionManager extensions(extensionsFolder);
    extensions.scan();
    gw::GrammarRegistry grammars(extensions);
    gw::tm::Grammar* grammar = grammars.forLanguage("cpp");
    if (grammar == nullptr) {
        std::printf("\n(no C++ grammar installed; skipping highlighting checks)\n");
        return 0;
    }

    std::printf("\nSyntax highlighting (TextMate grammar)\n");
    {
        gw::Highlighter highlighter(grammar);
        start = Clock::now();
        highlighter.tokens(document.buffer(), 60, 1000000);
        report("first screen (60 lines) cold", millisecondsSince(start), "ms");
    }
    {
        gw::Highlighter highlighter(grammar);
        const size_t lines = std::min<size_t>(document.buffer().lineCount(), 100000);
        start = Clock::now();
        highlighter.tokens(document.buffer(), lines - 1, 10000000);
        double elapsed = millisecondsSince(start);
        size_t bytes = 0;
        for (size_t line = 0; line < lines; ++line) {
            bytes += document.buffer().line(line).size() + 1;
        }
        report("100,000 lines", elapsed, "ms");
        report("throughput", static_cast<double>(lines) / (elapsed / 1000) / 1000, "k lines/s");
        report("throughput", static_cast<double>(bytes) / 1e6 / (elapsed / 1000), "MB/s");

        // Editing: only what follows the change is redone, and only until things settle.
        start = Clock::now();
        for (int round = 0; round < 20; ++round) {
            size_t line = 50000 + static_cast<size_t>(round);
            document.replace({{line, 0}, {line, 0}}, "x");
            highlighter.didChange({line, 0});
            highlighter.tokens(document.buffer(), line + 60, 100000);
        }
        report("re-highlight after an edit (mid-file, avg)", millisecondsSince(start) / 20, "ms");
    }

    // ---- Colouring
    std::printf("\nColouring a screen of code\n");
    {
        std::string themeError;
        std::unique_ptr<gw::Theme> theme;
        for (const auto& info : extensions.themes()) {
            if (info.label.find("Dark Modern") != std::string::npos) {
                theme = gw::Theme::load(info.path, info.dark(), &themeError);
                break;
            }
        }
        if (theme) {
            gw::Stylist stylist(*theme, gw::ColorCustomizations{});
            gw::Highlighter highlighter(grammar);
            highlighter.tokens(document.buffer(), 2000, 100000);
            start = Clock::now();
            size_t spans = 0;
            for (int repeat = 0; repeat < 50; ++repeat) {
                for (size_t line = 1000; line < 1060; ++line) {
                    const auto* tokens = highlighter.tokens(document.buffer(), line, 100000);
                    if (tokens) {
                        spans += stylist.styleLine(document.buffer().line(line), *tokens).size();
                    }
                }
            }
            report("style 60 lines (avg per screen)", millisecondsSince(start) / 50, "ms");
            (void)spans;
        }
    }

    // ---- Editing
    std::printf("\nEditing a big file\n");
    {
        gw::Document big = std::move(*opened);
        size_t middle = big.buffer().lineCount() / 2;
        start = Clock::now();
        for (int round = 0; round < 200; ++round) {
            big.replace({{middle, 3}, {middle, 3}}, "a", true);
        }
        report("type a character (avg)", millisecondsSince(start) / 200, "ms");
        start = Clock::now();
        for (int round = 0; round < 50; ++round) {
            big.replace({{middle, 0}, {middle, 0}}, "\n");
        }
        report("press Return mid-file (avg)", millisecondsSince(start) / 50, "ms");
        start = Clock::now();
        for (int round = 0; round < 50; ++round) {
            big.undo();
        }
        report("undo (avg)", millisecondsSince(start) / 50, "ms");
        start = Clock::now();
        std::string text = big.buffer().text();
        report("get the whole text back (save)", millisecondsSince(start), "ms");
    }

    // ---- Search
    std::printf("\nSearching\n");
    {
        gw::search::Query query;
        query.pattern = "reinterpret_cast";
        query.caseSensitive = true;
        gw::search::Matcher matcher(query);
        start = Clock::now();
        size_t hits = 0;
        matcher.forEachMatchingLine(corpus, [&hits](size_t, size_t, size_t) {
            ++hits;
            return true;
        });
        double elapsed = millisecondsSince(start);
        report("literal, case-sensitive", static_cast<double>(corpus.size()) / 1e6 / (elapsed / 1000) / 1000, "GB/s");

        query.caseSensitive = false;
        gw::search::Matcher insensitive(query);
        start = Clock::now();
        hits = 0;
        insensitive.forEachMatchingLine(corpus, [&hits](size_t, size_t, size_t) {
            ++hits;
            return true;
        });
        elapsed = millisecondsSince(start);
        report("literal, ignoring case", static_cast<double>(corpus.size()) / 1e6 / (elapsed / 1000) / 1000, "GB/s");

        query.caseSensitive = true;
        query.useRegex = true;
        query.pattern = "\\bstd::(unique|shared)_ptr<\\w+>";
        gw::search::Matcher regex(query);
        start = Clock::now();
        hits = 0;
        regex.forEachMatchingLine(corpus, [&hits](size_t, size_t, size_t) {
            ++hits;
            return true;
        });
        elapsed = millisecondsSince(start);
        report("regular expression", static_cast<double>(corpus.size()) / 1e6 / (elapsed / 1000) / 1000, "GB/s");
    }

    // ---- Fuzzy
    std::printf("\nQuick open (fuzzy file names)\n");
    {
        std::vector<std::string> paths;
        std::vector<size_t> nameStarts;
        const fs::path sdk = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk";
        for (const auto& entry : fs::recursive_directory_iterator(sdk, fs::directory_options::skip_permission_denied)) {
            if (paths.size() >= 60000) {
                break;
            }
            if (entry.is_regular_file()) {
                std::string path = entry.path().lexically_relative(sdk).string();
                nameStarts.push_back(path.rfind('/') == std::string::npos ? 0 : path.rfind('/') + 1);
                paths.push_back(std::move(path));
            }
        }
        start = Clock::now();
        size_t matches = 0;
        for (size_t index = 0; index < paths.size(); ++index) {
            if (gw::fuzzyScore("nsview", paths[index], nameStarts[index])) {
                ++matches;
            }
        }
        report("score 60,000 paths, one thread", millisecondsSince(start), "ms");
    }

    // ---- Diff
    std::printf("\nChange bars (line diff against the last commit)\n");
    {
        std::string edited = corpus;
        edited.insert(edited.size() / 2, "// one new line\n");
        edited.erase(edited.size() / 4, 40);
        start = Clock::now();
        auto oldLines = gw::splitLines(corpus);
        auto newLines = gw::splitLines(edited);
        auto hunks = gw::diffLines(oldLines, newLines);
        report("diff a 24 MB file with two edits", millisecondsSince(start), "ms");
        (void)hunks;
    }

    fs::remove(scratch);
    std::printf("\ndone\n");
    return 0;
}
