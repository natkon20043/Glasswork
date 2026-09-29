// Tests for the process runner, the line diff and the git layer.

#include "TestHarness.hpp"

#include "Git.hpp"
#include "LineDiff.hpp"
#include "Process.hpp"

#include <atomic>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <random>
#include <thread>
#include <unistd.h>

namespace {

using gw::DiffHunk;
using gw::LineChange;
using gw::LineChangeKind;

std::vector<std::string_view> viewsOf(const std::vector<std::string>& lines) {
    std::vector<std::string_view> views;
    for (const std::string& line : lines) {
        views.push_back(line);
    }
    return views;
}

/// Applies hunks to the old lines. If the diff is right, the result is the new lines.
std::vector<std::string> applyHunks(const std::vector<std::string>& oldLines, const std::vector<std::string>& newLines,
                                    const std::vector<DiffHunk>& hunks) {
    std::vector<std::string> result;
    size_t oldPosition = 0;
    for (const DiffHunk& hunk : hunks) {
        while (oldPosition < hunk.oldStart) {
            result.push_back(oldLines[oldPosition]);
            ++oldPosition;
        }
        oldPosition += hunk.oldCount;
        for (size_t index = 0; index < hunk.newCount; ++index) {
            result.push_back(newLines[hunk.newStart + index]);
        }
    }
    while (oldPosition < oldLines.size()) {
        result.push_back(oldLines[oldPosition]);
        ++oldPosition;
    }
    return result;
}

/// Length of the longest common subsequence, the slow textbook way. The best possible diff
/// keeps exactly this many lines.
size_t longestCommonSubsequence(const std::vector<std::string>& first, const std::vector<std::string>& second) {
    std::vector<std::vector<size_t>> table(first.size() + 1, std::vector<size_t>(second.size() + 1, 0));
    for (size_t row = 1; row <= first.size(); ++row) {
        for (size_t column = 1; column <= second.size(); ++column) {
            if (first[row - 1] == second[column - 1]) {
                table[row][column] = table[row - 1][column - 1] + 1;
            } else {
                table[row][column] = std::max(table[row - 1][column], table[row][column - 1]);
            }
        }
    }
    return table[first.size()][second.size()];
}

std::string makeTemporaryDirectory(const std::string& label) {
    std::filesystem::path path = std::filesystem::temp_directory_path() /
                                 ("glasswork-" + label + "-" + std::to_string(getpid()) + "-" +
                                  std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    std::filesystem::create_directories(path);
    return std::filesystem::canonical(path).string();
}

void writeFile(const std::string& path, const std::string& text) {
    std::filesystem::create_directories(std::filesystem::path(path).parent_path());
    std::ofstream file(path, std::ios::binary);
    file << text;
}

// ---------------------------------------------------------------------------
// Process

TEST(processCapturesOutputAndExitCode) {
    gw::ProcessResult ok = gw::runProcess({"/bin/sh", "-c", "echo hello; echo oops 1>&2; exit 3"});
    CHECK(ok.started);
    CHECK_EQ(ok.exitCode, 3);
    CHECK_EQ(ok.output, std::string("hello\n"));
    CHECK_EQ(ok.errorOutput, std::string("oops\n"));
    CHECK(!ok.succeeded());

    gw::ProcessResult fine = gw::runProcess({"/bin/echo", "a b"});
    CHECK(fine.succeeded());
    CHECK_EQ(fine.output, std::string("a b\n"));
}

TEST(processFeedsInputAndHandlesLargeOutput) {
    gw::ProcessOptions options;
    options.input = std::string(300000, 'x');
    gw::ProcessResult echoed = gw::runProcess({"/bin/cat"}, options);
    CHECK(echoed.succeeded());
    CHECK_EQ(echoed.output.size(), size_t(300000));
}

TEST(processReportsMissingProgramsAndTimeouts) {
    gw::ProcessResult missing = gw::runProcess({"definitely-not-a-real-program-xyz"});
    CHECK(!missing.started);
    CHECK(!missing.startError.empty());

    gw::ProcessOptions options;
    options.timeoutSeconds = 0.3;
    auto begin = std::chrono::steady_clock::now();
    gw::ProcessResult slow = gw::runProcess({"/bin/sleep", "20"}, options);
    double seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - begin).count();
    CHECK(slow.timedOut);
    CHECK(seconds < 5);
}

TEST(processUsesWorkingDirectoryAndEnvironment) {
    std::string directory = makeTemporaryDirectory("cwd");
    gw::ProcessOptions options;
    options.workingDirectory = directory;
    options.environment = {{"GLASSWORK_TEST_VALUE", "banana"}};
    gw::ProcessResult result = gw::runProcess({"/bin/sh", "-c", "pwd; echo $GLASSWORK_TEST_VALUE"}, options);
    CHECK(result.succeeded());
    CHECK_EQ(result.output, directory + "\nbanana\n");
    std::filesystem::remove_all(directory);
}

TEST(childProcessStreamsBothWays) {
    gw::ChildProcess child;
    std::mutex lock;
    std::string received;
    std::atomic<int> exitCode{-999};
    child.onOutput = [&](std::string_view bytes) {
        std::lock_guard<std::mutex> guard(lock);
        received.append(bytes);
    };
    child.onExit = [&](int code) { exitCode.store(code); };

    std::string error;
    CHECK(child.start({"/bin/cat"}, {}, &error));
    CHECK(child.write("first\n"));
    CHECK(child.write("second\n"));
    child.closeInput();

    for (int attempt = 0; attempt < 100 && exitCode.load() == -999; ++attempt) {
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    CHECK_EQ(exitCode.load(), 0);
    std::lock_guard<std::mutex> guard(lock);
    CHECK_EQ(received, std::string("first\nsecond\n"));
}

TEST(childProcessCanBeTerminated) {
    gw::ChildProcess child;
    std::atomic<int> exitCode{-999};
    child.onExit = [&](int code) { exitCode.store(code); };
    CHECK(child.start({"/bin/sleep", "60"}, {}));
    CHECK(child.isRunning());
    child.terminate();
    for (int attempt = 0; attempt < 100 && exitCode.load() == -999; ++attempt) {
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    CHECK(exitCode.load() != -999);
    CHECK(!child.isRunning());
}

// ---------------------------------------------------------------------------
// Line diff

TEST(splitLinesHandlesEndingsAndTrailingNewline) {
    CHECK_EQ(gw::splitLines("").size(), size_t(0));
    CHECK_EQ(gw::splitLines("a").size(), size_t(1));
    CHECK_EQ(gw::splitLines("a\nb\n").size(), size_t(2));
    CHECK_EQ(gw::splitLines("a\r\nb\r\n").size(), size_t(2));
    CHECK_EQ(gw::splitLines("a\r\nb\r\n")[0], std::string_view("a"));
    CHECK_EQ(gw::splitLines("a\n\nb").size(), size_t(3));
}

TEST(diffFindsInsertionDeletionAndModification) {
    std::vector<std::string> before = {"a", "b", "c", "d", "e"};

    std::vector<std::string> inserted = {"a", "b", "NEW", "c", "d", "e"};
    auto insertion = gw::diffLines(viewsOf(before), viewsOf(inserted));
    CHECK_EQ(insertion.size(), size_t(1));
    CHECK(insertion[0].oldCount == 0 && insertion[0].newCount == 1 && insertion[0].newStart == 2);

    std::vector<std::string> deleted = {"a", "b", "d", "e"};
    auto deletion = gw::diffLines(viewsOf(before), viewsOf(deleted));
    CHECK_EQ(deletion.size(), size_t(1));
    CHECK(deletion[0].oldCount == 1 && deletion[0].newCount == 0 && deletion[0].oldStart == 2);

    std::vector<std::string> modified = {"a", "b", "C!", "d", "e"};
    auto modification = gw::diffLines(viewsOf(before), viewsOf(modified));
    CHECK_EQ(modification.size(), size_t(1));
    CHECK(modification[0].oldCount == 1 && modification[0].newCount == 1 && modification[0].newStart == 2);

    CHECK(gw::diffLines(viewsOf(before), viewsOf(before)).empty());
}

TEST(diffHandlesEmptyAndCompletelyDifferentTexts) {
    std::vector<std::string> nothing;
    std::vector<std::string> some = {"x", "y"};
    auto created = gw::diffLines(viewsOf(nothing), viewsOf(some));
    CHECK_EQ(created.size(), size_t(1));
    CHECK(created[0].oldCount == 0 && created[0].newCount == 2);

    auto removed = gw::diffLines(viewsOf(some), viewsOf(nothing));
    CHECK_EQ(removed.size(), size_t(1));
    CHECK(removed[0].oldCount == 2 && removed[0].newCount == 0);

    std::vector<std::string> other = {"p", "q", "r"};
    auto replaced = gw::diffLines(viewsOf(some), viewsOf(other));
    CHECK_EQ(replaced.size(), size_t(1));
    CHECK(replaced[0].oldCount == 2 && replaced[0].newCount == 3);
}

TEST(diffIsCorrectAndMinimalOnRandomTexts) {
    std::mt19937 random(12345);
    for (int round = 0; round < 400; ++round) {
        size_t oldSize = random() % 14;
        size_t newSize = random() % 14;
        std::vector<std::string> before;
        std::vector<std::string> after;
        for (size_t index = 0; index < oldSize; ++index) {
            before.push_back(std::string(1, static_cast<char>('a' + random() % 5)));
        }
        for (size_t index = 0; index < newSize; ++index) {
            after.push_back(std::string(1, static_cast<char>('a' + random() % 5)));
        }

        std::vector<DiffHunk> hunks = gw::diffLines(viewsOf(before), viewsOf(after));

        // The hunks must turn the old text into the new one…
        CHECK(applyHunks(before, after, hunks) == after);

        // …and must not discard more lines than necessary.
        size_t removedLines = 0;
        size_t addedLines = 0;
        for (const DiffHunk& hunk : hunks) {
            removedLines += hunk.oldCount;
            addedLines += hunk.newCount;
        }
        size_t common = longestCommonSubsequence(before, after);
        CHECK_EQ(removedLines, before.size() - common);
        CHECK_EQ(addedLines, after.size() - common);
    }
}

TEST(diffScalesToLargeFilesWithSmallEdits) {
    std::vector<std::string> before;
    for (int index = 0; index < 200000; ++index) {
        before.push_back("line number " + std::to_string(index));
    }
    std::vector<std::string> after = before;
    after[100000] = "changed";
    after.insert(after.begin() + 150000, "inserted");
    after.erase(after.begin() + 50000);

    auto begin = std::chrono::steady_clock::now();
    std::vector<DiffHunk> hunks = gw::diffLines(viewsOf(before), viewsOf(after));
    double milliseconds = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - begin).count();
    CHECK_EQ(hunks.size(), size_t(3));
    CHECK(applyHunks(before, after, hunks) == after);
    CHECK(milliseconds < 500);
}

TEST(diffFallsBackToOneBlockWhenEverythingChanged) {
    std::vector<std::string> before;
    std::vector<std::string> after;
    for (int index = 0; index < 6000; ++index) {
        before.push_back("old " + std::to_string(index));
        after.push_back("new " + std::to_string(index));
    }
    std::vector<DiffHunk> hunks = gw::diffLines(viewsOf(before), viewsOf(after));
    CHECK_EQ(hunks.size(), size_t(1));
    CHECK(applyHunks(before, after, hunks) == after);
}

TEST(gutterChangesClassifyHunks) {
    std::vector<DiffHunk> hunks = {
        {2, 0, 2, 3},   // three lines added at line 2
        {10, 2, 13, 0}, // two lines deleted: marker at new line 13
        {20, 2, 23, 4}, // two lines became four: 2 modified + 2 added
        {40, 3, 43, 1}, // three lines became one: 1 modified + removed marker
    };
    std::vector<LineChange> changes = gw::gutterChanges(hunks);
    CHECK_EQ(changes.size(), size_t(6));
    CHECK(changes[0].kind == LineChangeKind::Added && changes[0].firstLine == 2 && changes[0].lineCount == 3);
    CHECK(changes[1].kind == LineChangeKind::Removed && changes[1].firstLine == 13);
    CHECK(changes[2].kind == LineChangeKind::Modified && changes[2].firstLine == 23 && changes[2].lineCount == 2);
    CHECK(changes[3].kind == LineChangeKind::Added && changes[3].firstLine == 25 && changes[3].lineCount == 2);
    CHECK(changes[4].kind == LineChangeKind::Modified && changes[4].firstLine == 43 && changes[4].lineCount == 1);
    CHECK(changes[5].kind == LineChangeKind::Removed && changes[5].firstLine == 44);
}

// ---------------------------------------------------------------------------
// Git

TEST(statusParserReadsBranchAndEntries) {
    std::string output;
    output += "# branch.oid 1234567890abcdef1234567890abcdef12345678";
    output += std::string(1, '\0');
    output += "# branch.head main";
    output += std::string(1, '\0');
    output += "# branch.upstream origin/main";
    output += std::string(1, '\0');
    output += "# branch.ab +2 -1";
    output += std::string(1, '\0');
    output += "1 .M N... 100644 100644 100644 aaaa bbbb src/edited file.cpp";
    output += std::string(1, '\0');
    output += "1 A. N... 000000 100644 100644 0000 cccc added.txt";
    output += std::string(1, '\0');
    output += "1 MM N... 100644 100644 100644 dddd eeee both.txt";
    output += std::string(1, '\0');
    output += "2 R. N... 100644 100644 100644 ffff gggg R100 new name.txt";
    output += std::string(1, '\0');
    output += "old name.txt";
    output += std::string(1, '\0');
    output += "u UU N... 100644 100644 100644 100644 h1 h2 h3 conflict.txt";
    output += std::string(1, '\0');
    output += "? untracked.txt";
    output += std::string(1, '\0');
    output += "! ignored.o";
    output += std::string(1, '\0');

    gw::git::Status status = gw::git::parseStatus(output);
    CHECK(status.isRepository);
    CHECK_EQ(status.branch, std::string("main"));
    CHECK_EQ(status.upstream, std::string("origin/main"));
    CHECK_EQ(status.ahead, 2);
    CHECK_EQ(status.behind, 1);
    CHECK(status.hasCommits());
    CHECK_EQ(status.changes.size(), size_t(6));

    CHECK_EQ(status.changes[0].path, std::string("src/edited file.cpp"));
    CHECK(status.changes[0].unstaged == gw::git::ChangeKind::Modified);
    CHECK(!status.changes[0].hasStagedChange());

    CHECK(status.changes[1].staged == gw::git::ChangeKind::Added);
    CHECK(!status.changes[1].hasUnstagedChange());

    CHECK(status.changes[2].hasStagedChange() && status.changes[2].hasUnstagedChange());

    CHECK(status.changes[3].staged == gw::git::ChangeKind::Renamed);
    CHECK_EQ(status.changes[3].path, std::string("new name.txt"));
    CHECK_EQ(status.changes[3].originalPath, std::string("old name.txt"));

    CHECK(status.changes[4].isConflicted());
    CHECK(status.changes[5].isUntracked());
    CHECK_EQ(status.stagedCount(), size_t(3));
}

TEST(statusParserHandlesDetachedHeadAndNoCommits) {
    std::string output = std::string("# branch.oid (initial)") + '\0' + "# branch.head (detached)" + '\0';
    gw::git::Status status = gw::git::parseStatus(output);
    CHECK(!status.hasCommits());
    CHECK(status.branch.empty());
}

TEST(statusParserTruncatesHugeChangeLists) {
    std::string output;
    for (int index = 0; index < 50; ++index) {
        output += "? file" + std::to_string(index);
        output += std::string(1, '\0');
    }
    gw::git::Status status = gw::git::parseStatus(output, 10);
    CHECK_EQ(status.changes.size(), size_t(10));
    CHECK(status.truncated);
}

TEST(gitWorkflowInARealRepository) {
    if (gw::findExecutable("git").empty()) {
        return;
    }
    std::string root = makeTemporaryDirectory("repo");

    // Not a repository yet.
    CHECK(!gw::git::readStatus(root).isRepository);

    CHECK(gw::git::initRepository(root).ok);
    gw::ProcessOptions options;
    options.workingDirectory = root;
    gw::runProcess({"git", "config", "user.name", "Test User"}, options);
    gw::runProcess({"git", "config", "user.email", "test@example.com"}, options);
    gw::runProcess({"git", "config", "commit.gpgsign", "false"}, options);

    writeFile(root + "/one.txt", "alpha\nbeta\ngamma\n");
    writeFile(root + "/folder/two.txt", "hello\n");

    gw::git::Status fresh = gw::git::readStatus(root);
    CHECK(fresh.isRepository);
    CHECK_EQ(fresh.root, root);
    CHECK(!fresh.hasCommits());
    CHECK_EQ(fresh.changes.size(), size_t(2));
    CHECK(fresh.changes[0].isUntracked());

    // Stage one file, then unstage it again (before the first commit exists).
    CHECK(gw::git::stagePaths(root, {"one.txt"}).ok);
    CHECK_EQ(gw::git::readStatus(root).stagedCount(), size_t(1));
    CHECK(gw::git::unstagePaths(root, {"one.txt"}, false).ok);
    CHECK_EQ(gw::git::readStatus(root).stagedCount(), size_t(0));

    CHECK(gw::git::stageAll(root).ok);
    gw::git::CommandResult committed = gw::git::commit(root, "First commit\n\nWith a body.");
    CHECK(committed.ok);

    gw::git::Status clean = gw::git::readStatus(root);
    CHECK(clean.hasCommits());
    CHECK_EQ(clean.branch, std::string("main"));
    CHECK(clean.changes.empty());

    // The HEAD version of a file, for the gutter.
    std::optional<std::string> head = gw::git::readHeadFile(root, "one.txt");
    CHECK(head.has_value() && *head == "alpha\nbeta\ngamma\n");
    CHECK(!gw::git::readHeadFile(root, "missing.txt").has_value());

    // Modify a file and look at the diff.
    writeFile(root + "/one.txt", "alpha\nBETA\ngamma\ndelta\n");
    gw::git::Status modified = gw::git::readStatus(root);
    CHECK_EQ(modified.changes.size(), size_t(1));
    CHECK(modified.changes[0].unstaged == gw::git::ChangeKind::Modified);
    std::string diff = gw::git::readDiff(root, "one.txt", false);
    CHECK(diff.find("-beta") != std::string::npos);
    CHECK(diff.find("+BETA") != std::string::npos);

    // Stage just one hunk with a generated patch, and see the split between staged and not.
    std::string worktree = "alpha\nBETA\ngamma\ndelta\n";
    std::vector<std::string_view> oldLines = gw::splitLines(*head);
    std::vector<std::string_view> newLines = gw::splitLines(worktree);
    std::vector<DiffHunk> hunks = gw::diffLines(oldLines, newLines);
    CHECK_EQ(hunks.size(), size_t(2));
    std::string patch = gw::patchForHunk("one.txt", oldLines, newLines, hunks[0]);
    gw::git::CommandResult applied = gw::git::applyPatch(root, patch, true, false);
    CHECK(applied.ok);
    if (!applied.ok) {
        std::printf("    apply error: %s\n", applied.error.c_str());
    }
    gw::git::Status partial = gw::git::readStatus(root);
    CHECK(partial.changes.size() == 1 && partial.changes[0].hasStagedChange() && partial.changes[0].hasUnstagedChange());

    // Discard the working changes.
    CHECK(gw::git::stageAll(root).ok);
    CHECK(gw::git::unstagePaths(root, {"one.txt"}, true).ok);
    CHECK(gw::git::discardPaths(root, {"one.txt"}).ok);
    CHECK(gw::git::readStatus(root).changes.empty());

    // Branches and the log.
    CHECK(gw::git::createBranch(root, "feature/x").ok);
    CHECK_EQ(gw::git::readStatus(root).branch, std::string("feature/x"));
    CHECK(gw::git::switchBranch(root, "main").ok);
    std::vector<gw::git::Branch> branches = gw::git::readBranches(root);
    CHECK_EQ(branches.size(), size_t(2));
    bool currentIsMain = false;
    for (const gw::git::Branch& branch : branches) {
        if (branch.isCurrent && branch.name == "main") {
            currentIsMain = true;
        }
    }
    CHECK(currentIsMain);

    std::vector<gw::git::LogEntry> log = gw::git::readLog(root, 10);
    CHECK_EQ(log.size(), size_t(1));
    CHECK_EQ(log[0].subject, std::string("First commit"));
    CHECK_EQ(log[0].author, std::string("Test User"));

    // Pushing with no remote explains itself instead of hanging.
    gw::git::CommandResult pushed = gw::git::push(root, false);
    CHECK(!pushed.ok);
    CHECK(pushed.error.find("no remote") != std::string::npos);

    std::filesystem::remove_all(root);
}

TEST(gitignoreSuggestionMatchesTheProject) {
    std::string folder = makeTemporaryDirectory("ignore");
    writeFile(folder + "/CMakeLists.txt", "project(x)\n");
    writeFile(folder + "/package.json", "{}\n");
    std::filesystem::create_directories(folder + "/App.xcodeproj");

    std::string text = gw::git::suggestedGitignore(folder);
    CHECK(text.find(".DS_Store") != std::string::npos);
    CHECK(text.find("build/") != std::string::npos);
    CHECK(text.find("node_modules/") != std::string::npos);
    CHECK(text.find("DerivedData/") != std::string::npos);
    CHECK(text.find("target/") == std::string::npos);  // no Rust here

    CHECK(gw::git::writeGitignoreIfMissing(folder, text));
    CHECK(!gw::git::writeGitignoreIfMissing(folder, "overwritten?"));  // never replaces an existing file
    std::ifstream file(folder + "/.gitignore");
    std::string written((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
    CHECK_EQ(written, text);
    std::filesystem::remove_all(folder);
}

TEST(commitDiffShowsWhatACommitChanged) {
    if (gw::findExecutable("git").empty()) {
        return;
    }
    std::string root = makeTemporaryDirectory("show");
    gw::git::initRepository(root);
    gw::ProcessOptions options;
    options.workingDirectory = root;
    gw::runProcess({"git", "config", "user.name", "Test User"}, options);
    gw::runProcess({"git", "config", "user.email", "test@example.com"}, options);
    gw::runProcess({"git", "config", "commit.gpgsign", "false"}, options);
    writeFile(root + "/a.txt", "hello\n");
    gw::git::stageAll(root);
    gw::git::commit(root, "Add a");

    std::vector<gw::git::LogEntry> log = gw::git::readLog(root, 5);
    CHECK_EQ(log.size(), size_t(1));
    std::string diff = gw::git::readCommitDiff(root, log[0].hash);
    CHECK(diff.find("Add a") != std::string::npos);
    CHECK(diff.find("+hello") != std::string::npos);
    std::filesystem::remove_all(root);
}

TEST(listFilesRespectsGitignore) {
    if (gw::findExecutable("git").empty()) {
        return;
    }
    std::string root = makeTemporaryDirectory("listfiles");
    gw::git::initRepository(root);
    writeFile(root + "/.gitignore", "build/\n*.log\n");
    writeFile(root + "/src/main.cpp", "int main() {}\n");
    writeFile(root + "/build/out.o", "binary\n");
    writeFile(root + "/debug.log", "log\n");
    writeFile(root + "/notes.txt", "notes\n");

    bool ok = false;
    std::vector<std::string> files = gw::git::listFiles(root, &ok);
    CHECK(ok);
    std::sort(files.begin(), files.end());
    CHECK_EQ(files.size(), size_t(3));  // .gitignore, notes.txt, src/main.cpp
    CHECK_EQ(files[2], std::string("src/main.cpp"));

    // Inside a sub-folder the paths are relative to it.
    std::vector<std::string> inside = gw::git::listFiles(root + "/src", &ok);
    CHECK(ok && inside.size() == 1 && inside[0] == "main.cpp");

    std::string plain = makeTemporaryDirectory("plain");
    gw::git::listFiles(plain, &ok);
    CHECK(!ok);
    std::filesystem::remove_all(root);
    std::filesystem::remove_all(plain);
}

TEST(originRepositoryNameIsParsedFromUrls) {
    if (gw::findExecutable("git").empty()) {
        return;
    }
    std::string root = makeTemporaryDirectory("origin");
    gw::git::initRepository(root);
    gw::ProcessOptions options;
    options.workingDirectory = root;

    gw::runProcess({"git", "remote", "add", "origin", "https://github.com/natkon20043/GlassDesk.git"}, options);
    CHECK_EQ(gw::git::readOriginRepository(root), std::string("natkon20043/GlassDesk"));

    gw::runProcess({"git", "remote", "set-url", "origin", "git@github.com:someone/thing.git"}, options);
    CHECK_EQ(gw::git::readOriginRepository(root), std::string("someone/thing"));

    gw::runProcess({"git", "remote", "set-url", "origin", "https://example.com/other/repo.git"}, options);
    CHECK_EQ(gw::git::readOriginRepository(root), std::string());
    std::filesystem::remove_all(root);
}

}  // namespace

int main() {
    return harness::runAllTests();
}
