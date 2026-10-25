#include "Pty.hpp"

#include <cerrno>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <libproc.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

extern char** environ;

namespace gw {

namespace {

/// Once this much output is waiting to be shown, reading pauses until it is dealt with.
constexpr size_t kMaxUnacknowledged = 8 * 1024 * 1024;

}  // namespace

std::string defaultShell() {
    const char* shell = std::getenv("SHELL");
    if (shell != nullptr && shell[0] == '/' && access(shell, X_OK) == 0) {
        return shell;
    }
    return "/bin/zsh";
}

Pty::Pty() = default;

Pty::~Pty() {
    // The reader stops waiting for the screen to catch up, and makes sure the program ends.
    stopping_.store(true);
    terminate();
    if (reader_.joinable()) {
        if (reader_.get_id() == std::this_thread::get_id()) {
            reader_.detach();
        } else {
            reader_.join();
        }
    }
    if (master_ >= 0) {
        close(master_);
        master_ = -1;
    }
}

bool Pty::start(const PtyOptions& options, std::string* error) {
    if (running_.load()) {
        if (error != nullptr) {
            *error = "already running";
        }
        return false;
    }

    // Everything the child needs is prepared before forking: after a fork, only very simple
    // calls are safe.
    std::string program = options.program;
    if (program.empty()) {
        program = defaultShell();
    }
    std::vector<std::string> argumentStrings = {program};
    if (options.program.empty() && options.arguments.empty()) {
        argumentStrings.push_back("-l");  // a login shell, so the usual profile (PATH, brew…) applies
    }
    argumentStrings.insert(argumentStrings.end(), options.arguments.begin(), options.arguments.end());
    std::vector<char*> arguments;
    for (std::string& argument : argumentStrings) {
        arguments.push_back(argument.data());
    }
    arguments.push_back(nullptr);

    std::vector<std::string> environmentStrings;
    for (char** entry = environ; entry != nullptr && *entry != nullptr; ++entry) {
        environmentStrings.emplace_back(*entry);
    }
    auto setVariable = [&environmentStrings](const std::string& name, const std::string& value) {
        std::string prefix = name + "=";
        for (std::string& entry : environmentStrings) {
            if (entry.compare(0, prefix.size(), prefix) == 0) {
                entry = prefix + value;
                return;
            }
        }
        environmentStrings.push_back(prefix + value);
    };
    auto removeVariable = [&environmentStrings](const std::string& name) {
        std::string prefix = name + "=";
        for (size_t index = 0; index < environmentStrings.size(); ++index) {
            if (environmentStrings[index].compare(0, prefix.size(), prefix) == 0) {
                environmentStrings.erase(environmentStrings.begin() + static_cast<long>(index));
                return;
            }
        }
    };
    setVariable("TERM", "xterm-256color");
    setVariable("COLORTERM", "truecolor");
    setVariable("TERM_PROGRAM", "Glasswork");
    if (std::getenv("LANG") == nullptr) {
        setVariable("LANG", "en_US.UTF-8");
    }
    setVariable("PATH", searchPathForChildren());
    // Not meaningful inside a new terminal.
    removeVariable("TERM_SESSION_ID");
    removeVariable("GLASSWORK_TIMING");
    removeVariable("GLASSWORK_BENCH");
    for (const auto& [name, value] : options.environment) {
        setVariable(name, value);
    }
    std::vector<char*> environment;
    for (std::string& entry : environmentStrings) {
        environment.push_back(entry.data());
    }
    environment.push_back(nullptr);

    std::string folder = options.workingDirectory;
    if (folder.empty()) {
        const char* home = std::getenv("HOME");
        if (home != nullptr) {
            folder = home;
        } else {
            folder = "/";
        }
    }

    struct winsize size = {};
    size.ws_col = static_cast<unsigned short>(std::max(1, options.columns));
    size.ws_row = static_cast<unsigned short>(std::max(1, options.rows));

    int master = -1;
    pid_t child = forkpty(&master, nullptr, nullptr, &size);
    if (child < 0) {
        if (error != nullptr) {
            *error = std::string("could not open a terminal: ") + std::strerror(errno);
        }
        return false;
    }
    if (child == 0) {
        // In the child: go to the folder and become the program.
        if (chdir(folder.c_str()) != 0) {
            (void)chdir("/");
        }
        execve(program.c_str(), arguments.data(), environment.data());
        _exit(127);
    }

    master_ = master;
    processId_ = child;
    unacknowledged_.store(0);
    stopping_.store(false);
    running_.store(true);
    reader_ = std::thread([this] { readLoop(); });
    return true;
}

void Pty::write(std::string_view bytes) {
    std::lock_guard<std::mutex> lock(writeMutex_);
    if (master_ < 0 || !running_.load()) {
        return;
    }
    size_t written = 0;
    while (written < bytes.size()) {
        ssize_t count = ::write(master_, bytes.data() + written, bytes.size() - written);
        if (count > 0) {
            written += static_cast<size_t>(count);
        } else if (count < 0 && (errno == EINTR || errno == EAGAIN)) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        } else {
            return;
        }
    }
}

void Pty::resize(int columns, int rows, int pixelWidth, int pixelHeight) {
    if (master_ < 0) {
        return;
    }
    struct winsize size = {};
    size.ws_col = static_cast<unsigned short>(std::max(1, columns));
    size.ws_row = static_cast<unsigned short>(std::max(1, rows));
    size.ws_xpixel = static_cast<unsigned short>(pixelWidth);
    size.ws_ypixel = static_cast<unsigned short>(pixelHeight);
    ioctl(master_, TIOCSWINSZ, &size);
}

void Pty::terminate() {
    if (running_.load() && processId_ > 0) {
        kill(processId_, SIGHUP);
    }
}

void Pty::acknowledge(size_t bytes) {
    size_t current = unacknowledged_.load();
    while (true) {
        size_t next = 0;
        if (current > bytes) {
            next = current - bytes;
        }
        if (unacknowledged_.compare_exchange_weak(current, next)) {
            break;
        }
    }
}

std::string Pty::foregroundProcessName() const {
    if (master_ < 0) {
        return std::string();
    }
    pid_t group = tcgetpgrp(master_);
    if (group <= 0) {
        return std::string();
    }
    char name[64] = {0};
    if (proc_name(group, name, sizeof name) <= 0) {
        return std::string();
    }
    return name;
}

std::string Pty::currentDirectory() const {
    if (processId_ <= 0) {
        return std::string();
    }
    struct proc_vnodepathinfo info;
    int filled = proc_pidinfo(processId_, PROC_PIDVNODEPATHINFO, 0, &info, sizeof info);
    if (filled != sizeof info) {
        return std::string();
    }
    return info.pvi_cdir.vip_path;
}

void Pty::readLoop() {
    std::vector<char> buffer(64 * 1024);
    int status = 0;
    bool exited = false;

    while (!stopping_.load()) {
        // Pause while the screen is far behind (but not once the terminal is going away: nothing
        // will catch up then).
        while (unacknowledged_.load() > kMaxUnacknowledged && !stopping_.load()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(2));
        }
        pollfd watched = {master_, POLLIN, 0};
        int ready = poll(&watched, 1, 100);
        if (ready > 0 && (watched.revents & (POLLIN | POLLHUP))) {
            ssize_t count = read(master_, buffer.data(), buffer.size());
            if (count > 0) {
                unacknowledged_.fetch_add(static_cast<size_t>(count));
                if (onOutput) {
                    onOutput(std::string_view(buffer.data(), static_cast<size_t>(count)));
                }
                continue;
            }
            bool closed = count == 0 || (errno != EINTR && errno != EAGAIN);
            if (closed) {
                break;  // the program closed its end
            }
        }
        if (!exited && waitpid(processId_, &status, WNOHANG) == processId_) {
            exited = true;
        }
        if (exited && ready <= 0) {
            break;
        }
        if (ready < 0 && errno != EINTR) {
            break;
        }
    }

    if (!exited) {
        // The program closed the terminal, or the terminal is going away; collect it (it may need
        // a moment to finish), and end it if it won't.
        for (int attempt = 0; attempt < 50 && !exited; ++attempt) {
            if (waitpid(processId_, &status, WNOHANG) == processId_) {
                exited = true;
                break;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(20));
        }
        if (!exited) {
            kill(processId_, SIGKILL);
            waitpid(processId_, &status, 0);
        }
    }
    running_.store(false);
    if (onExit) {
        onExit(exitCodeFromStatus(status));
    }
}

}  // namespace gw
