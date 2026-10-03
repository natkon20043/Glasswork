#pragma once

#include <nlohmann/json.hpp>

#include <map>
#include <optional>
#include <string>
#include <vector>

namespace gw {

/// One key press with its modifiers, as written in VS Code keybindings ("cmd+shift+p").
struct KeyChord {
    bool command = false;
    bool control = false;
    bool option = false;
    bool shift = false;
    /// The key, lower case: "a", "5", "f12", "enter", "escape", "tab", "space", "backspace",
    /// "delete", "up", "down", "left", "right", "home", "end", "pageup", "pagedown", or a symbol
    /// such as "/" or "[".
    std::string key;

    bool operator==(const KeyChord& other) const {
        return command == other.command && control == other.control && option == other.option && shift == other.shift && key == other.key;
    }
};

/// Reads "cmd+k cmd+s" (a chord sequence), "ctrl+shift+p" and the like. `cmd`, `meta`, `win` and
/// `super` mean Command; `ctrl`, `alt` and `option` mean what they say. Empty for text that is not
/// a key combination.
std::optional<std::vector<KeyChord>> parseKeyChords(const std::string& text);

/// Whether a `when` clause holds for the given context. Supports `a && b`, `a || b`, `!a`,
/// `(…)`, `a == 'x'`, `a != 'x'` and `a =~ /regex/`; a bare name is true when its value is set and
/// not "false" or "0". An empty clause is true.
bool evaluateWhenClause(const std::string& clause, const std::map<std::string, std::string>& context);

struct KeyBinding {
    std::vector<KeyChord> chords;
    std::string command;
    nlohmann::json arguments;  // the `args` given to the command, or null
    std::string when;
    bool removes = false;      // a "-command" entry: takes the command's default binding away
};

/// The bindings in force: those extensions declare (`contributes.keybindings`, macOS keys) and the
/// user's `keybindings.json`, which wins when both use the same keys.
class KeybindingTable {
public:
    void clear();
    /// Adds the entries of a keybindings array (a manifest's or the user's file). `fromUser`
    /// entries take precedence over the others.
    void add(const nlohmann::json& entries, bool fromUser);

    enum class MatchKind { None, Prefix, Complete };
    struct Match {
        MatchKind kind = MatchKind::None;
        const KeyBinding* binding = nullptr;  // for Complete
    };
    /// What the chords pressed so far lead to: nothing, the start of a longer sequence, or a
    /// binding whose `when` holds. The last-added binding wins, user bindings first.
    Match match(const std::vector<KeyChord>& pressed, const std::map<std::string, std::string>& context) const;

    size_t size() const { return bindings_.size(); }

private:
    std::vector<KeyBinding> bindings_;
    std::vector<KeyBinding> userBindings_;
};

}  // namespace gw
