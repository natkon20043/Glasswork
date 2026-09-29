#pragma once

#include <optional>
#include <string>
#include <vector>

namespace gw::git {

/// What happened to one file, as git reports it in each of the two columns of
/// `git status`: the staged column ("index") and the working-tree column.
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

struct FileChange {
    /// Path relative to the repository root, with "/" separators.
    std::string path;
    /// For renames and copies, where the file used to be.
    std::string originalPath;
    ChangeKind staged = ChangeKind::None;
    ChangeKind unstaged = ChangeKind::None;

    bool isUntracked() const { return unstaged == ChangeKind::Untracked; }
    bool isConflicted() const { return staged == ChangeKind::Conflicted; }
    bool hasStagedChange() const { return staged != ChangeKind::None && staged != ChangeKind::Conflicted; }
    bool hasUnstagedChange() const { return unstaged != ChangeKind::None; }
};

struct Status {
    bool isRepository = false;
    /// Absolute path of the repository's top folder.
    std::string root;
    /// Current branch, or empty when HEAD is detached.
    std::string branch;
    /// The commit HEAD points at (full hash), empty in a repository with no commits yet.
    std::string headCommit;
    /// The branch this one tracks, such as "origin/main". Empty if none.
    std::string upstream;
    int ahead = 0;
    int behind = 0;
    /// True if the repository has at least one remote (usually "origin").
    bool hasRemote = false;
    std::vector<FileChange> changes;
    /// True if there were more changes than `changes` holds.
    bool truncated = false;
    /// Non-empty if git failed in some way other than "not a repository".
    std::string error;

    bool hasCommits() const { return !headCommit.empty(); }
    size_t stagedCount() const;
    size_t unstagedCount() const;
};

/// Parses the output of `git status --porcelain=v2 --branch -z`. Kept apart from running
/// git so it can be tested with fixed text. Keeps at most `limit` changes.
Status parseStatus(const std::string& output, size_t limit = 5000);

/// Runs `git status` in `directory` (which may be anywhere inside a repository).
Status readStatus(const std::string& directory);

/// The result of running any git or gh command that changes something.
struct CommandResult {
    bool ok = false;
    std::string output;
    /// What went wrong, in git's own words, when `ok` is false.
    std::string error;
};

// ---- Reading -----------------------------------------------------------------------

/// The content of a file as of the last commit (HEAD). Nullopt if it isn't in HEAD, which
/// is the case for new files and for repositories with no commits.
std::optional<std::string> readHeadFile(const std::string& root, const std::string& relativePath);

/// The unified diff for one file. `staged` selects the staged changes instead of the
/// working-tree ones. For an untracked file the whole file is shown as added.
std::string readDiff(const std::string& root, const std::string& relativePath, bool staged);

struct LogEntry {
    std::string hash;
    std::string shortHash;
    std::string author;
    std::string relativeDate;  // "3 days ago"
    std::string subject;
};
std::vector<LogEntry> readLog(const std::string& root, int count);

/// Every file git knows in `folder` and below (tracked and untracked, but not ignored),
/// relative to `folder`. Empty (with `ok` false) when the folder isn't in a repository.
std::vector<std::string> listFiles(const std::string& folder, bool* ok = nullptr);

/// The whole diff of the working tree (or of what is staged), for summarising a change.
std::string readFullDiff(const std::string& root, bool staged);

/// The full change a commit made: its message, a summary of files, and the patch.
std::string readCommitDiff(const std::string& root, const std::string& hash);

struct Branch {
    std::string name;
    bool isCurrent = false;
    bool isRemote = false;
};
std::vector<Branch> readBranches(const std::string& root);

// ---- Changing ----------------------------------------------------------------------

CommandResult initRepository(const std::string& directory);
/// Lines for a .gitignore that suit what is in the folder (Xcode, CMake, Node, Python,
/// Rust…), plus the ones every project wants (.DS_Store). Only looks at the top level.
std::string suggestedGitignore(const std::string& folder);
/// Writes .gitignore in the folder unless one already exists. Returns false if it exists.
bool writeGitignoreIfMissing(const std::string& folder, const std::string& contents);
CommandResult stagePaths(const std::string& root, const std::vector<std::string>& paths);
CommandResult stageAll(const std::string& root);
CommandResult unstagePaths(const std::string& root, const std::vector<std::string>& paths, bool hasCommits);
/// Throws away working-tree changes to tracked files (cannot be undone).
CommandResult discardPaths(const std::string& root, const std::vector<std::string>& paths);
CommandResult commit(const std::string& root, const std::string& message, bool amend = false);
CommandResult push(const std::string& root, bool hasUpstream);
CommandResult pull(const std::string& root);
CommandResult fetch(const std::string& root);
CommandResult switchBranch(const std::string& root, const std::string& name);
CommandResult createBranch(const std::string& root, const std::string& name);
/// Applies a patch (as produced by patchForHunk) to the index, or reverses it in the
/// working tree. Used for staging and reverting single hunks.
CommandResult applyPatch(const std::string& root, const std::string& patch, bool toIndex, bool reverse);

// ---- GitHub (through the `gh` command line tool) -----------------------------------

struct GitHubState {
    bool ghInstalled = false;
    bool loggedIn = false;
    std::string user;
};
GitHubState readGitHubState();

/// The GitHub address of the "origin" remote as "owner/name", or empty.
std::string readOriginRepository(const std::string& root);

/// Creates a repository on GitHub from the local one, adds it as "origin", and pushes.
CommandResult publishToGitHub(const std::string& root, const std::string& name, bool isPrivate,
                              const std::string& description);

/// Opens a pull request for the current branch with the given title and body.
CommandResult createPullRequest(const std::string& root, const std::string& title, const std::string& body);

}  // namespace gw::git
