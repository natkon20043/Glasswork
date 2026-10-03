'use strict';

// The Glasswork extension host: a Node.js process that runs VS Code extensions.
//
// Glasswork starts it with `node host/main.js`, and talks to it over stdin/stdout using
// JSON-RPC with Language Server style framing (see rpc.js). Extensions `require('vscode')`
// and get the API built in api/index.js. Everything an extension returns from a provider is
// turned back into protocol messages by virtualServer.js, so to Glasswork an extension's
// languages look like any other language server.

// Keep the real stdout for the protocol; anything an extension prints must not corrupt it.
const protocolOutput = process.stdout;
const writeToProtocol = protocolOutput.write.bind(protocolOutput);

process.noDeprecation = true; // Node's own deprecation notices are noise for extension authors

const Module = require('module');
const { pathToFileURL } = require('url');
const path = require('path');
const { Connection } = require('./rpc');
const { ConfigurationStore } = require('./api/configuration');
const { DocumentManager } = require('./api/documents');
const { CommandRegistry } = require('./api/commands');
const { createApi } = require('./api');
const { VirtualServer, ProviderRegistry } = require('./virtualServer');
const { ActivationManager } = require('./activation');
const { EditorManager } = require('./api/editor');
const convertEdit = require('./api/lspConvert');

const connection = new Connection(process.stdin, { write: writeToProtocol });

function log(channel, text, newline) {
    connection.sendNotification('ui/log', { channel, text: newline === false ? String(text) : String(text) + '\n' });
}

// console.* and process.stdout/stderr go to the "Extension Host" output channel.
function redirectConsole() {
    const forward = (prefix) => (...args) => {
        const text = args.map((value) => (typeof value === 'string' ? value : require('util').inspect(value))).join(' ');
        log('Extension Host', prefix + text, true);
    };
    console.log = forward('');
    console.info = forward('');
    console.debug = forward('[debug] ');
    console.warn = forward('[warn] ');
    console.error = forward('[error] ');
    process.stdout.write = (chunk) => {
        log('Extension Host', Buffer.isBuffer(chunk) ? chunk.toString('utf8') : String(chunk), false);
        return true;
    };
    process.stderr.write = (chunk) => {
        log('Extension Host', Buffer.isBuffer(chunk) ? chunk.toString('utf8') : String(chunk), false);
        return true;
    };
}
redirectConsole();

process.on('uncaughtException', (error) => {
    log('Extension Host', `Uncaught exception: ${(error && error.stack) || error}`, true);
});
process.on('unhandledRejection', (reason) => {
    log('Extension Host', `Unhandled rejection: ${(reason && reason.stack) || reason}`, true);
});

// ---------------------------------------------------------------------------

const documents = new DocumentManager();
const registry = new ProviderRegistry();
const servers = new Map(); // server id → VirtualServer
let activation = null;
let commands = null;
let configuration = null;
let editors = null;
const fileWatchers = new Set();
let workspaceFolders = [];
let languageIdList = [];

// Diagnostics an extension publishes go to the virtual server of the document's language.
function publishDiagnostics(uri, diagnostics) {
    const document = documents.get(uri);
    if (!document) {
        return;
    }
    for (const server of servers.values()) {
        if (server.language === document.languageId) {
            server.sendToClient({ jsonrpc: '2.0', method: 'textDocument/publishDiagnostics', params: { uri, diagnostics } });
        }
    }
}

// Tells Glasswork which languages extensions now have providers for, so it can attach the
// extension host's server to open files of those languages.
let providerReportScheduled = false;
function reportProviderLanguages() {
    if (providerReportScheduled) {
        return;
    }
    providerReportScheduled = true;
    setImmediate(() => {
        providerReportScheduled = false;
        const { languagesOfSelector } = require('./api/documents');
        const languages = new Set();
        let any = false;
        for (const record of registry.providers) {
            const named = languagesOfSelector(record.selector);
            if (named.size === 0 || named.has('*')) {
                any = true;
            }
            for (const language of named) {
                languages.add(language);
            }
        }
        connection.sendNotification('providers/changed', { languages: Array.from(languages), any });
    });
}
registry.onChange(reportProviderLanguages);

function hookVscodeModule(api) {
    globalThis.__glassworkVscodeApi = api;
    const shim = path.join(__dirname, 'vscode-shim.js');
    const originalResolve = Module._resolveFilename;
    Module._resolveFilename = function (request, ...rest) {
        if (request === 'vscode') {
            return shim;
        }
        return originalResolve.call(this, request, ...rest);
    };

    // ES module extensions: `import ... from 'vscode'` goes through the loader hooks instead.
    const identifier = /^[A-Za-z_$][A-Za-z0-9_$]*$/;
    const names = Object.keys(api).filter((name) => identifier.test(name) && name !== 'default');
    Module.register(pathToFileURL(path.join(__dirname, 'esm-hooks.mjs')), { parentURL: pathToFileURL(__filename), data: { names } });
}

// Extensions that activate when the workspace contains a file ("workspaceContains:Cargo.toml").
function workspaceContains(pattern) {
    const { globToRegExp } = require('./api/documents');
    const fs = require('fs');
    const skip = new Set(['node_modules', '.git', 'target', 'build', 'dist']);
    const regex = globToRegExp(pattern.startsWith('**') ? pattern : '**/' + pattern);
    function walk(folder, depth) {
        if (depth > 4) return false;
        let entries;
        try {
            entries = fs.readdirSync(folder, { withFileTypes: true });
        } catch (error) {
            return false;
        }
        for (const entry of entries) {
            const full = path.join(folder, entry.name);
            if (entry.isDirectory()) {
                if (!skip.has(entry.name) && walk(full, depth + 1)) return true;
            } else if (regex.test(full)) {
                return true;
            }
        }
        return false;
    }
    return workspaceFolders.some((folder) => walk(require('./api/uri').Uri.parse(folder).fsPath, 0));
}

function fireWorkspaceEvents() {
    const patterns = new Set();
    for (const record of activation.records.values()) {
        for (const event of record.activationEvents) {
            if (event.startsWith('workspaceContains:')) {
                patterns.add(event);
            }
        }
    }
    for (const event of patterns) {
        if (workspaceContains(event.slice('workspaceContains:'.length))) {
            activation.fire(event).catch(() => {});
        }
    }
}

connection.onRequest('initialize', async (params) => {
    workspaceFolders = params.workspaceFolders || [];
    languageIdList = params.languageIds || [];

    configuration = new ConfigurationStore(async (key, value, target) => {
        await connection.sendRequest('workspace/updateConfiguration', { key, value, target });
    });

    activation = new ActivationManager({
        connection,
        log,
        configuration,
        storageRoot: params.storageRoot || path.join(require('os').tmpdir(), 'glasswork-extension-state'),
        workspaceFolders,
    });
    for (const description of params.extensions || []) {
        activation.add(description);
    }
    configuration.setUserSettings(params.configuration || {});

    commands = new CommandRegistry({ connection, titles: activation.commandTitles(), log });
    commands.beforeExecute = (id) => activation.fire(`onCommand:${id}`);

    async function applyEdit(edit) {
        const result = await connection.sendRequest('workspace/applyEdit', { edit: convertEdit.fromWorkspaceEdit(edit) });
        return !!(result && result.applied);
    }
    editors = new EditorManager({ connection, documents, applyEdit });

    const runtime = {
        connection,
        fileWatchers,
        editors,
        documents,
        registry,
        commands,
        configuration,
        log,
        workspaceFolders,
        appRoot: params.appRoot,
        machineId: params.machineId,
        extensionInfos: () => activation.infos(),
        languageIds: () => languageIdList,
        publishDiagnostics,
        languageForPath: (filePath) => (params.languageForPath && params.languageForPath[path.extname(filePath)]) || 'plaintext',
    };
    const api = createApi(runtime);
    hookVscodeModule(api);

    documents.closeEmitter.event((document) => editors.forget(document.uri.toString()));
    documents.saveRequester = async (document) => {
        const result = await connection.sendRequest('workspace/saveDocument', { uri: document.uri.toString() });
        return !!result;
    };

    // Extensions that want to run at startup ("*") start now, without holding up the answer.
    setImmediate(() => {
        activation.fire('*').catch(() => {});
        fireWorkspaceEvents();
    });
    return { ok: true, extensions: activation.infos().map((info) => info.id) };
});

connection.onRequest('host/event', async (params) => {
    await activation.fire(params.name);
    return { ok: true };
});

connection.onRequest('commands/execute', async (params) => {
    return commands.execute(params.id, ...(params.args || []));
});

// Files that changed on disk: [{uri, type}] with type 1 created, 2 changed, 3 deleted.
connection.onNotification('workspace/fileEvents', (params) => {
    const { matchesGlob, globToRegExp } = require('./api/documents');
    const { Uri } = require('./api/uri');
    for (const event of params.events || []) {
        const uri = Uri.parse(event.uri);
        for (const watcher of fileWatchers) {
            const pattern = watcher.globPattern;
            let matches;
            if (pattern && typeof pattern === 'object' && pattern.base !== undefined) {
                // A RelativePattern: relative to its own folder.
                const prefix = pattern.base.replace(/\/$/, '') + '/';
                matches = uri.fsPath.startsWith(prefix) && matchesGlob(pattern.pattern, uri.fsPath.slice(prefix.length));
                void globToRegExp;
            } else {
                matches = matchesGlob(pattern, uri.fsPath);
            }
            if (!matches) continue;
            if (event.type === 1 && !watcher.ignoreCreateEvents) watcher.created.fire(uri);
            else if (event.type === 2 && !watcher.ignoreChangeEvents) watcher.changed.fire(uri);
            else if (event.type === 3 && !watcher.ignoreDeleteEvents) watcher.deleted.fire(uri);
        }
    }
});

// The front editor (file, selections, settings), or null when no text file shows.
connection.onNotification('editor/state', (params) => {
    if (editors) {
        editors.update(params);
    }
});

connection.onNotification('workspace/didChangeConfiguration', (params) => {
    configuration.setUserSettings(params.configuration || {});
});

connection.onRequest('host/status', async () => {
    return {
        extensions: Array.from(activation.records.values()).map((record) => ({ id: record.id, state: record.state })),
        providers: registry.providers.length,
        commands: commands.list(),
    };
});

// ----- Virtual language servers (one per language Glasswork opens) -----

connection.onRequest('lsp/open', async (params) => {
    const existing = servers.get(params.server);
    if (existing) {
        existing.dispose();
    }
    const server = new VirtualServer({
        id: params.server,
        language: params.language,
        rootUri: params.rootUri,
        registry,
        documents,
        commands,
        log: (text) => log('Extension Host', text, true),
        send: (message) => connection.sendNotification('lsp/message', { server: params.server, message }),
    });
    servers.set(params.server, server);
    return { ok: true };
});

connection.onNotification('lsp/message', (params) => {
    const server = servers.get(params.server);
    if (server) {
        server.handle(params.message);
    }
});

connection.onNotification('lsp/close', (params) => {
    const server = servers.get(params.server);
    if (server) {
        server.dispose();
        servers.delete(params.server);
    }
});

connection.onRequest('shutdown', async () => {
    if (activation) {
        await activation.deactivateAll();
    }
    return null;
});

connection.onNotification('exit', () => {
    process.exit(0);
});

connection.onClose = () => {
    process.exit(0);
};

connection.sendNotification('host/ready', { pid: process.pid, node: process.version });
