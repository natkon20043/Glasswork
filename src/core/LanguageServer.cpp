#include "LanguageServer.hpp"

#include <algorithm>
#include <cctype>
#include <cerrno>
#include <charconv>
#include <csignal>
#include <fcntl.h>
#include <poll.h>
#include <spawn.h>
#include <stdexcept>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

namespace gw::lsp {
namespace {
constexpr size_t maximumMessage = 32 * 1024 * 1024;

size_t characterBytes(unsigned char first) {
    if (first < 0x80) return 1;
    if (first < 0xE0) return 2;
    if (first < 0xF0) return 3;
    return 4;
}

void waitFor(int descriptor, short events, std::chrono::steady_clock::time_point deadline) {
    for (;;) {
        auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - std::chrono::steady_clock::now()).count();
        if (remaining <= 0) {
            throw std::runtime_error("clangd timed out. Try again after indexing finishes.");
        }
        pollfd descriptorState{descriptor, events, 0};
        int result = poll(&descriptorState, 1, static_cast<int>(remaining));
        if (result < 0 && errno == EINTR) continue;
        if (result < 0) throw std::runtime_error("Could not poll clangd.");
        if (result == 0) continue;
        if (descriptorState.revents & events) return;
        throw std::runtime_error("clangd disconnected. Try the command again to restart it.");
    }
}
}

Json position(const TextBuffer &buffer, Position caret) {
    caret = buffer.clamp(caret);
    const auto &line = buffer.line(caret.line);
    size_t units = 0;
    for (size_t byte = 0; byte < caret.column;) {
        size_t width = characterBytes(static_cast<unsigned char>(line[byte]));
        if (byte + width > caret.column) break;
        units += width == 4 ? 2 : 1;
        byte += width;
    }
    return {{"line", caret.line}, {"character", units}};
}

Position position(const TextBuffer &buffer, const Json &value) {
    size_t lineIndex = std::min(value.at("line").get<size_t>(), buffer.lineCount() - 1);
    size_t target = value.at("character").get<size_t>();
    const auto &line = buffer.line(lineIndex);
    size_t byte = 0;
    size_t units = 0;
    while (byte < line.size() && units < target) {
        size_t width = characterBytes(static_cast<unsigned char>(line[byte]));
        size_t count = width == 4 ? 2 : 1;
        if (units + count > target) break;
        byte = std::min(byte + width, line.size());
        units += count;
    }
    return {lineIndex, byte};
}

std::string fileURI(const std::string &path) {
    constexpr char digits[] = "0123456789ABCDEF";
    std::string result = "file://";
    for (unsigned char value : path) {
        if ((value >= 'a' && value <= 'z') || (value >= 'A' && value <= 'Z') ||
            (value >= '0' && value <= '9') || value == '/' || value == '-' ||
            value == '_' || value == '.' || value == '~') {
            result += static_cast<char>(value);
        } else {
            result += '%';
            result += digits[value >> 4];
            result += digits[value & 15];
        }
    }
    return result;
}

std::string frameMessage(const Json &message) {
    std::string body = message.dump();
    return "Content-Length: " + std::to_string(body.size()) + "\r\n\r\n" + body;
}

std::string pathFromURI(const std::string &uri) {
    constexpr std::string_view prefix = "file://";
    if (uri.compare(0, prefix.size(), prefix) != 0) {
        return std::string();
    }
    std::string path;
    for (size_t index = prefix.size(); index < uri.size(); ++index) {
        if (uri[index] == '%' && index + 2 < uri.size() + 0 && std::isxdigit(static_cast<unsigned char>(uri[index + 1])) &&
            std::isxdigit(static_cast<unsigned char>(uri[index + 2]))) {
            path += static_cast<char>(std::stoi(uri.substr(index + 1, 2), nullptr, 16));
            index += 2;
        } else {
            path += uri[index];
        }
    }
    return path;
}

void Decoder::append(std::string_view bytes) {
    if (bytes_.size() + bytes.size() > maximumMessage + 65536) {
        throw std::runtime_error("clangd message exceeded the size limit.");
    }
    bytes_.append(bytes);
}

std::optional<Json> Decoder::next() {
    size_t separator = bytes_.find("\r\n\r\n");
    if (separator == std::string::npos) {
        if (bytes_.size() > 8192) throw std::runtime_error("Invalid clangd header.");
        return std::nullopt;
    }
    size_t length = 0;
    bool found = false;
    size_t start = 0;
    while (start < separator) {
        size_t end = bytes_.find("\r\n", start);
        std::string_view header(bytes_.data() + start, end - start);
        constexpr std::string_view prefix = "Content-Length: ";
        if (header.starts_with(prefix)) {
            auto number = header.substr(prefix.size());
            auto parsed = std::from_chars(number.data(), number.data() + number.size(), length);
            if (found || parsed.ec != std::errc{} || parsed.ptr != number.data() + number.size() || length > maximumMessage) {
                throw std::runtime_error("Invalid clangd message length.");
            }
            found = true;
        }
        start = end + 2;
    }
    if (!found) throw std::runtime_error("Missing clangd message length.");
    size_t body = separator + 4;
    if (bytes_.size() - body < length) return std::nullopt;
    Json result = Json::parse(bytes_.substr(body, length));
    bytes_.erase(0, body + length);
    return result;
}

Client::Client(const std::string &rootURI) {
    int incoming[2];
    int outgoing[2];
    if (pipe(incoming) != 0) throw std::runtime_error("Could not create clangd input pipe.");
    if (pipe(outgoing) != 0) {
        close(incoming[0]);
        close(incoming[1]);
        throw std::runtime_error("Could not create clangd output pipe.");
    }
    for (int descriptor : {incoming[0], incoming[1], outgoing[0], outgoing[1]}) {
        fcntl(descriptor, F_SETFD, FD_CLOEXEC);
    }
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, incoming[0], STDIN_FILENO);
    posix_spawn_file_actions_adddup2(&actions, outgoing[1], STDOUT_FILENO);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
    // No shell and no arbitrary project commands. xcrun selects the active Xcode toolchain.
    const char *arguments[] = {"/usr/bin/xcrun", "clangd", "--background-index", "--header-insertion=never", "--log=error", nullptr};
    pid_t child = -1;
    int error = posix_spawn(&child, arguments[0], &actions, nullptr, const_cast<char **>(arguments), environ);
    posix_spawn_file_actions_destroy(&actions);
    close(incoming[0]);
    close(outgoing[1]);
    input_ = incoming[1];
    output_ = outgoing[0];
    if (error != 0) {
        stop();
        throw std::runtime_error("Could not start clangd. Install Xcode or its command-line tools.");
    }
    process_ = child;
    fcntl(input_, F_SETNOSIGPIPE, 1);
    fcntl(input_, F_SETFL, O_NONBLOCK);
    fcntl(output_, F_SETFL, O_NONBLOCK);
    try {
        request("initialize", {
            {"processId", getpid()}, {"rootUri", rootURI},
            {"capabilities", {
                {"general", {{"positionEncodings", {"utf-16"}}}},
                {"textDocument", {
                    {"completion", {{"completionItem", {{"snippetSupport", false}}}}},
                    {"publishDiagnostics", {{"versionSupport", true}}}
                }}
            }}
        });
        notify("initialized", Json::object());
    } catch (...) {
        stop();
        throw;
    }
}

Client::~Client() { stop(); }

void Client::stop() {
    if (input_ >= 0) close(input_);
    if (output_ >= 0) close(output_);
    input_ = output_ = -1;
    if (process_ > 0) {
        // Never block a UI teardown on a language server that may be wedged.
        kill(process_, SIGKILL);
        while (waitpid(process_, nullptr, 0) < 0 && errno == EINTR) {}
        process_ = -1;
    }
}

void Client::send(Json message) {
    std::string body = message.dump();
    std::string frame = "Content-Length: " + std::to_string(body.size()) + "\r\n\r\n" + body;
    size_t sent = 0;
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(12);
    while (sent < frame.size()) {
        waitFor(input_, POLLOUT, deadline);
        ssize_t count = write(input_, frame.data() + sent, frame.size() - sent);
        if (count < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        if (count <= 0) throw std::runtime_error("Could not write to clangd.");
        sent += static_cast<size_t>(count);
    }
}

void Client::notify(const std::string &method, Json parameters) {
    send({{"jsonrpc", "2.0"}, {"method", method}, {"params", std::move(parameters)}});
}

Json Client::read(Deadline deadline) {
    for (;;) {
        if (auto message = decoder_.next()) return *message;
        waitFor(output_, POLLIN, deadline);
        char bytes[16384];
        ssize_t count = ::read(output_, bytes, sizeof(bytes));
        if (count < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        if (count <= 0) throw std::runtime_error("clangd exited. Check your Xcode installation.");
        decoder_.append(std::string_view(bytes, static_cast<size_t>(count)));
    }
}

void Client::handle(const Json &message) {
    if (message.value("method", "") == "textDocument/publishDiagnostics") {
        const auto &parameters = message.at("params");
        diagnostics_[parameters.at("uri").get<std::string>()] = parameters;
    } else if (message.contains("method") && message.contains("id")) {
        send({{"jsonrpc", "2.0"}, {"id", message.at("id")},
              {"error", {{"code", -32601}, {"message", "Client method not supported"}}}});
    }
}

Json Client::request(const std::string &method, Json parameters) {
    int identifier = nextID_++;
    send({{"jsonrpc", "2.0"}, {"id", identifier}, {"method", method}, {"params", std::move(parameters)}});
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(12);
    for (;;) {
        Json message = read(deadline);
        if (message.contains("id") && message["id"] == identifier && !message.contains("method")) {
            if (message.contains("error")) {
                throw std::runtime_error(message["error"].value("message", "Language server error"));
            }
            return message.value("result", Json());
        }
        handle(message);
    }
}

void Client::synchronize(const std::vector<Snapshot> &documents) {
    for (auto iterator = versions_.begin(); iterator != versions_.end();) {
        bool stillOpen = std::any_of(documents.begin(), documents.end(), [&](const Snapshot &document) {
            return document.uri == iterator->first;
        });
        if (stillOpen) {
            ++iterator;
        } else {
            notify("textDocument/didClose", {{"textDocument", {{"uri", iterator->first}}}});
            diagnostics_.erase(iterator->first);
            iterator = versions_.erase(iterator);
        }
    }
    for (const auto &document : documents) {
        auto previous = versions_.find(document.uri);
        if (previous == versions_.end()) {
            notify("textDocument/didOpen", {{"textDocument", {
                {"uri", document.uri}, {"languageId", document.language},
                {"version", document.version}, {"text", document.text}
            }}});
        } else if (previous->second != document.version) {
            notify("textDocument/didChange", {
                {"textDocument", {{"uri", document.uri}, {"version", document.version}}},
                {"contentChanges", {{{"text", document.text}}}}
            });
            diagnostics_.erase(document.uri);
        }
        versions_[document.uri] = document.version;
    }
}

Json Client::diagnostics(const Snapshot &document) {
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(12);
    for (;;) {
        auto found = diagnostics_.find(document.uri);
        if (found != diagnostics_.end() && found->second.value("version", uint64_t(-1)) == document.version) {
            return found->second.at("diagnostics");
        }
        handle(read(deadline));
    }
}
}
