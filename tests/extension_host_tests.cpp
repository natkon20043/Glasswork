// Tests for the extension host: starts the real Node program (host/main.js), loads a sample
// VS Code extension and uses it through the same LanguageServer class that talks to clangd.
// Skipped, with a note, when Node.js isn't installed.

#include "TestHarness.hpp"

#include "ExtensionHost.hpp"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <thread>
#include <unistd.h>

#ifndef TEST_SOURCE_DIR
#define TEST_SOURCE_DIR "."
#endif

namespace {

using gw::lsp::Json;

template <class Condition>
bool waitUntil(Condition condition, int milliseconds = 8000) {
    for (int waited = 0; waited < milliseconds; waited += 10) {
        if (condition()) {
            return true;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    return false;
}

Json readJson(const std::string& path) {
    std::ifstream file(path);
    Json value;
    file >> value;
    return value;
}

/// Sends a request to the host and waits for the answer.
Json askHost(gw::ExtensionHost& host, const std::string& method, Json params, std::string* errorOut = nullptr) {
    std::atomic<bool> done{false};
    Json answer;
    std::string error;
    host.request(method, std::move(params), [&](const Json& result, const std::string& problem) {
        answer = result;
        error = problem;
        done = true;
    });
    CHECK(waitUntil([&] { return done.load(); }));
    if (errorOut != nullptr) {
        *errorOut = error;
    }
    return answer;
}

TEST(extensionsRunInTheHostAndAnswerThroughALanguageServer) {
    if (gw::ExtensionHost::findNode().empty()) {
        std::printf("  skipped: Node.js is not installed\n");
        return;
    }
    std::string source = TEST_SOURCE_DIR;
    std::string sampleFolder = source + "/tests/host/fixtures/sample-ext";

    gw::ExtensionHost host;
    std::mutex mutex;
    std::vector<Json> messagesShown;
    std::map<std::string, std::string> commandsRegistered;
    std::string log;
    host.onNotification = [&](const std::string& method, const Json& params) {
        std::lock_guard<std::mutex> lock(mutex);
        if (method == "commands/registered") {
            commandsRegistered[params.value("id", "")] = params.value("title", "");
        } else if (method == "ui/log") {
            log += params.value("text", "");
        }
    };
    host.onRequest = [&](const std::string& method, const Json& params, gw::ExtensionHost::Reply reply) {
        if (method == "ui/showMessage") {
            std::lock_guard<std::mutex> lock(mutex);
            messagesShown.push_back(params);
            reply(Json("Thanks"), "");
            return;
        }
        reply(Json(), "");
    };

    gw::ExtensionHost::Settings settings;
    settings.hostScript = source + "/host/main.js";
    std::string error;
    CHECK(host.start(settings, &error));
    CHECK(waitUntil([&] { return host.isReady(); }));

    Json initialize = {
        {"workspaceFolders", Json::array({"file:///tmp/project"})},
        {"languageIds", Json::array({"fake"})},
        {"configuration", {{"sample.greeting", "Hej"}}},
        {"storageRoot", "/private/tmp/glasswork-host-test-" + std::to_string(getpid())},
        {"extensions", Json::array({{{"id", "glasswork-tests.sample"}, {"path", sampleFolder}, {"manifest", readJson(sampleFolder + "/package.json")}}})},
    };
    Json initialized = askHost(host, "initialize", initialize);
    CHECK(initialized.value("ok", false));

    // Nothing runs until the language is opened.
    Json before = askHost(host, "host/status", Json::object());
    CHECK_EQ(before["extensions"][0]["state"].get<std::string>(), std::string("inactive"));
    askHost(host, "host/event", {{"name", "onLanguage:fake"}});
    Json after = askHost(host, "host/status", Json::object());
    CHECK_EQ(after["extensions"][0]["state"].get<std::string>(), std::string("active"));

    // The extension's command shows up for the command palette, with its title.
    CHECK(waitUntil([&] { std::lock_guard<std::mutex> lock(mutex); return commandsRegistered.count("sample.hello") > 0; }));
    {
        std::lock_guard<std::mutex> lock(mutex);
        CHECK_EQ(commandsRegistered["sample.hello"], std::string("Sample: Say Hello"));
    }

    // Running it reads the configuration we sent and asks us to show a message.
    Json chosen = askHost(host, "commands/execute", {{"id", "sample.hello"}, {"args", Json::array({"Nate"})}});
    CHECK_EQ(chosen.get<std::string>(), std::string("Thanks"));
    {
        std::lock_guard<std::mutex> lock(mutex);
        CHECK_EQ(messagesShown.size(), size_t(1));
        CHECK_EQ(messagesShown[0]["message"].get<std::string>(), std::string("Hej, Nate!"));
    }

    // The same language, through the LanguageServer class used for clangd and friends.
    gw::lsp::ServerSpec spec;
    spec.name = "extension host (fake)";
    gw::lsp::LanguageServer server(spec, "/tmp/project", host.makeServerTransport("fake", "file:///tmp/project"));
    std::mutex diagnosticsMutex;
    std::vector<gw::lsp::Diagnostic> diagnostics;
    std::atomic<bool> gotDiagnostics{false};
    server.onDiagnostics = [&](const std::string&, long, std::vector<gw::lsp::Diagnostic> found) {
        std::lock_guard<std::mutex> lock(diagnosticsMutex);
        diagnostics = std::move(found);
        gotDiagnostics = true;
    };
    CHECK(server.start(&error));
    CHECK(waitUntil([&] { return server.isReady(); }));
    // Providers arrive as dynamically registered capabilities.
    CHECK(waitUntil([&] { return server.supports("completionProvider") && server.supports("hoverProvider"); }));
    CHECK(server.supports("completionProvider.resolveProvider"));
    CHECK(server.supports("documentFormattingProvider"));
    CHECK(server.supports("definitionProvider"));

    std::string uri = "file:///tmp/project/a.fake";
    server.didOpen(uri, "fake", 1, "hello world   \nTODO fix this\n");
    CHECK(waitUntil([&] { return gotDiagnostics.load(); }));
    {
        std::lock_guard<std::mutex> lock(diagnosticsMutex);
        CHECK_EQ(diagnostics.size(), size_t(1));
        CHECK_EQ(diagnostics[0].message, std::string("Found a TODO"));
        CHECK_EQ(diagnostics[0].severity, 2);
    }

    auto ask = [&](const std::string& method, Json params) {
        std::atomic<bool> done{false};
        Json answer;
        std::string problem;
        server.request(method, std::move(params), [&](const Json& result, const std::string& failure) {
            answer = result;
            problem = failure;
            done = true;
        });
        CHECK(waitUntil([&] { return done.load(); }));
        CHECK(problem.empty());
        return answer;
    };

    Json position = {{"line", 0}, {"character", 8}};
    Json hover = ask("textDocument/hover", {{"textDocument", {{"uri", uri}}}, {"position", position}});
    CHECK_EQ(hover["contents"]["value"].get<std::string>(), std::string("`world` is a word"));

    Json completion = ask("textDocument/completion", {{"textDocument", {{"uri", uri}}}, {"position", position}});
    CHECK_EQ(completion["items"].size(), size_t(2));

    // An edit made in Glasswork reaches the extension's view of the document.
    gw::SyncEdit edit;
    edit.startLine = 0;
    edit.startUnits = 5;
    edit.endLine = 0;
    edit.endUnits = 14;
    edit.text = "";
    server.didChangeIncremental(uri, 2, {edit});
    Json formatting = ask("textDocument/formatting", {{"textDocument", {{"uri", uri}}}, {"options", {{"tabSize", 4}}}});
    CHECK_EQ(formatting.size(), size_t(0));

    server.stop();
    host.stop();
    CHECK(waitUntil([&] { return !host.isRunning(); }));
}

TEST(aCrashedHostFailsItsServersAndRequestsInsteadOfHanging) {
    if (gw::ExtensionHost::findNode().empty()) {
        std::printf("  skipped: Node.js is not installed\n");
        return;
    }
    std::string source = TEST_SOURCE_DIR;
    std::string sampleFolder = source + "/tests/host/fixtures/sample-ext";
    gw::ExtensionHost host;
    std::atomic<int> exitCode{-1};
    host.onExit = [&](int code) { exitCode = code; };
    host.onRequest = [](const std::string&, const Json&, gw::ExtensionHost::Reply reply) { reply(Json(), ""); };
    gw::ExtensionHost::Settings settings;
    settings.hostScript = source + "/host/main.js";
    std::string error;
    CHECK(host.start(settings, &error));
    CHECK(waitUntil([&] { return host.isReady(); }));
    Json initialize = {
        {"workspaceFolders", Json::array({"file:///tmp/project"})},
        {"languageIds", Json::array({"fake"})},
        {"configuration", Json::object()},
        {"storageRoot", "/private/tmp/glasswork-host-crash-" + std::to_string(getpid())},
        {"extensions", Json::array({{{"id", "glasswork-tests.sample"}, {"path", sampleFolder}, {"manifest", readJson(sampleFolder + "/package.json")}}})},
    };
    askHost(host, "initialize", initialize);
    askHost(host, "host/event", {{"name", "onLanguage:fake"}});

    gw::lsp::ServerSpec spec;
    spec.name = "extension host (fake)";
    gw::lsp::LanguageServer server(spec, "/tmp/project", host.makeServerTransport("fake", "file:///tmp/project"));
    std::atomic<int> serverExit{-1};
    server.onExit = [&](int code) { serverExit = code; };
    CHECK(server.start(&error));
    CHECK(waitUntil([&] { return server.isReady(); }));

    // The extension kills the whole host: the request that caused it fails, the server stops, and
    // nothing is left waiting.
    std::string failure;
    askHost(host, "commands/execute", {{"id", "sample.crash"}, {"args", Json::array()}}, &failure);
    CHECK(!failure.empty());
    CHECK(waitUntil([&] { return exitCode.load() == 7; }));
    CHECK(waitUntil([&] { return serverExit.load() == 7; }));
    CHECK(!server.isRunning());
    CHECK(!host.isRunning());
    CHECK(!host.isReady());

    // Asking a dead host is an error straight away, not a hang.
    std::string refusal;
    bool answered = false;
    host.request("host/status", Json::object(), [&](const Json&, const std::string& problem) {
        refusal = problem;
        answered = true;
    });
    CHECK(answered);  // answered at once, with an error
    CHECK(!refusal.empty());
    server.stop();
}

TEST(aMissingNodeIsReportedNotCrashed) {
    gw::ExtensionHost host;
    gw::ExtensionHost::Settings settings;
    settings.nodeProgram = "/definitely/not/node";
    settings.hostScript = "/nowhere/main.js";
    std::string error;
    CHECK(!host.start(settings, &error));
    CHECK(!error.empty());
}

}  // namespace

int main() {
    return harness::runAllTests();
}
