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

/// (name, value) pairs.
using EnvironmentOverrides = std::vector<std::pair<std::string, std::string>>;

struct ProcessOptions {
    /// Empty: inherit ours.
    std::string workingDirectory;
    /// Added to or replacing the program's environment.
    EnvironmentOverrides environment;
    /// Written to standard input, which is then closed.
    std::string input;
    /// Zero waits forever.
    double timeoutSeconds = 0;
    /// Output beyond this is dropped.
    size_t maxOutputBytes = 64 * 1024 * 1024;
};

struct ProcessResult {
    bool succeeded() const { return started && !timedOut && exitCode == 0; }

    /// False if the program couldn't start at all.
    bool started = false;
    int exitCode = -1;
    bool timedOut = false;
    std::string output;
    std::string errorOutput;
    /// Why it couldn't start, when `started` is false.
    std::string startError;
};

/// Also searches Homebrew, MacPorts and per-user install folders, since GUI apps get a short PATH.
/// Empty if not found.
std::string findExecutable(const std::string& name);

/// Our PATH plus the usual extra install folders.
std::string searchPathForChildren();

/// Waits and collects output. Blocking: call from a background queue.
ProcessResult runProcess(const std::vector<std::string>& argv, const ProcessOptions& options = {});

/// A long-running child with a live two-way conversation over its pipes. Output arrives through
/// callbacks on a background thread.
class ChildProcess {
public:
    // ---- Constructors and destructor
    ChildProcess();
    ~ChildProcess();
    ChildProcess(const ChildProcess&) = delete;
    ChildProcess& operator=(const ChildProcess&) = delete;

    // ---- Lifecycle
    bool start(const std::vector<std::string>& argv, const ProcessOptions& options, std::string* error = nullptr);
    /// SIGTERM, then a kill if it hasn't stopped after a moment.
    void terminate();

    // ---- Input
    /// Safe from any thread.
    bool write(std::string_view bytes);
    /// Many programs finish up when standard input closes.
    void closeInput();

    // ---- Getters
    bool isRunning() const { return running_.load(); }

    // ---- Callbacks
    /// Whatever chunks the pipe delivers, not line by line.
    std::function<void(std::string_view)> onOutput;
    std::function<void(std::string_view)> onErrorOutput;
    /// Once, after the program ends and all output is delivered. Exit code, or 128 + signal.
    std::function<void(int)> onExit;

private:
    // ---- Private functions
    void readLoop();

    // ---- Private variables
    int processId_ = -1;
    int inputDescriptor_ = -1;
    int outputDescriptor_ = -1;
    int errorDescriptor_ = -1;
    std::atomic<bool> running_{false};
    std::mutex writeMutex_;
    std::thread reader_;
};

}  // namespace gw
