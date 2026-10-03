'use strict';

// Loading extensions and deciding when to run them. An extension's package.json lists the
// events that should wake it (activationEvents); until one happens its code is not even
// loaded, which keeps a window with fifty installed extensions as quick as one with none.

const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { pathToFileURL } = require('url');
const types = require('./api/types');
const { Uri } = require('./api/uri');
const { Memento } = require('./api/memento');

class ExtensionRecord {
    constructor(description, storageRoot, workspaceKey) {
        this.id = description.id;
        this.path = description.path;
        this.manifest = description.manifest || {};
        this.state = 'inactive'; // inactive | activating | active | failed
        this.exports = undefined;
        this.module = undefined;
        this.context = undefined;
        this.activation = null;
        this.storageRoot = storageRoot;
        this.workspaceKey = workspaceKey;
    }

    get activationEvents() {
        const events = new Set(this.manifest.activationEvents || []);
        const contributes = this.manifest.contributes || {};
        for (const command of contributes.commands || []) {
            if (command && command.command) events.add(`onCommand:${command.command}`);
        }
        for (const language of contributes.languages || []) {
            if (language && language.id) events.add(`onLanguage:${language.id}`);
        }
        return events;
    }

    info(runtime) {
        const record = this;
        return {
            id: record.id,
            extensionUri: Uri.file(record.path),
            extensionPath: record.path,
            get isActive() {
                return record.state === 'active';
            },
            packageJSON: record.manifest,
            extensionKind: types.ExtensionKind.Workspace,
            get exports() {
                return record.exports;
            },
            activate: () => runtime.activate(record.id).then(() => record.exports),
        };
    }
}

class ActivationManager {
    constructor({ connection, log, configuration, storageRoot, workspaceFolders }) {
        this.connection = connection;
        this.log = log;
        this.configuration = configuration;
        this.storageRoot = storageRoot;
        this.records = new Map();
        const key = crypto.createHash('sha1').update(workspaceFolders.join('\n')).digest('hex').slice(0, 12);
        this.workspaceKey = key;
        this.firedEvents = new Set();
    }

    add(description) {
        const record = new ExtensionRecord(description, this.storageRoot, this.workspaceKey);
        this.records.set(record.id, record);
        this.configuration.addDefaults((record.manifest.contributes || {}).configuration);
        return record;
    }

    infos() {
        return Array.from(this.records.values()).map((record) => record.info(this));
    }

    commandTitles() {
        const titles = new Map();
        for (const record of this.records.values()) {
            for (const command of (record.manifest.contributes || {}).commands || []) {
                if (command && command.command) {
                    const title = typeof command.title === 'string' ? command.title : command.title && command.title.value;
                    titles.set(command.command, command.category ? `${command.category}: ${title}` : title);
                }
            }
        }
        return titles;
    }

    // Activates every extension waiting for this event. Resolves when they have all finished
    // (or failed): callers that need an extension's providers registered wait for it.
    async fire(event) {
        this.firedEvents.add(event);
        const waiting = [];
        for (const record of this.records.values()) {
            if (record.state !== 'inactive') {
                continue;
            }
            const events = record.activationEvents;
            if (events.has('*') || events.has(event)) {
                waiting.push(this.activate(record.id));
            }
        }
        await Promise.all(waiting);
    }

    // Whether any extension has declared interest in a language, before anything has run.
    wantsLanguage(languageId) {
        for (const record of this.records.values()) {
            if (record.activationEvents.has(`onLanguage:${languageId}`) || record.activationEvents.has('*')) {
                return true;
            }
        }
        return false;
    }

    async activate(id) {
        const record = this.records.get(id);
        if (!record) {
            throw new Error(`Unknown extension ${id}`);
        }
        if (record.activation) {
            return record.activation;
        }
        record.state = 'activating';
        record.activation = this.run(record);
        return record.activation;
    }

    async run(record) {
        try {
            for (const dependency of record.manifest.extensionDependencies || []) {
                if (this.records.has(dependency)) {
                    await this.activate(dependency);
                }
            }
            if (!record.manifest.main) {
                record.state = 'active';
                this.report(record);
                return;
            }
            const entry = path.resolve(record.path, record.manifest.main);
            const started = Date.now();
            record.module = await this.load(entry);
            record.context = this.createContext(record);
            if (record.module && typeof record.module.activate === 'function') {
                record.exports = await record.module.activate(record.context);
            }
            record.state = 'active';
            this.log('Glasswork', `Activated ${record.id} in ${Date.now() - started} ms`, true);
            this.report(record);
        } catch (error) {
            record.state = 'failed';
            const message = (error && error.stack) || String(error);
            this.log('Glasswork', `Activating ${record.id} failed: ${message}`, true);
            this.report(record, message);
        }
    }

    async load(entry) {
        let resolved = entry;
        if (!fs.existsSync(resolved)) {
            for (const suffix of ['.js', '.cjs', '/index.js']) {
                if (fs.existsSync(entry + suffix)) {
                    resolved = entry + suffix;
                    break;
                }
            }
        }
        if (resolved.endsWith('.mjs')) {
            return import(pathToFileURL(resolved).href);
        }
        return require(resolved);
    }

    report(record, error) {
        this.connection.sendNotification('host/extensionState', { id: record.id, state: record.state, error: error || null });
    }

    createContext(record) {
        const storage = path.join(record.storageRoot, record.id);
        const globalFolder = path.join(storage, 'global');
        const workspaceFolder = path.join(storage, 'workspace', record.workspaceKey);
        const logFolder = path.join(storage, 'logs');
        for (const folder of [globalFolder, workspaceFolder, logFolder]) {
            fs.mkdirSync(folder, { recursive: true });
        }
        const secretValues = new Memento(path.join(storage, 'secrets.json'));
        const secretEmitter = new types.EventEmitter();
        const info = record.info(this);
        return {
            subscriptions: [],
            extensionPath: record.path,
            extensionUri: Uri.file(record.path),
            extensionMode: types.ExtensionMode.Production,
            extension: info,
            globalState: new Memento(path.join(storage, 'globalState.json')),
            workspaceState: new Memento(path.join(storage, 'workspace', record.workspaceKey, 'workspaceState.json')),
            secrets: {
                get: async (key) => secretValues.get(key),
                store: async (key, value) => {
                    await secretValues.update(key, value);
                    secretEmitter.fire({ key });
                },
                delete: async (key) => {
                    await secretValues.update(key, undefined);
                    secretEmitter.fire({ key });
                },
                onDidChange: secretEmitter.event,
            },
            storageUri: Uri.file(workspaceFolder),
            globalStorageUri: Uri.file(globalFolder),
            logUri: Uri.file(logFolder),
            storagePath: workspaceFolder,
            globalStoragePath: globalFolder,
            logPath: logFolder,
            environmentVariableCollection: {
                persistent: true,
                description: undefined,
                replace() {},
                append() {},
                prepend() {},
                get() {},
                forEach() {},
                delete() {},
                clear() {},
                getScoped() {
                    return this;
                },
                [Symbol.iterator]: function* () {},
            },
            asAbsolutePath: (relative) => path.join(record.path, relative),
            languageModelAccessInformation: { onDidChange: new types.EventEmitter().event, canSendRequest: () => undefined },
        };
    }

    async deactivateAll() {
        for (const record of this.records.values()) {
            if (record.state !== 'active') {
                continue;
            }
            try {
                if (record.module && typeof record.module.deactivate === 'function') {
                    await Promise.race([record.module.deactivate(), new Promise((resolve) => setTimeout(resolve, 2000))]);
                }
                for (const subscription of (record.context && record.context.subscriptions) || []) {
                    try {
                        if (subscription && typeof subscription.dispose === 'function') {
                            subscription.dispose();
                        }
                    } catch (error) {
                        // keep going
                    }
                }
            } catch (error) {
                this.log('Glasswork', `Deactivating ${record.id} failed: ${error && error.message}`, true);
            }
        }
    }
}

void os;
module.exports = { ActivationManager };
