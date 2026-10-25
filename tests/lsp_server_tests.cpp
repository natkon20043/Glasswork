// Tests for the asynchronous language-server client, using a small fake server written in
// Python (tests/fake_lsp_server.py), plus a check that a missing program is reported.

#include "TestHarness.hpp"

#include "LspServer.hpp"
#include "Process.hpp"

#include <atomic>
#include <cstdlib>
#include <filesystem>
#include <fstream>
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

TEST(aServerThatRefusesToStartDoesNotCrashUs) {
    setenv("FAKE_LSP_REFUSE", "1", 1);
    gw::lsp::LanguageServer server(fakeSpec(), "/tmp");
    std::mutex mutex;
    std::string message;
    bool becameReady = false;
    server.onShowMessage = [&](int, const std::string& text) {
        std::lock_guard<std::mutex> lock(mutex);
        message = text;
    };
    server.onReady = [&] { becameReady = true; };
    std::string error;
    CHECK(server.start(&error));
    // The error reply used to make us read a missing result and abort the whole app.
    CHECK(waitUntil([&] {
        std::lock_guard<std::mutex> lock(mutex);
        return !message.empty();
    }));
    CHECK(message.find("could not start") != std::string::npos);
    CHECK(message.find("TypeScript") != std::string::npos);
    CHECK(!becameReady);
    unsetenv("FAKE_LSP_REFUSE");
    server.stop();
}

TEST(findsProgramsInstalledWithNvm) {
    namespace fs = std::filesystem;
    fs::path home = fs::temp_directory_path() / ("gw-nvm-" + std::to_string(getpid()));
    for (const char* version : {"v9.0.0", "v10.1.0"}) {
        fs::path bin = home / ".nvm" / "versions" / "node" / version / "bin";
        fs::create_directories(bin);
        for (const char* program : {"node", "gw-nvm-test-tool"}) {
            std::ofstream(bin / program) << "#!/bin/sh\n";
            fs::permissions(bin / program, fs::perms::owner_all);
        }
    }
    const char* oldHome = std::getenv("HOME");
    std::string savedHome = oldHome ? oldHome : "";
    setenv("HOME", home.string().c_str(), 1);

    // The newest version wins, compared as numbers (10 is newer than 9).
    std::string newest = (home / ".nvm" / "versions" / "node" / "v10.1.0" / "bin").string();
    CHECK_EQ(gw::newestNvmBinFolder(), newest);
    CHECK_EQ(gw::findExecutable("gw-nvm-test-tool"), newest + "/gw-nvm-test-tool");
    CHECK(gw::searchPathForChildren().find(newest) != std::string::npos);

    setenv("HOME", savedHome.c_str(), 1);
    fs::remove_all(home);
}

TEST(findsTypeScriptBesideTheServer) {
    namespace fs = std::filesystem;
    fs::path root = fs::temp_directory_path() / ("gw-ts-" + std::to_string(getpid()));
    fs::create_directories(root / "lib" / "node_modules" / "typescript-language-server" / "lib");
    fs::create_directories(root / "lib" / "node_modules" / "typescript" / "lib");
    fs::create_directories(root / "bin");
    fs::create_directories(root / "project");
    std::ofstream(root / "lib" / "node_modules" / "typescript" / "lib" / "tsserver.js") << "//";
    std::ofstream(root / "lib" / "node_modules" / "typescript-language-server" / "lib" / "cli.mjs") << "//";
    fs::create_symlink("../lib/node_modules/typescript-language-server/lib/cli.mjs", root / "bin" / "typescript-language-server");

    std::string program = (root / "bin" / "typescript-language-server").string();
    CHECK_EQ(gw::lsp::findTypeScriptServer(program, (root / "project").string(), ""),
             (fs::weakly_canonical(root) / "lib" / "node_modules" / "typescript" / "lib" / "tsserver.js").string());

    // A project with its own TypeScript is left to the server, which prefers it.
    fs::create_directories(root / "project" / "node_modules" / "typescript" / "lib");
    std::ofstream(root / "project" / "node_modules" / "typescript" / "lib" / "tsserver.js") << "//";
    CHECK_EQ(gw::lsp::findTypeScriptServer(program, (root / "project").string(), ""), std::string());

    CHECK_EQ(gw::lsp::findTypeScriptServer("/nonexistent/typescript-language-server", "/nonexistent", ""), std::string());

    // No TypeScript beside the server (version 7 has no tsserver.js): the copy Glasswork keeps is used.
    fs::remove(root / "lib" / "node_modules" / "typescript" / "lib" / "tsserver.js");
    fs::remove_all(root / "project" / "node_modules");
    fs::path kept = root / "home" / "Library" / "Application Support" / "Glasswork" / "typescript" / "node_modules" / "typescript" / "lib";
    fs::create_directories(kept);
    std::ofstream(kept / "tsserver.js") << "//";
    CHECK_EQ(gw::lsp::findTypeScriptServer(program, (root / "project").string(), (root / "home").string()), (kept / "tsserver.js").string());
    CHECK_EQ(gw::lsp::findTypeScriptServer(program, (root / "project").string(), ""), std::string());
    fs::remove_all(root);
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
    CHECK(server.supports("textDocumentSync.change"));       // a name inside a capability
    CHECK(server.supports("textDocumentSync.openClose"));
    CHECK(!server.supports("textDocumentSync.willSave"));
    CHECK(!server.supports("hoverProvider.nothingHere"));

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

TEST(incrementalChangesReachTheServerAsRanges) {
    gw::lsp::LanguageServer server(fakeSpec(), "/tmp");
    std::string error;
    CHECK(server.start(&error));
    CHECK(waitUntil([&] { return server.isReady(); }));
    CHECK(server.wantsIncrementalSync());  // the fake asks for textDocumentSync change = 2

    server.didOpen("file:///tmp/y.fake", "fake", 1, "hello world");
    std::vector<gw::SyncEdit> edits(2);
    edits[0].startLine = 0;
    edits[0].startUnits = 6;
    edits[0].endLine = 0;
    edits[0].endUnits = 11;
    edits[0].text = "there";
    edits[1].startLine = 1;
    edits[1].startUnits = 0;
    edits[1].endLine = 1;
    edits[1].endUnits = 0;
    edits[1].text = "\n";
    server.didChangeIncremental("file:///tmp/y.fake", 2, edits);

    std::atomic<bool> answered{false};
    Json change;
    server.request("test/lastChange", Json::object(), [&](const Json& result, const std::string&) {
        change = result;
        answered = true;
    });
    CHECK(waitUntil([&] { return answered.load(); }));
    CHECK_EQ(change["textDocument"]["version"].get<int>(), 2);
    CHECK_EQ(change["contentChanges"].size(), size_t(2));
    CHECK_EQ(change["contentChanges"][0]["range"]["start"]["character"].get<int>(), 6);
    CHECK_EQ(change["contentChanges"][0]["range"]["end"]["character"].get<int>(), 11);
    CHECK_EQ(change["contentChanges"][0]["text"].get<std::string>(), std::string("there"));
    CHECK_EQ(change["contentChanges"][1]["range"]["start"]["line"].get<int>(), 1);

    server.stop();
    CHECK(waitUntil([&] { return !server.isRunning(); }));
}

TEST(serverRunCommandsCanChangeFilesThroughApplyEdit) {
    gw::lsp::LanguageServer server(fakeSpec(), "/tmp");
    std::mutex mutex;
    Json receivedEdit;
    std::atomic<bool> editArrived{false};
    server.onApplyEdit = [&](const Json& edit, std::function<void(bool)> reply) {
        {
            std::lock_guard<std::mutex> lock(mutex);
            receivedEdit = edit;
        }
        editArrived = true;
        // Answer later, from another thread, the way the app does after hopping to its main thread.
        std::thread([reply] {
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
            reply(true);
        }).detach();
    };
    std::string error;
    CHECK(server.start(&error));
    CHECK(waitUntil([&] { return server.isReady(); }));

    std::atomic<bool> commandDone{false};
    Json commandResult;
    server.request("workspace/executeCommand", {{"command", "fake.refactor"}, {"arguments", Json::array()}},
                   [&](const Json& result, const std::string&) {
                       commandResult = result;
                       commandDone = true;
                   });
    CHECK(waitUntil([&] { return commandDone.load() && editArrived.load(); }));
    CHECK_EQ(commandResult["ran"].get<std::string>(), std::string("fake.refactor"));
    {
        std::lock_guard<std::mutex> lock(mutex);
        CHECK_EQ(receivedEdit["changes"]["file:///tmp/z.fake"][0]["newText"].get<std::string>(), std::string("hi"));
    }

    // The server was told the edit was applied.
    Json serverSaw;
    bool asked = false;
    for (int attempt = 0; attempt < 50 && !(asked && serverSaw.is_object()); ++attempt) {
        std::atomic<bool> got{false};
        server.request("test/applyEditReply", Json::object(), [&](const Json& result, const std::string&) {
            serverSaw = result;
            got = true;
        });
        CHECK(waitUntil([&] { return got.load(); }));
        asked = true;
        if (!serverSaw.is_object()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(20));
        }
    }
    CHECK(serverSaw.is_object());
    CHECK(serverSaw["applied"].get<bool>());

    server.stop();
    CHECK(waitUntil([&] { return !server.isRunning(); }));
}

TEST(applyEditIsRefusedWithoutAHandler) {
    gw::lsp::LanguageServer server(fakeSpec(), "/tmp");
    std::string error;
    CHECK(server.start(&error));
    CHECK(waitUntil([&] { return server.isReady(); }));

    std::atomic<bool> commandDone{false};
    server.request("workspace/executeCommand", {{"command", "fake.refactor"}},
                   [&](const Json&, const std::string&) { commandDone = true; });
    CHECK(waitUntil([&] { return commandDone.load(); }));

    Json serverSaw;
    for (int attempt = 0; attempt < 50 && !serverSaw.is_object(); ++attempt) {
        std::atomic<bool> got{false};
        server.request("test/applyEditReply", Json::object(), [&](const Json& result, const std::string&) {
            serverSaw = result;
            got = true;
        });
        CHECK(waitUntil([&] { return got.load(); }));
        if (!serverSaw.is_object()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(20));
        }
    }
    CHECK(serverSaw.is_object());
    CHECK(!serverSaw["applied"].get<bool>());
    server.stop();
    CHECK(waitUntil([&] { return !server.isRunning(); }));
}

TEST(capabilitiesCanBeRegisteredAndUnregisteredAfterTheHandshake) {
    gw::lsp::LanguageServer server(fakeSpec(), "/tmp");
    std::string error;
    CHECK(server.start(&error));
    CHECK(waitUntil([&] { return server.isReady(); }));
    CHECK(!server.supports("documentFormattingProvider"));
    CHECK(!server.supports("completionProvider"));

    auto ask = [&](const char* method) {
        std::atomic<bool> done{false};
        server.request(method, Json::object(), [&](const Json&, const std::string&) { done = true; });
        CHECK(waitUntil([&] { return done.load(); }));
    };
    ask("test/registerDynamic");
    // The registration request is answered before the next message is handled, so it has landed.
    CHECK(server.supports("documentFormattingProvider"));
    CHECK(server.supports("completionProvider"));
    CHECK(server.supports("completionProvider.resolveProvider"));  // from the second registration
    Json completion = server.capabilities()["completionProvider"];
    CHECK_EQ(completion["triggerCharacters"].size(), size_t(2));  // "." and ":" joined, not repeated

    ask("test/unregisterDynamic");
    CHECK(!server.supports("documentFormattingProvider"));  // its only registration went
    CHECK(server.supports("completionProvider"));           // "b" still provides completion

    server.stop();
    CHECK(waitUntil([&] { return !server.isRunning(); }));
}

TEST(serverMessagesProgressAndSettingsReachTheApp) {
    gw::lsp::LanguageServer server(fakeSpec(), "/tmp");
    std::mutex mutex;
    std::vector<std::string> events;
    server.onShowMessage = [&](int type, const std::string& message) {
        std::lock_guard<std::mutex> lock(mutex);
        events.push_back("show " + std::to_string(type) + " " + message);
    };
    server.onLogMessage = [&](int type, const std::string& message) {
        std::lock_guard<std::mutex> lock(mutex);
        events.push_back("log " + message);
    };
    server.onProgress = [&](const std::string& token, const std::string& kind, const std::string& title, const std::string& message, int percentage) {
        std::lock_guard<std::mutex> lock(mutex);
        events.push_back("progress " + token + " " + kind + " " + title + " " + message + " " + std::to_string(percentage));
    };
    server.onShowMessageRequest = [&](int, const std::string& message, const std::vector<std::string>& actions, std::function<void(const std::string&)> reply) {
        {
            std::lock_guard<std::mutex> lock(mutex);
            events.push_back("ask " + message + " " + std::to_string(actions.size()));
        }
        reply("No");
    };
    server.onConfiguration = [&](const std::string& section, const std::string&) -> Json {
        if (section == "fake.size") {
            return Json(12);
        }
        return Json();
    };
    std::string error;
    CHECK(server.start(&error));
    CHECK(waitUntil([&] { return server.isReady(); }));

    std::atomic<bool> done{false};
    server.request("test/chatter", Json::object(), [&](const Json&, const std::string&) { done = true; });
    CHECK(waitUntil([&] { return done.load(); }));
    CHECK(waitUntil([&] { std::lock_guard<std::mutex> lock(mutex); return events.size() >= 6; }));
    {
        std::lock_guard<std::mutex> lock(mutex);
        CHECK_EQ(events[0], std::string("show 2 careful now"));
        CHECK_EQ(events[1], std::string("log a log line"));
        CHECK_EQ(events[2], std::string("progress idx begin Indexing  0"));
        CHECK_EQ(events[3], std::string("progress idx report  3/10 30"));
        CHECK_EQ(events[4], std::string("progress idx end   -1"));
        CHECK_EQ(events[5], std::string("ask Pick one 2"));
    }

    // The server received our answers: the chosen button and the settings.
    Json replies;
    for (int attempt = 0; attempt < 50 && !(replies.is_object() && replies["choice"].is_object()); ++attempt) {
        std::atomic<bool> got{false};
        server.request("test/chatterReplies", Json::object(), [&](const Json& result, const std::string&) {
            replies = result;
            got = true;
        });
        CHECK(waitUntil([&] { return got.load(); }));
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    CHECK_EQ(replies["choice"]["title"].get<std::string>(), std::string("No"));
    CHECK_EQ(replies["config"].size(), size_t(2));
    CHECK_EQ(replies["config"][0].get<int>(), 12);
    CHECK(replies["config"][1].is_null());

    server.stop();
    CHECK(waitUntil([&] { return !server.isRunning(); }));
}

TEST(serversHearOnlyAboutTheFilesTheyAskedFor) {
    std::string root = "/private/tmp/glasswork-watch-" + std::to_string(getpid());
    std::filesystem::create_directories(root);
    gw::lsp::LanguageServer server(fakeSpec(), root);
    std::string error;
    CHECK(server.start(&error));
    CHECK(waitUntil([&] { return server.isReady(); }));
    CHECK(!server.watchesFiles());

    std::atomic<bool> registered{false};
    server.request("test/watchFiles", Json::object(), [&](const Json&, const std::string&) { registered = true; });
    CHECK(waitUntil([&] { return registered.load(); }));
    CHECK(server.watchesFiles());

    server.didChangeWatchedFiles({
        {root + "/src/a.fake", 1},        // matches **/*.fake
        {root + "/src/b.txt", 2},         // no watcher for it
        {root + "/crates/x/Cargo.toml", 2},  // matches, and "changed" is allowed
        {root + "/Cargo.toml", 3},        // matches the pattern, but the watcher is for changes only
        {"/elsewhere/c.fake", 2},               // outside the project folder
    });
    Json changes;
    for (int attempt = 0; attempt < 50 && !(changes.is_array() && changes.size() >= 2); ++attempt) {
        std::atomic<bool> got{false};
        server.request("test/watchedChanges", Json::object(), [&](const Json& result, const std::string&) {
            changes = result;
            got = true;
        });
        CHECK(waitUntil([&] { return got.load(); }));
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    CHECK_EQ(changes.size(), size_t(2));
    CHECK_EQ(changes[0]["uri"].get<std::string>(), std::string("file://") + root + "/src/a.fake");
    CHECK_EQ(changes[0]["type"].get<int>(), 1);
    CHECK_EQ(changes[1]["uri"].get<std::string>(), std::string("file://") + root + "/crates/x/Cargo.toml");

    server.stop();
    CHECK(waitUntil([&] { return !server.isRunning(); }));
    std::filesystem::remove_all(root);
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

    // Fix the error with an incremental edit (line 1, "undefinedThing" is columns 20..34 -> "0").
    CHECK(server.wantsIncrementalSync());
    gw::SyncEdit fix;
    fix.startLine = 1;
    fix.startUnits = 20;
    fix.endLine = 1;
    fix.endUnits = 34;
    fix.text = "0";
    server.didChangeIncremental(uri, 2, {fix});
    CHECK(waitUntil([&] { return diagnosticCount.load() == 0; }));

    // A refactoring: ask for code actions on `value * value`, run one that is a server command,
    // and expect clangd to answer by asking us to apply an edit.
    std::atomic<bool> editRequested{false};
    server.onApplyEdit = [&](const Json&, std::function<void(bool)> reply) {
        editRequested = true;
        reply(true);
    };
    std::atomic<bool> actionsArrived{false};
    Json commandToRun;
    server.request("textDocument/codeAction",
                   {{"textDocument", {{"uri", uri}}},
                    {"range", {{"start", {{"line", 0}, {"character", 31}}}, {"end", {{"line", 0}, {"character", 44}}}}},
                    {"context", {{"diagnostics", Json::array()}}}},
                   [&](const Json& result, const std::string&) {
                       for (const Json& action : result) {
                           bool isRefactor = action.value("kind", "").rfind("refactor", 0) == 0;
                           if (isRefactor && action.contains("command") && action["command"].is_object()) {
                               commandToRun = action["command"];
                               break;
                           }
                       }
                       actionsArrived = true;
                   });
    CHECK(waitUntil([&] { return actionsArrived.load(); }));
    if (commandToRun.is_object()) {
        std::atomic<bool> commandDone{false};
        server.request("workspace/executeCommand",
                       {{"command", commandToRun["command"]}, {"arguments", commandToRun.value("arguments", Json::array())}},
                       [&](const Json&, const std::string&) { commandDone = true; });
        CHECK(waitUntil([&] { return commandDone.load(); }));
        CHECK(editRequested.load());
    } else {
        std::printf("  note: clangd offered no refactor command here\n");
    }

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
