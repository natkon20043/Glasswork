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

/// Debug Adapter Protocol connection (such as lldb-dap) over stdin/stdout. Responses and events
/// arrive through callbacks on a background thread.
class Connection {
public:
    using ResponseHandler = std::function<void(bool success, const Json& body, const std::string& message)>;

    // ---- Constructors and destructor
    Connection();
    ~Connection();
    Connection(const Connection&) = delete;
    Connection& operator=(const Connection&) = delete;

    // ---- Lifecycle
    bool start(const std::vector<std::string>& command, const std::string& workingDirectory, std::string* error);
    /// Asks the adapter to disconnect, then makes sure it is gone.
    void stop();

    // ---- Requests
    /// Safe from any thread.
    void request(const std::string& command, Json arguments, ResponseHandler handler);

    // ---- Getters
    bool isRunning() const { return process_.isRunning(); }

    // ---- Callbacks (set before start())
    /// Events such as "stopped", "output", "terminated".
    std::function<void(const std::string& event, const Json& body)> onEvent;
    /// Adapter-initiated requests (runInTerminal...). Return a response body, or set `success` false.
    /// The default answers "not supported".
    std::function<Json(const std::string& command, const Json& arguments, bool& success)> onReverseRequest;
    std::function<void(int exitCode)> onExit;

private:
    // ---- Private functions
    void handleOutput(std::string_view bytes);
    void handleMessage(const Json& message);
    void send(Json message);

    // ---- Private variables
    std::mutex mutex_;
    std::mutex callbackMutex_;
    gw::lsp::Decoder decoder_;
    std::atomic<int> nextSequence_{1};
    std::map<int, ResponseHandler> pending_;
    bool stopping_ = false;
    // Last: destroyed first, joining its thread before the rest goes.
    ChildProcess process_;
};

/// The Xcode LLDB adapter ("xcrun lldb-dap") as a command line.
std::vector<std::string> defaultAdapterCommand();

}  // namespace gw::dap
