#!/usr/bin/env python3
"""A tiny language server for tests: answers initialize, hover and echo, publishes a
diagnostic for every opened document, and asks the client for its configuration."""
import json
import os
import sys


def read_message():
    length = None
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return None
        line = line.decode().strip()
        if line == "":
            break
        if line.lower().startswith("content-length:"):
            length = int(line.split(":")[1])
    if length is None:
        return None
    return json.loads(sys.stdin.buffer.read(length).decode())


def send(message):
    body = json.dumps(message).encode()
    sys.stdout.buffer.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
    sys.stdout.buffer.flush()


configuration_reply = None
last_change = None
apply_edit_reply = None
chatter_choice = None
watched_changes = []
chatter_config = None
while True:
    message = read_message()
    if message is None:
        break
    method = message.get("method")
    if method == "initialize" and os.environ.get("FAKE_LSP_REFUSE"):
        # A server that cannot start (e.g. no TypeScript installation) answers with an error.
        send({"jsonrpc": "2.0", "id": message["id"],
              "error": {"code": -32603, "message": "Could not find a valid TypeScript installation"}})
    elif method == "initialize":
        send({"jsonrpc": "2.0", "id": message["id"],
              "result": {"capabilities": {"hoverProvider": True, "renameProvider": True,
                                          "textDocumentSync": {"openClose": True, "change": 2}}}})
    elif method == "textDocument/didOpen":
        uri = message["params"]["textDocument"]["uri"]
        version = message["params"]["textDocument"]["version"]
        send({"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics",
              "params": {"uri": uri, "version": version, "diagnostics": [
                  {"range": {"start": {"line": 0, "character": 1}, "end": {"line": 0, "character": 3}},
                   "severity": 2, "message": "fake warning", "source": "fake", "code": 7}]}})
        # Ask for configuration: the client must answer, not ignore us.
        send({"jsonrpc": "2.0", "id": 900, "method": "workspace/configuration",
              "params": {"items": [{"section": "a"}, {"section": "b"}]}})
    elif method == "textDocument/hover":
        send({"jsonrpc": "2.0", "id": message["id"],
              "result": {"contents": {"kind": "markdown", "value": "hover for line %d" % message["params"]["position"]["line"]}}})
    elif method == "textDocument/didChange":
        last_change = message["params"]
    elif method == "test/lastChange":
        send({"jsonrpc": "2.0", "id": message["id"], "result": last_change})
    elif method == "workspace/executeCommand":
        # A command that changes files: ask the client to apply an edit, then finish the command.
        send({"jsonrpc": "2.0", "id": 901, "method": "workspace/applyEdit",
              "params": {"label": "fake", "edit": {"changes": {"file:///tmp/z.fake": [
                  {"range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 0}}, "newText": "hi"}]}}}})
        send({"jsonrpc": "2.0", "id": message["id"], "result": {"ran": message["params"]["command"]}})
    elif method is None and message.get("id") == 901:
        apply_edit_reply = message.get("result")
    elif method == "test/applyEditReply":
        send({"jsonrpc": "2.0", "id": message["id"], "result": apply_edit_reply})
    elif method == "test/registerDynamic":
        # Capabilities arriving after the handshake, as the extension host sends them.
        send({"jsonrpc": "2.0", "id": "dyn-1", "method": "client/registerCapability", "params": {"registrations": [
            {"id": "a", "method": "textDocument/completion", "registerOptions": {"triggerCharacters": ["."], "resolveProvider": False}},
            {"id": "b", "method": "textDocument/completion", "registerOptions": {"triggerCharacters": [".", ":"], "resolveProvider": True}},
            {"id": "c", "method": "textDocument/formatting"}]}})
        send({"jsonrpc": "2.0", "id": message["id"], "result": True})
    elif method == "test/unregisterDynamic":
        send({"jsonrpc": "2.0", "id": "dyn-2", "method": "client/unregisterCapability", "params": {"unregisterations": [
            {"id": "c", "method": "textDocument/formatting"}, {"id": "a", "method": "textDocument/completion"}]}})
        send({"jsonrpc": "2.0", "id": message["id"], "result": True})
    elif method == "test/chatter":
        # Things a server says on its own: messages, a log line, progress, a question with buttons.
        send({"jsonrpc": "2.0", "method": "window/showMessage", "params": {"type": 2, "message": "careful now"}})
        send({"jsonrpc": "2.0", "method": "window/logMessage", "params": {"type": 4, "message": "a log line"}})
        send({"jsonrpc": "2.0", "method": "$/progress", "params": {"token": "idx", "value": {"kind": "begin", "title": "Indexing", "percentage": 0}}})
        send({"jsonrpc": "2.0", "method": "$/progress", "params": {"token": "idx", "value": {"kind": "report", "message": "3/10", "percentage": 30}}})
        send({"jsonrpc": "2.0", "method": "$/progress", "params": {"token": "idx", "value": {"kind": "end"}}})
        send({"jsonrpc": "2.0", "id": 902, "method": "window/showMessageRequest", "params": {"type": 3, "message": "Pick one", "actions": [{"title": "Yes"}, {"title": "No"}]}})
        send({"jsonrpc": "2.0", "id": 903, "method": "workspace/configuration", "params": {"items": [{"section": "fake.size"}, {"section": "fake.missing"}]}})
        send({"jsonrpc": "2.0", "id": message["id"], "result": True})
    elif method is None and message.get("id") == 902:
        chatter_choice = message.get("result")
    elif method is None and message.get("id") == 903:
        chatter_config = message.get("result")
    elif method == "test/chatterReplies":
        send({"jsonrpc": "2.0", "id": message["id"], "result": {"choice": chatter_choice, "config": chatter_config}})
    elif method == "test/watchFiles":
        send({"jsonrpc": "2.0", "id": "dyn-3", "method": "client/registerCapability", "params": {"registrations": [
            {"id": "w", "method": "workspace/didChangeWatchedFiles", "registerOptions": {"watchers": [
                {"globPattern": "**/*.fake"}, {"globPattern": "**/Cargo.toml", "kind": 2}]}}]}})
        send({"jsonrpc": "2.0", "id": message["id"], "result": True})
    elif method == "workspace/didChangeWatchedFiles":
        watched_changes.extend(message["params"]["changes"])
    elif method == "test/watchedChanges":
        send({"jsonrpc": "2.0", "id": message["id"], "result": watched_changes})
    elif method == "test/echo":
        send({"jsonrpc": "2.0", "id": message["id"], "result": message["params"]})
    elif method == "test/fail":
        send({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -1, "message": "nope"}})
    elif method == "test/configuration":
        send({"jsonrpc": "2.0", "id": message["id"], "result": configuration_reply})
    elif method is None and message.get("id") == 900:
        configuration_reply = message.get("result")
    elif method == "shutdown":
        send({"jsonrpc": "2.0", "id": message["id"], "result": None})
    elif method == "exit":
        break
