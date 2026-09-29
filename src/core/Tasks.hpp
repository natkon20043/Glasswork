#pragma once

#include <filesystem>
#include <string>
#include <vector>

namespace gw {

/// Something the project can be asked to do: a build, a test run, a script.
struct Task {
    std::string label;    // "Build (CMake)"
    std::string command;  // typed into the terminal, run from the project folder
    enum class Kind { Build, Run, Test, Other } kind = Kind::Other;
};

/// Looks at the project folder for the usual build files (CMake, Swift packages, Cargo, Go
/// modules, npm scripts, Makefiles) and lists what can be run. Builds come first.
std::vector<Task> detectTasks(const std::filesystem::path& folder);

/// A command that runs one source file by itself (a script, or a single C/C++/Rust file that is
/// compiled first), or an empty string for kinds of file that can't be run this way.
std::string commandToRunFile(const std::filesystem::path& file, const std::string& languageId);

/// Wraps a string in single quotes for a POSIX shell.
std::string shellQuote(const std::string& text);

}  // namespace gw
