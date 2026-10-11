#include "Tasks.hpp"

#include "Jsonc.hpp"

#include <algorithm>
#include <fstream>
#include <regex>
#include <sstream>

namespace gw {

namespace {

bool pathExists(const std::filesystem::path& path) {
    std::error_code error;
    return std::filesystem::exists(path, error);
}

std::string readFile(const std::filesystem::path& path) {
    std::ifstream stream(path, std::ios::binary);
    std::stringstream contents;
    contents << stream.rdbuf();
    return contents.str();
}

bool hasFileWithExtension(const std::filesystem::path& folder, const std::string& extension) {
    std::error_code error;
    for (const auto& entry : std::filesystem::directory_iterator(folder, error)) {
        if (entry.path().extension() == extension) {
            return true;
        }
    }
    return false;
}

void add(std::vector<Task>& tasks, const std::string& label, const std::string& command, Task::Kind kind) {
    tasks.push_back(Task{label, command, kind});
}

/// npm scripts from package.json, using whichever package manager the project uses.
void addNodeTasks(const std::filesystem::path& folder, std::vector<Task>& tasks) {
    std::filesystem::path manifest = folder / "package.json";
    if (!pathExists(manifest)) {
        return;
    }
    std::string runner = "npm run";
    if (pathExists(folder / "pnpm-lock.yaml")) runner = "pnpm run";
    else if (pathExists(folder / "yarn.lock")) runner = "yarn run";
    else if (pathExists(folder / "bun.lockb") || pathExists(folder / "bun.lock")) runner = "bun run";

    nlohmann::json document = parseJsonc(readFile(manifest));
    if (document.is_discarded() || !document.is_object() || !document.contains("scripts") || !document["scripts"].is_object()) {
        return;
    }
    for (const auto& [name, script] : document["scripts"].items()) {
        if (!script.is_string()) {
            continue;
        }
        Task::Kind kind = Task::Kind::Other;
        if (name == "build" || name.rfind("build:", 0) == 0) kind = Task::Kind::Build;
        else if (name == "start" || name == "dev" || name == "serve") kind = Task::Kind::Run;
        else if (name == "test" || name.rfind("test:", 0) == 0) kind = Task::Kind::Test;
        add(tasks, "npm script: " + name, runner + " " + name, kind);
    }
}

/// Targets of a Makefile that look like real targets (not patterns or variables).
void addMakeTasks(const std::filesystem::path& folder, std::vector<Task>& tasks) {
    std::filesystem::path makefile;
    for (const char* name : {"Makefile", "makefile", "GNUmakefile"}) {
        if (pathExists(folder / name)) {
            makefile = folder / name;
            break;
        }
    }
    if (makefile.empty()) {
        return;
    }
    add(tasks, "Build (make)", "make", Task::Kind::Build);
    std::istringstream input(readFile(makefile));
    std::string line;
    std::regex target(R"(^([A-Za-z][A-Za-z0-9_.-]*)\s*:(?!=))");
    size_t added = 0;
    while (std::getline(input, line) && added < 15) {
        std::smatch match;
        if (std::regex_search(line, match, target)) {
            std::string name = match[1];
            if (name == "all" || name == ".PHONY" || name == "default") {
                continue;
            }
            Task::Kind kind = name == "test" || name == "check" ? Task::Kind::Test : Task::Kind::Other;
            if (name == "run") kind = Task::Kind::Run;
            add(tasks, "make " + name, "make " + name, kind);
            ++added;
        }
    }
}

}  // namespace

std::string shellQuote(const std::string& text) {
    std::string quoted = "'";
    for (char character : text) {
        if (character == '\'') {
            quoted += "'\\''";
        } else {
            quoted += character;
        }
    }
    return quoted + "'";
}

std::vector<Task> detectTasks(const std::filesystem::path& folder) {
    std::vector<Task> tasks;
    if (pathExists(folder / "CMakeLists.txt")) {
        add(tasks, "Build (CMake)", "cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release && cmake --build "
                                    "build", Task::Kind::Build);
        add(tasks, "Build again (CMake)", "cmake --build build", Task::Kind::Build);
        add(tasks, "Test (CTest)", "ctest --test-dir build --output-on-failure", Task::Kind::Test);
    }
    if (pathExists(folder / "Package.swift")) {
        add(tasks, "Build (Swift)", "swift build", Task::Kind::Build);
        add(tasks, "Run (Swift)", "swift run", Task::Kind::Run);
        add(tasks, "Test (Swift)", "swift test", Task::Kind::Test);
    }
    if (pathExists(folder / "Cargo.toml")) {
        add(tasks, "Build (Cargo)", "cargo build", Task::Kind::Build);
        add(tasks, "Check (Cargo)", "cargo check", Task::Kind::Build);
        add(tasks, "Run (Cargo)", "cargo run", Task::Kind::Run);
        add(tasks, "Test (Cargo)", "cargo test", Task::Kind::Test);
    }
    if (pathExists(folder / "go.mod")) {
        add(tasks, "Build (Go)", "go build ./...", Task::Kind::Build);
        add(tasks, "Run (Go)", "go run .", Task::Kind::Run);
        add(tasks, "Test (Go)", "go test ./...", Task::Kind::Test);
    }
    if (hasFileWithExtension(folder, ".xcodeproj") || hasFileWithExtension(folder, ".xcworkspace")) {
        add(tasks, "Build (Xcode)", "xcodebuild build", Task::Kind::Build);
        add(tasks, "Test (Xcode)", "xcodebuild test", Task::Kind::Test);
    }
    if (pathExists(folder / "pyproject.toml") || pathExists(folder / "pytest.ini") || pathExists(folder / "tests")) {
        if (pathExists(folder / "pyproject.toml") || pathExists(folder / "pytest.ini")) {
            add(tasks, "Test (pytest)", "python3 -m pytest", Task::Kind::Test);
        }
    }
    addNodeTasks(folder, tasks);
    addMakeTasks(folder, tasks);

    // Builds first, then runs, tests and the rest, each group in the order found.
    std::stable_sort(tasks.begin(), tasks.end(), [](const Task& a, const Task& b) {
        return static_cast<int>(a.kind) < static_cast<int>(b.kind);
    });
    return tasks;
}

std::string commandToRunFile(const std::filesystem::path& file, const std::string& languageId) {
    std::string path = shellQuote(file.string());
    std::string extension = file.extension().string();
    if (languageId == "python") return "python3 " + path;
    if (languageId == "javascript" || languageId == "javascriptreact") return "node " + path;
    if (languageId == "typescript" || languageId == "typescriptreact") return "npx tsx " + path;
    if (languageId == "swift") return "swift " + path;
    if (languageId == "shellscript") return "bash " + path;
    if (languageId == "ruby") return "ruby " + path;
    if (languageId == "lua") return "lua " + path;
    if (languageId == "perl") return "perl " + path;
    if (languageId == "php") return "php " + path;
    if (languageId == "go") return "go run " + path;
    if (languageId == "rust") {
        return "rustc " + path + " -o /tmp/glasswork-run && /tmp/glasswork-run";
    }
    if (languageId == "cpp" && (extension == ".cpp" || extension == ".cc" || extension == ".cxx" || extension == ".mm")) {
        return "clang++ -std=c++20 -Wall " + path + " -o /tmp/glasswork-run && /tmp/glasswork-run";
    }
    if (languageId == "c" && extension == ".c") {
        return "clang -Wall " + path + " -o /tmp/glasswork-run && /tmp/glasswork-run";
    }
    return std::string();
}

}  // namespace gw
