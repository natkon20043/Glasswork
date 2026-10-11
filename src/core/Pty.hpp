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
    /// Empty: the user's shell ($SHELL, else zsh).
    std::string program;
    std::vector<std::string> arguments;
    /// Empty: the home folder.
    std::string workingDirectory;
    EnvironmentOverrides environment;
    int columns = 80;
    int rows = 24;
};

/// A program running inside a pseudo-terminal. Output arrives through `onOutput` on a background
/// thread; `write` sends it keystrokes.
class Pty {
public:
    // ---- Constructors and destructor
    Pty();
    ~Pty();
    Pty(const Pty&) = delete;
    Pty& operator=(const Pty&) = delete;

    // ---- Lifecycle
    bool start(const PtyOptions& options, std::string* error = nullptr);
    /// SIGHUP, which ends a shell.
    void terminate();

    // ---- Input and size
    void write(std::string_view bytes);
    void resize(int columns, int rows, int pixelWidth = 0, int pixelHeight = 0);
    /// Reports output as handled. The reader pauses when too much is waiting, so huge output can't flood memory.
    void acknowledge(size_t bytes);

    // ---- Getters
    bool isRunning() const { return running_.load(); }
    int processId() const { return processId_; }
    /// Foreground program ("zsh", "vim", "node"), or empty.
    std::string foregroundProcessName() const;
    std::string currentDirectory() const;

    // ---- Callbacks
    std::function<void(std::string_view)> onOutput;
    /// Exit code, or 128 + signal if killed.
    std::function<void(int)> onExit;

private:
    // ---- Private functions
    void readLoop();

    // ---- Private variables
    int master_ = -1;
    int processId_ = -1;
    std::atomic<bool> running_{false};
    std::atomic<size_t> unacknowledged_{0};
    std::mutex writeMutex_;
    std::thread reader_;
};

std::string defaultShell();

}  // namespace gw
