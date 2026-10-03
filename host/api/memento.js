'use strict';

// vscode.Memento: small key/value state an extension keeps between sessions (globalState and
// workspaceState). Stored as one JSON file per extension, written shortly after a change.

const fs = require('fs');
const path = require('path');

class Memento {
    constructor(filePath) {
        this.filePath = filePath;
        this.values = {};
        this.timer = null;
        try {
            this.values = JSON.parse(fs.readFileSync(filePath, 'utf8'));
        } catch (error) {
            this.values = {};
        }
    }

    keys() {
        return Object.keys(this.values);
    }

    get(key, defaultValue) {
        return Object.prototype.hasOwnProperty.call(this.values, key) ? this.values[key] : defaultValue;
    }

    update(key, value) {
        if (value === undefined) {
            delete this.values[key];
        } else {
            this.values[key] = value;
        }
        this.scheduleWrite();
        return Promise.resolve();
    }

    setKeysForSync() {}

    scheduleWrite() {
        if (this.timer) {
            return;
        }
        this.timer = setTimeout(() => {
            this.timer = null;
            this.flush();
        }, 200);
    }

    flush() {
        try {
            fs.mkdirSync(path.dirname(this.filePath), { recursive: true });
            fs.writeFileSync(this.filePath, JSON.stringify(this.values));
        } catch (error) {
            process.stderr.write(`[host] could not save ${this.filePath}: ${error.message}\n`);
        }
    }
}

module.exports = { Memento };
