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

LanguageServer::LanguageServer(ServerSpec spec, std::string rootPath)
    : spec_(std::move(spec)), rootPath_(std::move(rootPath)) {}

LanguageServer::~LanguageServer() {
    // Callbacks that reach into the owner must not run during teardown.
    {
        std::lock_guard<std::mutex> lock(callbackMutex_);
        onDiagnostics = nullptr;
        onReady = nullptr;
        onExit = nullptr;
    }
    process_.terminate();
}

bool LanguageServer::start(std::string* error) {
    std::vector<std::string> argv = spec_.command;
    std::string program = resolveProgram(argv.empty() ? std::string() : argv[0]);
    if (program.empty()) {
        if (error != nullptr) {
            *error = spec_.name + " isn't installed. " + spec_.installHint;
        }
        return false;
    }
    argv[0] = program;

    ProcessOptions options;
    options.workingDirectory = rootPath_;
    process_.onOutput = [this](std::string_view bytes) { handleOutput(bytes); };
    process_.onErrorOutput = [](std::string_view) {};  // servers log to stderr; nobody reads it
    process_.onExit = [this](int code) {
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
    if (!process_.start(argv, options, error)) {
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
            {"workspace", {{"workspaceEdit", {{"documentChanges", true}}}, {"configuration", true}}},
            {"textDocument",
             {{"synchronization", {{"didSave", true}}},
              {"completion",
               {{"completionItem", {{"snippetSupport", false}, {"documentationFormat", Json::array({"markdown", "plaintext"})}}}}},
              {"hover", {{"contentFormat", Json::array({"markdown", "plaintext"})}}},
              {"signatureHelp",
               {{"signatureInformation", {{"documentationFormat", Json::array({"markdown", "plaintext"})}}}}},
              {"definition", {{"linkSupport", false}}},
              {"references", Json::object()},
              {"rename", {{"prepareSupport", false}}},
              {"formatting", Json::object()},
              {"publishDiagnostics", {{"versionSupport", true}}}}}}}}}};
    int handshakeId = initialize["id"];
    {
        std::lock_guard<std::mutex> lock(mutex_);
        pending_[handshakeId] = [this](const Json& result, const std::string&) { finishHandshake(result); };
    }
    process_.write(frameMessage(initialize));
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
    process_.write(frameMessage({{"jsonrpc", "2.0"}, {"method", "initialized"}, {"params", Json::object()}}));
    for (Json& message : queued) {
        process_.write(frameMessage(message));
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
    if (wasRunning) {
        process_.write(frameMessage({{"jsonrpc", "2.0"}, {"id", nextId_.fetch_add(1)}, {"method", "shutdown"}}));
        process_.write(frameMessage({{"jsonrpc", "2.0"}, {"method", "exit"}}));
        process_.closeInput();
    }
    process_.terminate();
}

bool LanguageServer::isRunning() const { return process_.isRunning(); }

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
    if (!capabilities_.is_object() || !capabilities_.contains(capability)) {
        return false;
    }
    const Json& value = capabilities_[capability];
    if (value.is_boolean()) {
        return value.get<bool>();
    }
    return !value.is_null();
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
    process_.write(frame);
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

void LanguageServer::handleMessage(const Json& message) {
    trace("<-", message);
    bool hasMethod = message.contains("method");
    bool hasId = message.contains("id");

    if (!hasMethod && hasId) {
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

    if (hasMethod && hasId) {
        // The server is asking us something. Say no politely, except where "nothing" is a fine answer.
        std::string method = message["method"].get<std::string>();
        Json result;
        if (method == "workspace/configuration") {
            size_t count = message["params"].value("items", Json::array()).size();
            result = Json::array();
            for (size_t index = 0; index < count; ++index) {
                result.push_back(Json());
            }
        } else if (method == "workspace/applyEdit") {
            result = {{"applied", false}};
        } else if (method == "window/workDoneProgress/create" || method == "client/registerCapability" ||
                   method == "client/unregisterCapability" || method == "window/showMessageRequest") {
            result = Json();
        } else {
            process_.write(frameMessage({{"jsonrpc", "2.0"},
                                         {"id", message["id"]},
                                         {"error", {{"code", -32601}, {"message", "Not supported by this client"}}}}));
            return;
        }
        process_.write(frameMessage({{"jsonrpc", "2.0"}, {"id", message["id"]}, {"result", result}}));
        return;
    }

    if (hasMethod && message["method"] == "textDocument/publishDiagnostics") {
        std::function<void(const std::string&, long, std::vector<Diagnostic>)> handler;
        {
            std::lock_guard<std::mutex> lock(callbackMutex_);
            handler = onDiagnostics;
        }
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
