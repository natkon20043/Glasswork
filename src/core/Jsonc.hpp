#pragma once

#include <nlohmann/json.hpp>

#include <string>

namespace gw {

/// Allows `//` and `/* */` comments and trailing commas. On error returns a discarded value (`is_discarded()`).
nlohmann::json parseJsonc(const std::string& text);

}  // namespace gw
