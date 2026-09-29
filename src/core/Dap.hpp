#pragma once

#include "LanguageServer.hpp"
#include "Process.hpp"

#include <atomic>
#include <functional>
#include <map>
#include <mutex>
#include <string>
#include <vector>

namespace gw::dap {

using Json = gw::lsp::Json;

/// A connection to a debug adapter (such as lldb-dap) speaking the Debug Adapter Protocol: JSON
/// messages with Content-Length headers over the adapter's standard input and output. Requests
/// are answered, and events arrive, through callbacks on a background thread.
class Connection {
public:
    /// Called with whether the request worked, the response body, and an error message if not.
    using ResponseHandler = std::function<void(bool success, const Json& body, const std::string& message)>;

    Connection();
    ~Connection();
    Connection(const Connection&) = delete;
    Connection& operator=(const Connection&) = delete;

    /// Starts the adapter program.
    bool start(const std::vector<std::string>& command, const std::string& workingDirectory, std::string* error);
    /// Sends a request. Safe from any thread.
    void request(const std::string& command, Json arguments, ResponseHandler handler);
    /// Ends the session: asks the adapter to disconnect, then makes sure it is gone.
    void stop();
    bool isRunning() const { return process_.isRunning(); }

    // Set these before start(). They run on a background thread.
    /// An event such as "stopped", "output" or "terminated".
    std::function<void(const std::string& event, const Json& body)> onEvent;
    /// The adapter asked us to do something (runInTerminal…). Return a body to answer with, or set
    /// `success` to false. The default answers "not supported".
    std::function<Json(const std::string& command, const Json& arguments, bool& success)> onReverseRequest;
    /// The adapter program ended.
    std::function<void(int exitCode)> onExit;

private:
    void handleOutput(std::string_view bytes);
    void handleMessage(const Json& message);
    void send(Json message);

    std::mutex mutex_;
    std::mutex callbackMutex_;
    gw::lsp::Decoder decoder_;
    std::atomic<int> nextSequence_{1};
    std::map<int, ResponseHandler> pending_;
    bool stopping_ = false;

    ChildProcess process_;  // last: destroyed first, joining its thread before the rest goes
};

/// The debug adapter for LLDB that ships with Xcode ("xcrun lldb-dap"), as a command line.
std::vector<std::string> defaultAdapterCommand();

}  // namespace gw::dap
