#include "Process.hpp"

#include <cerrno>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <poll.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

extern char** environ;

namespace gw {

namespace {

// ---------------------------------------------------------------------------
// Small helpers

bool isExecutableFile(const std::string& path) {
    struct stat info;
    if (stat(path.c_str(), &info) != 0) {
        return false;
    }
    bool isRegularFile = S_ISREG(info.st_mode);
    bool canExecute = access(path.c_str(), X_OK) == 0;
    return isRegularFile && canExecute;
}

std::vector<std::string> splitPath(const std::string& path) {
    std::vector<std::string> parts;
    size_t start = 0;
    while (start <= path.size()) {
        size_t colon = path.find(':', start);
        if (colon == std::string::npos) {
            colon = path.size();
        }
        if (colon > start) {
            parts.push_back(path.substr(start, colon - start));
        }
        start = colon + 1;
    }
    return parts;
}

std::vector<std::string> extraSearchFolders() {
    std::vector<std::string> folders = {
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/local/sbin",
        "/opt/local/bin",
    };
    const char* home = std::getenv("HOME");
    if (home != nullptr) {
        std::string homeFolder = home;
        folders.push_back(homeFolder + "/.local/bin");
        folders.push_back(homeFolder + "/.cargo/bin");
        folders.push_back(homeFolder + "/bin");
    }
    return folders;
}

void closeDescriptor(int& descriptor) {
    if (descriptor >= 0) {
        close(descriptor);
        descriptor = -1;
    }
}

void makeNonBlocking(int descriptor) {
    int flags = fcntl(descriptor, F_GETFL, 0);
    fcntl(descriptor, F_SETFL, flags | O_NONBLOCK);
}

void makeCloseOnExec(int descriptor) {
    int flags = fcntl(descriptor, F_GETFD, 0);
    fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC);
}

/// The environment the child gets: ours, with a fuller PATH, then the caller's overrides.
std::vector<std::string> buildEnvironment(const EnvironmentOverrides& overrides) {
    std::vector<std::string> entries;
    for (char** entry = environ; entry != nullptr && *entry != nullptr; ++entry) {
        entries.emplace_back(*entry);
    }

    auto setVariable = [&entries](const std::string& name, const std::string& value) {
        std::string prefix = name + "=";
        for (std::string& entry : entries) {
            if (entry.compare(0, prefix.size(), prefix) == 0) {
                entry = prefix + value;
                return;
            }
        }
        entries.push_back(prefix + value);
    };

    setVariable("PATH", searchPathForChildren());
    for (const auto& [name, value] : overrides) {
        setVariable(name, value);
    }
    return entries;
}

/// Starts the program with its three standard streams connected to the given descriptors.
/// The child gets its own process group so the whole tree can be stopped together.
bool spawnProgram(const std::vector<std::string>& argv, const ProcessOptions& options, int childInput, int childOutput,
                  int childError, int& processId, std::string& error) {
    if (argv.empty()) {
        error = "no program to run";
        return false;
    }

    std::string program = argv[0];
    if (program.find('/') == std::string::npos) {
        program = findExecutable(program);
        if (program.empty()) {
            error = "could not find \"" + argv[0] + "\"";
            return false;
        }
    }

    std::vector<char*> arguments;
    for (const std::string& argument : argv) {
        arguments.push_back(const_cast<char*>(argument.c_str()));
    }
    arguments.push_back(nullptr);

    std::vector<std::string> environmentStrings = buildEnvironment(options.environment);
    std::vector<char*> environment;
    for (std::string& entry : environmentStrings) {
        environment.push_back(entry.data());
    }
    environment.push_back(nullptr);

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, childInput, STDIN_FILENO);
    posix_spawn_file_actions_adddup2(&actions, childOutput, STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, childError, STDERR_FILENO);
    if (!options.workingDirectory.empty()) {
        posix_spawn_file_actions_addchdir(&actions, options.workingDirectory.c_str());
    }

    posix_spawnattr_t attributes;
    posix_spawnattr_init(&attributes);
    posix_spawnattr_setpgroup(&attributes, 0);
    short flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT;
    posix_spawnattr_setflags(&attributes, flags);

    pid_t child = -1;
    int status = posix_spawn(&child, program.c_str(), &actions, &attributes, arguments.data(), environment.data());

    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);

    if (status != 0) {
        error = std::string("could not start \"") + program + "\": " + std::strerror(status);
        return false;
    }
    processId = static_cast<int>(child);
    return true;
}

int exitCodeFromStatus(int status) {
    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }
    if (WIFSIGNALED(status)) {
        return 128 + WTERMSIG(status);
    }
    return -1;
}

double secondsSince(std::chrono::steady_clock::time_point start) {
    return std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
}

void ignoreBrokenPipes() {
    // Writing to a program that already exited must return an error, not kill us.
    static bool done = [] {
        signal(SIGPIPE, SIG_IGN);
        return true;
    }();
    (void)done;
}

}  // namespace

// ---------------------------------------------------------------------------
// Finding programs

std::string searchPathForChildren() {
    std::string path;
    const char* existing = std::getenv("PATH");
    if (existing != nullptr) {
        path = existing;
    }
    if (path.empty()) {
        path = "/usr/bin:/bin:/usr/sbin:/sbin";
    }

    std::vector<std::string> present = splitPath(path);
    for (const std::string& folder : extraSearchFolders()) {
        bool alreadyThere = false;
        for (const std::string& known : present) {
            if (known == folder) {
                alreadyThere = true;
                break;
            }
        }
        if (!alreadyThere) {
            path += ":" + folder;
            present.push_back(folder);
        }
    }
    return path;
}

std::string findExecutable(const std::string& name) {
    if (name.find('/') != std::string::npos) {
        return isExecutableFile(name) ? name : std::string();
    }
    for (const std::string& folder : splitPath(searchPathForChildren())) {
        std::string candidate = folder + "/" + name;
        if (isExecutableFile(candidate)) {
            return candidate;
        }
    }
    return std::string();
}

// ---------------------------------------------------------------------------
// runProcess: run to completion

ProcessResult runProcess(const std::vector<std::string>& argv, const ProcessOptions& options) {
    ignoreBrokenPipes();
    ProcessResult result;

    int inputPipe[2] = {-1, -1};
    int outputPipe[2] = {-1, -1};
    int errorPipe[2] = {-1, -1};
    if (pipe(inputPipe) != 0 || pipe(outputPipe) != 0 || pipe(errorPipe) != 0) {
        result.startError = "could not create pipes";
        closeDescriptor(inputPipe[0]);
        closeDescriptor(inputPipe[1]);
        closeDescriptor(outputPipe[0]);
        closeDescriptor(outputPipe[1]);
        closeDescriptor(errorPipe[0]);
        closeDescriptor(errorPipe[1]);
        return result;
    }
    // Our ends must not leak into the child.
    makeCloseOnExec(inputPipe[1]);
    makeCloseOnExec(outputPipe[0]);
    makeCloseOnExec(errorPipe[0]);

    int processId = -1;
    std::string spawnError;
    bool started = spawnProgram(argv, options, inputPipe[0], outputPipe[1], errorPipe[1], processId, spawnError);

    // The child has its own copies of these now.
    closeDescriptor(inputPipe[0]);
    closeDescriptor(outputPipe[1]);
    closeDescriptor(errorPipe[1]);

    if (!started) {
        result.startError = spawnError;
        closeDescriptor(inputPipe[1]);
        closeDescriptor(outputPipe[0]);
        closeDescriptor(errorPipe[0]);
        return result;
    }
    result.started = true;

    makeNonBlocking(inputPipe[1]);
    size_t inputWritten = 0;
    if (options.input.empty()) {
        closeDescriptor(inputPipe[1]);
    }

    auto startTime = std::chrono::steady_clock::now();
    bool exited = false;
    int waitStatus = 0;
    std::vector<char> chunk(64 * 1024);

    while (true) {
        std::vector<pollfd> watched;
        int inputIndex = -1;
        int outputIndex = -1;
        int errorIndex = -1;
        if (inputPipe[1] >= 0) {
            inputIndex = static_cast<int>(watched.size());
            watched.push_back({inputPipe[1], POLLOUT, 0});
        }
        if (outputPipe[0] >= 0) {
            outputIndex = static_cast<int>(watched.size());
            watched.push_back({outputPipe[0], POLLIN, 0});
        }
        if (errorPipe[0] >= 0) {
            errorIndex = static_cast<int>(watched.size());
            watched.push_back({errorPipe[0], POLLIN, 0});
        }
        if (watched.empty()) {
            break;
        }

        // A short slice, so we notice the program exiting even if a grandchild keeps the
        // pipes open, and so the timeout is checked regularly.
        int ready = poll(watched.data(), static_cast<nfds_t>(watched.size()), 50);
        if (ready < 0 && errno != EINTR) {
            break;
        }

        if (inputIndex >= 0 && (watched[static_cast<size_t>(inputIndex)].revents & (POLLOUT | POLLERR | POLLHUP)) != 0) {
            size_t remaining = options.input.size() - inputWritten;
            ssize_t written = write(inputPipe[1], options.input.data() + inputWritten, remaining);
            if (written > 0) {
                inputWritten += static_cast<size_t>(written);
            }
            bool failed = written < 0 && errno != EAGAIN && errno != EINTR;
            if (failed || inputWritten >= options.input.size()) {
                closeDescriptor(inputPipe[1]);
            }
        }

        auto drain = [&](int index, int& descriptor, std::string& into) {
            if (index < 0 || descriptor < 0) {
                return;
            }
            if ((watched[static_cast<size_t>(index)].revents & (POLLIN | POLLHUP | POLLERR)) == 0) {
                return;
            }
            ssize_t count = read(descriptor, chunk.data(), chunk.size());
            if (count > 0) {
                size_t room = options.maxOutputBytes > into.size() ? options.maxOutputBytes - into.size() : 0;
                into.append(chunk.data(), std::min(static_cast<size_t>(count), room));
            } else if (count == 0 || (errno != EINTR && errno != EAGAIN)) {
                closeDescriptor(descriptor);
            }
        };
        drain(outputIndex, outputPipe[0], result.output);
        drain(errorIndex, errorPipe[0], result.errorOutput);

        if (!exited) {
            pid_t finished = waitpid(processId, &waitStatus, WNOHANG);
            if (finished == processId) {
                exited = true;
            }
        }
        if (exited && ready == 0) {
            break;  // it is gone and nothing more is arriving
        }

        bool overTime = options.timeoutSeconds > 0 && secondsSince(startTime) > options.timeoutSeconds;
        if (overTime && !exited) {
            result.timedOut = true;
            kill(-processId, SIGKILL);
            kill(processId, SIGKILL);
        }
    }

    closeDescriptor(inputPipe[1]);
    closeDescriptor(outputPipe[0]);
    closeDescriptor(errorPipe[0]);

    if (!exited) {
        waitpid(processId, &waitStatus, 0);
    }
    result.exitCode = exitCodeFromStatus(waitStatus);
    return result;
}

// ---------------------------------------------------------------------------
// ChildProcess: a live conversation

ChildProcess::ChildProcess() = default;

ChildProcess::~ChildProcess() {
    terminate();
    if (reader_.joinable()) {
        if (reader_.get_id() == std::this_thread::get_id()) {
            reader_.detach();  // destroyed from inside one of its own callbacks
        } else {
            reader_.join();
        }
    }
    closeDescriptor(inputDescriptor_);
}

bool ChildProcess::start(const std::vector<std::string>& argv, const ProcessOptions& options, std::string* error) {
    ignoreBrokenPipes();
    if (running_.load()) {
        if (error != nullptr) {
            *error = "already running";
        }
        return false;
    }
    if (reader_.joinable()) {
        reader_.join();  // a previous run that has finished
    }

    int inputPipe[2] = {-1, -1};
    int outputPipe[2] = {-1, -1};
    int errorPipe[2] = {-1, -1};
    if (pipe(inputPipe) != 0 || pipe(outputPipe) != 0 || pipe(errorPipe) != 0) {
        if (error != nullptr) {
            *error = "could not create pipes";
        }
        closeDescriptor(inputPipe[0]);
        closeDescriptor(inputPipe[1]);
        closeDescriptor(outputPipe[0]);
        closeDescriptor(outputPipe[1]);
        closeDescriptor(errorPipe[0]);
        closeDescriptor(errorPipe[1]);
        return false;
    }
    makeCloseOnExec(inputPipe[1]);
    makeCloseOnExec(outputPipe[0]);
    makeCloseOnExec(errorPipe[0]);

    int processId = -1;
    std::string spawnError;
    bool started = spawnProgram(argv, options, inputPipe[0], outputPipe[1], errorPipe[1], processId, spawnError);

    closeDescriptor(inputPipe[0]);
    closeDescriptor(outputPipe[1]);
    closeDescriptor(errorPipe[1]);

    if (!started) {
        if (error != nullptr) {
            *error = spawnError;
        }
        closeDescriptor(inputPipe[1]);
        closeDescriptor(outputPipe[0]);
        closeDescriptor(errorPipe[0]);
        return false;
    }

    processId_ = processId;
    inputDescriptor_ = inputPipe[1];
    outputDescriptor_ = outputPipe[0];
    errorDescriptor_ = errorPipe[0];
    running_.store(true);
    reader_ = std::thread([this] { readLoop(); });
    return true;
}

bool ChildProcess::write(std::string_view bytes) {
    std::lock_guard<std::mutex> lock(writeMutex_);
    if (inputDescriptor_ < 0 || !running_.load()) {
        return false;
    }
    size_t written = 0;
    while (written < bytes.size()) {
        ssize_t count = ::write(inputDescriptor_, bytes.data() + written, bytes.size() - written);
        if (count > 0) {
            written += static_cast<size_t>(count);
            continue;
        }
        if (count < 0 && errno == EINTR) {
            continue;
        }
        return false;
    }
    return true;
}

void ChildProcess::closeInput() {
    std::lock_guard<std::mutex> lock(writeMutex_);
    closeDescriptor(inputDescriptor_);
}

void ChildProcess::terminate() {
    if (!running_.load() || processId_ <= 0) {
        return;
    }
    kill(-processId_, SIGTERM);
    kill(processId_, SIGTERM);

    // If it ignores the polite request, force it after a short grace period.
    int processId = processId_;
    // This thread may outlive the ChildProcess, so it only looks at the process id (kill with
    // signal 0 says whether it still exists), never at members of `this`.
    std::thread([processId] {
        for (int attempt = 0; attempt < 20; ++attempt) {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
            if (kill(processId, 0) != 0) {
                return;
            }
        }
        kill(-processId, SIGKILL);
        kill(processId, SIGKILL);
    }).detach();
}

void ChildProcess::readLoop() {
    std::vector<char> chunk(64 * 1024);
    bool exited = false;
    int waitStatus = 0;

    while (outputDescriptor_ >= 0 || errorDescriptor_ >= 0) {
        std::vector<pollfd> watched;
        int outputIndex = -1;
        int errorIndex = -1;
        if (outputDescriptor_ >= 0) {
            outputIndex = static_cast<int>(watched.size());
            watched.push_back({outputDescriptor_, POLLIN, 0});
        }
        if (errorDescriptor_ >= 0) {
            errorIndex = static_cast<int>(watched.size());
            watched.push_back({errorDescriptor_, POLLIN, 0});
        }

        int ready = poll(watched.data(), static_cast<nfds_t>(watched.size()), 100);
        if (ready < 0 && errno != EINTR) {
            break;
        }

        auto drain = [&](int index, int& descriptor, const std::function<void(std::string_view)>& callback) {
            if (index < 0 || descriptor < 0) {
                return;
            }
            if ((watched[static_cast<size_t>(index)].revents & (POLLIN | POLLHUP | POLLERR)) == 0) {
                return;
            }
            ssize_t count = read(descriptor, chunk.data(), chunk.size());
            if (count > 0) {
                if (callback) {
                    callback(std::string_view(chunk.data(), static_cast<size_t>(count)));
                }
            } else if (count == 0 || (errno != EINTR && errno != EAGAIN)) {
                closeDescriptor(descriptor);
            }
        };
        drain(outputIndex, outputDescriptor_, onOutput);
        drain(errorIndex, errorDescriptor_, onErrorOutput);

        if (!exited) {
            pid_t finished = waitpid(processId_, &waitStatus, WNOHANG);
            if (finished == processId_) {
                exited = true;
            }
        }
        if (exited && ready == 0) {
            break;  // gone, and nothing more is arriving (a grandchild may still hold the pipes)
        }
    }

    closeDescriptor(outputDescriptor_);
    closeDescriptor(errorDescriptor_);
    if (!exited) {
        waitpid(processId_, &waitStatus, 0);
    }
    closeInput();
    running_.store(false);

    if (onExit) {
        onExit(exitCodeFromStatus(waitStatus));
    }
}

}  // namespace gw
