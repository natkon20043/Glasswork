#pragma once

#include "TextBuffer.hpp"
#include <nlohmann/json.hpp>
#include <chrono>
#include <map>
#include <optional>
#include <string>
#include <vector>

namespace gw::lsp {
using Json = nlohmann::json;

// LSP positions count UTF-16 code units; our editor counts UTF-8 bytes.
Json position(const TextBuffer &buffer, Position caret);
Position position(const TextBuffer &buffer, const Json &value);
std::string fileURI(const std::string &absolutePath);
/// The wire form of a message: a Content-Length header followed by the JSON.
std::string frameMessage(const Json &message);
/// The path a file:// URI stands for (percent escapes decoded); empty if it isn't a file URI.
std::string pathFromURI(const std::string &uri);

// Streaming framing, independent of the process and UI, to handle split/coalesced reads.
class Decoder {
public:
    void append(std::string_view bytes);
    std::optional<Json> next();
private:
    std::string bytes_;
};

struct Snapshot {
    std::string uri;
    std::string language;
    std::string text;
    uint64_t version;
};

// Confined to one background queue. Never performs I/O on the AppKit main thread.
// Starts only when a code-intelligence command is requested, and retains one server.
class Client {
public:
    explicit Client(const std::string &rootURI);
    ~Client();
    Client(const Client &) = delete;
    Client &operator=(const Client &) = delete;
    void synchronize(const std::vector<Snapshot> &documents);
    Json request(const std::string &method, Json parameters);
    Json diagnostics(const Snapshot &document);
private:
    using Deadline = std::chrono::steady_clock::time_point;
    void send(Json message);
    void notify(const std::string &method, Json parameters);
    Json read(Deadline deadline);
    void handle(const Json &message);
    void stop();
    int process_ = -1;
    int input_ = -1;
    int output_ = -1;
    int nextID_ = 1;
    Decoder decoder_;
    std::map<std::string, uint64_t> versions_;
    std::map<std::string, Json> diagnostics_;
};
}
