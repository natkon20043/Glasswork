'use strict';

// JSON-RPC 2.0 over a pair of byte streams, framed like the Language Server Protocol:
//
//     Content-Length: 123\r\n
//     \r\n
//     {"jsonrpc":"2.0", ...}
//
// Glasswork's C++ side uses the same framing for language servers, so one decoder serves both.
// The connection is symmetrical: either side can send requests and notifications.

class Connection {
    constructor(input, output) {
        this.output = output;
        this.buffer = Buffer.alloc(0);
        this.nextId = 1;
        this.pending = new Map();
        this.requestHandlers = new Map();
        this.notificationHandlers = new Map();
        this.closed = false;
        this.onClose = null;

        input.on('data', (chunk) => this.receive(chunk));
        input.on('end', () => this.close());
        input.on('close', () => this.close());
    }

    onRequest(method, handler) {
        this.requestHandlers.set(method, handler);
    }

    onNotification(method, handler) {
        this.notificationHandlers.set(method, handler);
    }

    sendNotification(method, params) {
        this.write({ jsonrpc: '2.0', method, params });
    }

    sendRequest(method, params) {
        const id = this.nextId++;
        return new Promise((resolve, reject) => {
            this.pending.set(id, { resolve, reject });
            this.write({ jsonrpc: '2.0', id, method, params });
        });
    }

    write(message) {
        if (this.closed) {
            return;
        }
        const body = Buffer.from(JSON.stringify(message), 'utf8');
        const header = Buffer.from(`Content-Length: ${body.length}\r\n\r\n`, 'ascii');
        this.output.write(Buffer.concat([header, body]));
    }

    receive(chunk) {
        this.buffer = Buffer.concat([this.buffer, chunk]);
        for (;;) {
            const message = this.nextMessage();
            if (message === null) {
                return;
            }
            this.dispatch(message);
        }
    }

    nextMessage() {
        const separator = this.buffer.indexOf('\r\n\r\n');
        if (separator < 0) {
            return null;
        }
        const header = this.buffer.slice(0, separator).toString('ascii');
        const match = /content-length:\s*(\d+)/i.exec(header);
        if (!match) {
            // Garbage: skip past the separator and try again.
            this.buffer = this.buffer.slice(separator + 4);
            return this.nextMessage();
        }
        const length = parseInt(match[1], 10);
        const start = separator + 4;
        if (this.buffer.length < start + length) {
            return null;
        }
        const body = this.buffer.slice(start, start + length).toString('utf8');
        this.buffer = this.buffer.slice(start + length);
        try {
            return JSON.parse(body);
        } catch (error) {
            return this.nextMessage();
        }
    }

    dispatch(message) {
        const hasMethod = typeof message.method === 'string';
        const hasId = message.id !== undefined && message.id !== null;

        if (!hasMethod && hasId) {
            const waiting = this.pending.get(message.id);
            if (!waiting) {
                return;
            }
            this.pending.delete(message.id);
            if (message.error) {
                const error = new Error(message.error.message || 'Request failed');
                error.code = message.error.code;
                waiting.reject(error);
            } else {
                waiting.resolve(message.result);
            }
            return;
        }

        if (hasMethod && hasId) {
            this.answerRequest(message);
            return;
        }

        if (hasMethod) {
            const handler = this.notificationHandlers.get(message.method);
            if (handler) {
                try {
                    handler(message.params);
                } catch (error) {
                    process.stderr.write(`[host] notification ${message.method} failed: ${error && error.stack}\n`);
                }
            }
        }
    }

    async answerRequest(message) {
        const handler = this.requestHandlers.get(message.method);
        if (!handler) {
            this.write({ jsonrpc: '2.0', id: message.id, error: { code: -32601, message: `Unknown method ${message.method}` } });
            return;
        }
        try {
            const result = await handler(message.params);
            this.write({ jsonrpc: '2.0', id: message.id, result: result === undefined ? null : result });
        } catch (error) {
            this.write({
                jsonrpc: '2.0',
                id: message.id,
                error: { code: -32603, message: (error && error.message) || String(error) },
            });
        }
    }

    close() {
        if (this.closed) {
            return;
        }
        this.closed = true;
        for (const waiting of this.pending.values()) {
            waiting.reject(new Error('Connection closed'));
        }
        this.pending.clear();
        if (this.onClose) {
            this.onClose();
        }
    }
}

module.exports = { Connection };
