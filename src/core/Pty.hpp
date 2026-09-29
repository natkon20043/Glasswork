#pragma once

#include "Process.hpp"

#include <atomic>
#include <functional>
#include <mutex>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

namespace gw {

struct PtyOptions {
    /// The program to run. Empty means the user's shell ($SHELL, else zsh).
    std::string program;
    std::vector<std::string> arguments;
    /// Where it starts. Empty means the home folder.
    std::string workingDirectory;
    EnvironmentOverrides environment;
    int columns = 80;
    int rows = 24;
};

/// A program running inside a pseudo-terminal, the way Terminal.app runs your shell. What it
/// prints arrives through `onOutput` on a background thread; `write` sends it keystrokes.
class Pty {
public:
    Pty();
    ~Pty();
    Pty(const Pty&) = delete;
    Pty& operator=(const Pty&) = delete;

    std::function<void(std::string_view)> onOutput;
    /// Called once when the program ends, with its exit code (128 + signal if it was killed).
    std::function<void(int)> onExit;

    bool start(const PtyOptions& options, std::string* error = nullptr);
    void write(std::string_view bytes);
    void resize(int columns, int rows, int pixelWidth = 0, int pixelHeight = 0);
    /// Hangs the program up (SIGHUP), which ends a shell.
    void terminate();

    bool isRunning() const { return running_.load(); }
    int processId() const { return processId_; }

    /// The name of the program in the foreground ("zsh", "vim", "node"), or empty.
    std::string foregroundProcessName() const;
    /// The folder the shell is in right now, or empty.
    std::string currentDirectory() const;

    /// Tell the pty how much output has been dealt with. The reader pauses when too much is
    /// waiting, so a program printing gigabytes can't flood memory.
    void acknowledge(size_t bytes);

private:
    void readLoop();

    int master_ = -1;
    int processId_ = -1;
    std::atomic<bool> running_{false};
    std::atomic<size_t> unacknowledged_{0};
    std::mutex writeMutex_;
    std::thread reader_;
};

/// The default shell for the user.
std::string defaultShell();

}  // namespace gw
