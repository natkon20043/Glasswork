#include "LanguageServer.hpp"

#include <algorithm>
#include <cctype>
#include <charconv>
#include <stdexcept>

namespace gw::lsp {

namespace {

constexpr size_t maximumMessage = 32 * 1024 * 1024;

size_t characterBytes(unsigned char first) {
    if (first < 0x80) {
        return 1;
    }
    if (first < 0xE0) {
        return 2;
    }
    if (first < 0xF0) {
        return 3;
    }
    return 4;
}

}  // namespace

Json position(const TextBuffer &buffer, Position caret) {
    caret = buffer.clamp(caret);
    const auto &line = buffer.line(caret.line);
    size_t units = 0;
    for (size_t byte = 0; byte < caret.column;) {
        size_t width = characterBytes(static_cast<unsigned char>(line[byte]));
        if (byte + width > caret.column) {
            break;
        }
        // A character outside the Basic Multilingual Plane is a surrogate pair in UTF-16.
        if (width == 4) {
            units += 2;
        } else {
            units += 1;
        }
        byte += width;
    }
    return {{"line", caret.line}, {"character", units}};
}

Position position(const TextBuffer &buffer, const Json &value) {
    size_t lineIndex = std::min(value.at("line").get<size_t>(), buffer.lineCount() - 1);
    size_t target = value.at("character").get<size_t>();
    const auto &line = buffer.line(lineIndex);
    size_t byte = 0;
    size_t units = 0;
    while (byte < line.size() && units < target) {
        size_t width = characterBytes(static_cast<unsigned char>(line[byte]));
        size_t count = 1;
        if (width == 4) {
            count = 2;
        }
        if (units + count > target) {
            break;
        }
        byte = std::min(byte + width, line.size());
        units += count;
    }
    return {lineIndex, byte};
}

std::string fileURI(const std::string &path) {
    constexpr char digits[] = "0123456789ABCDEF";
    std::string result = "file://";
    for (unsigned char value : path) {
        bool letterOrDigit = std::isalnum(value) != 0;
        bool plain = letterOrDigit || value == '/' || value == '-' || value == '_' || value == '.' || value == '~';
        if (plain) {
            result += static_cast<char>(value);
        } else {
            result += '%';
            result += digits[value >> 4];
            result += digits[value & 15];
        }
    }
    return result;
}

std::string frameMessage(const Json &message) {
    std::string body = message.dump();
    return "Content-Length: " + std::to_string(body.size()) + "\r\n\r\n" + body;
}

std::string pathFromURI(const std::string &uri) {
    constexpr std::string_view prefix = "file://";
    if (uri.compare(0, prefix.size(), prefix) != 0) {
        return std::string();
    }
    std::string path;
    for (size_t index = prefix.size(); index < uri.size(); ++index) {
        bool escaped = uri[index] == '%' && index + 2 < uri.size() &&
                       std::isxdigit(static_cast<unsigned char>(uri[index + 1])) &&
                       std::isxdigit(static_cast<unsigned char>(uri[index + 2]));
        if (escaped) {
            path += static_cast<char>(std::stoi(uri.substr(index + 1, 2), nullptr, 16));
            index += 2;
        } else {
            path += uri[index];
        }
    }
    return path;
}

void Decoder::append(std::string_view bytes) {
    if (bytes_.size() + bytes.size() > maximumMessage + 65536) {
        throw std::runtime_error("A message exceeded the size limit.");
    }
    bytes_.append(bytes);
}

std::optional<Json> Decoder::next() {
    size_t separator = bytes_.find("\r\n\r\n");
    if (separator == std::string::npos) {
        if (bytes_.size() > 8192) {
            throw std::runtime_error("Invalid message header.");
        }
        return std::nullopt;
    }
    size_t length = 0;
    bool found = false;
    size_t start = 0;
    while (start < separator) {
        size_t end = bytes_.find("\r\n", start);
        std::string_view header(bytes_.data() + start, end - start);
        constexpr std::string_view prefix = "Content-Length: ";
        if (header.starts_with(prefix)) {
            auto number = header.substr(prefix.size());
            auto parsed = std::from_chars(number.data(), number.data() + number.size(), length);
            bool notWholeNumber = parsed.ec != std::errc{} || parsed.ptr != number.data() + number.size();
            if (found || notWholeNumber || length > maximumMessage) {
                throw std::runtime_error("Invalid message length.");
            }
            found = true;
        }
        start = end + 2;
    }
    if (!found) {
        throw std::runtime_error("Missing message length.");
    }
    size_t body = separator + 4;
    if (bytes_.size() - body < length) {
        return std::nullopt;
    }
    Json result = Json::parse(bytes_.substr(body, length));
    bytes_.erase(0, body + length);
    return result;
}

}  // namespace gw::lsp
