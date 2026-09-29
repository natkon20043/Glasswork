#include "ClaudeSession.hpp"

namespace gw::claude {

Session::Session() = default;

Session::~Session() {
    stop();
}

bool Session::isInstalled() {
    return !executablePath().empty();
}

std::string Session::executablePath() {
    return findExecutable("claude");
}

std::string Session::nextRequestId() {
    int number = ++requestCounter_;
    return "glasswork-" + std::to_string(number);
}

bool Session::start(const SessionOptions& options, std::string* error) {
    if (child_.isRunning()) {
        if (error != nullptr) {
            *error = "The session is already running.";
        }
        return false;
    }

    std::vector<std::string> command = {
        "claude",
        "-p",
        "--input-format", "stream-json",
        "--output-format", "stream-json",
        "--verbose",
        "--include-partial-messages",
        // Permission questions come to us, so the IDE can show them.
        "--permission-prompt-tool", "stdio",
        "--permission-mode", options.permissionMode.empty() ? std::string("manual") : options.permissionMode,
    };
    if (!options.model.empty()) {
        command.push_back("--model");
        command.push_back(options.model);
    }
    if (!options.effort.empty()) {
        command.push_back("--effort");
        command.push_back(options.effort);
    }
    if (!options.resumeSessionId.empty()) {
        command.push_back("--resume");
        command.push_back(options.resumeSessionId);
    }
    if (!options.appendSystemPrompt.empty()) {
        command.push_back("--append-system-prompt");
        command.push_back(options.appendSystemPrompt);
    }
    for (const std::string& directory : options.extraDirectories) {
        command.push_back("--add-dir");
        command.push_back(directory);
    }

    {
        std::lock_guard<std::mutex> lock(errorMutex_);
        errorText_.clear();
    }
    splitter_ = LineSplitter();

    ProcessOptions processOptions;
    processOptions.workingDirectory = options.workingDirectory;

    child_.onOutput = [this](std::string_view bytes) { handleOutput(bytes); };
    child_.onErrorOutput = [this](std::string_view bytes) {
        std::lock_guard<std::mutex> lock(errorMutex_);
        if (errorText_.size() < 16 * 1024) {
            errorText_.append(bytes);
        }
    };
    child_.onExit = [this](int exitCode) {
        std::string text;
        {
            std::lock_guard<std::mutex> lock(errorMutex_);
            text = errorText_;
        }
        if (onExit) {
            onExit(exitCode, text);
        }
    };
    return child_.start(command, processOptions, error);
}

void Session::handleOutput(std::string_view bytes) {
    for (const std::string& line : splitter_.feed(bytes)) {
        std::optional<Event> event = parseEvent(line);
        if (event && onEvent) {
            onEvent(*event);
        }
    }
}

bool Session::sendUserMessage(const std::string& text) {
    return child_.write(userMessageLine(text));
}

void Session::answerPermission(const std::string& requestId, bool allow, const Json& input,
                               const std::string& denyMessage) {
    child_.write(permissionResponseLine(requestId, allow, input, denyMessage));
}

void Session::interrupt() {
    child_.write(interruptLine(nextRequestId()));
}

void Session::setPermissionMode(const std::string& mode) {
    child_.write(setPermissionModeLine(nextRequestId(), mode));
}

void Session::setModel(const std::string& model) {
    child_.write(setModelLine(nextRequestId(), model));
}

void Session::stop() {
    if (child_.isRunning()) {
        child_.closeInput();
        child_.terminate();
    }
}

// ---------------------------------------------------------------------------

std::string askOnce(const std::string& prompt, const std::string& workingDirectory, const std::string& model,
                    std::string* error, double timeoutSeconds) {
    std::vector<std::string> command = {
        "claude", "-p",
        "--output-format", "text",
        "--no-session-persistence",
        // No tools at all: it can only answer.
        "--tools", "",
    };
    if (!model.empty()) {
        command.push_back("--model");
        command.push_back(model);
    }

    ProcessOptions options;
    options.workingDirectory = workingDirectory;
    options.input = prompt;
    options.timeoutSeconds = timeoutSeconds;
    ProcessResult result = runProcess(command, options);

    if (!result.started) {
        if (error != nullptr) {
            *error = result.startError;
        }
        return std::string();
    }
    if (!result.succeeded()) {
        if (error != nullptr) {
            *error = result.timedOut ? "Claude took too long to answer."
                                     : (result.errorOutput.empty() ? result.output : result.errorOutput);
        }
        return std::string();
    }

    // Trim surrounding whitespace.
    std::string answer = result.output;
    size_t start = answer.find_first_not_of(" \t\r\n");
    size_t end = answer.find_last_not_of(" \t\r\n");
    if (start == std::string::npos) {
        return std::string();
    }
    return answer.substr(start, end - start + 1);
}

}  // namespace gw::claude
