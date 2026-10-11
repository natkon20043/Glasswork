#include "CssColor.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdlib>
#include <map>
#include <vector>

namespace gw {

namespace {

std::string trimmedLower(const std::string& text) {
    size_t start = 0;
    size_t end = text.size();
    while (start < end && std::isspace(static_cast<unsigned char>(text[start]))) ++start;
    while (end > start && std::isspace(static_cast<unsigned char>(text[end - 1]))) --end;
    std::string result = text.substr(start, end - start);
    std::transform(result.begin(), result.end(), result.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return result;
}

uint32_t pack(int red, int green, int blue, int alpha) {
    auto clamp = [](int value) { return static_cast<uint32_t>(std::max(0, std::min(255, value))); };
    return (clamp(red) << 24) | (clamp(green) << 16) | (clamp(blue) << 8) | clamp(alpha);
}

int hexValue(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}

/// The numbers inside "name(a, b, c)", each possibly with a % sign (recorded as a flag).
bool functionArguments(const std::string& text, const std::string& name, std::vector<double>& values, std::vector<bool>& percents) {
    if (text.rfind(name + "(", 0) != 0 || text.back() != ')') return false;
    std::string inside = text.substr(name.size() + 1, text.size() - name.size() - 2);
    for (char& c : inside) {
        if (c == ',' || c == '/') c = ' ';
    }
    size_t index = 0;
    while (index < inside.size()) {
        while (index < inside.size() && std::isspace(static_cast<unsigned char>(inside[index]))) ++index;
        if (index >= inside.size()) break;
        char* end = nullptr;
        double value = std::strtod(inside.c_str() + index, &end);
        if (end == inside.c_str() + index) return false;
        index = static_cast<size_t>(end - inside.c_str());
        bool percent = index < inside.size() && inside[index] == '%';
        if (percent) ++index;
        // "deg" and other units after a number are ignored.
        while (index < inside.size() && std::isalpha(static_cast<unsigned char>(inside[index]))) ++index;
        values.push_back(value);
        percents.push_back(percent);
    }
    return true;
}

/// One red, green or blue channel (0 to 1) of an HSL color. `low` and `high` are the darkest and
/// brightest the channels get for this lightness and saturation; `position` is where the hue sits on
/// the color wheel for this channel (0 to 1, wrapping round).
double hueToChannel(double low, double high, double position) {
    if (position < 0) position += 1;
    if (position > 1) position -= 1;
    if (position < 1.0 / 6) return low + (high - low) * 6 * position;
    if (position < 1.0 / 2) return high;
    if (position < 2.0 / 3) return low + (high - low) * (2.0 / 3 - position) * 6;
    return low;
}

}  // namespace

std::optional<uint32_t> parseCssColor(const std::string& original) {
    std::string text = trimmedLower(original);
    if (text.empty()) return std::nullopt;

    if (text[0] == '#') {
        std::vector<int> digits;
        for (size_t index = 1; index < text.size(); ++index) {
            int value = hexValue(text[index]);
            if (value < 0) return std::nullopt;
            digits.push_back(value);
        }
        if (digits.size() == 3 || digits.size() == 4) {
            int alpha = digits.size() == 4 ? digits[3] * 17 : 255;
            return pack(digits[0] * 17, digits[1] * 17, digits[2] * 17, alpha);
        }
        if (digits.size() == 6 || digits.size() == 8) {
            int alpha = digits.size() == 8 ? digits[6] * 16 + digits[7] : 255;
            return pack(digits[0] * 16 + digits[1], digits[2] * 16 + digits[3], digits[4] * 16 + digits[5], alpha);
        }
        return std::nullopt;
    }

    std::vector<double> values;
    std::vector<bool> percents;
    if (functionArguments(text, "rgb", values, percents) || functionArguments(text, "rgba", values, percents)) {
        if (values.size() < 3) return std::nullopt;
        auto channel = [&](size_t index) { return static_cast<int>(std::lround(percents[index] ? values[index] * 2.55 : values[index])); };
        int alpha = 255;
        if (values.size() >= 4) {
            alpha = static_cast<int>(std::lround((percents[3] ? values[3] / 100.0 : values[3]) * 255));
        }
        return pack(channel(0), channel(1), channel(2), alpha);
    }
    values.clear();
    percents.clear();
    if (functionArguments(text, "hsl", values, percents) || functionArguments(text, "hsla", values, percents)) {
        if (values.size() < 3) return std::nullopt;
        double hue = std::fmod(values[0], 360.0);
        if (hue < 0) hue += 360;
        hue /= 360;
        double saturation = std::max(0.0, std::min(1.0, values[1] / 100.0));
        double lightness = std::max(0.0, std::min(1.0, values[2] / 100.0));
        double high = lightness < 0.5 ? lightness * (1 + saturation) : lightness + saturation - lightness * saturation;
        double low = 2 * lightness - high;
        int alpha = 255;
        if (values.size() >= 4) {
            double fraction = percents[3] ? values[3] / 100.0 : values[3];
            alpha = static_cast<int>(std::lround(fraction * 255));
        }
        auto channel = [&](double position) {
            return static_cast<int>(std::lround(hueToChannel(low, high, position) * 255));
        };
        return pack(channel(hue + 1.0 / 3), channel(hue), channel(hue - 1.0 / 3), alpha);
    }

    static const std::map<std::string, uint32_t> names = {
        {"transparent", 0x00000000}, {"black", 0x000000FF}, {"white", 0xFFFFFFFF}, {"red", 0xFF0000FF},
        {"green", 0x008000FF}, {"lime", 0x00FF00FF}, {"blue", 0x0000FFFF}, {"yellow", 0xFFFF00FF},
        {"orange", 0xFFA500FF}, {"purple", 0x800080FF}, {"pink", 0xFFC0CBFF}, {"gray", 0x808080FF},
        {"grey", 0x808080FF}, {"cyan", 0x00FFFFFF}, {"aqua", 0x00FFFFFF}, {"magenta", 0xFF00FFFF},
        {"fuchsia", 0xFF00FFFF}, {"brown", 0xA52A2AFF}, {"gold", 0xFFD700FF}, {"navy", 0x000080FF},
        {"teal", 0x008080FF}, {"maroon", 0x800000FF}, {"olive", 0x808000FF}, {"silver", 0xC0C0C0FF},
        {"crimson", 0xDC143CFF}, {"tomato", 0xFF6347FF}, {"salmon", 0xFA8072FF}, {"coral", 0xFF7F50FF},
        {"indigo", 0x4B0082FF}, {"violet", 0xEE82EEFF}, {"turquoise", 0x40E0D0FF}, {"lightgray", 0xD3D3D3FF},
        {"lightgrey", 0xD3D3D3FF}, {"darkgray", 0xA9A9A9FF}, {"darkgrey", 0xA9A9A9FF}, {"darkred", 0x8B0000FF},
        {"darkgreen", 0x006400FF}, {"darkblue", 0x00008BFF}, {"orangered", 0xFF4500FF}, {"limegreen", 0x32CD32FF},
    };
    auto found = names.find(text);
    if (found != names.end()) return found->second;
    return std::nullopt;
}

}  // namespace gw
