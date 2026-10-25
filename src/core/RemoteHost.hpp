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

// ---- Parsing

/// "host:/path", "user@host:/path" or "ssh://user@host/path"; nullopt for anything else. "~" and
/// "~/x" are kept as typed.
std::optional<RemoteLocation> parseRemoteLocation(const std::string& text);

/// A Linux machine reachable with the system `ssh` (Tailscale SSH included). Every call blocks, so
/// use them from a background queue. Calls share one connection.
class RemoteHost {
public:
    // ---- Constructors
    explicit RemoteHost(std::string destination);

    // ---- Getters
    const std::string& destination() const { return destination_; }

    // ---- Files and folders
    /// Hidden entries included; links count as what they point to.
    bool listDirectory(const std::string& path, std::vector<RemoteEntry>* entries, std::string* error) const;
    bool readFile(const std::string& path, std::string* contents, std::string* error) const;
    /// Written beside the file and swapped in, keeping its permissions; through a link, the target changes.
    bool writeFile(const std::string& path, const std::string& contents, std::string* error) const;
    /// `path` made absolute, "~" expanded.
    std::optional<std::string> resolvePath(const std::string& path, std::string* error) const;

    // ---- Terminal
    /// Arguments for an interactive shell in `folder`.
    std::vector<std::string> shellCommand(const std::string& folder) const;

private:
    // ---- Private functions
    bool run(const std::string& command, const std::string& input, double timeoutSeconds, std::string* output,
             std::string* error) const;
    std::vector<std::string> baseArguments() const;

    // ---- Private variables
    std::string destination_;
};

}  // namespace gw
