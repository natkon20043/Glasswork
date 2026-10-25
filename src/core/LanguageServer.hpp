#pragma once

#include "TextBuffer.hpp"
#include <nlohmann/json.hpp>
#include <optional>
#include <string>
#include <vector>

namespace gw::lsp {
using Json = nlohmann::json;

// ---- Conversions (LSP counts UTF-16 code units; the editor counts UTF-8 bytes)

Json position(const TextBuffer &buffer, Position caret);
Position position(const TextBuffer &buffer, const Json &value);
std::string fileURI(const std::string &absolutePath);
/// Empty if not a file:// URI; percent escapes are decoded.
std::string pathFromURI(const std::string &uri);
/// Content-Length header followed by the JSON.
std::string frameMessage(const Json &message);

/// Reassembles messages from split or coalesced reads, independent of process and UI.
class Decoder {
public:
    // ---- Input
    void append(std::string_view bytes);
    std::optional<Json> next();

private:
    // ---- Private variables
    std::string bytes_;
};

}  // namespace gw::lsp
