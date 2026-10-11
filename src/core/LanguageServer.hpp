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

struct Snapshot {
    std::string uri;
    std::string language;
    std::string text;
    uint64_t version;
};

// ---- Conversions (LSP counts UTF-16 code units; the editor counts UTF-8 bytes)

Json position(const TextBuffer &buffer, Position caret);
Position position(const TextBuffer &buffer, const Json &value);
std::string fileURI(const std::string &absolutePath);
/// Empty if not a file:// URI; percent escapes are decoded.
std::string pathFromURI(const std::string &uri);
/// Content-Length header followed by the JSON.
std::string frameMessage(const Json &message);

/// Reassembles messages from split or coalesced reads, independent of process and UI.
class Decoder {
public:
    // ---- Input
    void append(std::string_view bytes);
    std::optional<Json> next();

private:
    // ---- Private variables
    std::string bytes_;
};

/// Confined to one background queue; never does I/O on the AppKit main thread. Starts only when a
/// code-intelligence command is requested and retains one server.
class Client {
public:
    // ---- Constructors and destructor
    explicit Client(const std::string &rootURI);
    ~Client();
    Client(const Client &) = delete;
    Client &operator=(const Client &) = delete;

    // ---- Requests
    void synchronize(const std::vector<Snapshot> &documents);
    Json request(const std::string &method, Json parameters);
    Json diagnostics(const Snapshot &document);

private:
    using Deadline = std::chrono::steady_clock::time_point;

    // ---- Private functions
    void send(Json message);
    void notify(const std::string &method, Json parameters);
    Json read(Deadline deadline);
    void handle(const Json &message);
    void stop();

    // ---- Private variables
    int process_ = -1;
    int input_ = -1;
    int output_ = -1;
    int nextID_ = 1;
    Decoder decoder_;
    std::map<std::string, uint64_t> versions_;
    std::map<std::string, Json> diagnostics_;
};
}
