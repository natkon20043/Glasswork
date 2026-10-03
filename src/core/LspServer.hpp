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

/// Where a language server's bytes travel. Usually a child program's pipes (ProcessTransport),
/// but a server can also live inside the extension host (see ExtensionHost), which is why the
/// server code talks to this interface instead of to a process.
class ServerTransport {
public:
    virtual ~ServerTransport() = default;

    /// Bytes from the server, in whatever chunks arrive; set before start().
    std::function<void(std::string_view)> onOutput;
    /// The server went away (exit code, or 128 + signal); set before start().
    std::function<void(int)> onExit;

    virtual bool start(std::string* error) = 0;
    virtual bool write(std::string_view bytes) = 0;
    virtual void closeInput() = 0;
    virtual void terminate() = 0;
    virtual bool isRunning() const = 0;
};

/// Runs `spec.command` as a child process with `workingDirectory` as its folder.
std::unique_ptr<ServerTransport> makeProcessTransport(const ServerSpec& spec, const std::string& workingDirectory);

/// The capability a protocol method switches on ("textDocument/hover" → "hoverProvider"), or an
/// empty string for methods that have none (resolve requests, notifications).
std::string capabilityKeyForMethod(const std::string& method);

/// A running language server: starts the program, does the handshake, keeps documents in sync
/// and answers requests. Everything is asynchronous — callbacks arrive on a background thread.
class LanguageServer {
public:
    using ResponseHandler = std::function<void(const Json& result, const std::string& error)>;

    /// With no `transport`, the server runs as the child program the spec names.
    LanguageServer(ServerSpec spec, std::string rootPath, std::unique_ptr<ServerTransport> transport = nullptr);
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
    /// Tells the server only what changed. Only for servers where wantsIncrementalSync() is true.
    void didChangeIncremental(const std::string& uri, uint64_t version, const std::vector<SyncEdit>& edits);
    /// True if the server asked to be sent changes rather than the whole file each time
    /// (`textDocumentSync` 2, or an object whose `change` is 2).
    bool wantsIncrementalSync() const;
    void didSave(const std::string& uri);
    /// Tells the server the settings changed (`workspace/didChangeConfiguration`). Servers that
    /// ask for their settings with `workspace/configuration` re-ask when they get this.
    void didChangeConfiguration(const Json& settings);

    /// A change to a file on disk, as `workspace/didChangeWatchedFiles` describes it.
    struct FileEvent {
        std::string path;  // absolute
        int type = 2;      // 1 created, 2 changed, 3 deleted
    };
    /// True once the server has registered interest in file changes (most do, for build files and
    /// sources the user has not opened).
    bool watchesFiles() const;
    /// Sends the server the events that match the files it asked to hear about; nothing is sent
    /// if none do. Safe to call with events for files the server doesn't care about.
    void didChangeWatchedFiles(const std::vector<FileEvent>& events);
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
    /// `window/showMessage`: the server wants the user to see something. `type` is 1 error, 2 warning,
    /// 3 info, 4 log.
    std::function<void(int type, const std::string& message)> onShowMessage;
    /// `window/showMessageRequest`: a message with buttons. Call `reply` with the chosen button's
    /// title, or an empty string if it was dismissed. Without this handler it is dismissed.
    std::function<void(int type, const std::string& message, const std::vector<std::string>& actions,
                       std::function<void(const std::string& chosen)> reply)>
        onShowMessageRequest;
    /// `window/logMessage`: output for the server's log.
    std::function<void(int type, const std::string& message)> onLogMessage;
    /// `$/progress`: work the server reports ("Indexing", with a message and percentage). `kind` is
    /// "begin", "report" or "end"; `token` tells reports apart.
    std::function<void(const std::string& token, const std::string& kind, const std::string& title,
                       const std::string& message, int percentage)>
        onProgress;
    /// `workspace/configuration`: the server asks for a setting by section ("python.analysis").
    /// Return the value, or null for "not set".
    std::function<Json(const std::string& section, const std::string& scopeUri)> onConfiguration;
    /// The server asks us to change files (`workspace/applyEdit`), usually while running a command
    /// such as a refactoring. `edit` is a WorkspaceEdit. Call `reply(true)` once the changes are
    /// made (or `reply(false)` if they could not be), from any thread, any time later. Without
    /// this handler such requests are refused.
    std::function<void(const Json& edit, std::function<void(bool applied)> reply)> onApplyEdit;

private:
    void handleOutput(std::string_view bytes);
    void handleMessage(const Json& message);
    void sendLocked(Json message);
    void send(Json message);
    void finishHandshake(const Json& result);

    /// Lets a late reply (made after the server is gone) find out that it is too late.
    struct Liveness {
        std::mutex mutex;
        LanguageServer* server = nullptr;
    };
    void replyToApplyEdit(const Json& requestId, bool applied);
    void registerCapabilities(const Json& registrations);
    void unregisterCapabilities(const Json& unregisterations);

    ServerSpec spec_;
    std::string rootPath_;
    std::shared_ptr<Liveness> liveness_ = std::make_shared<Liveness>();

    mutable std::mutex mutex_;
    std::mutex callbackMutex_;  // guards clearing the callbacks during teardown
    Decoder decoder_;
    bool ready_ = false;
    bool stopping_ = false;
    Json capabilities_;
    std::atomic<int> nextId_{1};
    std::map<int, ResponseHandler> pending_;
    std::vector<Json> waitingForReady_;  // messages queued during the handshake

    /// What the server asked to hear about (`workspace/didChangeWatchedFiles` registrations).
    struct Watcher {
        std::string registrationId;
        std::shared_ptr<GlobPattern> pattern;
        std::string base;  // the folder the pattern is relative to
        int kinds = 7;     // 1 create | 2 change | 4 delete
    };
    std::vector<Watcher> watchers_;

    /// Capabilities added by `client/registerCapability`: registration id → capability key.
    std::map<std::string, std::string> registrationKeys_;
    /// Capability keys the server had no static answer for, so unregistering may remove them.
    std::set<std::string> dynamicOnlyKeys_;

    // Declared last so it is destroyed first: its reader thread is joined before any of the
    // members above (which its callbacks use) go away.
    std::unique_ptr<ServerTransport> transport_;
};

}  // namespace gw::lsp
