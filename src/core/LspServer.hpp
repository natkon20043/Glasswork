#pragma once

#include "LanguageServer.hpp"
#include "Process.hpp"

#include <atomic>
#include <condition_variable>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace gw::lsp {

/// A language server we know how to start.
struct ServerSpec {
    std::string name;                        // "clangd"
    std::vector<std::string> command;        // program and arguments; the program is looked up on the PATH
    std::vector<std::string> languageIds;    // the languages it serves
    std::string installHint;                 // shown when the program can't be found
};

/// The servers Glasswork tries by default: clangd and sourcekit-lsp (from Xcode), pyright,
/// typescript-language-server, rust-analyzer and gopls when they are installed.
const std::vector<ServerSpec>& defaultServerSpecs();

/// The server for a language, or null. `overrides` (from settings.json) replace or add to the defaults.
const ServerSpec* serverForLanguage(const std::vector<ServerSpec>& specs, const std::string& languageId);

/// Turns `command[0]` into a full path: xcrun-hosted tools ("xcrun clangd") stay as they are, other
/// names are searched for on the PATH and the usual install folders. Empty if not found.
std::string resolveProgram(const std::string& program);

/// One problem reported by a server. `range` is the raw LSP range (UTF-16 columns).
struct Diagnostic {
    Json range;
    int severity = 1;  // 1 error, 2 warning, 3 information, 4 hint
    std::string message;
    std::string source;
    std::string code;
    /// Exactly what the server sent, to give back in code-action requests.
    Json original;

    /// The LSP object for this problem (what a server sent, in the form it expects back).
    Json toJson() const {
        if (!original.is_null()) {
            return original;
        }
        Json result = {{"range", range}, {"severity", severity}, {"message", message}};
        if (!source.empty()) {
            result["source"] = source;
        }
        if (!code.empty()) {
            result["code"] = code;
        }
        return result;
    }
};

std::vector<Diagnostic> parseDiagnostics(const Json& array);

/// A running language server: starts the program, does the handshake, keeps documents in sync
/// and answers requests. Everything is asynchronous — callbacks arrive on a background thread.
class LanguageServer {
public:
    using ResponseHandler = std::function<void(const Json& result, const std::string& error)>;

    LanguageServer(ServerSpec spec, std::string rootPath);
    ~LanguageServer();
    LanguageServer(const LanguageServer&) = delete;
    LanguageServer& operator=(const LanguageServer&) = delete;

    /// Starts the program and begins the handshake. Returns false (with `error`) if it can't run.
    bool start(std::string* error);
    /// Asks the server to shut down cleanly.
    void stop();

    const ServerSpec& spec() const { return spec_; }
    bool isRunning() const;
    /// True once the server has answered `initialize`.
    bool isReady() const;
    /// What the server said it can do (the `capabilities` object), or null before it is ready.
    Json capabilities() const;
    bool supports(const std::string& capability) const;

    // Document synchronisation. Sent as soon as the server is ready.
    void didOpen(const std::string& uri, const std::string& languageId, uint64_t version, const std::string& text);
    void didChange(const std::string& uri, uint64_t version, const std::string& text);
    void didSave(const std::string& uri);
    void didClose(const std::string& uri);

    /// Sends a request. The handler runs on the server's reader thread with the result, or with an
    /// error message (empty when fine). Requests made before the server is ready wait for it.
    void request(const std::string& method, Json parameters, ResponseHandler handler);
    /// Forgets the answer to a request that is no longer wanted.
    void cancel(int requestId);
    int lastRequestId() const { return nextId_.load() - 1; }

    // Set these before start(). They run on a background thread.
    /// New diagnostics for a file. `version` is -1 when the server doesn't say which version.
    std::function<void(const std::string& uri, long version, std::vector<Diagnostic> diagnostics)> onDiagnostics;
    /// The server became ready, or ended (after which `isRunning()` is false).
    std::function<void()> onReady;
    std::function<void(int exitCode)> onExit;

private:
    void handleOutput(std::string_view bytes);
    void handleMessage(const Json& message);
    void sendLocked(Json message);
    void send(Json message);
    void finishHandshake(const Json& result);

    ServerSpec spec_;
    std::string rootPath_;

    mutable std::mutex mutex_;
    std::mutex callbackMutex_;  // guards clearing the callbacks during teardown
    Decoder decoder_;
    bool ready_ = false;
    bool stopping_ = false;
    Json capabilities_;
    std::atomic<int> nextId_{1};
    std::map<int, ResponseHandler> pending_;
    std::vector<Json> waitingForReady_;  // messages queued during the handshake

    // Declared last so it is destroyed first: its reader thread is joined before any of the
    // members above (which its callbacks use) go away.
    ChildProcess process_;
};

}  // namespace gw::lsp
