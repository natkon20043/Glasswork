#pragma once

#include <cstdint>
#include <optional>
#include <string>

namespace gw {

// ---- Parsing

/// Accepts #rgb, #rgba, #rrggbb, #rrggbbaa, rgb(), rgba(), hsl(), hsla(), common names and
/// `transparent`. Returns packed 0xRRGGBBAA (gw::Color's form), or nothing if not a color.
std::optional<uint32_t> parseCssColor(const std::string& text);

}  // namespace gw
