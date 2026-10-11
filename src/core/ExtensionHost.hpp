#pragma once

#include "LspServer.hpp"
#include "Process.hpp"

#include <atomic>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>

namespace gw {

/// Starts the Node.js program (host/main.js) that runs VS Code extensions, talks LSP-framed JSON-RPC
/// to it, and exposes the providers extensions register as virtual language servers.
/// Callbacks arrive on a background thread.
class ExtensionHost {
public:
    using Json = lsp::Json;
    /// Call exactly once per host request, from any thread, at any later time.
    using Reply = std::function<void(const Json& result, const std::string& error)>;
    using ResponseHandler = std::function<void(const Json& result, const std::string& error)>;

    struct Settings {
        /// Empty: findNode().
        std::string nodeProgram;
        std::string hostScript;
        std::string workingDirectory;
    };

    // ---- Constructors and destructor
    ExtensionHost();
    ~ExtensionHost();
    ExtensionHost(const ExtensionHost&) = delete;
    ExtensionHost& operator=(const ExtensionHost&) = delete;

    // ---- Lifecycle
    /// Returns false, with a reason, if Node can't be found or won't run.
    bool start(const Settings& settings, std::string* error);
    /// Asks extensions to deactivate, then stops the process.
    void stop();

    // ---- Messaging
    void request(const std::string& method, Json params, ResponseHandler handler);
    void notify(const std::string& method, Json params);
    /// A language server living in the host, answering from registered extension providers.
    std::unique_ptr<lsp::ServerTransport> makeServerTransport(const std::string& language, const std::string& rootUri);

    // ---- Getters
    /// Looks on the PATH, then nvm, Volta and Homebrew. Empty if none.
    static std::string findNode();
    bool isRunning() const;
    /// True once the host has said hello.
    bool isReady() const { return ready_.load(); }

    // ---- Callbacks
    /// Host requests (show message, ask input, apply edit...). Always call `reply`.
    std::function<void(const std::string& method, const Json& params, Reply reply)> onRequest;
    /// Host notifications (log output, status bar items, registered commands...).
    std::function<void(const std::string& method, const Json& params)> onNotification;
    std::function<void()> onReady;
    /// Exit code, or 128 + signal.
    std::function<void(int exitCode)> onExit;
    std::function<void(std::string_view)> onStderr;

private:
    struct Shared;
    class HostTransport;
    friend class HostTransport;

    // ---- Private functions
    void handleOutput(std::string_view bytes);
    void handleMessage(const Json& message);
    void send(const Json& message);
    void deliverToServer(const std::string& serverId, const Json& message);
    void serverEnded(const std::string& serverId);
    void failEverything(int exitCode);

    // ---- Private variables
    std::shared_ptr<Shared> shared_;
    std::atomic<bool> ready_{false};
    std::atomic<int> nextId_{1};
    std::atomic<int> nextServer_{1};
    lsp::Decoder decoder_;
    std::mutex mutex_;
    std::map<int, ResponseHandler> pending_;
    std::map<std::string, HostTransport*> transports_;
    bool stopping_ = false;
    // Last, so its reader thread is joined before the members its callbacks use are destroyed.
    ChildProcess process_;
};

}  // namespace gw
