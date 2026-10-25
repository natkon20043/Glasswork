#include "Git.hpp"

#include "Process.hpp"

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <set>

namespace gw::git {

namespace {

// ---------------------------------------------------------------------------
// Running git

/// How long each kind of command may take before we give up on it.
constexpr double kQuickTimeout = 30;
constexpr double kSlowTimeout = 180;  // network, and commits that run hooks

ProcessOptions optionsFor(const std::string& directory, double timeoutSeconds) {
    ProcessOptions options;
    options.workingDirectory = directory;
    options.timeoutSeconds = timeoutSeconds;
    options.environment = {
        // Never stop and wait for someone to type a password, in a window they can't see.
        {"GIT_TERMINAL_PROMPT", "0"},
        {"GIT_SSH_COMMAND", "ssh -o BatchMode=yes"},
        {"GIT_EDITOR", "true"},
        {"GIT_PAGER", "cat"},
        // Reading the status must not take the repository lock: a commit may be running.
        {"GIT_OPTIONAL_LOCKS", "0"},
    };
    return options;
}

ProcessResult runGit(const std::string& directory, std::vector<std::string> arguments,
                     double timeoutSeconds = kQuickTimeout, const std::string& input = "") {
    std::vector<std::string> command = {"git", "-c", "core.quotepath=false"};
    command.insert(command.end(), arguments.begin(), arguments.end());
    ProcessOptions options = optionsFor(directory, timeoutSeconds);
    options.input = input;
    return runProcess(command, options);
}

/// Turns a finished process into the result the UI shows.
CommandResult toCommandResult(const ProcessResult& process, const std::string& programName) {
    CommandResult result;
    result.output = process.output;
    if (!process.started) {
        result.error = process.startError;
        return result;
    }
    if (process.timedOut) {
        result.error = programName + " took too long and was stopped.";
        return result;
    }
    if (process.exitCode != 0) {
        result.error = process.errorOutput;
        if (result.error.empty()) {
            result.error = process.output;
        }
        if (result.error.empty()) {
            result.error = programName + " failed (exit code " + std::to_string(process.exitCode) + ").";
        }
        return result;
    }
    result.ok = true;
    return result;
}

CommandResult runGitCommand(const std::string& root, std::vector<std::string> arguments,
                            double timeoutSeconds = kQuickTimeout, const std::string& input = "") {
    return toCommandResult(runGit(root, std::move(arguments), timeoutSeconds, input), "git");
}

std::string trimmed(const std::string& text) {
    size_t start = text.find_first_not_of(" \t\r\n");
    if (start == std::string::npos) {
        return std::string();
    }
    size_t end = text.find_last_not_of(" \t\r\n");
    return text.substr(start, end - start + 1);
}

// ---------------------------------------------------------------------------
// Parsing status

ChangeKind kindFromLetter(char letter) {
    switch (letter) {
        case 'M':
            return ChangeKind::Modified;
        case 'A':
            return ChangeKind::Added;
        case 'D':
            return ChangeKind::Deleted;
        case 'R':
            return ChangeKind::Renamed;
        case 'C':
            return ChangeKind::Copied;
        case 'T':
            return ChangeKind::TypeChanged;
        case 'U':
            return ChangeKind::Conflicted;
        default:
            return ChangeKind::None;
    }
}

/// Splits `line` at spaces into at most `fieldCount` fields; the last field keeps any
/// spaces it contains (file names may have them).
std::vector<std::string> splitFields(const std::string& line, size_t fieldCount) {
    std::vector<std::string> fields;
    size_t start = 0;
    while (fields.size() + 1 < fieldCount) {
        size_t space = line.find(' ', start);
        if (space == std::string::npos) {
            break;
        }
        fields.push_back(line.substr(start, space - start));
        start = space + 1;
    }
    fields.push_back(line.substr(start));
    return fields;
}

}  // namespace

// ---------------------------------------------------------------------------
// Status

size_t Status::stagedCount() const {
    size_t count = 0;
    for (const FileChange& change : changes) {
        if (change.hasStagedChange()) {
            ++count;
        }
    }
    return count;
}

size_t Status::unstagedCount() const {
    size_t count = 0;
    for (const FileChange& change : changes) {
        if (change.hasUnstagedChange() || change.isConflicted()) {
            ++count;
        }
    }
    return count;
}

Status parseStatus(const std::string& output, size_t limit) {
    Status status;
    status.isRepository = true;

    std::vector<std::string> records;
    size_t start = 0;
    while (start < output.size()) {
        size_t end = output.find('\0', start);
        if (end == std::string::npos) {
            end = output.size();
        }
        records.push_back(output.substr(start, end - start));
        start = end + 1;
    }

    for (size_t index = 0; index < records.size(); ++index) {
        const std::string& record = records[index];
        if (record.empty()) {
            continue;
        }

        if (record[0] == '#') {
            // Header lines: "# branch.head main", "# branch.ab +1 -2" …
            if (record.rfind("# branch.oid ", 0) == 0) {
                std::string value = record.substr(13);
                if (value != "(initial)") {
                    status.headCommit = value;
                }
            } else if (record.rfind("# branch.head ", 0) == 0) {
                std::string value = record.substr(14);
                if (value != "(detached)") {
                    status.branch = value;
                }
            } else if (record.rfind("# branch.upstream ", 0) == 0) {
                status.upstream = record.substr(18);
            } else if (record.rfind("# branch.ab ", 0) == 0) {
                std::vector<std::string> parts = splitFields(record.substr(12), 2);
                if (parts.size() == 2 && parts[0].size() > 1 && parts[1].size() > 1) {
                    status.ahead = std::atoi(parts[0].c_str() + 1);
                    status.behind = std::atoi(parts[1].c_str() + 1);
                }
            }
            continue;
        }

        FileChange change;
        if (record[0] == '1') {
            // 1 XY sub mH mI mW hH hI path
            std::vector<std::string> fields = splitFields(record, 9);
            if (fields.size() < 9) {
                continue;
            }
            change.staged = kindFromLetter(fields[1][0]);
            change.unstaged = kindFromLetter(fields[1][1]);
            change.path = fields[8];
        } else if (record[0] == '2') {
            // 2 XY sub mH mI mW hH hI Xscore path   (the original path is the next record)
            std::vector<std::string> fields = splitFields(record, 10);
            if (fields.size() < 10) {
                continue;
            }
            change.staged = kindFromLetter(fields[1][0]);
            change.unstaged = kindFromLetter(fields[1][1]);
            change.path = fields[9];
            if (index + 1 < records.size()) {
                change.originalPath = records[index + 1];
                ++index;
            }
        } else if (record[0] == 'u') {
            // u XY sub m1 m2 m3 mW h1 h2 h3 path
            std::vector<std::string> fields = splitFields(record, 11);
            if (fields.size() < 11) {
                continue;
            }
            change.staged = ChangeKind::Conflicted;
            change.unstaged = ChangeKind::Conflicted;
            change.path = fields[10];
        } else if (record[0] == '?') {
            change.unstaged = ChangeKind::Untracked;
            change.path = record.substr(2);
        } else {
            continue;  // ignored files ("!") and anything unknown
        }

        if (status.changes.size() >= limit) {
            status.truncated = true;
            continue;
        }
        status.changes.push_back(std::move(change));
    }
    return status;
}

Status readStatus(const std::string& directory) {
    ProcessResult top = runGit(directory, {"rev-parse", "--show-toplevel"});
    if (!top.started) {
        Status failed;
        failed.error = top.startError;
        return failed;
    }
    if (top.exitCode != 0) {
        return Status();  // not inside a repository: not an error
    }
    std::string root = trimmed(top.output);

    ProcessResult result = runGit(root, {"status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"});
    if (!result.succeeded()) {
        Status failed;
        failed.isRepository = true;
        failed.root = root;
        failed.error = result.errorOutput;
        if (failed.error.empty()) {
            failed.error = "git status failed";
        }
        return failed;
    }
    Status status = parseStatus(result.output);
    status.root = root;

    ProcessResult remotes = runGit(root, {"remote"});
    status.hasRemote = remotes.succeeded() && !trimmed(remotes.output).empty();
    return status;
}

// ---------------------------------------------------------------------------
// Reading

std::optional<std::string> readHeadFile(const std::string& root, const std::string& relativePath) {
    ProcessResult result = runGit(root, {"cat-file", "blob", "HEAD:" + relativePath});
    if (!result.succeeded()) {
        return std::nullopt;
    }
    return result.output;
}

std::string readDiff(const std::string& root, const std::string& relativePath, bool staged) {
    std::vector<std::string> arguments = {"diff", "--no-color", "--no-ext-diff"};
    if (staged) {
        arguments.push_back("--cached");
    }
    arguments.push_back("--");
    arguments.push_back(relativePath);
    ProcessResult result = runGit(root, arguments);
    if (result.started && !result.output.empty()) {
        return result.output;
    }

    // Nothing from the normal diff: it may be an untracked file, which has no "before".
    ProcessResult untracked = runGit(root, {"diff", "--no-color", "--no-index", "--", "/dev/null", relativePath});
    return untracked.output;
}

std::vector<LogEntry> readLog(const std::string& root, int count) {
    std::vector<LogEntry> entries;
    ProcessResult result = runGit(root, {"log", "-n", std::to_string(count),
                                         "--pretty=format:%H%x1f%h%x1f%an%x1f%ar%x1f%s%x1e"});
    if (!result.succeeded()) {
        return entries;
    }

    size_t start = 0;
    while (start < result.output.size()) {
        size_t end = result.output.find('\x1e', start);
        if (end == std::string::npos) {
            end = result.output.size();
        }
        std::string record = result.output.substr(start, end - start);
        start = end + 1;

        std::vector<std::string> fields;
        size_t fieldStart = 0;
        while (true) {
            size_t separator = record.find('\x1f', fieldStart);
            if (separator == std::string::npos) {
                fields.push_back(record.substr(fieldStart));
                break;
            }
            fields.push_back(record.substr(fieldStart, separator - fieldStart));
            fieldStart = separator + 1;
        }
        if (fields.size() < 5) {
            continue;
        }
        LogEntry entry;
        entry.hash = trimmed(fields[0]);
        entry.shortHash = fields[1];
        entry.author = fields[2];
        entry.relativeDate = fields[3];
        entry.subject = fields[4];
        entries.push_back(std::move(entry));
    }
    return entries;
}

std::vector<std::string> listFiles(const std::string& folder, bool* ok) {
    std::vector<std::string> files;
    ProcessOptions options = optionsFor(folder, 60);
    options.maxOutputBytes = 256 * 1024 * 1024;
    std::vector<std::string> command = {
        "git", "-c", "core.quotepath=false", "ls-files", "-z", "--cached", "--others", "--exclude-standard",
    };
    ProcessResult result = runProcess(command, options);
    if (ok != nullptr) {
        *ok = result.succeeded();
    }
    if (!result.succeeded()) {
        return files;
    }
    size_t start = 0;
    while (start < result.output.size()) {
        size_t end = result.output.find('\0', start);
        if (end == std::string::npos) {
            end = result.output.size();
        }
        if (end > start) {
            files.emplace_back(result.output, start, end - start);
        }
        start = end + 1;
    }
    return files;
}

std::string readFullDiff(const std::string& root, bool staged) {
    std::vector<std::string> arguments = {"diff", "--no-color", "--no-ext-diff"};
    if (staged) {
        arguments.push_back("--cached");
    }
    ProcessResult result = runGit(root, arguments);
    return result.output;
}

std::string readCommitDiff(const std::string& root, const std::string& hash) {
    ProcessResult result = runGit(root, {"show", "--no-color", "--no-ext-diff", "--stat", "--patch", hash});
    return result.output;
}

std::vector<Branch> readBranches(const std::string& root) {
    std::vector<Branch> branches;
    ProcessResult result = runGit(root, {"branch", "-a", "--format=%(HEAD)%09%(refname)%09%(refname:short)"});
    if (!result.succeeded()) {
        return branches;
    }

    size_t start = 0;
    while (start < result.output.size()) {
        size_t end = result.output.find('\n', start);
        if (end == std::string::npos) {
            end = result.output.size();
        }
        std::string line = result.output.substr(start, end - start);
        start = end + 1;

        std::vector<std::string> fields;
        size_t fieldStart = 0;
        while (true) {
            size_t tab = line.find('\t', fieldStart);
            if (tab == std::string::npos) {
                fields.push_back(line.substr(fieldStart));
                break;
            }
            fields.push_back(line.substr(fieldStart, tab - fieldStart));
            fieldStart = tab + 1;
        }
        if (fields.size() < 3 || fields[2].empty()) {
            continue;
        }
        bool isRemote = fields[1].rfind("refs/remotes/", 0) == 0;
        if (isRemote && fields[1].size() >= 5 && fields[1].compare(fields[1].size() - 5, 5, "/HEAD") == 0) {
            continue;  // "origin/HEAD" is an alias, not a branch to show
        }
        if (fields[2].rfind("(HEAD detached", 0) == 0) {
            continue;
        }
        Branch branch;
        branch.name = fields[2];
        branch.isCurrent = fields[0] == "*";
        branch.isRemote = isRemote;
        branches.push_back(std::move(branch));
    }
    return branches;
}

// ---------------------------------------------------------------------------
// Changing

CommandResult initRepository(const std::string& directory) {
    return runGitCommand(directory, {"init", "-b", "main"});
}

std::string suggestedGitignore(const std::string& folder) {
    std::set<std::string> names;
    std::error_code error;
    for (const auto& entry : std::filesystem::directory_iterator(folder, error)) {
        names.insert(entry.path().filename().string());
    }
    auto has = [&names](const char* name) { return names.count(name) > 0; };
    auto hasSuffix = [&names](const std::string& suffix) {
        for (const std::string& name : names) {
            if (name.size() >= suffix.size() && name.compare(name.size() - suffix.size(), suffix.size(), suffix) == 0) {
                return true;
            }
        }
        return false;
    };

    std::string text = "# macOS\n.DS_Store\n\n";
    if (has("CMakeLists.txt")) {
        text += "# CMake\nbuild/\ncmake-build-*/\n\n";
    }
    if (has("package.json")) {
        text += "# Node\nnode_modules/\ndist/\n.env\n\n";
    }
    if (has("Package.swift")) {
        text += "# Swift package manager\n.build/\n.swiftpm/\n\n";
    }
    if (hasSuffix(".xcodeproj") || hasSuffix(".xcworkspace")) {
        text += "# Xcode\nDerivedData/\n*.xcuserstate\nxcuserdata/\n\n";
    }
    if (has("requirements.txt") || has("pyproject.toml") || has("setup.py")) {
        text += "# Python\n__pycache__/\n*.pyc\n.venv/\nvenv/\n\n";
    }
    if (has("Cargo.toml")) {
        text += "# Rust\ntarget/\n\n";
    }
    if (has("go.mod")) {
        text += "# Go\nbin/\n\n";
    }
    if (has("pom.xml") || has("build.gradle") || has("build.gradle.kts")) {
        text += "# Java\ntarget/\n.gradle/\nbuild/\n*.class\n\n";
    }
    text += "# Editors\n.idea/\n.vscode/\n*.swp\n";
    return text;
}

bool writeGitignoreIfMissing(const std::string& folder, const std::string& contents) {
    std::filesystem::path path = std::filesystem::path(folder) / ".gitignore";
    if (std::filesystem::exists(path)) {
        return false;
    }
    std::ofstream file(path, std::ios::binary);
    file << contents;
    return static_cast<bool>(file);
}

CommandResult stagePaths(const std::string& root, const std::vector<std::string>& paths) {
    std::vector<std::string> arguments = {"add", "-A", "--"};
    arguments.insert(arguments.end(), paths.begin(), paths.end());
    return runGitCommand(root, arguments);
}

CommandResult stageAll(const std::string& root) {
    return runGitCommand(root, {"add", "-A"});
}

CommandResult unstagePaths(const std::string& root, const std::vector<std::string>& paths, bool hasCommits) {
    std::vector<std::string> arguments;
    if (hasCommits) {
        arguments = {"restore", "--staged", "--"};
    } else {
        arguments = {"rm", "--cached", "-r", "-q", "--"};
    }
    arguments.insert(arguments.end(), paths.begin(), paths.end());
    return runGitCommand(root, arguments);
}

CommandResult discardPaths(const std::string& root, const std::vector<std::string>& paths) {
    std::vector<std::string> arguments = {"restore", "--"};
    arguments.insert(arguments.end(), paths.begin(), paths.end());
    return runGitCommand(root, arguments);
}

CommandResult commit(const std::string& root, const std::string& message, bool amend) {
    std::vector<std::string> arguments = {"commit", "-F", "-"};
    if (amend) {
        arguments.push_back("--amend");
    }
    return runGitCommand(root, arguments, kSlowTimeout, message);
}

CommandResult push(const std::string& root, bool hasUpstream) {
    ProcessResult remotes = runGit(root, {"remote"});
    if (remotes.succeeded() && trimmed(remotes.output).empty()) {
        CommandResult result;
        result.error = "This repository has no remote yet. Use “Publish to GitHub” to create one.";
        return result;
    }
    std::vector<std::string> arguments = {"push"};
    if (!hasUpstream) {
        arguments = {"push", "-u", "origin", "HEAD"};
    }
    CommandResult result = runGitCommand(root, arguments, kSlowTimeout);
    if (!result.ok) {
        bool needsLogin = result.error.find("could not read Username") != std::string::npos ||
                          result.error.find("Authentication failed") != std::string::npos ||
                          result.error.find("Permission denied") != std::string::npos;
        if (needsLogin) {
            result.error += "\n\nGit needs to sign in to GitHub. Run “gh auth login” once in a terminal, then "
                            "“gh auth setup-git”, and try again.";
        }
    }
    return result;
}

CommandResult pull(const std::string& root) {
    return runGitCommand(root, {"pull", "--ff-only"}, kSlowTimeout);
}

CommandResult fetch(const std::string& root) {
    return runGitCommand(root, {"fetch", "--all", "--prune"}, kSlowTimeout);
}

namespace {

/// A branch name typed as "-x" would be read by git as an option.
std::optional<CommandResult> refuseOptionLikeName(const std::string& name) {
    if (!name.empty() && name[0] != '-') {
        return std::nullopt;
    }
    CommandResult refused;
    refused.error = "Branch names can't be empty or start with \"-\".";
    return refused;
}

}  // namespace

CommandResult switchBranch(const std::string& root, const std::string& name) {
    if (std::optional<CommandResult> refused = refuseOptionLikeName(name)) {
        return *refused;
    }
    return runGitCommand(root, {"switch", name});
}

CommandResult createBranch(const std::string& root, const std::string& name) {
    if (std::optional<CommandResult> refused = refuseOptionLikeName(name)) {
        return *refused;
    }
    return runGitCommand(root, {"switch", "-c", name});
}

CommandResult applyPatch(const std::string& root, const std::string& patch, bool toIndex, bool reverse) {
    std::vector<std::string> arguments = {"apply", "--unidiff-zero", "--whitespace=nowarn"};
    if (toIndex) {
        arguments.push_back("--cached");
    }
    if (reverse) {
        arguments.push_back("-R");
    }
    arguments.push_back("-");
    return runGitCommand(root, arguments, kQuickTimeout, patch);
}

// ---------------------------------------------------------------------------
// GitHub

GitHubState readGitHubState() {
    GitHubState state;
    if (findExecutable("gh").empty()) {
        return state;
    }
    state.ghInstalled = true;

    ProcessOptions options;
    options.timeoutSeconds = kQuickTimeout;
    ProcessResult login = runProcess({"gh", "auth", "status"}, options);
    state.loggedIn = login.succeeded();
    if (state.loggedIn) {
        ProcessResult user = runProcess({"gh", "api", "user", "--jq", ".login"}, options);
        if (user.succeeded()) {
            state.user = trimmed(user.output);
        }
    }
    return state;
}

std::string readOriginRepository(const std::string& root) {
    ProcessResult result = runGit(root, {"remote", "get-url", "origin"});
    if (!result.succeeded()) {
        return std::string();
    }
    std::string url = trimmed(result.output);
    size_t hostPosition = url.find("github.com");
    if (hostPosition == std::string::npos) {
        return std::string();
    }
    // https://github.com/owner/name.git  or  git@github.com:owner/name.git
    std::string rest = url.substr(hostPosition + 10);
    if (!rest.empty() && (rest[0] == '/' || rest[0] == ':')) {
        rest.erase(0, 1);
    }
    if (rest.size() > 4 && rest.compare(rest.size() - 4, 4, ".git") == 0) {
        rest.erase(rest.size() - 4);
    }
    return rest;
}

CommandResult publishToGitHub(const std::string& root, const std::string& name, bool isPrivate,
                              const std::string& description) {
    std::string visibility = "--public";
    if (isPrivate) {
        visibility = "--private";
    }
    std::vector<std::string> command = {
        "gh", "repo", "create", name, visibility, "--source=.", "--remote=origin", "--push",
    };
    if (!description.empty()) {
        command.push_back("--description");
        command.push_back(description);
    }
    ProcessOptions options = optionsFor(root, kSlowTimeout);
    return toCommandResult(runProcess(command, options), "gh");
}

CommandResult createPullRequest(const std::string& root, const std::string& title, const std::string& body) {
    std::vector<std::string> command = {"gh", "pr", "create"};
    if (title.empty()) {
        command.push_back("--fill");
    } else {
        command.push_back("--title");
        command.push_back(title);
        command.push_back("--body");
        command.push_back(body);
    }
    ProcessOptions options = optionsFor(root, kSlowTimeout);
    return toCommandResult(runProcess(command, options), "gh");
}

}  // namespace gw::git
