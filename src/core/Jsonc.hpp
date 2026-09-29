#pragma once

#include <nlohmann/json.hpp>

#include <string>

namespace gw {

/// Parses "JSON with comments" as VS Code writes it: `//` and `/* */` comments plus trailing
/// commas are allowed. Returns a discarded value (check `is_discarded()`) on error.
nlohmann::json parseJsonc(const std::string& text);

}  // namespace gw
