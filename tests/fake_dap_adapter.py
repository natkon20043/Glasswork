#!/usr/bin/env python3
"""A tiny debug adapter for tests: answers initialize, sends a stopped event after
configurationDone, echoes evaluate, and makes a reverse request."""
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
    return json.loads(sys.stdin.buffer.read(length).decode()) if length else None


seq = 0


def send(message):
    global seq
    seq += 1
    message["seq"] = seq
    body = json.dumps(message).encode()
    sys.stdout.buffer.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
    sys.stdout.buffer.flush()


while True:
    message = read_message()
    if message is None:
        break
    if message.get("type") == "response":
        continue
    command = message.get("command")
    if command == "initialize":
        send({"type": "response", "request_seq": message["seq"], "success": True, "command": command,
              "body": {"supportsConfigurationDoneRequest": True}})
        send({"type": "event", "event": "initialized"})
    elif command == "configurationDone":
        send({"type": "response", "request_seq": message["seq"], "success": True, "command": command})
        send({"type": "event", "event": "stopped", "body": {"reason": "breakpoint", "threadId": 7}})
        send({"type": "request", "command": "runInTerminal", "arguments": {"args": ["x"]}})
    elif command == "evaluate":
        send({"type": "response", "request_seq": message["seq"], "success": True, "command": command,
              "body": {"result": "= " + message["arguments"]["expression"], "variablesReference": 0}})
    elif command == "bad":
        send({"type": "response", "request_seq": message["seq"], "success": False, "command": command,
              "message": "no good"})
    elif command == "disconnect":
        send({"type": "response", "request_seq": message["seq"], "success": True, "command": command})
        break
