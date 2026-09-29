#pragma once

#include "ClaudeProtocol.hpp"
#include "Process.hpp"

#include <atomic>
#include <functional>
#include <mutex>
#include <string>
#include <vector>

namespace gw::claude {

struct SessionOptions {
    /// The project folder. Claude works in here and reads its CLAUDE.md, git state, etc.
    std::string workingDirectory;
    /// "sonnet", "opus", "fable", a full model name, or empty for the account default.
    std::string model;
    /// One of: manual (ask for everything), acceptEdits, plan, auto, bypassPermissions.
    std::string permissionMode = "manual";
    /// low, medium, high, xhigh, max — or empty for the default.
    std::string effort;
    /// Continue an earlier conversation.
    std::string resumeSessionId;
    /// Extra instructions added to Claude's own (for example, what IDE it is running in).
    std::string appendSystemPrompt;
    std::vector<std::string> extraDirectories;
};

/// A running `claude` process that we talk to over its standard input and output using the
/// stream-json protocol. Events arrive on a background thread.
class Session {
public:
    Session();
    ~Session();
    Session(const Session&) = delete;
    Session& operator=(const Session&) = delete;

    /// Called on a background thread for every event, in order.
    std::function<void(const Event&)> onEvent;
    /// Called once when the process ends. `errorText` is whatever it printed to stderr.
    std::function<void(int exitCode, const std::string& errorText)> onExit;

    /// True if the `claude` command can be found.
    static bool isInstalled();
    static std::string executablePath();

    bool start(const SessionOptions& options, std::string* error = nullptr);
    bool isRunning() const { return child_.isRunning(); }

    bool sendUserMessage(const std::string& text);
    void answerPermission(const std::string& requestId, bool allow, const Json& input,
                          const std::string& denyMessage = "");
    /// Stops what Claude is doing right now, but keeps the session.
    void interrupt();
    void setPermissionMode(const std::string& mode);
    void setModel(const std::string& model);
    /// Ends the session and the process.
    void stop();

private:
    std::string nextRequestId();
    void handleOutput(std::string_view bytes);

    ChildProcess child_;
    LineSplitter splitter_;
    std::mutex errorMutex_;
    std::string errorText_;
    std::atomic<int> requestCounter_{0};
};

/// A one-off question with no tools and no saved history, such as "write a commit message
/// for this diff". Blocking: call it from a background queue. Returns the answer, or an
/// empty string with `error` filled in.
std::string askOnce(const std::string& prompt, const std::string& workingDirectory, const std::string& model,
                    std::string* error, double timeoutSeconds = 90);

}  // namespace gw::claude
