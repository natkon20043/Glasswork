#include "Keybindings.hpp"
#include "JsonText.hpp"

#include <algorithm>
#include <cctype>
#include <regex>
#include <sstream>

namespace gw {

namespace {

std::string lowerCase(std::string text) {
    std::transform(text.begin(), text.end(), text.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return text;
}

/// Splits on spaces.
std::vector<std::string> words(const std::string& text) {
    std::vector<std::string> result;
    std::istringstream stream(text);
    std::string word;
    while (stream >> word) {
        result.push_back(word);
    }
    return result;
}

std::string normalizedKeyName(const std::string& name) {
    static const std::map<std::string, std::string> aliases = {
        {"return", "enter"}, {"esc", "escape"}, {"del", "delete"}, {"pgup", "pageup"}, {"pgdn", "pagedown"},
        {"pagedown", "pagedown"}, {"arrowup", "up"}, {"arrowdown", "down"}, {"arrowleft", "left"},
        {"arrowright", "right"}, {"ins", "insert"},
    };
    auto found = aliases.find(name);
    return found == aliases.end() ? name : found->second;
}

std::optional<KeyChord> parseOneChord(const std::string& text) {
    KeyChord chord;
    std::string current;
    std::vector<std::string> parts;
    // Split on '+', keeping a trailing '+' as the key itself ("cmd++").
    for (size_t index = 0; index < text.size(); ++index) {
        if (text[index] == '+' && index + 1 < text.size() && !current.empty()) {
            parts.push_back(current);
            current.clear();
        } else {
            current += text[index];
        }
    }
    parts.push_back(current);

    for (size_t index = 0; index + 1 < parts.size(); ++index) {
        std::string modifier = lowerCase(parts[index]);
        if (modifier == "cmd" || modifier == "meta" || modifier == "win" || modifier == "super" || modifier == "command") {
            chord.command = true;
        } else if (modifier == "ctrl" || modifier == "control") {
            chord.control = true;
        } else if (modifier == "alt" || modifier == "option") {
            chord.option = true;
        } else if (modifier == "shift") {
            chord.shift = true;
        } else {
            return std::nullopt;
        }
    }
    chord.key = normalizedKeyName(lowerCase(parts.back()));
    if (chord.key.empty()) {
        return std::nullopt;
    }
    return chord;
}

// ---------------------------------------------------------------------------
// When clauses

class WhenParser {
public:
    WhenParser(const std::string& text, const std::map<std::string, std::string>& context) : text_(text), context_(context) {}

    bool evaluate() {
        skipSpace();
        if (position_ >= text_.size()) {
            return true;
        }
        bool value = parseOr();
        return value;
    }

private:
    void skipSpace() {
        while (position_ < text_.size() && std::isspace(static_cast<unsigned char>(text_[position_]))) {
            ++position_;
        }
    }

    bool consume(const std::string& token) {
        skipSpace();
        if (position_ >= text_.size()) {
            return false;
        }
        if (text_.compare(position_, token.size(), token) == 0) {
            position_ += token.size();
            return true;
        }
        return false;
    }

    bool parseOr() {
        bool value = parseAnd();
        while (consume("||")) {
            bool right = parseAnd();
            value = value || right;
        }
        return value;
    }

    bool parseAnd() {
        bool value = parseUnary();
        while (consume("&&")) {
            bool right = parseUnary();
            value = value && right;
        }
        return value;
    }

    bool parseUnary() {
        if (++depth_ > 64) {
            return false;  // absurdly nested: give up rather than recurse without end
        }
        struct Leave {
            int& depth;
            ~Leave() { --depth; }
        } leave{depth_};
        skipSpace();
        if (position_ < text_.size() && text_[position_] == '!' && (position_ + 1 >= text_.size() || text_[position_ + 1] != '=')) {
            ++position_;
            return !parseUnary();
        }
        if (consume("(")) {
            bool value = parseOr();
            consume(")");
            return value;
        }
        return parseComparison();
    }

    std::string readName() {
        skipSpace();
        size_t start = position_;
        while (position_ < text_.size() && (std::isalnum(static_cast<unsigned char>(text_[position_])) || text_[position_] == '.' ||
                                            text_[position_] == '_' || text_[position_] == '-' || text_[position_] == ':')) {
            ++position_;
        }
        return text_.substr(start, position_ - start);
    }

    std::string readValue() {
        skipSpace();
        if (position_ < text_.size() && (text_[position_] == '\'' || text_[position_] == '"')) {
            char quote = text_[position_++];
            size_t start = position_;
            while (position_ < text_.size() && text_[position_] != quote) {
                ++position_;
            }
            std::string value = text_.substr(start, position_ - start);
            if (position_ < text_.size()) {
                ++position_;
            }
            return value;
        }
        return readName();
    }

    std::string lookup(const std::string& name) const {
        auto found = context_.find(name);
        return found == context_.end() ? std::string() : found->second;
    }

    bool parseComparison() {
        std::string name = readName();
        if (name.empty()) {
            if (position_ < text_.size()) {
                ++position_;  // skip something unreadable so parsing always ends
            }
            return false;
        }
        std::string actual = lookup(name);
        if (consume("==")) {
            return actual == readValue();
        }
        if (consume("!=")) {
            return actual != readValue();
        }
        if (consume("=~")) {
            skipSpace();
            if (position_ < text_.size() && text_[position_] == '/') {
                size_t end = text_.find('/', position_ + 1);
                if (end != std::string::npos) {
                    std::string pattern = text_.substr(position_ + 1, end - position_ - 1);
                    position_ = end + 1;
                    while (position_ < text_.size() && std::isalpha(static_cast<unsigned char>(text_[position_]))) {
                        ++position_; // flags
                    }
                    try {
                        return std::regex_search(actual, std::regex(pattern, std::regex::ECMAScript | std::regex::icase));
                    } catch (const std::regex_error&) {
                        return false;
                    }
                }
            }
            return false;
        }
        return !actual.empty() && actual != "false" && actual != "0";
    }

    const std::string& text_;
    const std::map<std::string, std::string>& context_;
    size_t position_ = 0;
    int depth_ = 0;
};

}  // namespace

std::optional<std::vector<KeyChord>> parseKeyChords(const std::string& text) {
    std::vector<KeyChord> chords;
    for (const std::string& word : words(text)) {
        std::optional<KeyChord> chord = parseOneChord(word);
        if (!chord) {
            return std::nullopt;
        }
        chords.push_back(*chord);
    }
    if (chords.empty()) {
        return std::nullopt;
    }
    return chords;
}

bool evaluateWhenClause(const std::string& clause, const std::map<std::string, std::string>& context) {
    WhenParser parser(clause, context);
    return parser.evaluate();
}

void KeybindingTable::clear() {
    bindings_.clear();
    userBindings_.clear();
}

void KeybindingTable::add(const nlohmann::json& entries, bool fromUser) {
    if (!entries.is_array()) {
        return;
    }
    for (const nlohmann::json& entry : entries) {
        if (!entry.is_object() || !entry.contains("command") || !entry["command"].is_string()) {
            continue;
        }
        // Extensions may give a macOS-specific key besides the generic one.
        std::string keyText;
        if (entry.contains("mac") && entry["mac"].is_string()) {
            keyText = entry["mac"].get<std::string>();
        } else if (entry.contains("key") && entry["key"].is_string()) {
            keyText = entry["key"].get<std::string>();
        }
        std::optional<std::vector<KeyChord>> chords = parseKeyChords(keyText);
        if (!chords) {
            continue;
        }
        KeyBinding binding;
        binding.chords = *chords;
        binding.command = entry["command"].get<std::string>();
        if (!binding.command.empty() && binding.command[0] == '-') {
            binding.command = binding.command.substr(1);
            binding.removes = true;
        }
        binding.arguments = entry.contains("args") ? entry["args"] : nlohmann::json();
        binding.when = stringOr(entry, "when");
        (fromUser ? userBindings_ : bindings_).push_back(std::move(binding));
    }
}

KeybindingTable::Match KeybindingTable::match(const std::vector<KeyChord>& pressed, const std::map<std::string, std::string>& context) const {
    Match result;
    if (pressed.empty()) {
        return result;
    }
    // Later entries beat earlier ones; the user's beat everything else.
    std::vector<const KeyBinding*> ordered;
    for (auto entry = userBindings_.rbegin(); entry != userBindings_.rend(); ++entry) {
        ordered.push_back(&*entry);
    }
    for (auto entry = bindings_.rbegin(); entry != bindings_.rend(); ++entry) {
        ordered.push_back(&*entry);
    }

    // A user entry "-command" with these keys switches the other bindings for that command off.
    auto removed = [&](const KeyBinding& candidate) {
        for (const KeyBinding& user : userBindings_) {
            if (user.removes && user.command == candidate.command && user.chords == candidate.chords) {
                return true;
            }
        }
        return false;
    };

    for (const KeyBinding* binding : ordered) {
        if (binding->removes || removed(*binding)) {
            continue;
        }
        if (binding->chords.size() < pressed.size()) {
            continue;
        }
        bool samePrefix = std::equal(pressed.begin(), pressed.end(), binding->chords.begin());
        if (!samePrefix) {
            continue;
        }
        if (!evaluateWhenClause(binding->when, context)) {
            continue;
        }
        if (binding->chords.size() == pressed.size()) {
            result.kind = MatchKind::Complete;
            result.binding = binding;
            return result;
        }
        result.kind = MatchKind::Prefix;  // keep looking: a complete match for these chords wins
    }
    return result;
}

}  // namespace gw
