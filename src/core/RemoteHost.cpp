#include "RemoteHost.hpp"

#include "Process.hpp"
#include "Tasks.hpp"

#include <cctype>

namespace gw {

namespace {

bool looksLikeHost(const std::string& text) {
    if (text.empty()) {
        return false;
    }
    for (char character : text) {
        unsigned char byte = static_cast<unsigned char>(character);
        bool allowed = std::isalnum(byte) || character == '.' || character == '-' || character == '_' || character == '@';
        if (!allowed) {
            return false;
        }
    }
    return true;
}

}  // namespace

std::optional<RemoteLocation> parseRemoteLocation(const std::string& text) {
    const std::string scheme = "ssh://";
    if (text.compare(0, scheme.size(), scheme) == 0) {
        std::string rest = text.substr(scheme.size());
        size_t slash = rest.find('/');
        if (slash == std::string::npos) {
            return std::nullopt;
        }
        std::string destination = rest.substr(0, slash);
        if (!looksLikeHost(destination)) {
            return std::nullopt;
        }
        return RemoteLocation{destination, rest.substr(slash)};
    }

    size_t colon = text.find(':');
    if (colon == std::string::npos) {
        return std::nullopt;
    }
    std::string destination = text.substr(0, colon);
    std::string path = text.substr(colon + 1);
    if (!looksLikeHost(destination) || path.empty()) {
        return std::nullopt;
    }
    bool pathIsUsable = path[0] == '/' || path[0] == '~';
    if (!pathIsUsable) {
        return std::nullopt;
    }
    return RemoteLocation{destination, path};
}

namespace {

/// A path for the remote shell. "~" and "~/x" must stay outside the quotes so the shell expands them.
std::string remotePathWord(const std::string& path) {
    if (path == "~") {
        return "~";
    }
    if (path.compare(0, 2, "~/") == 0) {
        return "~/" + shellQuote(path.substr(2));
    }
    return shellQuote(path);
}

}  // namespace

namespace {

/// Printed by every remote command before its own output. Some machines print a banner (system
/// info, a message of the day) from their shell startup files on every login, even for a single
/// command; everything before this marker is that banner, not the answer.
const char* const kStartMarker = "@@glasswork-start-9c1e5b@@";

}  // namespace

RemoteHost::RemoteHost(std::string destination) : destination_(std::move(destination)) {}

std::vector<std::string> RemoteHost::baseArguments() const {
    return {
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=10",
        "-o", "ServerAliveInterval=15",
        "-o", "ControlMaster=auto",
        "-o", "ControlPath=/tmp/glasswork-ssh-%C",
        "-o", "ControlPersist=10m",
    };
}

bool RemoteHost::run(const std::string& command, const std::string& input, double timeoutSeconds, std::string* output,
                     std::string* error) const {
    std::string ssh = findExecutable("ssh");
    if (ssh.empty()) {
        ssh = "/usr/bin/ssh";
    }
    std::vector<std::string> arguments = {ssh};
    for (const std::string& argument : baseArguments()) {
        arguments.push_back(argument);
    }
    arguments.push_back(destination_);
    arguments.push_back("printf '%s' " + shellQuote(kStartMarker) + "; " + command);

    ProcessOptions options;
    options.input = input;
    options.timeoutSeconds = timeoutSeconds;
    ProcessResult result = runProcess(arguments, options);

    if (!result.started) {
        if (error) {
            *error = "Couldn't start ssh: " + result.startError;
        }
        return false;
    }
    if (result.timedOut) {
        if (error) {
            *error = "Timed out talking to " + destination_ + ".";
        }
        return false;
    }
    if (result.exitCode != 0) {
        if (error) {
            std::string message = result.errorOutput;
            while (!message.empty() && (message.back() == '\n' || message.back() == '\r')) {
                message.pop_back();
            }
            if (message.empty()) {
                message = "ssh exited with code " + std::to_string(result.exitCode) + ".";
            }
            *error = message;
        }
        return false;
    }
    // Drop whatever the machine printed before our marker (its login banner).
    size_t markerPosition = result.output.find(kStartMarker);
    if (markerPosition == std::string::npos) {
        if (error) {
            *error = "Unexpected reply from " + destination_ + ": the command's output never started.";
        }
        return false;
    }
    if (output) {
        *output = result.output.substr(markerPosition + std::string(kStartMarker).size());
    }
    return true;
}

bool RemoteHost::listDirectory(const std::string& path, std::vector<RemoteEntry>* entries, std::string* error) const {
    // -L follows links, so %Y is what each entry really is ("d" for a folder, even through a
    // link). Each record is that letter, a space and the name, ended by a NUL so names with
    // spaces or newlines survive.
    std::string command = "find -L " + remotePathWord(path) + " -mindepth 1 -maxdepth 1 -printf '%Y %f\\0'";
    std::string output;
    if (!run(command, "", 20, &output, error)) {
        return false;
    }
    entries->clear();
    size_t position = 0;
    while (position < output.size()) {
        size_t end = output.find('\0', position);
        if (end == std::string::npos) {
            end = output.size();
        }
        const size_t prefixLength = 2;  // the type letter and the space
        if (end - position > prefixLength) {
            RemoteEntry entry;
            entry.isDirectory = output[position] == 'd';
            entry.name = output.substr(position + prefixLength, end - position - prefixLength);
            entries->push_back(std::move(entry));
        }
        position = end + 1;
    }
    return true;
}

bool RemoteHost::readFile(const std::string& path, std::string* contents, std::string* error) const {
    return run("cat -- " + remotePathWord(path), "", 60, contents, error);
}

bool RemoteHost::writeFile(const std::string& path, const std::string& contents, std::string* error) const {
    std::string target = remotePathWord(path);
    std::string temporary = remotePathWord(path + ".glasswork-save");
    // Write beside the file, copy its permissions if it exists, then swap it in.
    std::string command = "cat > " + temporary + " && { chmod --reference=" + target + " " + temporary +
                          " 2>/dev/null; true; } && mv -f -- " + temporary + " " + target;
    return run(command, contents, 60, nullptr, error);
}

std::optional<std::string> RemoteHost::resolvePath(const std::string& path, std::string* error) const {
    std::string output;
    if (!run("cd " + remotePathWord(path) + " && pwd", "", 20, &output, error)) {
        return std::nullopt;
    }
    while (!output.empty() && (output.back() == '\n' || output.back() == '\r')) {
        output.pop_back();
    }
    if (output.empty()) {
        return std::nullopt;
    }
    return output;
}

std::vector<std::string> RemoteHost::shellCommand(const std::string& folder) const {
    // -t: a real terminal on the other side. exec the user's login shell in the folder.
    std::string remote = "cd " + remotePathWord(folder) + " && exec \"${SHELL:-/bin/sh}\" -l";
    return {"ssh", "-t", destination_, remote};
}

}  // namespace gw
