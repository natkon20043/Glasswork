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
    /// Claude works here and reads its CLAUDE.md and git state.
    std::string workingDirectory;
    /// "sonnet", "opus", "fable", a full model name, or empty for the account default.
    std::string model;
    /// manual, acceptEdits, plan, auto or bypassPermissions.
    std::string permissionMode = "manual";
    /// low, medium, high, xhigh, max, or empty for the default.
    std::string effort;
    std::string resumeSessionId;
    /// Extra instructions added to Claude's own.
    std::string appendSystemPrompt;
    std::vector<std::string> extraDirectories;
};

/// A running `claude` process driven over stdin/stdout with the stream-json protocol.
/// Events arrive on a background thread.
class Session {
public:
    // ---- Constructors and destructor
    Session();
    ~Session();
    Session(const Session&) = delete;
    Session& operator=(const Session&) = delete;

    // ---- Static queries
    static bool isInstalled();
    static std::string executablePath();

    // ---- Lifecycle
    bool start(const SessionOptions& options, std::string* error = nullptr);
    /// Ends the session and the process.
    void stop();
    /// Stops what Claude is doing now but keeps the session.
    void interrupt();

    // ---- Sending
    bool sendUserMessage(const std::string& text);
    void answerPermission(const std::string& requestId, bool allow, const Json& input,
                          const std::string& denyMessage = "");

    // ---- Setters
    void setPermissionMode(const std::string& mode);
    void setModel(const std::string& model);

    // ---- Getters
    bool isRunning() const { return child_.isRunning(); }

    // ---- Callbacks
    /// Background thread, every event, in order.
    std::function<void(const Event&)> onEvent;
    /// Once when the process ends; `errorText` is its stderr.
    std::function<void(int exitCode, const std::string& errorText)> onExit;

private:
    // ---- Private functions
    std::string nextRequestId();
    void handleOutput(std::string_view bytes);

    // ---- Private variables
    LineSplitter splitter_;
    std::mutex errorMutex_;
    std::string errorText_;
    std::atomic<int> requestCounter_{0};
    // Last, so its reader thread is joined before the members its callbacks use are destroyed.
    ChildProcess child_;
};

/// One-off question with no tools or history. Blocking: call from a background queue.
/// Returns an empty string with `error` filled in on failure.
std::string askOnce(const std::string& prompt, const std::string& workingDirectory, const std::string& model,
                    std::string* error, double timeoutSeconds = 90);

}  // namespace gw::claude
