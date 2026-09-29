// A manual check against the real `claude` command. It needs Claude Code installed and
// logged in, and it spends a few cents, so it is not part of `ctest`. Run it with:
//
//     ./build/glasswork_claude_live
//
// It starts a session in a temporary folder and walks through: a permission prompt that we
// allow, switching to auto-accept mode, interrupting a long task, and a one-off question.

#include "ClaudeSession.hpp"

#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <filesystem>
#include <mutex>
#include <thread>
#include <unistd.h>

namespace {

using gw::claude::Event;
using gw::claude::EventKind;

int failures = 0;

void expect(bool condition, const char* what) {
    std::printf("  %s %s\n", condition ? "ok  " : "FAIL", what);
    if (!condition) {
        ++failures;
    }
}

/// Collects what the session reports so the main thread can wait for particular moments.
struct Recorder {
    std::mutex mutex;
    std::condition_variable changed;
    gw::claude::Transcript transcript;
    int permissionRequests = 0;
    int turnsFinished = 0;
    bool sessionStarted = false;
    bool autoAllow = true;
    gw::claude::Session* session = nullptr;
    int exitCode = -999;

    void handle(const Event& event) {
        std::unique_lock<std::mutex> lock(mutex);
        if (event.kind == EventKind::SessionInit) {
            sessionStarted = true;
        }
        if (event.kind == EventKind::PermissionRequest) {
            ++permissionRequests;
            std::printf("    [permission asked for %s]\n", event.toolName.c_str());
            if (autoAllow && session != nullptr) {
                session->answerPermission(event.requestId, true, event.toolInput);
            }
        }
        if (event.kind == EventKind::TurnResult) {
            ++turnsFinished;
        }
        transcript.apply(event);
        changed.notify_all();
    }

    template <typename Condition>
    bool waitFor(Condition condition, int seconds) {
        std::unique_lock<std::mutex> lock(mutex);
        return changed.wait_for(lock, std::chrono::seconds(seconds), condition);
    }
};

std::string assistantText(const gw::claude::Transcript& transcript) {
    std::string text;
    for (const auto& message : transcript.messages()) {
        if (message.role != gw::claude::Message::Role::Assistant) {
            continue;
        }
        for (const auto& block : message.blocks) {
            if (block.kind == gw::claude::Block::Kind::Text) {
                text += block.text + "\n";
            }
        }
    }
    return text;
}

}  // namespace

int main() {
    if (!gw::claude::Session::isInstalled()) {
        std::printf("`claude` was not found; nothing to check.\n");
        return 0;
    }

    std::filesystem::path folder = std::filesystem::temp_directory_path() / ("glasswork-live-" + std::to_string(getpid()));
    std::filesystem::create_directories(folder);
    std::string directory = std::filesystem::canonical(folder).string();

    Recorder recorder;
    gw::claude::Session session;
    recorder.session = &session;
    session.onEvent = [&recorder](const Event& event) { recorder.handle(event); };
    session.onExit = [&recorder](int code, const std::string&) {
        std::lock_guard<std::mutex> lock(recorder.mutex);
        recorder.exitCode = code;
        recorder.changed.notify_all();
    };

    gw::claude::SessionOptions options;
    options.workingDirectory = directory;
    options.model = "sonnet";
    options.permissionMode = "manual";
    std::string error;

    std::printf("Starting a session…\n");
    expect(session.start(options, &error), "session starts");
    if (!error.empty()) {
        std::printf("    %s\n", error.c_str());
    }

    std::printf("\n1. A permission prompt that we allow\n");
    session.sendUserMessage("Create a file named hello.txt containing exactly the word hi. Then reply with just DONE.");
    expect(recorder.waitFor([&] { return recorder.turnsFinished >= 1; }, 120), "the turn finishes");
    expect(recorder.permissionRequests >= 1, "a permission request arrived");
    expect(std::filesystem::exists(folder / "hello.txt"), "the file was created after we allowed it");
    {
        std::lock_guard<std::mutex> lock(recorder.mutex);
        expect(recorder.transcript.sessionId().size() > 10, "the transcript knows the session id");
        expect(assistantText(recorder.transcript).find("DONE") != std::string::npos, "the reply mentions DONE");
        std::printf("    cost: $%.4f, %ld ms\n", recorder.transcript.lastTurn().costUsd,
                    recorder.transcript.lastTurn().durationMilliseconds);
    }

    std::printf("\n2. Switching to auto-accept edits\n");
    int askedBefore = recorder.permissionRequests;
    session.setPermissionMode("acceptEdits");
    std::this_thread::sleep_for(std::chrono::milliseconds(500));
    session.sendUserMessage("Create a file named second.txt containing the word two. Then reply with just OK.");
    expect(recorder.waitFor([&] { return recorder.turnsFinished >= 2; }, 120), "the second turn finishes");
    expect(std::filesystem::exists(folder / "second.txt"), "the second file was created");
    expect(recorder.permissionRequests == askedBefore, "no permission question was needed");

    std::printf("\n3. Interrupting a long task\n");
    session.sendUserMessage("Run this shell command and wait for it: for i in $(seq 1 60); do echo $i; sleep 1; done");
    std::this_thread::sleep_for(std::chrono::seconds(12));
    auto interruptedAt = std::chrono::steady_clock::now();
    session.interrupt();
    expect(recorder.waitFor([&] { return recorder.turnsFinished >= 3; }, 30), "the turn ends after interrupt");
    double seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - interruptedAt).count();
    std::printf("    stopped %.1f s after the interrupt\n", seconds);
    expect(seconds < 20, "it stopped promptly");

    std::printf("\n4. The session is still usable after an interrupt\n");
    session.sendUserMessage("Reply with just the word alive.");
    expect(recorder.waitFor([&] { return recorder.turnsFinished >= 4; }, 60), "a new turn finishes");
    {
        std::lock_guard<std::mutex> lock(recorder.mutex);
        expect(assistantText(recorder.transcript).find("alive") != std::string::npos, "it answered");
    }

    session.stop();
    expect(recorder.waitFor([&] { return recorder.exitCode != -999; }, 15), "the process exits when stopped");

    std::printf("\n5. A one-off question with no tools\n");
    std::string askError;
    std::string answer = gw::claude::askOnce("Reply with only the number 4 spelled as a digit: what is 2+2?", directory,
                                             "sonnet", &askError);
    std::printf("    answer: \"%s\" %s\n", answer.c_str(), askError.c_str());
    expect(answer.find('4') != std::string::npos, "askOnce answered");

    std::filesystem::remove_all(folder);
    std::printf("\n%s\n", failures == 0 ? "All live checks passed." : "Some live checks FAILED.");
    return failures == 0 ? 0 : 1;
}
