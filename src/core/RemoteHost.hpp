#pragma once

#include <optional>
#include <string>
#include <vector>

// (shellQuote, for the remote shell, is in Tasks.hpp.)

namespace gw {

/// Where something lives on another machine: "user@host" (or just "host", or a Tailscale name)
/// and an absolute path there.
struct RemoteLocation {
    std::string destination;
    std::string path;
};

/// One entry of a remote folder.
struct RemoteEntry {
    std::string name;
    bool isDirectory = false;
};

/// Understands "host:/path", "user@host:/path" and "ssh://user@host/path". Nullopt if the text is
/// not one of those (a plain local path, for example). A path of "~" or "~/x" is kept as typed.
std::optional<RemoteLocation> parseRemoteLocation(const std::string& text);

/// Works with a Linux machine reachable over SSH (Tailscale SSH included) by running the system
/// `ssh`. Every call blocks: use them from a background queue (or accept a short pause).
/// Connections are shared between calls, so only the first one pays for the handshake.
class RemoteHost {
public:
    explicit RemoteHost(std::string destination);

    const std::string& destination() const { return destination_; }

    /// The folder's entries (hidden ones included, "." and ".." not). Symbolic links count as
    /// what they point to.
    bool listDirectory(const std::string& path, std::vector<RemoteEntry>* entries, std::string* error) const;

    /// The whole file.
    bool readFile(const std::string& path, std::string* contents, std::string* error) const;

    /// Replaces the file: the new text goes to a temporary file next to it first, so a dropped
    /// connection never leaves half a file behind. Keeps the old file's permissions.
    bool writeFile(const std::string& path, const std::string& contents, std::string* error) const;

    /// The home folder, and `path` made absolute ("~" and "~/x" expanded). Nullopt on failure.
    std::optional<std::string> resolvePath(const std::string& path, std::string* error) const;

    /// Arguments for an interactive shell in `folder` on the remote machine (for a terminal).
    std::vector<std::string> shellCommand(const std::string& folder) const;

private:
    /// Runs `command` on the remote machine, with `input` as its standard input.
    bool run(const std::string& command, const std::string& input, double timeoutSeconds, std::string* output,
             std::string* error) const;

    /// Options shared by every ssh call: no prompts, a connect timeout, a shared connection.
    std::vector<std::string> baseArguments() const;

    std::string destination_;
};

}  // namespace gw
