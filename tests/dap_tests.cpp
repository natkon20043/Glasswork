// Tests for the debug adapter client, with a fake adapter written in Python, plus (only with
// GLASSWORK_DAP_LIVE=1) a real debugging session with lldb-dap from Xcode.

#include "TestHarness.hpp"

#include "Dap.hpp"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <thread>
#include <unistd.h>

#ifndef TEST_SOURCE_DIR
#define TEST_SOURCE_DIR "."
#endif

namespace {

using gw::dap::Json;

template <class Condition>
bool waitUntil(Condition condition, int milliseconds = 8000) {
    for (int waited = 0; waited < milliseconds; waited += 20) {
        if (condition()) {
            return true;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    return false;
}

TEST(requestsEventsAndReverseRequests) {
    gw::dap::Connection connection;
    std::mutex mutex;
    std::vector<std::string> events;
    std::atomic<bool> reverseSeen{false};
    connection.onEvent = [&](const std::string& event, const Json& body) {
        std::lock_guard<std::mutex> lock(mutex);
        events.push_back(event);
        if (event == "stopped") {
            CHECK_EQ(body["threadId"].get<int>(), 7);
        }
    };
    connection.onReverseRequest = [&](const std::string& command, const Json&, bool& success) {
        reverseSeen = command == "runInTerminal";
        success = false;  // we don't support it; the adapter must cope
        return Json();
    };
    std::string error;
    CHECK(connection.start({"python3", std::string(TEST_SOURCE_DIR) + "/tests/fake_dap_adapter.py"}, "/tmp", &error));

    std::atomic<bool> initialized{false};
    connection.request("initialize", {{"adapterID", "test"}}, [&](bool success, const Json& body, const std::string&) {
        CHECK(success);
        CHECK(body["supportsConfigurationDoneRequest"].get<bool>());
        initialized = true;
    });
    CHECK(waitUntil([&] { return initialized.load(); }));

    std::atomic<bool> configured{false};
    connection.request("configurationDone", Json::object(), [&](bool success, const Json&, const std::string&) {
        configured = success;
    });
    CHECK(waitUntil([&] { return configured.load(); }));
    CHECK(waitUntil([&] {
        std::lock_guard<std::mutex> lock(mutex);
        return std::find(events.begin(), events.end(), "stopped") != events.end();
    }));
    CHECK(waitUntil([&] { return reverseSeen.load(); }));
    {
        std::lock_guard<std::mutex> lock(mutex);
        CHECK_EQ(events.front(), std::string("initialized"));
    }

    std::atomic<bool> evaluated{false};
    std::string result;
    connection.request("evaluate", {{"expression", "1+1"}}, [&](bool success, const Json& body, const std::string&) {
        CHECK(success);
        result = body["result"].get<std::string>();
        evaluated = true;
    });
    CHECK(waitUntil([&] { return evaluated.load(); }));
    CHECK_EQ(result, std::string("= 1+1"));

    std::atomic<bool> failed{false};
    std::string message;
    connection.request("bad", Json(), [&](bool success, const Json&, const std::string& text) {
        CHECK(!success);
        message = text;
        failed = true;
    });
    CHECK(waitUntil([&] { return failed.load(); }));
    CHECK_EQ(message, std::string("no good"));

    connection.stop();
    CHECK(waitUntil([&] { return !connection.isRunning(); }));
}

TEST(pendingRequestsFailWhenTheAdapterEnds) {
    gw::dap::Connection connection;
    std::string error;
    CHECK(connection.start({"python3", std::string(TEST_SOURCE_DIR) + "/tests/fake_dap_adapter.py"}, "/tmp", &error));
    std::atomic<bool> answered{false};
    bool wasSuccess = true;
    // The fake adapter never answers this command.
    connection.request("neverAnswered", Json::object(), [&](bool success, const Json&, const std::string&) {
        wasSuccess = success;
        answered = true;
    });
    connection.stop();
    CHECK(waitUntil([&] { return answered.load(); }));
    CHECK(!wasSuccess);
}

// A real session: build a small program with symbols, stop at a breakpoint, read a variable.
TEST(realLldbStopsAtABreakpointAndReadsVariables) {
    if (std::getenv("GLASSWORK_DAP_LIVE") == nullptr) {
        return;
    }
    std::filesystem::path directory = std::filesystem::temp_directory_path() / ("gw-dap-live-" + std::to_string(getpid()));
    std::filesystem::create_directories(directory);
    std::string source = (directory / "prog.c").string();
    std::string program = (directory / "prog").string();
    std::ofstream(source) << "#include <stdio.h>\n"
                             "int main(void) {\n"
                             "    int answer = 6 * 7;\n"
                             "    printf(\"%d\\n\", answer);\n"
                             "    return 0;\n"
                             "}\n";
    std::string compile = "clang -g -O0 " + source + " -o " + program;
    CHECK_EQ(std::system(compile.c_str()), 0);

    gw::dap::Connection connection;
    std::atomic<bool> stopped{false};
    std::atomic<bool> initialized{false};
    std::atomic<bool> terminated{false};
    connection.onEvent = [&](const std::string& event, const Json&) {
        if (event == "stopped") stopped = true;
        if (event == "initialized") initialized = true;
        if (event == "terminated" || event == "exited") terminated = true;
    };
    std::string error;
    CHECK(connection.start(gw::dap::defaultAdapterCommand(), directory.string(), &error));

    std::atomic<bool> ready{false};
    connection.request("initialize", {{"adapterID", "lldb-dap"}, {"linesStartAt1", true}, {"columnsStartAt1", true}, {"pathFormat", "path"}},
                       [&](bool success, const Json&, const std::string&) { ready = success; });
    CHECK(waitUntil([&] { return ready.load(); }));
    // launch is answered only after configurationDone, so don't wait for it here.
    connection.request("launch", {{"program", program}, {"cwd", directory.string()}, {"stopOnEntry", false}},
                       [](bool, const Json&, const std::string&) {});
    CHECK(waitUntil([&] { return initialized.load(); }));
    std::atomic<bool> breakpointSet{false};
    connection.request("setBreakpoints", {{"source", {{"path", source}}}, {"breakpoints", Json::array({{{"line", 4}}})}},
                       [&](bool success, const Json&, const std::string&) { breakpointSet = success; });
    CHECK(waitUntil([&] { return breakpointSet.load(); }));
    connection.request("configurationDone", Json::object(), [](bool, const Json&, const std::string&) {});
    CHECK(waitUntil([&] { return stopped.load(); }, 20000));

    // Threads, stack, scopes and variables.
    std::atomic<bool> gotThreads{false};
    int threadId = 0;
    connection.request("threads", Json::object(), [&](bool success, const Json& body, const std::string&) {
        if (success && !body["threads"].empty()) threadId = body["threads"][0]["id"].get<int>();
        gotThreads = true;
    });
    CHECK(waitUntil([&] { return gotThreads.load(); }));
    std::atomic<bool> gotStack{false};
    int frameId = -1;
    int line = 0;
    connection.request("stackTrace", {{"threadId", threadId}}, [&](bool success, const Json& body, const std::string&) {
        if (success && !body["stackFrames"].empty()) {
            frameId = body["stackFrames"][0]["id"].get<int>();
            line = body["stackFrames"][0]["line"].get<int>();
        }
        gotStack = true;
    });
    CHECK(waitUntil([&] { return gotStack.load(); }));
    CHECK_EQ(line, 4);

    std::atomic<bool> gotScopes{false};
    int localsReference = 0;
    connection.request("scopes", {{"frameId", frameId}}, [&](bool success, const Json& body, const std::string&) {
        if (success) {
            for (const Json& scope : body["scopes"]) {
                if (scope.value("name", "") == "Locals") localsReference = scope["variablesReference"].get<int>();
            }
        }
        gotScopes = true;
    });
    CHECK(waitUntil([&] { return gotScopes.load(); }));
    CHECK(localsReference != 0);

    std::atomic<bool> gotVariables{false};
    std::string answerValue;
    connection.request("variables", {{"variablesReference", localsReference}}, [&](bool success, const Json& body, const std::string&) {
        if (success) {
            for (const Json& variable : body["variables"]) {
                if (variable.value("name", "") == "answer") answerValue = variable.value("value", "");
            }
        }
        gotVariables = true;
    });
    CHECK(waitUntil([&] { return gotVariables.load(); }));
    CHECK_EQ(answerValue, std::string("42"));

    connection.request("continue", {{"threadId", threadId}}, [](bool, const Json&, const std::string&) {});
    CHECK(waitUntil([&] { return terminated.load(); }, 15000));
    connection.stop();
    std::filesystem::remove_all(directory);
}

}  // namespace

int main() {
    return harness::runAllTests();
}
