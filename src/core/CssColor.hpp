#pragma once

#include <cstdint>
#include <optional>
#include <string>

namespace gw {

/// Reads a colour as extensions write it in decoration options: `#rgb`, `#rgba`, `#rrggbb`,
/// `#rrggbbaa`, `rgb(r, g, b)`, `rgba(r, g, b, a)`, `hsl(h, s%, l%)`, `hsla(…)`, and the common colour
/// names plus `transparent`. The result is packed 0xRRGGBBAA, the form gw::Color uses. Nothing
/// when the text is not a colour.
std::optional<uint32_t> parseCssColor(const std::string& text);

}  // namespace gw
