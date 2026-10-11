#pragma once

#include <filesystem>
#include <string>
#include <vector>

namespace gw {

/// A build, test run or script the project can be asked to do.
struct Task {
    // Build file or script detected -> what the task does.
    enum class Kind { Build, Run, Test, Other };

    /// "Build (CMake)"
    std::string label;
    /// Typed into the terminal and run from the project folder.
    std::string command;
    Kind kind = Kind::Other;
};

/// Reads CMake, Swift packages, Cargo, Go modules, npm scripts and Makefiles. Builds come first.
std::vector<Task> detectTasks(const std::filesystem::path& folder);

/// Runs one file alone (a script, or a single C/C++/Rust file compiled first). Empty for files that can't.
std::string commandToRunFile(const std::filesystem::path& file, const std::string& languageId);

/// Single-quotes a string for a POSIX shell.
std::string shellQuote(const std::string& text);

}  // namespace gw
