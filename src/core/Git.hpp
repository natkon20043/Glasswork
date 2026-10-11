#pragma once

#include <optional>
#include <string>
#include <vector>

namespace gw::git {

// One column of `git status` for a file (staged "index" column, or working-tree column) -> what happened to it.
enum class ChangeKind {
    None,
    Modified,
    Added,
    Deleted,
    Renamed,
    Copied,
    TypeChanged,
    Untracked,
    Conflicted,
};

// ---- Types

struct FileChange {
    /// Relative to the repository root, "/" separators.
    std::string path;
    /// Where a renamed or copied file used to be.
    std::string originalPath;
    ChangeKind staged = ChangeKind::None;
    ChangeKind unstaged = ChangeKind::None;

    bool isUntracked() const { return unstaged == ChangeKind::Untracked; }
    bool isConflicted() const { return staged == ChangeKind::Conflicted; }
    bool hasStagedChange() const { return staged != ChangeKind::None && staged != ChangeKind::Conflicted; }
    bool hasUnstagedChange() const { return unstaged != ChangeKind::None; }
};

struct Status {
    bool hasCommits() const { return !headCommit.empty(); }
    size_t stagedCount() const;
    size_t unstagedCount() const;

    bool isRepository = false;
    /// Absolute path of the repository's top folder.
    std::string root;
    /// Empty when HEAD is detached.
    std::string branch;
    /// Full hash; empty before the first commit.
    std::string headCommit;
    /// Tracked branch such as "origin/main", or empty.
    std::string upstream;
    int ahead = 0;
    int behind = 0;
    bool hasRemote = false;
    std::vector<FileChange> changes;
    /// There were more changes than `changes` holds.
    bool truncated = false;
    /// Set when git failed for a reason other than "not a repository".
    std::string error;
};

struct CommandResult {
    bool ok = false;
    std::string output;
    /// In git's own words, when `ok` is false.
    std::string error;
};

struct LogEntry {
    std::string hash;
    std::string shortHash;
    std::string author;
    /// "3 days ago"
    std::string relativeDate;
    std::string subject;
};

struct Branch {
    std::string name;
    bool isCurrent = false;
    bool isRemote = false;
};

struct GitHubState {
    bool ghInstalled = false;
    bool loggedIn = false;
    std::string user;
};

// ---- Status

/// Parses `git status --porcelain=v2 --branch -z` output, keeping at most `limit` changes.
Status parseStatus(const std::string& output, size_t limit = 5000);
/// `directory` may be anywhere inside a repository.
Status readStatus(const std::string& directory);

// ---- Reading

/// Nullopt for new files and repositories without commits.
std::optional<std::string> readHeadFile(const std::string& root, const std::string& relativePath);
/// An untracked file shows as entirely added.
std::string readDiff(const std::string& root, const std::string& relativePath, bool staged);
std::string readFullDiff(const std::string& root, bool staged);
/// Message, file summary and patch.
std::string readCommitDiff(const std::string& root, const std::string& hash);
std::vector<LogEntry> readLog(const std::string& root, int count);
std::vector<Branch> readBranches(const std::string& root);
/// Tracked and untracked, not ignored, relative to `folder`. Empty with `ok` false outside a repository.
std::vector<std::string> listFiles(const std::string& folder, bool* ok = nullptr);

// ---- Staging and committing

CommandResult stagePaths(const std::string& root, const std::vector<std::string>& paths);
CommandResult stageAll(const std::string& root);
CommandResult unstagePaths(const std::string& root, const std::vector<std::string>& paths, bool hasCommits);
/// Cannot be undone.
CommandResult discardPaths(const std::string& root, const std::vector<std::string>& paths);
CommandResult commit(const std::string& root, const std::string& message, bool amend = false);
/// Applies a patch from patchForHunk to the index, or reverses it in the working tree.
CommandResult applyPatch(const std::string& root, const std::string& patch, bool toIndex, bool reverse);

// ---- Branches and remotes

CommandResult push(const std::string& root, bool hasUpstream);
CommandResult pull(const std::string& root);
CommandResult fetch(const std::string& root);
CommandResult switchBranch(const std::string& root, const std::string& name);
CommandResult createBranch(const std::string& root, const std::string& name);

// ---- Repository setup

CommandResult initRepository(const std::string& directory);
/// Looks only at the folder's top level (Xcode, CMake, Node, Python, Rust...) plus .DS_Store.
std::string suggestedGitignore(const std::string& folder);
/// Returns false if a .gitignore already exists.
bool writeGitignoreIfMissing(const std::string& folder, const std::string& contents);

// ---- GitHub (through the `gh` tool)

GitHubState readGitHubState();
/// "owner/name" of the "origin" remote, or empty.
std::string readOriginRepository(const std::string& root);
/// Creates the repository on GitHub, adds it as "origin" and pushes.
CommandResult publishToGitHub(const std::string& root, const std::string& name, bool isPrivate,
                              const std::string& description);
CommandResult createPullRequest(const std::string& root, const std::string& title, const std::string& body);

}  // namespace gw::git
