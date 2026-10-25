// Tests for talking to another machine over SSH. A stand-in `ssh` program that runs the command
// on this machine is put first on the PATH, so nothing touches the network.

#include "TestHarness.hpp"

#include "RemoteHost.hpp"
#include "Tasks.hpp"

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <unistd.h>

namespace {

namespace fs = std::filesystem;

TEST(parsesRemoteLocations) {
    auto plain = gw::parseRemoteLocation("devbox:/home/nate/project");
    CHECK(plain.has_value());
    CHECK_EQ(plain->destination, std::string("devbox"));
    CHECK_EQ(plain->path, std::string("/home/nate/project"));

    auto withUser = gw::parseRemoteLocation("nate@devbox.tail1234.ts.net:~/code");
    CHECK(withUser.has_value());
    CHECK_EQ(withUser->destination, std::string("nate@devbox.tail1234.ts.net"));
    CHECK_EQ(withUser->path, std::string("~/code"));

    auto url = gw::parseRemoteLocation("ssh://nate@100.64.0.5/srv/app");
    CHECK(url.has_value());
    CHECK_EQ(url->destination, std::string("nate@100.64.0.5"));
    CHECK_EQ(url->path, std::string("/srv/app"));

    CHECK(!gw::parseRemoteLocation("/Users/nate/code").has_value());
    CHECK(!gw::parseRemoteLocation("devbox:").has_value());
    CHECK(!gw::parseRemoteLocation("devbox:relative/path").has_value());
    CHECK(!gw::parseRemoteLocation("has space:/x").has_value());
}

TEST(quotesForTheShell) {
    CHECK_EQ(gw::shellQuote("plain"), std::string("'plain'"));
    CHECK_EQ(gw::shellQuote("it's"), std::string("'it'\\''s'"));
    CHECK_EQ(gw::shellQuote("a b;rm -rf *"), std::string("'a b;rm -rf *'"));
}

TEST(buildsAShellCommand) {
    gw::RemoteHost host("nate@devbox");
    std::vector<std::string> command = host.shellCommand("/srv/my app");
    CHECK_EQ(command.size(), size_t(4));
    CHECK_EQ(command[0], std::string("ssh"));
    CHECK_EQ(command[1], std::string("-t"));
    CHECK_EQ(command[2], std::string("nate@devbox"));
    CHECK(command[3].find("cd '/srv/my app'") != std::string::npos);
}

TEST(readsAndWritesThroughSsh) {
    fs::path folder = fs::temp_directory_path() / ("gw-remote-" + std::to_string(getpid()));
    fs::create_directories(folder / "bin");
    {
        // The stand-in ssh: ignore the options, the host is the second to last argument and the
        // command the last one; run the command here.
        std::ofstream script(folder / "bin" / "ssh");
        script << "#!/bin/sh\n"
                  "for last; do :; done\n"
                  "echo 'BANNER: welcome to the machine'\n"  // like a login banner on every command
                  "exec /bin/sh -c \"$last\"\n";
    }
    fs::permissions(folder / "bin" / "ssh", fs::perms::owner_all);
    std::string path = std::string(getenv("PATH") ? getenv("PATH") : "");
    setenv("PATH", ((folder / "bin").string() + ":" + path).c_str(), 1);

    gw::RemoteHost host("fake");
    std::string error;

    fs::path target = folder / "odd name's file.txt";
    CHECK(host.writeFile(target.string(), "hello\nworld\n", &error));
    CHECK_EQ(error, std::string());

    std::string contents;
    CHECK(host.readFile(target.string(), &contents, &error));
    CHECK_EQ(contents, std::string("hello\nworld\n"));  // the banner is not part of the file

    // Saving again replaces the text and leaves no temporary file behind.
    CHECK(host.writeFile(target.string(), "second", &error));
    CHECK(host.readFile(target.string(), &contents, &error));
    CHECK_EQ(contents, std::string("second"));
    CHECK(!fs::exists(target.string() + ".glasswork-save"));

    CHECK(!host.readFile((folder / "missing").string(), &contents, &error));
    CHECK(!error.empty());

    auto resolved = host.resolvePath(folder.string(), &error);
    CHECK(resolved.has_value());
    CHECK(resolved->find("BANNER") == std::string::npos);
    CHECK(resolved->find('\n') == std::string::npos);

    setenv("PATH", path.c_str(), 1);
    fs::remove_all(folder);
}

}  // namespace

int main() {
    return harness::runAllTests();
}
