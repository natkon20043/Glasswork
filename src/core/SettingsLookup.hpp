#pragma once

#include <nlohmann/json.hpp>

#include <string>

namespace gw {

/// Looks up a dotted name in settings written flat, nested, or both. A section ("a.b") returns
/// everything beneath it as one object. Null when unset.
nlohmann::json settingsSection(const nlohmann::json& settings, const std::string& section);

}  // namespace gw
