#include "SettingsLookup.hpp"

namespace gw {

nlohmann::json settingsSection(const nlohmann::json& settings, const std::string& section) {
    using json = nlohmann::json;
    if (!settings.is_object()) {
        return json();
    }
    if (section.empty()) {
        return settings;
    }
    if (settings.contains(section)) {
        return settings[section];
    }

    // Walk down nested objects. A step may itself contain dots: "a.b" then "c" is as good as
    // "a" then "b" then "c", so try the longest head that exists at each level.
    const json* current = &settings;
    std::string remaining = section;
    while (!remaining.empty()) {
        bool descended = false;
        for (size_t end = remaining.size();; end = remaining.rfind('.', end - 1)) {
            std::string head = remaining.substr(0, end);
            if (current->is_object() && current->contains(head)) {
                current = &(*current)[head];
                remaining = end >= remaining.size() ? std::string() : remaining.substr(end + 1);
                descended = true;
                break;
            }
            if (end == 0 || end == std::string::npos || remaining.rfind('.', end - 1) == std::string::npos) {
                break;
            }
        }
        if (!descended) {
            break;
        }
    }

    json found;
    if (remaining.empty() && current != &settings) {
        found = *current;
    }
    // Flat keys beneath the section ("a.b.c": 1 when "a.b" was asked) join the result.
    std::string prefix = section + ".";
    for (const auto& [key, value] : settings.items()) {
        if (key.rfind(prefix, 0) == 0) {
            if (!found.is_object()) {
                found = json::object();
            }
            found[key.substr(prefix.size())] = value;
        }
    }
    return found;
}

}  // namespace gw
