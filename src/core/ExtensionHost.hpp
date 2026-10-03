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

/// The extension host: a Node.js program (host/main.js) that runs VS Code extensions. This class
/// starts it, talks JSON-RPC to it over its pipes (framed like LSP), and turns the providers
/// extensions register into virtual language servers (see makeServerTransport), so the rest of
/// Glasswork treats an extension's language features like any other language server's.
///
/// Callbacks arrive on a background thread.
class ExtensionHost {
public:
    using Json = lsp::Json;
    /// Answers a request from the host. Call it once, from any thread, at any time later.
    using Reply = std::function<void(const Json& result, const std::string& error)>;
    using ResponseHandler = std::function<void(const Json& result, const std::string& error)>;

    ExtensionHost();
    ~ExtensionHost();
    ExtensionHost(const ExtensionHost&) = delete;
    ExtensionHost& operator=(const ExtensionHost&) = delete;

    /// The Node.js program to run the host with: from the PATH, or the usual per-user installs
    /// (nvm, Volta, Homebrew). Empty if there is none.
    static std::string findNode();

    struct Settings {
        std::string nodeProgram;       // empty: findNode()
        std::string hostScript;        // path to host/main.js
        std::string workingDirectory;  // the project folder
    };

    /// Starts the host. Returns false, with a reason, if Node can't be found or won't run.
    bool start(const Settings& settings, std::string* error);
    /// Asks the extensions to deactivate and stops the process.
    void stop();
    bool isRunning() const;
    /// True once the host has said hello.
    bool isReady() const { return ready_.load(); }

    void request(const std::string& method, Json params, ResponseHandler handler);
    void notify(const std::string& method, Json params);

    /// Requests from the host (show a message, ask for input, apply an edit…). Without an answer
    /// being sent they stay unanswered, so always call `reply`.
    std::function<void(const std::string& method, const Json& params, Reply reply)> onRequest;
    /// Notifications from the host (log output, status bar items, registered commands…).
    std::function<void(const std::string& method, const Json& params)> onNotification;
    std::function<void()> onReady;
    /// The host process ended (exit code, or 128 + signal).
    std::function<void(int exitCode)> onExit;
    /// The host's own standard error, for diagnosing a crash.
    std::function<void(std::string_view)> onStderr;

    /// A language server living in the host: it answers for `language` using whatever providers
    /// extensions have registered. Give it to LanguageServer as its transport.
    std::unique_ptr<lsp::ServerTransport> makeServerTransport(const std::string& language, const std::string& rootUri);

private:
    struct Shared;
    class HostTransport;
    friend class HostTransport;

    void handleOutput(std::string_view bytes);
    void handleMessage(const Json& message);
    void send(const Json& message);
    void deliverToServer(const std::string& serverId, const Json& message);
    void serverEnded(const std::string& serverId);
    void failEverything(int exitCode);

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
