#include "LspServer.hpp"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <unistd.h>

namespace gw::lsp {

namespace {

/// GLASSWORK_LSP_TRACE=1 prints every message to and from the servers (for debugging).
bool traceEnabled() {
    static const bool enabled = std::getenv("GLASSWORK_LSP_TRACE") != nullptr;
    return enabled;
}

void trace(const char* direction, const Json& message) {
    if (!traceEnabled()) {
        return;
    }
    std::string text = message.dump();
    if (text.size() > 300) {
        text = text.substr(0, 300) + "…";
    }
    std::fprintf(stderr, "[lsp %s] %s\n", direction, text.c_str());
}

}  // namespace

// ---------------------------------------------------------------------------
// The server table

const std::vector<ServerSpec>& defaultServerSpecs() {
    static const std::vector<ServerSpec> specs = {
        {"clangd",
         {"xcrun", "clangd", "--background-index", "--header-insertion=never", "--log=error"},
         {"c", "cpp", "objective-c", "objective-cpp"},
         "Install Xcode or its command-line tools (xcode-select --install)."},
        {"sourcekit-lsp", {"xcrun", "sourcekit-lsp"}, {"swift"}, "Install Xcode or the Swift toolchain."},
        {"pyright",
         {"pyright-langserver", "--stdio"},
         {"python"},
         "Install it with: npm install -g pyright"},
        {"typescript-language-server",
         {"typescript-language-server", "--stdio"},
         {"typescript", "typescriptreact", "javascript", "javascriptreact"},
         "Install it with: npm install -g typescript typescript-language-server"},
        {"rust-analyzer", {"rust-analyzer"}, {"rust"}, "Install it with: rustup component add rust-analyzer"},
        {"gopls", {"gopls"}, {"go"}, "Install it with: go install golang.org/x/tools/gopls@latest"},
    };
    return specs;
}

const ServerSpec* serverForLanguage(const std::vector<ServerSpec>& specs, const std::string& languageId) {
    for (const ServerSpec& spec : specs) {
        if (std::find(spec.languageIds.begin(), spec.languageIds.end(), languageId) != spec.languageIds.end()) {
            return &spec;
        }
    }
    return nullptr;
}

std::string resolveProgram(const std::string& program) {
    if (program.empty()) {
        return std::string();
    }
    if (program == "xcrun") {
        return access("/usr/bin/xcrun", X_OK) == 0 ? std::string("/usr/bin/xcrun") : std::string();
    }
    if (program.find('/') != std::string::npos) {
        return access(program.c_str(), X_OK) == 0 ? program : std::string();
    }
    return findExecutable(program);
}

std::vector<Diagnostic> parseDiagnostics(const Json& array) {
    std::vector<Diagnostic> result;
    if (!array.is_array()) {
        return result;
    }
    for (const Json& item : array) {
        if (!item.is_object() || !item.contains("range")) {
            continue;
        }
        Diagnostic diagnostic;
        diagnostic.original = item;
        diagnostic.range = item["range"];
        diagnostic.severity = item.value("severity", 1);
        diagnostic.message = item.value("message", "");
        diagnostic.source = item.value("source", "");
        if (item.contains("code")) {
            const Json& code = item["code"];
            diagnostic.code = code.is_string() ? code.get<std::string>() : code.dump();
        }
        result.push_back(std::move(diagnostic));
    }
    return result;
}

// ---------------------------------------------------------------------------
// LanguageServer

namespace {

/// The usual transport: the server is a child program talking over its standard input and output.
class ProcessTransport : public ServerTransport {
public:
    ProcessTransport(std::vector<std::string> argv, std::string workingDirectory)
        : argv_(std::move(argv)), workingDirectory_(std::move(workingDirectory)) {}

    bool start(std::string* error) override {
        ProcessOptions options;
        options.workingDirectory = workingDirectory_;
        process_.onOutput = [this](std::string_view bytes) {
            if (onOutput) onOutput(bytes);
        };
        process_.onErrorOutput = [](std::string_view) {};  // servers log to stderr; nobody reads it
        process_.onExit = [this](int code) {
            if (onExit) onExit(code);
        };
        return process_.start(argv_, options, error);
    }
    bool write(std::string_view bytes) override { return process_.write(bytes); }
    void closeInput() override { process_.closeInput(); }
    void terminate() override { process_.terminate(); }
    bool isRunning() const override { return process_.isRunning(); }

private:
    std::vector<std::string> argv_;
    std::string workingDirectory_;
    // Declared last so the reader thread is joined before the members its callbacks use go away.
    ChildProcess process_;
};

}  // namespace

std::unique_ptr<ServerTransport> makeProcessTransport(const ServerSpec& spec, const std::string& workingDirectory) {
    return std::make_unique<ProcessTransport>(spec.command, workingDirectory);
}

LanguageServer::LanguageServer(ServerSpec spec, std::string rootPath, std::unique_ptr<ServerTransport> transport)
    : spec_(std::move(spec)), rootPath_(std::move(rootPath)), transport_(std::move(transport)) {
    liveness_->server = this;
}

LanguageServer::~LanguageServer() {
    // Callbacks that reach into the owner must not run during teardown.
    {
        std::lock_guard<std::mutex> lock(callbackMutex_);
        onDiagnostics = nullptr;
        onReady = nullptr;
        onExit = nullptr;
        onApplyEdit = nullptr;
        onShowMessage = nullptr;
        onShowMessageRequest = nullptr;
        onLogMessage = nullptr;
        onProgress = nullptr;
        onConfiguration = nullptr;
    }
    {
        std::lock_guard<std::mutex> lock(liveness_->mutex);
        liveness_->server = nullptr;  // a reply that arrives from now on is dropped
    }
    if (transport_) {
        transport_->terminate();
    }
}

bool LanguageServer::start(std::string* error) {
    if (!transport_) {
        // A child program: find it first, so a missing server is reported with its install hint.
        std::vector<std::string> argv = spec_.command;
        std::string program = resolveProgram(argv.empty() ? std::string() : argv[0]);
        if (program.empty()) {
            if (error != nullptr) {
                *error = spec_.name + " isn't installed. " + spec_.installHint;
            }
            return false;
        }
        argv[0] = program;
        ServerSpec resolved = spec_;
        resolved.command = argv;
        transport_ = makeProcessTransport(resolved, rootPath_);
    }

    transport_->onOutput = [this](std::string_view bytes) { handleOutput(bytes); };
    transport_->onExit = [this](int code) {
        std::map<int, ResponseHandler> orphaned;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            ready_ = false;
            orphaned.swap(pending_);
        }
        for (auto& [id, handler] : orphaned) {
            handler(Json(), spec_.name + " stopped");
        }
        std::function<void(int)> exitHandler;
        {
            std::lock_guard<std::mutex> lock(callbackMutex_);
            exitHandler = onExit;
        }
        if (exitHandler) {
            exitHandler(code);
        }
    };
    if (!transport_->start(error)) {
        return false;
    }

    Json initialize = {
        {"jsonrpc", "2.0"},
        {"id", nextId_.fetch_add(1)},
        {"method", "initialize"},
        {"params",
         {{"processId", static_cast<int>(getpid())},
          {"clientInfo", {{"name", "Glasswork"}, {"version", "1.0"}}},
          {"rootUri", fileURI(rootPath_)},
          {"workspaceFolders", Json::array({{{"uri", fileURI(rootPath_)}, {"name", "workspace"}}})},
          {"capabilities",
           {{"general", {{"positionEncodings", Json::array({"utf-16"})}}},
            {"window", {{"workDoneProgress", true}, {"showMessage", {{"messageActionItem", {{"additionalPropertiesSupport", false}}}}}}},
            {"workspace",
             {{"workspaceEdit", {{"documentChanges", true}}},
              {"configuration", true},
              {"didChangeConfiguration", {{"dynamicRegistration", false}}},
              {"didChangeWatchedFiles", {{"dynamicRegistration", true}, {"relativePatternSupport", true}}},
              {"applyEdit", static_cast<bool>(onApplyEdit)},
              {"executeCommand", Json::object()}}},
            {"textDocument",
             {{"synchronization", {{"didSave", true}}},
              {"inlayHint", {{"dynamicRegistration", false}}},
              {"codeAction",
               {{"isPreferredSupport", true},
                {"dataSupport", true},
                {"resolveSupport", {{"properties", Json::array({"edit"})}}},
                {"codeActionLiteralSupport",
                 {{"codeActionKind",
                   {{"valueSet", Json::array({"", "quickfix", "refactor", "refactor.extract", "refactor.inline",
                                              "refactor.rewrite", "source", "source.organizeImports"})}}}}}}},
              {"completion",
               {{"completionItem",
                 {{"snippetSupport", true},
                  {"documentationFormat", Json::array({"markdown", "plaintext"})},
                  {"deprecatedSupport", true},
                  {"tagSupport", {{"valueSet", Json::array({1})}}},
                  {"preselectSupport", true},
                  {"commitCharactersSupport", true},
                  {"labelDetailsSupport", true},
                  {"resolveSupport", {{"properties", Json::array({"documentation", "detail", "additionalTextEdits"})}}}}},
                {"contextSupport", true}}},
              {"hover", {{"contentFormat", Json::array({"markdown", "plaintext"})}}},
              {"signatureHelp",
               {{"signatureInformation", {{"documentationFormat", Json::array({"markdown", "plaintext"})}}}}},
              {"definition", {{"linkSupport", false}}},
              {"references", Json::object()},
              {"rename", {{"prepareSupport", false}}},
              {"formatting", Json::object()},
              {"publishDiagnostics", {{"versionSupport", true}}},
              {"semanticTokens",
               {{"requests", {{"full", true}}},
                {"tokenTypes", Json::array({"namespace", "type", "class", "enum", "interface", "struct", "typeParameter",
                                            "parameter", "variable", "property", "enumMember", "event", "function", "method",
                                            "macro", "keyword", "modifier", "comment", "string", "number", "regexp",
                                            "operator", "decorator"})},
                {"tokenModifiers", Json::array({"declaration", "definition", "readonly", "static", "deprecated", "abstract",
                                                "async", "modification", "documentation", "defaultLibrary"})},
                {"formats", Json::array({"relative"})},
                {"multilineTokenSupport", false},
                {"overlappingTokenSupport", false}}}}}}}}}};
    int handshakeId = initialize["id"];
    {
        std::lock_guard<std::mutex> lock(mutex_);
        pending_[handshakeId] = [this](const Json& result, const std::string&) { finishHandshake(result); };
    }
    transport_->write(frameMessage(initialize));
    return true;
}

void LanguageServer::finishHandshake(const Json& result) {
    std::vector<Json> queued;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        capabilities_ = result.value("capabilities", Json::object());
        ready_ = true;
        queued.swap(waitingForReady_);
    }
    transport_->write(frameMessage({{"jsonrpc", "2.0"}, {"method", "initialized"}, {"params", Json::object()}}));
    for (Json& message : queued) {
        transport_->write(frameMessage(message));
    }
    std::function<void()> readyHandler;
    {
        std::lock_guard<std::mutex> lock(callbackMutex_);
        readyHandler = onReady;
    }
    if (readyHandler) {
        readyHandler();
    }
}

void LanguageServer::stop() {
    bool wasRunning = false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        wasRunning = ready_ && !stopping_;
        stopping_ = true;
    }
    if (wasRunning && transport_) {
        transport_->write(frameMessage({{"jsonrpc", "2.0"}, {"id", nextId_.fetch_add(1)}, {"method", "shutdown"}}));
        transport_->write(frameMessage({{"jsonrpc", "2.0"}, {"method", "exit"}}));
        transport_->closeInput();
    }
    if (transport_) {
        transport_->terminate();
    }
}

bool LanguageServer::isRunning() const { return transport_ != nullptr && transport_->isRunning(); }

bool LanguageServer::isReady() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return ready_;
}

Json LanguageServer::capabilities() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return capabilities_;
}

bool LanguageServer::supports(const std::string& capability) const {
    std::lock_guard<std::mutex> lock(mutex_);

    // "codeActionProvider.resolveProvider" looks inside the capability, one name at a time.
    const Json* current = &capabilities_;
    size_t nameStart = 0;
    while (nameStart <= capability.size()) {
        size_t dot = capability.find('.', nameStart);
        size_t nameEnd = dot == std::string::npos ? capability.size() : dot;
        std::string name = capability.substr(nameStart, nameEnd - nameStart);
        if (!current->is_object() || !current->contains(name)) {
            return false;
        }
        current = &(*current)[name];
        if (dot == std::string::npos) {
            break;
        }
        nameStart = dot + 1;
    }

    if (current->is_boolean()) {
        return current->get<bool>();
    }
    return !current->is_null();
}

void LanguageServer::send(Json message) {
    trace("->", message);
    std::string frame = frameMessage(message);
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!ready_) {
            waitingForReady_.push_back(std::move(message));
            return;
        }
    }
    transport_->write(frame);
}

void LanguageServer::didOpen(const std::string& uri, const std::string& languageId, uint64_t version, const std::string& text) {
    send({{"jsonrpc", "2.0"},
          {"method", "textDocument/didOpen"},
          {"params", {{"textDocument", {{"uri", uri}, {"languageId", languageId}, {"version", version}, {"text", text}}}}}});
}

void LanguageServer::didChange(const std::string& uri, uint64_t version, const std::string& text) {
    send({{"jsonrpc", "2.0"},
          {"method", "textDocument/didChange"},
          {"params",
           {{"textDocument", {{"uri", uri}, {"version", version}}}, {"contentChanges", Json::array({{{"text", text}}})}}}});
}

void LanguageServer::didChangeIncremental(const std::string& uri, uint64_t version, const std::vector<SyncEdit>& edits) {
    Json changes = Json::array();
    for (const SyncEdit& edit : edits) {
        Json start = {{"line", edit.startLine}, {"character", edit.startUnits}};
        Json end = {{"line", edit.endLine}, {"character", edit.endUnits}};
        changes.push_back({{"range", {{"start", start}, {"end", end}}}, {"text", edit.text}});
    }
    send({{"jsonrpc", "2.0"},
          {"method", "textDocument/didChange"},
          {"params", {{"textDocument", {{"uri", uri}, {"version", version}}}, {"contentChanges", changes}}}});
}

bool LanguageServer::wantsIncrementalSync() const {
    constexpr int kIncremental = 2;
    std::lock_guard<std::mutex> lock(mutex_);
    if (!capabilities_.is_object() || !capabilities_.contains("textDocumentSync")) {
        return false;
    }
    const Json& sync = capabilities_["textDocumentSync"];
    if (sync.is_number_integer()) {
        return sync.get<int>() == kIncremental;
    }
    if (sync.is_object() && sync.contains("change") && sync["change"].is_number_integer()) {
        return sync["change"].get<int>() == kIncremental;
    }
    return false;
}

bool LanguageServer::watchesFiles() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return !watchers_.empty();
}

void LanguageServer::didChangeWatchedFiles(const std::vector<FileEvent>& events) {
    Json changes = Json::array();
    {
        std::lock_guard<std::mutex> lock(mutex_);
        for (const FileEvent& event : events) {
            int kindBit = event.type == 1 ? 1 : (event.type == 2 ? 2 : 4);
            for (const Watcher& watcher : watchers_) {
                if ((watcher.kinds & kindBit) == 0) continue;
                std::string prefix = watcher.base + "/";
                if (event.path.rfind(prefix, 0) != 0) continue;  // outside the folder the pattern is for
                if (watcher.pattern->matches(event.path.substr(prefix.size()))) {
                    changes.push_back({{"uri", fileURI(event.path)}, {"type", event.type}});
                    break;
                }
            }
        }
    }
    if (changes.empty()) {
        return;
    }
    send({{"jsonrpc", "2.0"}, {"method", "workspace/didChangeWatchedFiles"}, {"params", {{"changes", changes}}}});
}

void LanguageServer::didChangeConfiguration(const Json& settings) {
    send({{"jsonrpc", "2.0"}, {"method", "workspace/didChangeConfiguration"}, {"params", {{"settings", settings}}}});
}

void LanguageServer::didSave(const std::string& uri) {
    send({{"jsonrpc", "2.0"}, {"method", "textDocument/didSave"}, {"params", {{"textDocument", {{"uri", uri}}}}}});
}

void LanguageServer::didClose(const std::string& uri) {
    send({{"jsonrpc", "2.0"}, {"method", "textDocument/didClose"}, {"params", {{"textDocument", {{"uri", uri}}}}}});
}

void LanguageServer::request(const std::string& method, Json parameters, ResponseHandler handler) {
    int identifier = nextId_.fetch_add(1);
    {
        std::lock_guard<std::mutex> lock(mutex_);
        pending_[identifier] = std::move(handler);
    }
    send({{"jsonrpc", "2.0"}, {"id", identifier}, {"method", method}, {"params", std::move(parameters)}});
}

void LanguageServer::cancel(int requestId) {
    bool wasPending = false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        wasPending = pending_.erase(requestId) > 0;
    }
    if (wasPending) {
        send({{"jsonrpc", "2.0"}, {"method", "$/cancelRequest"}, {"params", {{"id", requestId}}}});
    }
}

void LanguageServer::handleOutput(std::string_view bytes) {
    std::vector<Json> messages;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        try {
            decoder_.append(bytes);
            while (std::optional<Json> next = decoder_.next()) {
                messages.push_back(std::move(*next));
            }
        } catch (const std::exception&) {
            // A broken stream can't be resynchronised: give up on this server.
            stopping_ = true;
            decoder_ = Decoder();
        }
    }
    for (const Json& message : messages) {
        handleMessage(message);
    }
}

std::string capabilityKeyForMethod(const std::string& method) {
    static const std::map<std::string, std::string> keys = {
        {"textDocument/completion", "completionProvider"},
        {"textDocument/hover", "hoverProvider"},
        {"textDocument/signatureHelp", "signatureHelpProvider"},
        {"textDocument/definition", "definitionProvider"},
        {"textDocument/declaration", "declarationProvider"},
        {"textDocument/typeDefinition", "typeDefinitionProvider"},
        {"textDocument/implementation", "implementationProvider"},
        {"textDocument/references", "referencesProvider"},
        {"textDocument/documentHighlight", "documentHighlightProvider"},
        {"textDocument/documentSymbol", "documentSymbolProvider"},
        {"workspace/symbol", "workspaceSymbolProvider"},
        {"textDocument/codeAction", "codeActionProvider"},
        {"textDocument/codeLens", "codeLensProvider"},
        {"textDocument/documentLink", "documentLinkProvider"},
        {"textDocument/formatting", "documentFormattingProvider"},
        {"textDocument/rangeFormatting", "documentRangeFormattingProvider"},
        {"textDocument/onTypeFormatting", "documentOnTypeFormattingProvider"},
        {"textDocument/rename", "renameProvider"},
        {"textDocument/foldingRange", "foldingRangeProvider"},
        {"textDocument/selectionRange", "selectionRangeProvider"},
        {"textDocument/semanticTokens", "semanticTokensProvider"},
        {"textDocument/semanticTokens/full", "semanticTokensProvider"},
        {"textDocument/inlayHint", "inlayHintProvider"},
        {"workspace/executeCommand", "executeCommandProvider"},
    };
    auto found = keys.find(method);
    return found == keys.end() ? std::string() : found->second;
}

namespace {

/// Combines two registrations of the same capability: lists are joined, flags are or-ed
/// (two completion providers with different trigger characters trigger on both sets).
Json mergeCapability(const Json& existing, const Json& incoming) {
    if (!existing.is_object() || !incoming.is_object()) {
        return incoming.is_object() ? incoming : (existing.is_object() ? existing : Json(true));
    }
    Json merged = existing;
    for (const auto& [key, value] : incoming.items()) {
        if (!merged.contains(key)) {
            merged[key] = value;
        } else if (merged[key].is_array() && value.is_array()) {
            for (const Json& item : value) {
                bool present = false;
                for (const Json& known : merged[key]) {
                    if (known == item) {
                        present = true;
                        break;
                    }
                }
                if (!present) {
                    merged[key].push_back(item);
                }
            }
        } else if (merged[key].is_boolean() && value.is_boolean()) {
            merged[key] = merged[key].get<bool>() || value.get<bool>();
        }
    }
    return merged;
}

}  // namespace

/// `client/registerCapability`: the server adds features after the handshake (many do, and the
/// extension host always does, since providers appear as extensions activate).
void LanguageServer::registerCapabilities(const Json& registrations) {
    if (!registrations.is_array()) {
        return;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    if (!capabilities_.is_object()) {
        capabilities_ = Json::object();
    }
    for (const Json& registration : registrations) {
        std::string id = registration.value("id", "");
        if (registration.value("method", "") == "workspace/didChangeWatchedFiles") {
            // Not a capability: a list of file patterns the server wants to hear about.
            Json options = registration.contains("registerOptions") ? registration["registerOptions"] : Json::object();
            for (const Json& watcher : options.value("watchers", Json::array())) {
                if (!watcher.is_object() || !watcher.contains("globPattern")) continue;
                Watcher entry;
                entry.registrationId = id;
                entry.kinds = watcher.value("kind", 7);
                entry.base = rootPath_;
                const Json& glob = watcher["globPattern"];
                std::string pattern;
                if (glob.is_string()) {
                    pattern = glob.get<std::string>();
                } else if (glob.is_object() && glob.contains("pattern")) {
                    pattern = glob.value("pattern", "");
                    Json base = glob.contains("baseUri") ? glob["baseUri"] : Json();
                    std::string baseUri = base.is_string() ? base.get<std::string>() : (base.is_object() ? base.value("uri", "") : "");
                    if (!baseUri.empty()) entry.base = pathFromURI(baseUri);
                }
                if (pattern.empty()) continue;
                entry.pattern = std::make_shared<GlobPattern>(pattern);
                watchers_.push_back(std::move(entry));
            }
            continue;
        }
        std::string key = capabilityKeyForMethod(registration.value("method", ""));
        if (key.empty()) {
            continue;
        }
        Json options = registration.contains("registerOptions") ? registration["registerOptions"] : Json(true);
        if (!capabilities_.contains(key)) {
            dynamicOnlyKeys_.insert(key);
        }
        Json current = capabilities_.contains(key) ? capabilities_[key] : Json();
        if (!current.is_null()) {
            capabilities_[key] = mergeCapability(current, options);
        } else if (options.is_object()) {
            capabilities_[key] = options;
        } else {
            capabilities_[key] = Json(true);  // registered without options: the feature is simply on
        }
        if (!id.empty()) {
            registrationKeys_[id] = key;
        }
    }
}

void LanguageServer::unregisterCapabilities(const Json& unregisterations) {
    if (!unregisterations.is_array()) {
        return;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    for (const Json& item : unregisterations) {
        std::string id = item.value("id", "");
        watchers_.erase(std::remove_if(watchers_.begin(), watchers_.end(), [&](const Watcher& watcher) { return watcher.registrationId == id; }),
                        watchers_.end());
        auto found = registrationKeys_.find(id);
        if (found == registrationKeys_.end()) {
            continue;
        }
        std::string key = found->second;
        registrationKeys_.erase(found);
        bool stillRegistered = false;
        for (const auto& [otherId, otherKey] : registrationKeys_) {
            if (otherKey == key) {
                stillRegistered = true;
                break;
            }
        }
        if (!stillRegistered && dynamicOnlyKeys_.count(key) > 0 && capabilities_.is_object()) {
            capabilities_.erase(key);
            dynamicOnlyKeys_.erase(key);
        }
    }
}

void LanguageServer::replyToApplyEdit(const Json& requestId, bool applied) {
    transport_->write(frameMessage({{"jsonrpc", "2.0"}, {"id", requestId}, {"result", {{"applied", applied}}}}));
}

void LanguageServer::handleMessage(const Json& message) {
    trace("<-", message);
    bool hasMethod = message.contains("method");
    bool hasId = message.contains("id");

    if (!hasMethod && hasId) {
        handleResponse(message);
    } else if (hasMethod && hasId) {
        handleServerRequest(message);
    } else if (hasMethod) {
        handleNotification(message);
    }
}

/// An answer to one of our requests: finds who asked and hands it over.
void LanguageServer::handleResponse(const Json& message) {
    // An answer to one of our requests.
    int identifier = message["id"].is_number_integer() ? message["id"].get<int>() : -1;
    ResponseHandler handler;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto found = pending_.find(identifier);
        if (found == pending_.end()) {
            return;
        }
        handler = std::move(found->second);
        pending_.erase(found);
    }
    std::string error;
    if (message.contains("error")) {
        error = message["error"].value("message", "Language server error");
    }
    handler(error.empty() ? message.value("result", Json()) : Json(), error);
    return;
}

/// The server is asking us something. We say no politely, except where "nothing" is a fine answer.
void LanguageServer::handleServerRequest(const Json& message) {
    // The server is asking us something. Say no politely, except where "nothing" is a fine answer.
    std::string method = message["method"].get<std::string>();
    Json result;
    if (method == "workspace/configuration") {
        std::function<Json(const std::string&, const std::string&)> provider;
        {
            std::lock_guard<std::mutex> lock(callbackMutex_);
            provider = onConfiguration;
        }
        result = Json::array();
        for (const Json& item : message["params"].value("items", Json::array())) {
            Json value;  // null: not set
            if (provider && item.is_object()) {
                value = provider(item.value("section", ""), item.value("scopeUri", ""));
            }
            result.push_back(value);
        }
    } else if (method == "window/showMessageRequest") {
        auto handler = copyCallback(onShowMessageRequest);
        if (handler) {
            std::vector<std::string> actions;
            for (const Json& action : message["params"].value("actions", Json::array())) {
                actions.push_back(action.value("title", ""));
            }
            std::shared_ptr<Liveness> liveness = liveness_;
            Json requestId = message["id"];
            Json originalActions = message["params"].value("actions", Json::array());
            handler(message["params"].value("type", 3), message["params"].value("message", ""), actions,
                    [liveness, requestId, originalActions](const std::string& chosen) {
                        std::lock_guard<std::mutex> lock(liveness->mutex);
                        if (liveness->server == nullptr) {
                            return;
                        }
                        Json answer;  // null: dismissed
                        for (const Json& action : originalActions) {
                            if (action.value("title", "") == chosen && !chosen.empty()) {
                                answer = action;
                            }
                        }
                        liveness->server->transport_->write(
                            frameMessage({{"jsonrpc", "2.0"}, {"id", requestId}, {"result", answer}}));
                    });
            return;
        }
        result = Json();
    } else if (method == "workspace/applyEdit") {
        auto handler = copyCallback(onApplyEdit);
        if (handler) {
            // The answer goes out whenever the app has made (or refused) the changes.
            std::shared_ptr<Liveness> liveness = liveness_;
            Json requestId = message["id"];
            handler(message["params"].value("edit", Json::object()), [liveness, requestId](bool applied) {
                std::lock_guard<std::mutex> lock(liveness->mutex);
                if (liveness->server != nullptr) {
                    liveness->server->replyToApplyEdit(requestId, applied);
                }
            });
            return;
        }
        result = {{"applied", false}};
    } else if (method == "client/registerCapability") {
        registerCapabilities(message["params"].value("registrations", Json::array()));
        result = Json();
    } else if (method == "client/unregisterCapability") {
        unregisterCapabilities(message["params"].value("unregisterations", Json::array()));
        result = Json();
    } else if (method == "window/workDoneProgress/create") {
        result = Json();
    } else {
        transport_->write(frameMessage({{"jsonrpc", "2.0"},
                                     {"id", message["id"]},
                                     {"error", {{"code", -32601}, {"message", "Not supported by this client"}}}}));
        return;
    }
    transport_->write(frameMessage({{"jsonrpc", "2.0"}, {"id", message["id"]}, {"result", result}}));
    return;
}

/// Something the server tells us and expects no answer to: messages, progress and problems found.
void LanguageServer::handleNotification(const Json& message) {
    std::string method = message["method"].get<std::string>();
    const Json parameters = message.contains("params") ? message["params"] : Json::object();
    if (method == "window/showMessage" || method == "window/logMessage") {
        std::function<void(int, const std::string&)> handler;
        {
            std::lock_guard<std::mutex> lock(callbackMutex_);
            handler = method == "window/showMessage" ? onShowMessage : onLogMessage;
        }
        if (handler) {
            handler(parameters.value("type", 3), parameters.value("message", ""));
        }
        return;
    }
    if (method == "$/progress") {
        auto handler = copyCallback(onProgress);
        if (handler && parameters.contains("value") && parameters["value"].is_object()) {
            const Json& value = parameters["value"];
            // A progress token is a string or a number; either way it is only used as a name.
            std::string token;
            if (parameters.contains("token")) {
                const Json& tokenValue = parameters["token"];
                token = tokenValue.is_string() ? tokenValue.get<std::string>() : tokenValue.dump();
            }
            int percentage = value.contains("percentage") && value["percentage"].is_number() ? value["percentage"].get<int>() : -1;
            handler(token, value.value("kind", ""), value.value("title", ""), value.value("message", ""), percentage);
        }
        return;
    }

    if (message["method"] == "textDocument/publishDiagnostics") {
        auto handler = copyCallback(onDiagnostics);
        if (handler) {
            const Json& parameters = message["params"];
            long version = -1;
            if (parameters.contains("version") && parameters["version"].is_number()) {
                version = parameters["version"].get<long>();
            }
            handler(parameters.value("uri", ""), version, parseDiagnostics(parameters.value("diagnostics", Json::array())));
        }
    }
}

}  // namespace gw::lsp
