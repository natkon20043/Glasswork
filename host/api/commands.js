'use strict';

// vscode.commands: commands extensions register, and the built-in ones they call.

const { Disposable } = require('./types');

class CommandRegistry {
    constructor({ connection, titles, log }) {
        this.connection = connection;
        this.titles = titles; // command id → title from package.json
        this.log = log;
        this.handlers = new Map();
        this.contexts = new Map();
        this.beforeExecute = null; // activates extensions that declared onCommand:<id>
    }

    register(id, callback, thisArgument) {
        if (this.handlers.has(id)) {
            throw new Error(`command '${id}' already exists`);
        }
        const handler = thisArgument ? callback.bind(thisArgument) : callback;
        this.handlers.set(id, handler);
        this.connection.sendNotification('commands/registered', { id, title: this.titles.get(id) || null });
        return new Disposable(() => {
            this.handlers.delete(id);
            this.connection.sendNotification('commands/unregistered', { id });
        });
    }

    has(id) {
        return this.handlers.has(id);
    }

    list() {
        return Array.from(this.handlers.keys());
    }

    async execute(id, ...args) {
        if (id === 'setContext') {
            this.contexts.set(args[0], args[1]);
            this.connection.sendNotification('commands/setContext', { key: args[0], value: args[1] });
            return undefined;
        }
        if (!this.handlers.has(id) && this.beforeExecute) {
            await this.beforeExecute(id);
        }
        const handler = this.handlers.get(id);
        if (handler) {
            return handler(...args);
        }
        // Not ours: Glasswork may know it (a built-in editor command).
        return this.connection.sendRequest('commands/executeBuiltin', { id, args: JSON.parse(JSON.stringify(args)) });
    }
}

module.exports = { CommandRegistry };
