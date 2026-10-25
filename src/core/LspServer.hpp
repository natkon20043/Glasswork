#pragma once

#include "Document.hpp"
#include "Glob.hpp"
#include "LanguageServer.hpp"
#include "Process.hpp"

#include <atomic>
#include <condition_variable>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <vector>

namespace gw::lsp {

/// A language server we know how to start.
struct ServerSpec {
    /// "clangd"
    std::string name;
    /// Program and arguments; the program is looked up on the PATH.
    std::vector<std::string> command;
    std::vector<std::string> languageIds;
    /// Shown when the program can't be found.
    std::string installHint;
};

/// A problem reported by a server. `range` is the raw LSP range (UTF-16 columns).
struct Diagnostic {
    Json range;
    /// 1 error, 2 warning, 3 information, 4 hint.
    int severity = 1;
    std::string message;
    std::string source;
    std::string code;
    /// Exactly what the server sent, to hand back in code-action requests.
    Json original;

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

// ---- Server specs and programs

/// clangd, sourcekit-lsp, pyright, typescript-language-server, rust-analyzer and gopls when installed.
const std::vector<ServerSpec>& defaultServerSpecs();
const ServerSpec* serverForLanguage(const std::vector<ServerSpec>& specs, const std::string& languageId);
/// "xcrun ..." tools stay as they are; other names are searched on the PATH and usual install folders.
/// Empty if not found.
std::string resolveProgram(const std::string& program);

std::vector<Diagnostic> parseDiagnostics(const Json& array);

/// "textDocument/hover" -> "hoverProvider". Empty for methods without one (resolve requests, notifications).
std::string capabilityKeyForMethod(const std::string& method);

/// Where a server's bytes travel: a child process's pipes, or the extension host. Lets server code
/// avoid depending on a process.
class ServerTransport {
public:
    // ---- Destructor
    virtual ~ServerTransport() = default;

    // ---- Lifecycle
    virtual bool start(std::string* error) = 0;
    virtual void terminate() = 0;
    virtual bool isRunning() const = 0;

    // ---- I/O
    virtual bool write(std::string_view bytes) = 0;
    virtual void closeInput() = 0;

    // ---- Callbacks (set before start())
    /// Server bytes in whatever chunks arrive.
    std::function<void(std::string_view)> onOutput;
    /// Exit code, or 128 + signal.
    std::function<void(int)> onExit;
};

std::unique_ptr<ServerTransport> makeProcessTransport(const ServerSpec& spec, const std::string& workingDirectory);

/// Starts the program, does the handshake, keeps documents in sync and answers requests.
/// Asynchronous: callbacks arrive on a background thread.
class LanguageServer {
public:
    using ResponseHandler = std::function<void(const Json& result, const std::string& error)>;

    struct FileEvent {
        /// Absolute.
        std::string path;
        /// 1 created, 2 changed, 3 deleted.
        int type = 2;
    };

    // ---- Constructors and destructor
    /// With no `transport` the server runs as the child program the spec names.
    LanguageServer(ServerSpec spec, std::string rootPath, std::unique_ptr<ServerTransport> transport = nullptr);
    ~LanguageServer();
    LanguageServer(const LanguageServer&) = delete;
    LanguageServer& operator=(const LanguageServer&) = delete;

    // ---- Lifecycle
    /// Returns false, with `error`, if the program can't run.
    bool start(std::string* error);
    void stop();

    // ---- Document sync (sent as soon as the server is ready)
    void didOpen(const std::string& uri, const std::string& languageId, uint64_t version, const std::string& text);
    void didChange(const std::string& uri, uint64_t version, const std::string& text);
    /// Only for servers where wantsIncrementalSync() is true.
    void didChangeIncremental(const std::string& uri, uint64_t version, const std::vector<SyncEdit>& edits);
    void didSave(const std::string& uri);
    void didClose(const std::string& uri);
    /// Servers that ask for settings with `workspace/configuration` re-ask on this.
    void didChangeConfiguration(const Json& settings);
    /// Sends only events matching what the server registered for; safe with irrelevant events.
    void didChangeWatchedFiles(const std::vector<FileEvent>& events);

    // ---- Requests
    /// Handler runs on the reader thread; `error` is empty when fine. Requests made before the
    /// server is ready wait for it.
    void request(const std::string& method, Json parameters, ResponseHandler handler);
    void cancel(int requestId);

    // ---- Getters
    const ServerSpec& spec() const { return spec_; }
    bool isRunning() const;
    /// True once the server has answered `initialize`.
    bool isReady() const;
    /// The `capabilities` object, or null before ready.
    Json capabilities() const;
    bool supports(const std::string& capability) const;
    /// `textDocumentSync` 2, or an object whose `change` is 2.
    bool wantsIncrementalSync() const;
    /// True once the server registered interest in file changes.
    bool watchesFiles() const;
    int lastRequestId() const { return nextId_.load() - 1; }

    // ---- Callbacks (set before start(); run on a background thread)
    /// `version` is -1 when the server doesn't say which version.
    std::function<void(const std::string& uri, long version, std::vector<Diagnostic> diagnostics)> onDiagnostics;
    /// Server became ready or ended (then `isRunning()` is false).
    std::function<void()> onReady;
    std::function<void(int exitCode)> onExit;
    /// `window/showMessage`. `type`: 1 error, 2 warning, 3 info, 4 log.
    std::function<void(int type, const std::string& message)> onShowMessage;
    /// `window/showMessageRequest`: call `reply` with the chosen button's title, or empty if dismissed.
    /// Dismissed when no handler is set.
    std::function<void(int type, const std::string& message, const std::vector<std::string>& actions,
                       std::function<void(const std::string& chosen)> reply)>
        onShowMessageRequest;
    std::function<void(int type, const std::string& message)> onLogMessage;
    /// `$/progress`. `kind` is "begin", "report" or "end"; `token` tells reports apart.
    std::function<void(const std::string& token, const std::string& kind, const std::string& title,
                       const std::string& message, int percentage)>
        onProgress;
    /// `workspace/configuration`: return the value for a section ("python.analysis"), or null.
    std::function<Json(const std::string& section, const std::string& scopeUri)> onConfiguration;
    /// `workspace/applyEdit` (`edit` is a WorkspaceEdit). Call `reply` from any thread once done.
    /// Refused when no handler is set.
    std::function<void(const Json& edit, std::function<void(bool applied)> reply)> onApplyEdit;

private:
    /// Lets a late reply (after the server is gone) find out it is too late.
    struct Liveness {
        std::mutex mutex;
        LanguageServer* server = nullptr;
    };

    /// A `workspace/didChangeWatchedFiles` registration.
    struct Watcher {
        std::string registrationId;
        std::shared_ptr<GlobPattern> pattern;
        /// Folder the pattern is relative to.
        std::string base;
        /// 1 create | 2 change | 4 delete
        int kinds = 7;
    };

    // ---- Incoming messages
    void handleOutput(std::string_view bytes);
    void handleMessage(const Json& message);
    void handleResponse(const Json& message);
    void handleServerRequest(const Json& message);
    void handleNotification(const Json& message);
    void finishHandshake(const Json& result, const std::string& error);

    // ---- Outgoing messages
    void sendLocked(Json message);
    void send(Json message);
    void replyToApplyEdit(const Json& requestId, bool applied);

    // ---- Capabilities
    void registerCapabilities(const Json& registrations);
    void unregisterCapabilities(const Json& unregisterations);

    /// Copy a callback under the lock and call the copy; the original may be cleared by another
    /// thread during teardown.
    template <typename Callback>
    Callback copyCallback(const Callback& callback) {
        std::lock_guard<std::mutex> lock(callbackMutex_);
        return callback;
    }

    // ---- Private variables
    ServerSpec spec_;
    std::string rootPath_;
    std::shared_ptr<Liveness> liveness_ = std::make_shared<Liveness>();

    mutable std::mutex mutex_;
    // Guards clearing the callbacks during teardown.
    std::mutex callbackMutex_;

    Decoder decoder_;
    bool ready_ = false;
    bool stopping_ = false;
    Json capabilities_;
    std::atomic<int> nextId_{1};
    std::map<int, ResponseHandler> pending_;
    // Messages queued during the handshake.
    std::vector<Json> waitingForReady_;
    std::vector<Watcher> watchers_;
    // From `client/registerCapability`: registration id -> capability key.
    std::map<std::string, std::string> registrationKeys_;
    // Keys with no static answer from the server, so unregistering may remove them.
    std::set<std::string> dynamicOnlyKeys_;

    // Last, so it is destroyed first: its reader thread is joined before the members its callbacks use go away.
    std::unique_ptr<ServerTransport> transport_;
};

}  // namespace gw::lsp
