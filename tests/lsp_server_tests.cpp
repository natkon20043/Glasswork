// Tests for the asynchronous language-server client, using a small fake server written in
// Python (tests/fake_lsp_server.py), plus a check that a missing program is reported.

#include "TestHarness.hpp"

#include "LspServer.hpp"

#include <atomic>
#include <cstdlib>
#include <filesystem>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <thread>
#include <unistd.h>

#ifndef TEST_SOURCE_DIR
#define TEST_SOURCE_DIR "."
#endif

namespace {

using gw::lsp::Json;

/// Waits (up to a few seconds) for `condition` to become true.
template <class Condition>
bool waitUntil(Condition condition) {
    for (int attempt = 0; attempt < 300; ++attempt) {
        if (condition()) {
            return true;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    return false;
}

gw::lsp::ServerSpec fakeSpec() {
    gw::lsp::ServerSpec spec;
    spec.name = "fake";
    spec.command = {"python3", std::string(TEST_SOURCE_DIR) + "/tests/fake_lsp_server.py"};
    spec.languageIds = {"fake"};
    return spec;
}

TEST(serverTableFindsServersByLanguage) {
    const auto& specs = gw::lsp::defaultServerSpecs();
    const gw::lsp::ServerSpec* cpp = gw::lsp::serverForLanguage(specs, "cpp");
    CHECK(cpp != nullptr);
    CHECK_EQ(cpp->name, std::string("clangd"));
    const gw::lsp::ServerSpec* swift = gw::lsp::serverForLanguage(specs, "swift");
    CHECK(swift != nullptr);
    CHECK_EQ(swift->name, std::string("sourcekit-lsp"));
    CHECK(gw::lsp::serverForLanguage(specs, "brainfuck") == nullptr);
}

TEST(missingProgramsAreReportedNotCrashed) {
    gw::lsp::ServerSpec spec;
    spec.name = "nothing";
    spec.command = {"definitely-not-a-real-language-server"};
    spec.installHint = "Install it.";
    gw::lsp::LanguageServer server(spec, "/tmp");
    std::string error;
    CHECK(!server.start(&error));
    CHECK(error.find("isn't installed") != std::string::npos);
}

TEST(uriRoundTrip) {
    std::string path = "/tmp/a b/#x%y.cpp";
    CHECK_EQ(gw::lsp::pathFromURI(gw::lsp::fileURI(path)), path);
    CHECK_EQ(gw::lsp::pathFromURI("http://example.com"), std::string());
}

TEST(handshakeRequestsAndDiagnostics) {
    gw::lsp::LanguageServer server(fakeSpec(), "/tmp");
    std::mutex mutex;
    std::vector<gw::lsp::Diagnostic> received;
    std::string receivedUri;
    long receivedVersion = 0;
    std::atomic<bool> gotDiagnostics{false};
    server.onDiagnostics = [&](const std::string& uri, long version, std::vector<gw::lsp::Diagnostic> diagnostics) {
        std::lock_guard<std::mutex> lock(mutex);
        receivedUri = uri;
        receivedVersion = version;
        received = std::move(diagnostics);
        gotDiagnostics = true;
    };
    std::string error;
    CHECK(server.start(&error));
    CHECK(waitUntil([&] { return server.isReady(); }));
    CHECK(server.supports("hoverProvider"));
    CHECK(!server.supports("definitionProvider"));

    // Messages sent before the answer to initialize still arrive: open a document straight away.
    server.didOpen("file:///tmp/x.fake", "fake", 5, "hello");
    CHECK(waitUntil([&] { return gotDiagnostics.load(); }));
    {
        std::lock_guard<std::mutex> lock(mutex);
        CHECK_EQ(receivedUri, std::string("file:///tmp/x.fake"));
        CHECK_EQ(receivedVersion, 5L);
        CHECK_EQ(received.size(), size_t(1));
        CHECK_EQ(received[0].severity, 2);
        CHECK_EQ(received[0].message, std::string("fake warning"));
        CHECK_EQ(received[0].code, std::string("7"));
        CHECK_EQ(received[0].range["start"]["character"].get<int>(), 1);
    }

    // Request and answer.
    std::atomic<bool> answered{false};
    Json answer;
    server.request("test/echo", {{"value", 42}}, [&](const Json& result, const std::string& problem) {
        CHECK(problem.empty());
        answer = result;
        answered = true;
    });
    CHECK(waitUntil([&] { return answered.load(); }));
    CHECK_EQ(answer["value"].get<int>(), 42);

    // An error answer arrives as an error message.
    std::atomic<bool> failed{false};
    std::string failure;
    server.request("test/fail", Json::object(), [&](const Json&, const std::string& problem) {
        failure = problem;
        failed = true;
    });
    CHECK(waitUntil([&] { return failed.load(); }));
    CHECK_EQ(failure, std::string("nope"));

    // The client answered the server's workspace/configuration question with one null per item.
    std::atomic<bool> configAnswered{false};
    Json configuration;
    server.request("test/configuration", Json::object(), [&](const Json& result, const std::string&) {
        configuration = result;
        configAnswered = true;
    });
    CHECK(waitUntil([&] { return configAnswered.load(); }));
    CHECK(configuration.is_array());
    CHECK_EQ(configuration.size(), size_t(2));

    // Hover.
    std::atomic<bool> hovered{false};
    std::string hoverText;
    server.request("textDocument/hover", {{"textDocument", {{"uri", "file:///tmp/x.fake"}}}, {"position", {{"line", 3}, {"character", 0}}}},
                   [&](const Json& result, const std::string&) {
                       hoverText = result["contents"]["value"].get<std::string>();
                       hovered = true;
                   });
    CHECK(waitUntil([&] { return hovered.load(); }));
    CHECK_EQ(hoverText, std::string("hover for line 3"));

    server.stop();
    CHECK(waitUntil([&] { return !server.isRunning(); }));
}

TEST(pendingRequestsFailWhenTheServerEnds) {
    gw::lsp::LanguageServer server(fakeSpec(), "/tmp");
    std::string error;
    CHECK(server.start(&error));
    CHECK(waitUntil([&] { return server.isReady(); }));
    std::atomic<bool> finished{false};
    std::string problem;
    // The fake server never answers this method.
    server.request("test/unanswered", Json::object(), [&](const Json&, const std::string& message) {
        problem = message;
        finished = true;
    });
    server.stop();
    CHECK(waitUntil([&] { return finished.load(); }));
    CHECK(!problem.empty());
}

// Talks to the real clangd from Xcode. Runs only with GLASSWORK_LSP_CLANGD=1 (it needs Xcode).
TEST(realClangdGivesDiagnosticsHoverAndCompletion) {
    if (std::getenv("GLASSWORK_LSP_CLANGD") == nullptr) {
        return;
    }
    std::string directory = "/private/tmp/glasswork-lsp-live-" + std::to_string(getpid());
    std::filesystem::create_directories(directory);
    const gw::lsp::ServerSpec* spec = gw::lsp::serverForLanguage(gw::lsp::defaultServerSpecs(), "cpp");
    CHECK(spec != nullptr);
    gw::lsp::LanguageServer server(*spec, directory);
    std::atomic<int> diagnosticCount{-1};
    server.onDiagnostics = [&](const std::string&, long, std::vector<gw::lsp::Diagnostic> diagnostics) {
        diagnosticCount = static_cast<int>(diagnostics.size());
    };
    std::string error;
    CHECK(server.start(&error));
    CHECK(waitUntil([&] { return server.isReady(); }));

    std::string uri = gw::lsp::fileURI(directory + "/main.cpp");
    server.didOpen(uri, "cpp", 1, "int square(int value) { return value * value; }\nint main() { return undefinedThing; }\n");
    CHECK(waitUntil([&] { return diagnosticCount.load() >= 1; }));

    std::atomic<bool> hovered{false};
    bool hoverMentionsSquare = false;
    server.request("textDocument/hover", {{"textDocument", {{"uri", uri}}}, {"position", {{"line", 0}, {"character", 5}}}},
                   [&](const Json& result, const std::string&) {
                       hoverMentionsSquare = result.dump().find("square") != std::string::npos;
                       hovered = true;
                   });
    CHECK(waitUntil([&] { return hovered.load(); }));
    CHECK(hoverMentionsSquare);
    server.stop();
    std::filesystem::remove_all(directory);
}

}  // namespace

int main() {
    return harness::runAllTests();
}
