#pragma once

#include <nlohmann/json.hpp>

#include <string>

namespace gw {

/// A setting from a settings object by dotted name. VS Code settings may be written flat
/// (`"a.b.c": 1`), nested (`{"a": {"b": {"c": 1}}}`) or both, and a section ("a.b") stands for
/// everything beneath it, which comes back as one object. Null when nothing is set there.
nlohmann::json settingsSection(const nlohmann::json& settings, const std::string& section);

}  // namespace gw
