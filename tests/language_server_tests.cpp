#include "LanguageServer.hpp"
#include <iostream>
#include <stdexcept>

using gw::lsp::Json;

void require(bool condition, const char *message) {
    if (!condition) {
        throw std::runtime_error(message);
    }
}

int main() {
    try {
        gw::TextBuffer unicode("aé猫😀z\nsecond");
        for (size_t byte : {size_t(0), size_t(1), size_t(3), size_t(6), size_t(10), size_t(11)}) {
            auto wire = gw::lsp::position(unicode, gw::Position{0, byte});
            require(gw::lsp::position(unicode, wire) == gw::Position{0, byte}, "UTF-16 round trip failed");
        }
        require(gw::lsp::position(unicode, gw::Position{0, 10})["character"] == 5, "Astral character needs two UTF-16 units");
        require(gw::lsp::position(unicode, Json{{"line", 0}, {"character", 4}}).column == 6, "Surrogate split must clamp");
        require(gw::lsp::fileURI("/tmp/a #%.cpp") == "file:///tmp/a%20%23%25.cpp", "URI escaping failed");
        Json expected = {{"jsonrpc", "2.0"}, {"result", "é😀"}};
        std::string body = expected.dump();
        std::string frame = "Content-Length: " + std::to_string(body.size()) + "\r\n\r\n" + body;
        for (size_t split = 0; split < frame.size(); ++split) {
            gw::lsp::Decoder decoder;
            decoder.append(frame.substr(0, split));
            require(!decoder.next(), "Partial frame incorrectly completed");
            decoder.append(frame.substr(split) + frame);
            require(decoder.next() == expected, "Split frame was corrupted");
            require(decoder.next() == expected, "Coalesced frame was lost");
            require(!decoder.next(), "Consumed message was repeated");
        }
        for (const auto *bad : {"Content-Length: -1\r\n\r\n", "Content-Length: 99999999999\r\n\r\n", "Other: 4\r\n\r\n"}) {
            bool rejected = false;
            try {
                gw::lsp::Decoder decoder;
                decoder.append(bad);
                decoder.next();
            } catch (const std::exception &) {
                rejected = true;
            }
            require(rejected, "Malformed frame must be rejected");
        }
        std::cout << "Protocol framing, URI escaping and Unicode positions passed\n";
        return 0;
    } catch (const std::exception &error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
