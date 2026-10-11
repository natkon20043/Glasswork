#pragma once

#include <nlohmann/json.hpp>

#include <map>
#include <optional>
#include <string>
#include <vector>

namespace gw {

/// One key press with modifiers, as written in VS Code keybindings ("cmd+shift+p").
struct KeyChord {
    bool command = false;
    bool control = false;
    bool option = false;
    bool shift = false;
    /// Lower case: "a", "5", "f12", "enter", "escape", "tab", "space", "backspace", "delete",
    /// arrows, "home", "end", "pageup", "pagedown", or a symbol such as "/" or "[".
    std::string key;

    bool operator==(const KeyChord& other) const {
        return command == other.command && control == other.control && option == other.option && shift == other.shift && key == other.key;
    }
};

struct KeyBinding {
    std::vector<KeyChord> chords;
    std::string command;
    /// The `args` given to the command, or null.
    nlohmann::json arguments;
    std::string when;
    /// A "-command" entry that removes the command's default binding.
    bool removes = false;
};

/// "cmd+k cmd+s" or "ctrl+shift+p" -> chord sequence. `cmd`, `meta`, `win`, `super` mean Command.
/// Empty if the text isn't a key combination.
std::optional<std::vector<KeyChord>> parseKeyChords(const std::string& text);

/// Supports `a && b`, `a || b`, `!a`, `(...)`, `a == 'x'`, `a != 'x'`, `a =~ /regex/`. A bare name is
/// true when set and not "false" or "0". An empty clause is true.
bool evaluateWhenClause(const std::string& clause, const std::map<std::string, std::string>& context);

/// Extension keybindings plus the user's keybindings.json, which wins when both use the same keys.
class KeybindingTable {
public:
    // Chords pressed so far -> nothing, the start of a longer sequence, or a complete binding.
    enum class MatchKind { None, Prefix, Complete };

    struct Match {
        MatchKind kind = MatchKind::None;
        /// Set for Complete.
        const KeyBinding* binding = nullptr;
    };

    // ---- Loading
    void clear();
    /// Takes a keybindings array (a manifest's or the user's file); `fromUser` entries take precedence.
    void add(const nlohmann::json& entries, bool fromUser);

    // ---- Matching
    /// Last-added wins, user bindings first. A binding only completes if its `when` holds.
    Match match(const std::vector<KeyChord>& pressed, const std::map<std::string, std::string>& context) const;

    // ---- Getters
    size_t size() const { return bindings_.size(); }

private:
    // ---- Private variables
    std::vector<KeyBinding> bindings_;
    std::vector<KeyBinding> userBindings_;
};

}  // namespace gw
