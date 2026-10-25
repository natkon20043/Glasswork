#include "ExtensionHost.hpp"

#include <algorithm>
#include <cstdlib>
#include <dirent.h>
#include <unistd.h>

namespace gw {

namespace {

}  // namespace

// ---------------------------------------------------------------------------
// The shared state transports use to reach the host without owning it

struct ExtensionHost::Shared {
    std::mutex mutex;
    ExtensionHost* host = nullptr;  // null once the host is destroyed
};

/// One virtual language server inside the host. LanguageServer writes framed LSP messages here;
/// they are unwrapped and forwarded as `lsp/message` notifications, and the host's answers come
/// back (via deliver) as framed bytes for LanguageServer's decoder.
class ExtensionHost::HostTransport : public lsp::ServerTransport {
public:
    HostTransport(std::shared_ptr<Shared> shared, std::string serverId, std::string language, std::string rootUri)
        : shared_(std::move(shared)),
          serverId_(std::move(serverId)),
          language_(std::move(language)),
          rootUri_(std::move(rootUri)) {}

    ~HostTransport() override { terminate(); }

    bool start(std::string*) override {
        std::lock_guard<std::mutex> lock(shared_->mutex);
        ExtensionHost* host = shared_->host;
        if (host == nullptr || !host->isRunning()) {
            return false;
        }
        {
            std::lock_guard<std::mutex> hostLock(host->mutex_);
            host->transports_[serverId_] = this;
        }
        running_ = true;
        host->request("lsp/open", Json{{"server", serverId_}, {"language", language_}, {"rootUri", rootUri_}},
                      [](const Json&, const std::string&) {});
        return true;
    }

    bool write(std::string_view bytes) override {
        std::lock_guard<std::mutex> lock(shared_->mutex);
        ExtensionHost* host = shared_->host;
        if (host == nullptr || !running_) {
            return false;
        }
        incoming_.append(bytes);
        while (std::optional<Json> message = incoming_.next()) {
            host->notify("lsp/message", Json{{"server", serverId_}, {"message", *message}});
        }
        return true;
    }

    void closeInput() override {}

    void terminate() override {
        std::lock_guard<std::mutex> lock(shared_->mutex);
        if (!running_) {
            return;
        }
        running_ = false;
        ExtensionHost* host = shared_->host;
        if (host != nullptr) {
            {
                std::lock_guard<std::mutex> hostLock(host->mutex_);
                host->transports_.erase(serverId_);
            }
            host->notify("lsp/close", Json{{"server", serverId_}});
        }
    }

    bool isRunning() const override { return running_.load(); }

    /// A message from the host's virtual server: hand it to LanguageServer as framed bytes.
    void deliver(const Json& message) {
        if (onOutput) {
            onOutput(lsp::frameMessage(message));
        }
    }

    /// The host went away.
    void ended(int exitCode) {
        bool wasRunning = running_.exchange(false);
        if (wasRunning && onExit) {
            onExit(exitCode);
        }
    }

private:
    std::shared_ptr<Shared> shared_;
    std::string serverId_;
    std::string language_;
    std::string rootUri_;
    std::atomic<bool> running_{false};
    lsp::Decoder incoming_;
};

// ---------------------------------------------------------------------------

ExtensionHost::ExtensionHost() : shared_(std::make_shared<Shared>()) {
    shared_->host = this;
}

ExtensionHost::~ExtensionHost() {
    {
        std::lock_guard<std::mutex> lock(shared_->mutex);
        shared_->host = nullptr;  // transports still alive stop talking to us
    }
    process_.terminate();
}

std::string ExtensionHost::findNode() {
    std::string onPath = findExecutable("node");
    if (!onPath.empty()) {
        return onPath;
    }
    std::string nvmFolder = newestNvmBinFolder();
    if (!nvmFolder.empty()) {
        std::string nvmNode = nvmFolder + "/node";
        if (access(nvmNode.c_str(), X_OK) == 0) {
            return nvmNode;
        }
    }
    const char* home = std::getenv("HOME");
    std::vector<std::string> candidates = {"/opt/homebrew/bin/node", "/usr/local/bin/node"};
    if (home != nullptr) {
        candidates.push_back(std::string(home) + "/.volta/bin/node");
        candidates.push_back(std::string(home) + "/.local/bin/node");
    }
    for (const std::string& candidate : candidates) {
        if (access(candidate.c_str(), X_OK) == 0) {
            return candidate;
        }
    }
    return std::string();
}

bool ExtensionHost::start(const Settings& settings, std::string* error) {
    std::string node = settings.nodeProgram.empty() ? findNode() : settings.nodeProgram;
    if (node.empty()) {
        if (error != nullptr) {
            *error = "Extensions need Node.js, which wasn't found. Install it from nodejs.org or with Homebrew (brew install "
                     "node).";
        }
        return false;
    }

    // The host needs a reasonably recent Node (module hooks, fetch, structuredClone).
    ProcessResult versionCheck = runProcess({node, "--version"});
    long version = versionNumber(versionCheck.output);
    if (!versionCheck.succeeded() || version < 18000000) {
        if (error != nullptr) {
            std::string found = versionCheck.output.empty() ? std::string("none that runs") : versionCheck.output;
            *error = "Extensions need Node.js 18 or newer; found " + found;
        }
        return false;
    }

    process_.onOutput = [this](std::string_view bytes) { handleOutput(bytes); };
    process_.onErrorOutput = [this](std::string_view bytes) {
        if (onStderr) onStderr(bytes);
    };
    process_.onExit = [this](int code) { failEverything(code); };

    ProcessOptions options;
    options.workingDirectory = settings.workingDirectory;
    return process_.start({node, settings.hostScript}, options, error);
}

void ExtensionHost::stop() {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (stopping_) {
            return;
        }
        stopping_ = true;
    }
    if (process_.isRunning()) {
        send(Json{{"jsonrpc", "2.0"}, {"id", nextId_.fetch_add(1)}, {"method", "shutdown"}});
        send(Json{{"jsonrpc", "2.0"}, {"method", "exit"}});
        process_.closeInput();
    }
    process_.terminate();
}

bool ExtensionHost::isRunning() const { return process_.isRunning(); }

void ExtensionHost::send(const Json& message) {
    process_.write(lsp::frameMessage(message));
}

void ExtensionHost::request(const std::string& method, Json params, ResponseHandler handler) {
    if (!process_.isRunning()) {
        // Nobody would ever answer: say so now rather than leave the caller waiting.
        handler(Json(), "The extension host isn't running");
        return;
    }
    int identifier = nextId_.fetch_add(1);
    {
        std::lock_guard<std::mutex> lock(mutex_);
        pending_[identifier] = std::move(handler);
    }
    send(Json{{"jsonrpc", "2.0"}, {"id", identifier}, {"method", method}, {"params", std::move(params)}});
}

void ExtensionHost::notify(const std::string& method, Json params) {
    send(Json{{"jsonrpc", "2.0"}, {"method", method}, {"params", std::move(params)}});
}

std::unique_ptr<lsp::ServerTransport> ExtensionHost::makeServerTransport(const std::string& language, const std::string& rootUri) {
    std::string identifier = "ext:" + language + ":" + std::to_string(nextServer_.fetch_add(1));
    return std::make_unique<HostTransport>(shared_, identifier, language, rootUri);
}

void ExtensionHost::handleOutput(std::string_view bytes) {
    decoder_.append(bytes);
    while (std::optional<Json> message = decoder_.next()) {
        handleMessage(*message);
    }
}

void ExtensionHost::deliverToServer(const std::string& serverId, const Json& message) {
    HostTransport* transport = nullptr;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto found = transports_.find(serverId);
        if (found != transports_.end()) {
            transport = found->second;
        }
    }
    if (transport != nullptr) {
        transport->deliver(message);
    }
}

void ExtensionHost::handleMessage(const Json& message) {
    bool hasMethod = message.contains("method");
    bool hasId = message.contains("id") && !message["id"].is_null();

    if (!hasMethod && hasId) {
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
            error = message["error"].value("message", "Extension host error");
        }
        handler(error.empty() ? message.value("result", Json()) : Json(), error);
        return;
    }

    if (!hasMethod) {
        return;
    }
    std::string method = message["method"].get<std::string>();
    Json params = message.contains("params") ? message["params"] : Json::object();

    if (hasId) {
        // The host is asking us something. The answer is sent whenever `reply` is called.
        Json requestId = message["id"];
        std::shared_ptr<Shared> shared = shared_;
        Reply reply = [shared, requestId](const Json& result, const std::string& error) {
            std::lock_guard<std::mutex> lock(shared->mutex);
            if (shared->host == nullptr) {
                return;
            }
            if (error.empty()) {
                shared->host->send(Json{{"jsonrpc", "2.0"}, {"id", requestId}, {"result", result}});
            } else {
                shared->host->send(Json{{"jsonrpc", "2.0"},
                                        {"id", requestId},
                                        {"error", {{"code", -32603}, {"message", error}}}});
            }
        };
        if (onRequest) {
            onRequest(method, params, reply);
        } else {
            reply(Json(), "Not supported");
        }
        return;
    }

    if (method == "lsp/message") {
        deliverToServer(params.value("server", ""), params.value("message", Json::object()));
        return;
    }
    if (method == "host/ready") {
        ready_ = true;
        if (onReady) onReady();
        return;
    }
    if (onNotification) {
        onNotification(method, params);
    }
}

void ExtensionHost::failEverything(int exitCode) {
    ready_ = false;
    std::map<int, ResponseHandler> orphaned;
    {
        // The shared lock is held while the transports are told, so none of them can be destroyed
        // (their destructors wait for it) between being found and being used.
        std::lock_guard<std::mutex> sharedLock(shared_->mutex);
        std::vector<HostTransport*> affected;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            orphaned.swap(pending_);
            for (auto& [id, transport] : transports_) {
                affected.push_back(transport);
            }
            transports_.clear();
        }
        for (HostTransport* transport : affected) {
            transport->ended(exitCode);
        }
    }
    for (auto& [id, handler] : orphaned) {
        handler(Json(), "The extension host stopped");
    }
    if (onExit) {
        onExit(exitCode);
    }
}

}  // namespace gw
