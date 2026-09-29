// Checks that skipping regexes by their first byte never changes how code is highlighted:
// real grammars, real code, token for token, with the shortcut on and off.
//
// Needs the default language extensions installed (Glasswork installs them on first run).
// Languages or sample files that are missing are skipped.

#include "Extensions.hpp"
#include "Highlighter.hpp"
#include "textmate/Regex.hpp"
#include "TextBuffer.hpp"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>

namespace fs = std::filesystem;

namespace {

struct Sample {
    const char* language;
    std::vector<std::string> candidates;  // first one that exists is used
};

std::string readLines(const fs::path& path, size_t maxLines) {
    std::ifstream file(path, std::ios::binary);
    std::string text;
    std::string line;
    size_t count = 0;
    while (count < maxLines && std::getline(file, line)) {
        if (line.size() > 4000) line.resize(4000);
        text += line;
        text += '\n';
        ++count;
    }
    return text;
}

struct Signature {
    std::vector<std::vector<std::tuple<uint32_t, uint32_t, const void*>>> lines;
    bool operator==(const Signature& other) const { return lines == other.lines; }
};

Signature tokenize(gw::tm::Grammar* grammar, const gw::TextBuffer& buffer) {
    gw::Highlighter highlighter(grammar);
    Signature signature;
    for (size_t line = 0; line < buffer.lineCount(); ++line) {
        const auto* tokens = highlighter.tokens(buffer, line, 1000000);
        std::vector<std::tuple<uint32_t, uint32_t, const void*>> row;
        if (tokens != nullptr) {
            for (const auto& token : *tokens) row.emplace_back(token.start, token.end, token.scopes);
        }
        signature.lines.push_back(std::move(row));
    }
    return signature;
}

}  // namespace

int main() {
    const char* home = std::getenv("HOME");
    fs::path extensionsFolder = fs::path(home ? home : ".") / "Library/Application Support/Glasswork/extensions";
    gw::ExtensionManager extensions(extensionsFolder);
    extensions.scan();
    gw::GrammarRegistry grammars(extensions);

    const std::string sdk = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk";
    std::vector<Sample> samples = {
        {"cpp", {sdk + "/usr/include/c++/v1/vector", sdk + "/usr/include/c++/v1/algorithm"}},
        {"c", {sdk + "/usr/include/stdio.h", sdk + "/usr/include/stdlib.h"}},
        {"objective-c", {sdk + "/System/Library/Frameworks/Foundation.framework/Headers/NSString.h"}},
        {"python", {"/Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework/Versions/3.9/lib/python3.9/argparse.py",
                    "/usr/lib/python3/dist-packages/six.py"}},
        {"shellscript", {"/etc/zshrc", "/etc/profile", "/usr/bin/gettext.sh"}},
        {"json", {std::string(home ? home : "") + "/.claude.json", "/Library/Preferences/com.apple.loginwindow.plist"}},
        {"markdown", {std::string(home ? home : "") + "/Code/Glasswork/README.md"}},
        {"swift", {sdk + "/usr/lib/swift/Swift.swiftmodule/arm64e-apple-macos.swiftinterface"}},
        {"javascript", {std::string(home ? home : "") + "/.nvm/nvm.sh"}},
        {"makefile", {"/Library/Developer/CommandLineTools/usr/share/man/../../../../../etc/paths"}},
    };

    int failures = 0;
    int compared = 0;
    for (const Sample& sample : samples) {
        gw::tm::Grammar* grammar = grammars.forLanguage(sample.language);
        if (grammar == nullptr) {
            std::printf("skip  %-12s (no grammar installed)\n", sample.language);
            continue;
        }
        std::string text;
        std::string used;
        for (const std::string& candidate : sample.candidates) {
            if (fs::exists(candidate)) {
                text = readLines(candidate, 3000);
                used = candidate;
                break;
            }
        }
        if (text.empty()) {
            std::printf("skip  %-12s (no sample file)\n", sample.language);
            continue;
        }
        gw::TextBuffer buffer(text);

        gw::tm::Regex::setFirstByteSkippingEnabled(false);
        auto start = std::chrono::steady_clock::now();
        Signature without = tokenize(grammar, buffer);
        double withoutMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();

        gw::tm::Regex::setFirstByteSkippingEnabled(true);
        start = std::chrono::steady_clock::now();
        Signature with = tokenize(grammar, buffer);
        double withMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();

        bool same = without == with;
        ++compared;
        if (!same) ++failures;
        std::printf("%s  %-12s %5zu lines   %7.0f ms → %7.0f ms   (%s)\n", same ? "ok  " : "FAIL", sample.language, buffer.lineCount(),
                    withoutMs, withMs, fs::path(used).filename().c_str());
    }
    std::printf("\n%d languages compared, %d differed\n", compared, failures);
    return failures == 0 ? 0 : 1;
}
