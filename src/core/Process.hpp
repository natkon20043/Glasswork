#pragma once

#include <atomic>
#include <functional>
#include <mutex>
#include <string>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>

namespace gw {

/// Environment variable overrides, as (name, value) pairs.
using EnvironmentOverrides = std::vector<std::pair<std::string, std::string>>;

struct ProcessOptions {
    /// Directory the program runs in. Empty means "inherit ours".
    std::string workingDirectory;
    /// Added to (or replacing) the environment the program starts with.
    EnvironmentOverrides environment;
    /// Bytes written to the program's standard input, which is then closed.
    std::string input;
    /// Kill the program after this many seconds. Zero means wait forever.
    double timeoutSeconds = 0;
    /// Output beyond this many bytes is dropped (protects against runaway commands).
    size_t maxOutputBytes = 64 * 1024 * 1024;
};

struct ProcessResult {
    /// False if the program could not be started at all (not found, no permission…).
    bool started = false;
    int exitCode = -1;
    bool timedOut = false;
    std::string output;       // standard output
    std::string errorOutput;  // standard error
    /// Why it could not start, when `started` is false.
    std::string startError;

    bool succeeded() const { return started && !timedOut && exitCode == 0; }
};

/// Finds a program by name. GUI apps start with a very short PATH, so besides $PATH this
/// also looks in the usual Homebrew, MacPorts and per-user install folders.
/// Returns an empty string if it isn't found anywhere.
std::string findExecutable(const std::string& name);

/// The PATH child programs should get: ours plus the usual extra install folders.
std::string searchPathForChildren();

/// Runs `argv[0]` with the arguments and waits for it to finish, collecting its output.
/// Blocking: call it from a background queue, never from the UI thread.
ProcessResult runProcess(const std::vector<std::string>& argv, const ProcessOptions& options = {});

/// A long-running child program with a live, two-way conversation over its pipes. Output
/// arrives through callbacks on a background thread. Used for the Claude session, and by
/// anything else that needs to stream.
class ChildProcess {
public:
    ChildProcess();
    ~ChildProcess();
    ChildProcess(const ChildProcess&) = delete;
    ChildProcess& operator=(const ChildProcess&) = delete;

    /// Standard output arrives in whatever chunks the pipe delivers, not line by line.
    std::function<void(std::string_view)> onOutput;
    std::function<void(std::string_view)> onErrorOutput;
    /// Called once, after the program ends and all output has been delivered.
    /// The value is the exit code, or 128 + signal number if it was killed.
    std::function<void(int)> onExit;

    /// Starts the program. Returns false and fills `error` if that fails.
    bool start(const std::vector<std::string>& argv, const ProcessOptions& options, std::string* error = nullptr);

    /// Sends bytes to the program's standard input. Safe to call from any thread.
    bool write(std::string_view bytes);
    /// Closes standard input, which tells many programs to finish up.
    void closeInput();

    /// Asks the program to stop (SIGTERM), and kills it if it hasn't after a moment.
    void terminate();

    bool isRunning() const { return running_.load(); }

private:
    void readLoop();

    int processId_ = -1;
    int inputDescriptor_ = -1;
    int outputDescriptor_ = -1;
    int errorDescriptor_ = -1;
    std::atomic<bool> running_{false};
    std::mutex writeMutex_;
    std::thread reader_;
};

}  // namespace gw
