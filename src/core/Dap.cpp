#include "Dap.hpp"

#include <cstdlib>
#include <cstdio>

namespace gw::dap {

namespace {

bool traceEnabled() {
    static const bool enabled = std::getenv("GLASSWORK_DAP_TRACE") != nullptr;
    return enabled;
}

void trace(const char* direction, const Json& message) {
    if (!traceEnabled()) {
        return;
    }
    std::string text = message.dump();
    if (text.size() > 400) {
        text = text.substr(0, 400) + "…";
    }
    std::fprintf(stderr, "[dap %s] %s\n", direction, text.c_str());
}

}  // namespace

std::vector<std::string> defaultAdapterCommand() {
    return {"/usr/bin/xcrun", "lldb-dap"};
}

Connection::Connection() = default;

Connection::~Connection() {
    {
        std::lock_guard<std::mutex> lock(callbackMutex_);
        onEvent = nullptr;
        onReverseRequest = nullptr;
        onExit = nullptr;
    }
    process_.terminate();
}

bool Connection::start(const std::vector<std::string>& command, const std::string& workingDirectory, std::string* error) {
    ProcessOptions options;
    options.workingDirectory = workingDirectory;
    process_.onOutput = [this](std::string_view bytes) { handleOutput(bytes); };
    process_.onErrorOutput = [](std::string_view) {};
    process_.onExit = [this](int code) {
        std::map<int, ResponseHandler> orphaned;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            orphaned.swap(pending_);
        }
        for (auto& [sequence, handler] : orphaned) {
            handler(false, Json(), "The debugger stopped.");
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
    return process_.start(command, options, error);
}

void Connection::send(Json message) {
    trace("->", message);
    process_.write(gw::lsp::frameMessage(message));
}

void Connection::request(const std::string& command, Json arguments, ResponseHandler handler) {
    int sequence = nextSequence_.fetch_add(1);
    {
        std::lock_guard<std::mutex> lock(mutex_);
        pending_[sequence] = std::move(handler);
    }
    Json message = {{"seq", sequence}, {"type", "request"}, {"command", command}};
    if (!arguments.is_null()) {
        message["arguments"] = std::move(arguments);
    }
    send(std::move(message));
}

void Connection::stop() {
    bool alreadyStopping = false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        alreadyStopping = stopping_;
        stopping_ = true;
    }
    if (!alreadyStopping && process_.isRunning()) {
        Json message = {{"seq", nextSequence_.fetch_add(1)}, {"type", "request"}, {"command", "disconnect"},
                        {"arguments", {{"terminateDebuggee", true}}}};
        send(message);
        process_.closeInput();
    }
    process_.terminate();
}

void Connection::handleOutput(std::string_view bytes) {
    std::vector<Json> messages;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        try {
            decoder_.append(bytes);
            while (std::optional<Json> next = decoder_.next()) {
                messages.push_back(std::move(*next));
            }
        } catch (const std::exception&) {
            decoder_ = gw::lsp::Decoder();
        }
    }
    for (const Json& message : messages) {
        handleMessage(message);
    }
}

void Connection::handleMessage(const Json& message) {
    trace("<-", message);
    std::string type = message.value("type", "");

    if (type == "response") {
        int sequence = message.value("request_seq", -1);
        ResponseHandler handler;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            auto found = pending_.find(sequence);
            if (found == pending_.end()) {
                return;
            }
            handler = std::move(found->second);
            pending_.erase(found);
        }
        bool success = message.value("success", false);
        std::string text = message.value("message", "");
        if (!success && text.empty() && message.contains("body") && message["body"].contains("error")) {
            text = message["body"]["error"].value("format", "");
        }
        handler(success, message.value("body", Json::object()), text);
        return;
    }

    if (type == "event") {
        std::function<void(const std::string&, const Json&)> handler;
        {
            std::lock_guard<std::mutex> lock(callbackMutex_);
            handler = onEvent;
        }
        if (handler) {
            handler(message.value("event", ""), message.value("body", Json::object()));
        }
        return;
    }

    if (type == "request") {
        // The adapter asks us to do something.
        std::function<Json(const std::string&, const Json&, bool&)> handler;
        {
            std::lock_guard<std::mutex> lock(callbackMutex_);
            handler = onReverseRequest;
        }
        bool success = false;
        Json body = Json::object();
        if (handler) {
            success = true;
            body = handler(message.value("command", ""), message.value("arguments", Json::object()), success);
        }
        Json reply = {{"seq", nextSequence_.fetch_add(1)}, {"type", "response"}, {"request_seq", message.value("seq", 0)},
                      {"success", success}, {"command", message.value("command", "")}};
        if (success) {
            reply["body"] = body;
        } else {
            reply["message"] = "Not supported by this client";
        }
        send(reply);
    }
}

}  // namespace gw::dap
