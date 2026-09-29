#!/usr/bin/env python3
"""A tiny language server for tests: answers initialize, hover and echo, publishes a
diagnostic for every opened document, and asks the client for its configuration."""
import json
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
while True:
    message = read_message()
    if message is None:
        break
    method = message.get("method")
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": message["id"],
              "result": {"capabilities": {"hoverProvider": True, "renameProvider": True}}})
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
