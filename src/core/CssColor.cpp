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
    while (start < end && std::isspace(static_cast<unsigned char>(text[start]))) {
        ++start;
    }
    while (end > start && std::isspace(static_cast<unsigned char>(text[end - 1]))) {
        --end;
    }
    std::string result = text.substr(start, end - start);
    for (char& character : result) {
        character = static_cast<char>(std::tolower(static_cast<unsigned char>(character)));
    }
    return result;
}

uint32_t clampedChannel(int value) {
    return static_cast<uint32_t>(std::clamp(value, 0, 255));
}

uint32_t pack(int red, int green, int blue, int alpha) {
    return (clampedChannel(red) << 24) | (clampedChannel(green) << 16) | (clampedChannel(blue) << 8) |
           clampedChannel(alpha);
}

int hexValue(char c) {
    if (c >= '0' && c <= '9') {
        return c - '0';
    }
    if (c >= 'a' && c <= 'f') {
        return c - 'a' + 10;
    }
    return -1;
}

/// The numbers inside "name(a, b, c)", each possibly with a % sign (recorded as a flag).
bool functionArguments(const std::string& text,
                       const std::string& name,
                       std::vector<double>& values,
                       std::vector<bool>& percents) {
    if (text.rfind(name + "(", 0) != 0 || text.back() != ')') {
        return false;
    }
    std::string inside = text.substr(name.size() + 1, text.size() - name.size() - 2);
    for (char& c : inside) {
        if (c == ',' || c == '/') {
            c = ' ';
        }
    }
    size_t index = 0;
    while (index < inside.size()) {
        while (index < inside.size() && std::isspace(static_cast<unsigned char>(inside[index]))) {
            ++index;
        }
        if (index >= inside.size()) {
            break;
        }
        const char* numberStart = inside.c_str() + index;
        char* numberEnd = nullptr;
        double value = std::strtod(numberStart, &numberEnd);
        if (numberEnd == numberStart) {
            return false;
        }
        index = static_cast<size_t>(numberEnd - inside.c_str());
        bool percent = index < inside.size() && inside[index] == '%';
        if (percent) {
            ++index;
        }
        // "deg" and other units after a number are ignored.
        while (index < inside.size() && std::isalpha(static_cast<unsigned char>(inside[index]))) {
            ++index;
        }
        values.push_back(value);
        percents.push_back(percent);
    }
    return true;
}

/// One red, green or blue channel (0 to 1) of an HSL color. `low` and `high` are the darkest and
/// brightest the channels get for this lightness and saturation; `position` is where the hue sits on
/// the color wheel for this channel (0 to 1, wrapping round).
double hueToChannel(double low, double high, double position) {
    if (position < 0) {
        position += 1;
    }
    if (position > 1) {
        position -= 1;
    }
    if (position < 1.0 / 6) {
        return low + (high - low) * 6 * position;
    }
    if (position < 1.0 / 2) {
        return high;
    }
    if (position < 2.0 / 3) {
        return low + (high - low) * (2.0 / 3 - position) * 6;
    }
    return low;
}

/// An alpha given as 0 to 1 (or as a percentage) on the 0 to 255 scale.
int alphaChannel(double value, bool percent) {
    double fraction = value;
    if (percent) {
        fraction = value / 100.0;
    }
    return static_cast<int>(std::lround(fraction * 255));
}

}  // namespace

std::optional<uint32_t> parseCssColor(const std::string& original) {
    std::string text = trimmedLower(original);
    if (text.empty()) {
        return std::nullopt;
    }

    if (text[0] == '#') {
        std::vector<int> digits;
        for (size_t index = 1; index < text.size(); ++index) {
            int value = hexValue(text[index]);
            if (value < 0) {
                return std::nullopt;
            }
            digits.push_back(value);
        }
        // A short digit stands for itself twice: #f80 is #ff8800 (0xf * 17 = 0xff).
        if (digits.size() == 3 || digits.size() == 4) {
            int alpha = 255;
            if (digits.size() == 4) {
                alpha = digits[3] * 17;
            }
            return pack(digits[0] * 17, digits[1] * 17, digits[2] * 17, alpha);
        }
        if (digits.size() == 6 || digits.size() == 8) {
            int alpha = 255;
            if (digits.size() == 8) {
                alpha = digits[6] * 16 + digits[7];
            }
            int red = digits[0] * 16 + digits[1];
            int green = digits[2] * 16 + digits[3];
            int blue = digits[4] * 16 + digits[5];
            return pack(red, green, blue, alpha);
        }
        return std::nullopt;
    }

    std::vector<double> values;
    std::vector<bool> percents;
    if (functionArguments(text, "rgb", values, percents) || functionArguments(text, "rgba", values, percents)) {
        if (values.size() < 3) {
            return std::nullopt;
        }
        // A channel is 0 to 255, or a percentage of that.
        int channels[3];
        for (size_t index = 0; index < 3; ++index) {
            double value = values[index];
            if (percents[index]) {
                value = value * 2.55;
            }
            channels[index] = static_cast<int>(std::lround(value));
        }
        int alpha = 255;
        if (values.size() >= 4) {
            alpha = alphaChannel(values[3], percents[3]);
        }
        return pack(channels[0], channels[1], channels[2], alpha);
    }
    values.clear();
    percents.clear();
    if (functionArguments(text, "hsl", values, percents) || functionArguments(text, "hsla", values, percents)) {
        if (values.size() < 3) {
            return std::nullopt;
        }
        double hue = std::fmod(values[0], 360.0);
        if (hue < 0) {
            hue += 360;
        }
        hue /= 360;
        double saturation = std::clamp(values[1] / 100.0, 0.0, 1.0);
        double lightness = std::clamp(values[2] / 100.0, 0.0, 1.0);
        double high = 0;
        if (lightness < 0.5) {
            high = lightness * (1 + saturation);
        } else {
            high = lightness + saturation - lightness * saturation;
        }
        double low = 2 * lightness - high;
        int alpha = 255;
        if (values.size() >= 4) {
            alpha = alphaChannel(values[3], percents[3]);
        }
        int red = static_cast<int>(std::lround(hueToChannel(low, high, hue + 1.0 / 3) * 255));
        int green = static_cast<int>(std::lround(hueToChannel(low, high, hue) * 255));
        int blue = static_cast<int>(std::lround(hueToChannel(low, high, hue - 1.0 / 3) * 255));
        return pack(red, green, blue, alpha);
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
    if (found != names.end()) {
        return found->second;
    }
    return std::nullopt;
}

}  // namespace gw
