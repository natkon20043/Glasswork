#pragma once

#include <nlohmann/json.hpp>
#include <string>

namespace gw {

// ---- Reading

/// Safe string lookup: `fallback` when the key is missing or not a string (nlohmann's `value()` throws on a wrong type).
inline std::string stringOr(const nlohmann::json& object, const char* key, const std::string& fallback = std::string()) {
    if (!object.is_object()) {
        return fallback;
    }
    auto found = object.find(key);
    if (found == object.end() || !found->is_string()) {
        return fallback;
    }
    return found->get<std::string>();
}

}  // namespace gw
