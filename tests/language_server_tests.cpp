#include "LanguageServer.hpp"
#include "Document.hpp"
#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <unistd.h>

using gw::lsp::Json;

void require(bool condition, const char *message) {
    if (!condition) throw std::runtime_error(message);
}

int main(int argc, char **argv) {
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
        if (argc == 1 || std::string(argv[1]) != "--clangd") return 0;

        std::string directory = "/private/tmp/glasswork-lsp-" + std::to_string(getpid());
        std::filesystem::create_directories(directory);
        struct Cleanup {
            std::string path;
            ~Cleanup() { std::filesystem::remove_all(path); }
        } cleanup{directory};
        gw::lsp::Client client(gw::lsp::fileURI(directory));
        gw::lsp::Snapshot file{
            gw::lsp::fileURI(directory + "/main.cpp"), "cpp",
            "int square(int value) { return value * value; }\nint main() { return square(4); }\n", 1
        };
        client.synchronize({file});
        auto errors = client.diagnostics(file);
        require(errors.empty(), "Valid C++ should have no diagnostics");
        Json params = {{"textDocument", {{"uri", file.uri}}}, {"position", {{"line", 1}, {"character", 22}}}};
        auto definition = client.request("textDocument/definition", params);
        require(definition.is_array() && !definition.empty(), "Definition not found");
        require(definition[0]["range"]["start"]["line"] == 0, "Definition jumped to wrong line");
        params["context"] = {{"includeDeclaration", true}};
        auto references = client.request("textDocument/references", params);
        require(references.size() >= 2, "References missed declaration or usage");

        file.version = 2;
        file.text = "int square(int value) { return value * value; }\nint main() { return squ; }\n";
        client.synchronize({file});
        params.erase("context");
        params["position"] = {{"line", 1}, {"character", 23}};
        auto completion = client.request("textDocument/completion", params);
        bool found = false;
        for (const auto &item : completion.at("items")) {
            if (item.value("label", "").find("square") != std::string::npos) {
                found = true;
                gw::Document editorDocument;
                editorDocument.typeText(file.text);
                const auto &edit = item.at("textEdit");
                const auto &range = edit.at("range");
                gw::Range replacement{
                    gw::lsp::position(editorDocument.buffer(), range.at("start")),
                    gw::lsp::position(editorDocument.buffer(), range.at("end"))
                };
                editorDocument.replace(replacement, edit.at("newText").get<std::string>());
                require(editorDocument.buffer().line(1).find("square") != std::string::npos,
                        "Completion did not update the document");
                require(editorDocument.undo() && editorDocument.buffer().text() == file.text,
                        "Completion must undo as one edit");
                require(editorDocument.redo(), "Completion must be redoable");
            }
        }
        require(found, "Completion did not contain square");
        errors = client.diagnostics(file);
        require(!errors.empty(), "Unsaved invalid code should produce diagnostics");

        file.version = 3;
        file.text = "int main() { return 0; }\n";
        client.synchronize({file});
        require(client.diagnostics(file).empty(), "Diagnostics did not clear after unsaved fix");
        client.synchronize({});
        file.version = 4;
        client.synchronize({file});
        require(client.diagnostics(file).empty(), "Close/reopen synchronization failed");
        std::cout << "Real clangd: diagnostics, definition, references, completion, unsaved changes and reopen passed\n";
        return 0;
    } catch (const std::exception &error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
