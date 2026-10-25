// Tests for running programs inside a pseudo-terminal and showing what they print.

#include "TestHarness.hpp"

#include "Pty.hpp"
#include "Terminal.hpp"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <thread>
#include <unistd.h>

namespace {

/// Runs a program in a pty and gathers everything it prints, through a Screen.
struct Session {
    gw::term::Screen screen{40, 10};
    gw::Pty pty;
    std::mutex mutex;
    std::string raw;
    std::atomic<int> exitCode{-999};

    explicit Session(const gw::PtyOptions& options) {
        screen.resize(options.columns, options.rows);
        screen.onReply = [this](const std::string& reply) { pty.write(reply); };
        pty.onOutput = [this](std::string_view bytes) {
            std::lock_guard<std::mutex> lock(mutex);
            raw.append(bytes);
            screen.write(bytes);
            pty.acknowledge(bytes.size());
        };
        pty.onExit = [this](int code) { exitCode.store(code); };
        std::string error;
        started = pty.start(options, &error);
    }

    bool waitForExit(int seconds = 10) {
        for (int attempt = 0; attempt < seconds * 100 && exitCode.load() == -999; ++attempt) {
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
        return exitCode.load() != -999;
    }

    bool waitForText(const std::string& text, int seconds = 10) {
        for (int attempt = 0; attempt < seconds * 100; ++attempt) {
            {
                std::lock_guard<std::mutex> lock(mutex);
                if (raw.find(text) != std::string::npos) {
                    return true;
                }
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
        return false;
    }

    std::string screenText() {
        std::lock_guard<std::mutex> lock(mutex);
        return screen.textInRange(-static_cast<long>(screen.historyCount()), 0, screen.rows() - 1, screen.columns());
    }

    bool started = false;
};

TEST(aProgramPrintsThroughThePty) {
    gw::PtyOptions options;
    options.program = "/bin/sh";
    options.arguments = {"-c", "printf 'hello \\033[31mred\\033[0m\\n'; echo done"};
    Session session(options);
    CHECK(session.started);
    CHECK(session.waitForExit());
    CHECK_EQ(session.exitCode.load(), 0);
    std::string text = session.screenText();
    CHECK(text.find("hello red") != std::string::npos);
    CHECK(text.find("done") != std::string::npos);
    CHECK(session.screen.cellAt(0, 6).foreground.isIndexed());  // the "r" is red
}

TEST(theProgramSeesTheWindowSizeAndTerminalName) {
    gw::PtyOptions options;
    options.program = "/bin/sh";
    options.arguments = {"-c", "stty size; echo TERM=$TERM COLORTERM=$COLORTERM"};
    options.columns = 57;
    options.rows = 13;
    Session session(options);
    CHECK(session.started);
    CHECK(session.waitForExit());
    std::string text = session.screenText();
    CHECK(text.find("13 57") != std::string::npos);
    CHECK(text.find("TERM=xterm-256color COLORTERM=truecolor") != std::string::npos);
}

TEST(typingReachesTheProgramAndEchoesBack) {
    gw::PtyOptions options;
    options.program = "/bin/cat";
    Session session(options);
    CHECK(session.started);
    session.pty.write("typed text\n");
    CHECK(session.waitForText("typed text"));
    // Control-D ends the input, so cat exits by itself.
    session.pty.write("\x04");
    CHECK(session.waitForExit());
    CHECK_EQ(session.exitCode.load(), 0);
}

TEST(resizingTellsTheProgram) {
    gw::PtyOptions options;
    options.program = "/bin/sh";
    options.arguments = {"-c", "sleep 0.5; stty size"};
    options.columns = 30;
    options.rows = 8;
    Session session(options);
    CHECK(session.started);
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    session.pty.resize(66, 21);
    CHECK(session.waitForExit());
    CHECK(session.screenText().find("21 66") != std::string::npos);
}

TEST(exitCodesAndMissingPrograms) {
    gw::PtyOptions failing;
    failing.program = "/bin/sh";
    failing.arguments = {"-c", "exit 7"};
    Session session(failing);
    CHECK(session.waitForExit());
    CHECK_EQ(session.exitCode.load(), 7);

    gw::PtyOptions missing;
    missing.program = "/no/such/program";
    Session broken(missing);
    CHECK(broken.waitForExit());
    CHECK_EQ(broken.exitCode.load(), 127);
}

TEST(theWorkingDirectoryAndShellNameAreAvailable) {
    gw::PtyOptions options;
    options.program = "/bin/sh";
    options.arguments = {"-c", "sleep 1"};
    options.workingDirectory = "/private/tmp";
    Session session(options);
    CHECK(session.started);
    std::this_thread::sleep_for(std::chrono::milliseconds(300));
    CHECK_EQ(session.pty.currentDirectory(), std::string("/private/tmp"));
    session.pty.terminate();
    CHECK(session.waitForExit());
}

TEST(aLoginShellStartsAndRunsCommands) {
    gw::PtyOptions options;  // default: the user's shell as a login shell
    options.columns = 80;
    options.rows = 24;
    Session session(options);
    CHECK(session.started);
    session.pty.write("echo glasswork-$((6*7))\r");
    CHECK(session.waitForText("glasswork-42"));
    session.pty.write("exit\r");
    CHECK(session.waitForExit());
}

TEST(aFullScreenProgramDrawsCorrectly) {
    // vim uses the alternate screen, cursor addressing, scroll regions, colors and bracketed
    // paste: a good check that the emulator agrees with a real terminal program.
    if (access("/usr/bin/vim", X_OK) != 0) {
        return;
    }
    std::string path = "/private/tmp/glasswork-pty-vim-test.txt";
    {
        FILE* file = fopen(path.c_str(), "w");
        for (int line = 1; line <= 60; ++line) {
            fprintf(file, "line %d of the test file\n", line);
        }
        fclose(file);
    }
    gw::PtyOptions options;
    options.program = "/usr/bin/vim";
    options.arguments = {"-u", "NONE", "-N", "-n", path};
    options.columns = 60;
    options.rows = 15;
    Session session(options);
    CHECK(session.started);
    CHECK(session.waitForText("line 1 of the test file"));
    std::this_thread::sleep_for(std::chrono::milliseconds(300));
    {
        std::lock_guard<std::mutex> lock(session.mutex);
        CHECK(session.screen.onAlternateScreen());
        CHECK_EQ(session.screen.textInRange(0, 0, 0, 60), std::string("line 1 of the test file"));
        CHECK_EQ(session.screen.textInRange(13, 0, 13, 60), std::string("line 14 of the test file"));
        CHECK(session.screen.textInRange(14, 0, 14, 60).find("test.txt") != std::string::npos);  // the status line
    }
    // Page down: the text scrolls and the new lines appear.
    session.pty.write("\x06");  // Control-F
    std::this_thread::sleep_for(std::chrono::milliseconds(300));
    {
        std::lock_guard<std::mutex> lock(session.mutex);
        CHECK_EQ(session.screen.textInRange(0, 0, 0, 60), std::string("line 13 of the test file"));
        CHECK_EQ(session.screen.textInRange(13, 0, 13, 60), std::string("line 26 of the test file"));
    }
    session.pty.write(":q!\r");
    CHECK(session.waitForExit());
    {
        std::lock_guard<std::mutex> lock(session.mutex);
        CHECK(!session.screen.onAlternateScreen());
    }
    remove(path.c_str());
}

TEST(hugeOutputDoesNotFloodMemory) {
    gw::PtyOptions options;
    options.program = "/bin/sh";
    options.arguments = {"-c", "yes 'a line of output to fill the screen' | head -n 200000"};
    Session session(options);
    CHECK(session.started);
    CHECK(session.waitForExit(30));
    CHECK(session.screen.historyCount() > 1000);
}

TEST(closingATerminalNobodyIsReadingDoesNotHang) {
    // A program floods the terminal while the screen never catches up (nothing acknowledges the
    // output), and one that ignores the hang-up signal. Closing either must still finish promptly.
    for (const char* script : {"yes", "trap '' HUP; while true; do sleep 1; done"}) {
        auto pty = std::make_unique<gw::Pty>();
        pty->onOutput = [](std::string_view) {};
        gw::PtyOptions options;
        options.program = "/bin/sh";
        options.arguments = {"-c", script};
        CHECK(pty->start(options));
        std::this_thread::sleep_for(std::chrono::milliseconds(500));
        auto start = std::chrono::steady_clock::now();
        pty.reset();
        double seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
        CHECK(seconds < 3);
    }
}

}  // namespace

int main() {
    return harness::runAllTests();
}
