'use strict';

// The `vscode` module that extensions require. Everything an extension can call lives here
// and talks to Glasswork over the host connection. APIs that Glasswork has no counterpart
// for yet (webviews, notebooks, the test explorer…) are present but inert: they log once and
// return harmless values, so an extension that merely touches them still activates.

const fs = require('fs');
const os = require('os');
const path = require('path');
const types = require('./types');
const convert = require('./lspConvert');
const { Uri } = require('./uri');
const { matchSelector, matchesGlob, globToRegExp } = require('./documents');

const { Disposable, EventEmitter, Position, Range } = types;

function createApi(runtime) {
    const { connection, documents, registry, commands, configuration, log } = runtime;

    const warnedAbout = new Set();
    function unsupported(name) {
        if (!warnedAbout.has(name)) {
            warnedAbout.add(name);
            log('Glasswork', `vscode.${name.replace(/^\./, '')} is not supported yet; ignoring.`);
        }
    }

    // A stand-in for APIs we do not implement: callable, chainable, never throws.
    function inertValue(name) {
        const target = function () {
            unsupported(name);
            return inertValue(name + '()');
        };
        return new Proxy(target, {
            get(_object, property) {
                if (property === 'then' || typeof property === 'symbol' || property === 'toJSON') {
                    return undefined;
                }
                if (property === 'dispose') {
                    return () => {};
                }
                return inertValue(`${name}.${String(property)}`);
            },
            apply() {
                unsupported(name);
                return new Disposable(() => {});
            },
        });
    }

    // Wraps a namespace so members we have not written yet fall back to inert values.
    function withFallback(name, namespace) {
        return new Proxy(namespace, {
            get(object, property) {
                if (property in object || typeof property === 'symbol' || property === 'then' || property === 'toJSON') {
                    return object[property];
                }
                return inertValue(`${name}.${String(property)}`);
            },
        });
    }

    // ----- commands -----

    const commandsApi = {
        registerCommand: (id, callback, thisArgument) => commands.register(id, callback, thisArgument),
        registerTextEditorCommand: (id, callback, thisArgument) =>
            commands.register(id, (...args) => callback(undefined, undefined, ...args), thisArgument),
        executeCommand: (id, ...args) => commands.execute(id, ...args),
        getCommands: async () => commands.list(),
    };

    // ----- window -----

    const outputChannels = new Map();
    function createOutputChannel(name) {
        const channel = {
            name,
            append: (text) => log(name, text, false),
            appendLine: (text) => log(name, text, true),
            replace: (text) => {
                connection.sendNotification('ui/logClear', { channel: name });
                log(name, text, false);
            },
            clear: () => connection.sendNotification('ui/logClear', { channel: name }),
            show: () => connection.sendNotification('ui/logShow', { channel: name }),
            hide: () => {},
            dispose: () => outputChannels.delete(name),
            // LogOutputChannel methods
            trace: (message) => log(name, `[trace] ${message}`, true),
            debug: (message) => log(name, `[debug] ${message}`, true),
            info: (message) => log(name, `[info] ${message}`, true),
            warn: (message) => log(name, `[warning] ${message}`, true),
            error: (message) => log(name, `[error] ${message instanceof Error ? message.stack : message}`, true),
            logLevel: types.LogLevel.Info,
            onDidChangeLogLevel: new EventEmitter().event,
        };
        outputChannels.set(name, channel);
        return channel;
    }

    let nextStatusId = 1;
    function createStatusBarItem(idOrAlignment, alignmentOrPriority, priority) {
        let id;
        let alignment;
        let itemPriority;
        if (typeof idOrAlignment === 'string') {
            id = idOrAlignment;
            alignment = alignmentOrPriority;
            itemPriority = priority;
        } else {
            id = `status-${nextStatusId++}`;
            alignment = idOrAlignment;
            itemPriority = alignmentOrPriority;
        }
        const item = {
            id,
            alignment: alignment || types.StatusBarAlignment.Left,
            priority: itemPriority || 0,
            text: '',
            tooltip: undefined,
            command: undefined,
            color: undefined,
            backgroundColor: undefined,
            name: undefined,
            accessibilityInformation: undefined,
            visible: false,
            push() {
                if (!this.visible) {
                    return;
                }
                const command = typeof this.command === 'string' ? this.command : this.command && this.command.command;
                connection.sendNotification('ui/statusBar', {
                    id: this.id,
                    alignment: this.alignment,
                    priority: this.priority,
                    text: this.text,
                    tooltip: typeof this.tooltip === 'string' ? this.tooltip : this.tooltip && this.tooltip.value,
                    command,
                    visible: true,
                });
            },
            show() {
                this.visible = true;
                this.push();
            },
            hide() {
                this.visible = false;
                connection.sendNotification('ui/statusBar', { id: this.id, visible: false });
            },
            dispose() {
                this.hide();
            },
        };
        // Changing text/tooltip/command after show() updates the item.
        return new Proxy(item, {
            set(object, property, value) {
                object[property] = value;
                if (['text', 'tooltip', 'command', 'priority'].includes(property)) {
                    object.push();
                }
                return true;
            },
        });
    }

    function splitMessageArguments(args) {
        let options = {};
        let items = args;
        const first = args[0];
        const firstIsOptions = first !== null && typeof first === 'object' && !first.title && first.modal !== undefined;
        if (args.length > 0 && firstIsOptions) {
            options = args[0];
            items = args.slice(1);
        }
        return { options, items };
    }

    function showMessage(severity) {
        return async (message, ...rest) => {
            const { options, items } = splitMessageArguments(rest);
            const labels = items.map((item) => (typeof item === 'string' ? item : item.title));
            const chosen = await connection.sendRequest('ui/showMessage', {
                severity,
                message: String(message),
                items: labels,
                modal: !!options.modal,
                detail: options.detail,
            });
            if (chosen === null || chosen === undefined) {
                return undefined;
            }
            const index = labels.indexOf(chosen);
            return index >= 0 ? items[index] : undefined;
        };
    }

    async function showQuickPick(itemsOrPromise, options, token) {
        const items = await itemsOrPromise;
        const normalized = items.map((item) => (typeof item === 'string' ? { label: item } : item));
        const result = await connection.sendRequest('ui/quickPick', {
            items: normalized.map((item, index) => ({
                index,
                label: item.label,
                description: item.description,
                detail: item.detail,
                kind: item.kind,
                picked: item.picked,
            })),
            placeHolder: options && options.placeHolder,
            title: options && options.title,
            canPickMany: !!(options && options.canPickMany),
        });
        void token;
        if (result === null || result === undefined) {
            return undefined;
        }
        if (options && options.canPickMany) {
            return result.map((index) => items[index]);
        }
        return items[result];
    }

    async function showInputBox(options) {
        const result = await connection.sendRequest('ui/inputBox', {
            prompt: options && options.prompt,
            placeHolder: options && options.placeHolder,
            value: options && options.value,
            title: options && options.title,
            password: !!(options && options.password),
        });
        return result === null ? undefined : result;
    }

    async function withProgress(options, task) {
        const title = options && options.title;
        const progress = {
            report(value) {
                const text = [title, value && value.message].filter(Boolean).join(': ');
                connection.sendNotification('ui/statusMessage', { text: text || 'Working…', timeout: 0 });
            },
        };
        connection.sendNotification('ui/statusMessage', { text: title || 'Working…', timeout: 0 });
        const token = new types.CancellationTokenSource().token;
        try {
            return await task(progress, token);
        } finally {
            connection.sendNotification('ui/statusMessage', { text: '', timeout: 0 });
        }
    }

    const windowApi = {
        showInformationMessage: showMessage('info'),
        showWarningMessage: showMessage('warning'),
        showErrorMessage: showMessage('error'),
        showQuickPick,
        showInputBox,
        createOutputChannel,
        createStatusBarItem,
        setStatusBarMessage(text, hideAfterTimeoutOrPromise) {
            const timeout = typeof hideAfterTimeoutOrPromise === 'number' ? hideAfterTimeoutOrPromise : 0;
            connection.sendNotification('ui/statusMessage', { text: String(text), timeout });
            if (hideAfterTimeoutOrPromise && typeof hideAfterTimeoutOrPromise.then === 'function') {
                hideAfterTimeoutOrPromise.then(() => connection.sendNotification('ui/statusMessage', { text: '', timeout: 0 }));
            }
            return new Disposable(() => connection.sendNotification('ui/statusMessage', { text: '', timeout: 0 }));
        },
        withProgress,
        get activeTextEditor() {
            return runtime.editors.active;
        },
        get visibleTextEditors() {
            return runtime.editors.visible;
        },
        activeTerminal: undefined,
        terminals: [],
        state: { focused: true },
        onDidChangeActiveTextEditor: runtime.editors.activeEmitter.event,
        onDidChangeVisibleTextEditors: runtime.editors.visibleEmitter.event,
        onDidChangeTextEditorSelection: runtime.editors.selectionEmitter.event,
        onDidChangeWindowState: new EventEmitter().event,
        onDidOpenTerminal: new EventEmitter().event,
        onDidCloseTerminal: new EventEmitter().event,
        async showTextDocument(documentOrUri, optionsOrColumn) {
            const uri = documentOrUri.uri || documentOrUri;
            const selection = optionsOrColumn && optionsOrColumn.selection;
            await connection.sendRequest('ui/openDocument', {
                uri: uri.toString(),
                line: selection ? selection.start.line : undefined,
                character: selection ? selection.start.character : undefined,
            });
            // The editor appears once Glasswork has opened the file and reported it.
            for (let attempt = 0; attempt < 50; attempt++) {
                const editor = runtime.editors.editors.get(uri.toString());
                if (editor && runtime.editors.activeUri === uri.toString()) {
                    return editor;
                }
                await new Promise((resolve) => setTimeout(resolve, 20));
            }
            return runtime.editors.active;
        },
        createTextEditorDecorationType: (options) => runtime.editors.createDecorationType(options),
        createTerminal: (options) => {
            unsupported('window.createTerminal');
            return { name: (options && options.name) || 'terminal', sendText() {}, show() {}, hide() {}, dispose() {}, processId: Promise.resolve(undefined) };
        },
        registerTreeDataProvider: (viewId, provider) => runtime.views.registerTreeDataProvider(viewId, provider),
        createTreeView: (viewId, options) => runtime.views.createTreeView(viewId, options),
        registerWebviewViewProvider: (viewId, provider, options) => runtime.views.registerWebviewViewProvider(viewId, provider, options),
        registerWebviewPanelSerializer: (viewType, serializer) => runtime.views.registerWebviewPanelSerializer(viewType, serializer),
        registerUriHandler: () => new Disposable(() => {}),
        registerCustomEditorProvider: () => new Disposable(() => {}),
        registerFileDecorationProvider: () => new Disposable(() => {}),
        createWebviewPanel: (viewType, title, showOptions, options) => runtime.views.createWebviewPanel(viewType, title, showOptions, options),
        // The editor's tabs: one group holding every open file (Glasswork has a single editor area).
        tabGroups: (() => {
            const changeTabs = new EventEmitter();
            const changeGroups = new EventEmitter();
            const group = {
                isActive: true,
                viewColumn: 1,
                get tabs() {
                    const activeUri = runtime.editors.activeUri;
                    return runtime.documents
                        .all()
                        .filter((document) => document.uri.scheme === 'file')
                        .map((document) => ({
                            label: path.basename(document.uri.fsPath),
                            input: new types.TabInputText(document.uri),
                            isActive: document.uri.toString() === activeUri,
                            isDirty: document.isDirty,
                            isPinned: false,
                            isPreview: false,
                            group,
                        }));
                },
                get activeTab() {
                    return group.tabs.find((tab) => tab.isActive);
                },
            };
            const fireChange = () => changeTabs.fire({ opened: [], closed: [], changed: [] });
            runtime.documents.openEmitter.event(fireChange);
            runtime.documents.closeEmitter.event(fireChange);
            return {
                get all() {
                    return [group];
                },
                get activeTabGroup() {
                    return group;
                },
                onDidChangeTabs: changeTabs.event,
                onDidChangeTabGroups: changeGroups.event,
                close: async () => false,
            };
        })(),
        showOpenDialog: async () => undefined,
        showSaveDialog: async () => undefined,
        showWorkspaceFolderPick: async () => undefined,
    };

    // ----- workspace -----

    const workspaceFolders = runtime.workspaceFolders.map((uri, index) => {
        const parsed = Uri.parse(uri);
        return { uri: parsed, name: path.basename(parsed.fsPath), index };
    });

    function relativePath(pathOrUri, includeWorkspaceFolder) {
        const filePath = typeof pathOrUri === 'string' ? pathOrUri : pathOrUri.fsPath;
        for (const folder of workspaceFolders) {
            const root = folder.uri.fsPath;
            if (filePath === root || filePath.startsWith(root + '/')) {
                const relative = filePath.slice(root.length + 1);
                return includeWorkspaceFolder && workspaceFolders.length > 1 ? `${folder.name}/${relative}` : relative;
            }
        }
        return filePath;
    }

    const fileSystem = {
        async readFile(uri) {
            return new Uint8Array(await fs.promises.readFile(uri.fsPath));
        },
        async writeFile(uri, content) {
            await fs.promises.mkdir(path.dirname(uri.fsPath), { recursive: true });
            await fs.promises.writeFile(uri.fsPath, content);
        },
        async stat(uri) {
            try {
                const stats = await fs.promises.lstat(uri.fsPath);
                let kind = types.FileType.File;
                if (stats.isDirectory()) {
                    kind = types.FileType.Directory;
                } else if (stats.isSymbolicLink()) {
                    kind = types.FileType.SymbolicLink;
                }
                return { type: kind, ctime: stats.ctimeMs, mtime: stats.mtimeMs, size: stats.size };
            } catch (error) {
                throw types.FileSystemError.FileNotFound(uri);
            }
        },
        async readDirectory(uri) {
            const entries = await fs.promises.readdir(uri.fsPath, { withFileTypes: true });
            return entries.map((entry) => [entry.name, entry.isDirectory() ? types.FileType.Directory : types.FileType.File]);
        },
        async createDirectory(uri) {
            await fs.promises.mkdir(uri.fsPath, { recursive: true });
        },
        async delete(uri, options) {
            await fs.promises.rm(uri.fsPath, { recursive: !!(options && options.recursive), force: true });
        },
        async rename(source, target) {
            await fs.promises.rename(source.fsPath, target.fsPath);
        },
        async copy(source, target) {
            await fs.promises.cp(source.fsPath, target.fsPath, { recursive: true });
        },
        isWritableFileSystem: () => true,
    };

    async function findFiles(include, exclude, maxResults) {
        const includePattern = typeof include === 'string' ? include : include && include.pattern;
        const excludePattern = typeof exclude === 'string' ? exclude : exclude && exclude.pattern;
        // A pattern like "*.js" means "in any folder": "**/*.js". Patterns that start with ** (or, for
        // includes, with a slash) already say where they apply.
        const anywhere = (pattern, alsoKeepIfStartsWithSlash) => {
            const alreadyAnchored = pattern.startsWith('**') || (alsoKeepIfStartsWithSlash && pattern.startsWith('/'));
            return globToRegExp(alreadyAnchored ? pattern : '**/' + pattern);
        };
        const includeRegex = includePattern ? anywhere(includePattern, true) : null;
        const excludeRegex = excludePattern ? anywhere(excludePattern, false) : null;
        const found = [];
        const skipFolders = new Set(['node_modules', '.git', '.hg', '.svn', 'build', 'dist', 'target']);

        async function walk(folder, depth) {
            if (depth > 12 || (maxResults && found.length >= maxResults)) {
                return;
            }
            let entries;
            try {
                entries = await fs.promises.readdir(folder, { withFileTypes: true });
            } catch (error) {
                return;
            }
            for (const entry of entries) {
                const full = path.join(folder, entry.name);
                if (entry.isDirectory()) {
                    if (!skipFolders.has(entry.name) || (includeRegex && includeRegex.test(full + '/'))) {
                        await walk(full, depth + 1);
                    }
                } else {
                    if (includeRegex && !includeRegex.test(full)) {
                        continue;
                    }
                    if (excludeRegex && excludeRegex.test(full)) {
                        continue;
                    }
                    found.push(Uri.file(full));
                    if (maxResults && found.length >= maxResults) {
                        return;
                    }
                }
            }
        }
        for (const folder of workspaceFolders) {
            await walk(folder.uri.fsPath, 0);
        }
        return found;
    }

    async function openTextDocument(arg) {
        if (arg && arg.uri) {
            return arg;
        }
        const describesNewDocument = arg && typeof arg === 'object' && !(arg instanceof Uri) && (arg.content !== undefined || arg.language !== undefined);
        if (describesNewDocument) {
            return documents.createDetached(Uri.parse('untitled:Untitled-1'), arg.language || 'plaintext', arg.content || '');
        }
        const uri = typeof arg === 'string' ? Uri.file(arg) : arg;
        const open = documents.get(uri);
        if (open) {
            return open;
        }
        const text = await fs.promises.readFile(uri.fsPath, 'utf8');
        return documents.createDetached(uri, runtime.languageForPath ? runtime.languageForPath(uri.fsPath) : 'plaintext', text);
    }

    async function applyEdit(edit) {
        const result = await connection.sendRequest('workspace/applyEdit', { edit: convert.fromWorkspaceEdit(edit) });
        return !!(result && result.applied);
    }

    const workspaceApi = {
        workspaceFolders: workspaceFolders.length > 0 ? workspaceFolders : undefined,
        rootPath: workspaceFolders.length > 0 ? workspaceFolders[0].uri.fsPath : undefined,
        name: workspaceFolders.length > 0 ? workspaceFolders[0].name : undefined,
        isTrusted: true,
        workspaceFile: undefined,
        notebookDocuments: [],
        fs: fileSystem,
        get textDocuments() {
            return documents.all();
        },
        getConfiguration: (section) => configuration.getConfiguration(section),
        onDidChangeConfiguration: configuration.onDidChange,
        onDidOpenTextDocument: documents.openEmitter.event,
        onDidCloseTextDocument: documents.closeEmitter.event,
        onDidChangeTextDocument: documents.changeEmitter.event,
        onDidSaveTextDocument: documents.saveEmitter.event,
        onWillSaveTextDocument: new EventEmitter().event,
        onDidChangeWorkspaceFolders: new EventEmitter().event,
        onDidGrantWorkspaceTrust: new EventEmitter().event,
        onDidCreateFiles: new EventEmitter().event,
        onDidDeleteFiles: new EventEmitter().event,
        onDidRenameFiles: new EventEmitter().event,
        onWillCreateFiles: new EventEmitter().event,
        onWillDeleteFiles: new EventEmitter().event,
        onWillRenameFiles: new EventEmitter().event,
        openTextDocument,
        applyEdit,
        findFiles,
        saveAll: async () => connection.sendRequest('workspace/saveAll', {}).then(() => true),
        asRelativePath: relativePath,
        getWorkspaceFolder(uri) {
            return workspaceFolders.find((folder) => uri.fsPath === folder.uri.fsPath || uri.fsPath.startsWith(folder.uri.fsPath + '/'));
        },
        updateWorkspaceFolders: () => false,
        // Glasswork reports files changing on disk (`workspace/fileEvents`); a watcher fires for the
        // ones that match its pattern.
        createFileSystemWatcher(globPattern, ignoreCreateEvents, ignoreChangeEvents, ignoreDeleteEvents) {
            const created = new EventEmitter();
            const changed = new EventEmitter();
            const deleted = new EventEmitter();
            const watcher = {
                globPattern,
                ignoreCreateEvents: !!ignoreCreateEvents,
                ignoreChangeEvents: !!ignoreChangeEvents,
                ignoreDeleteEvents: !!ignoreDeleteEvents,
                onDidCreate: created.event,
                onDidChange: changed.event,
                onDidDelete: deleted.event,
                created,
                changed,
                deleted,
                dispose() {
                    runtime.fileWatchers.delete(watcher);
                },
            };
            runtime.fileWatchers.add(watcher);
            return watcher;
        },
        registerTextDocumentContentProvider: () => new Disposable(() => {}),
        registerFileSystemProvider: () => new Disposable(() => {}),
        registerTaskProvider: () => new Disposable(() => {}),
        registerNotebookSerializer: () => new Disposable(() => {}),
    };

    // ----- languages -----

    const diagnosticCollections = new Set();
    const diagnosticsEmitter = new EventEmitter();

    function publishDiagnostics(uri, diagnostics) {
        runtime.publishDiagnostics(uri.toString(), diagnostics.map(convert.fromDiagnostic));
        diagnosticsEmitter.fire({ uris: [uri] });
    }

    function createDiagnosticCollection(name) {
        const entries = new Map(); // uri string → {uri, diagnostics}
        const collection = {
            name: name || 'unnamed',
            set(uriOrEntries, diagnostics) {
                if (Array.isArray(uriOrEntries)) {
                    for (const [uri, list] of uriOrEntries) {
                        collection.set(uri, list);
                    }
                    return;
                }
                const key = uriOrEntries.toString();
                const list = diagnostics ? diagnostics.slice() : [];
                if (list.length === 0) {
                    entries.delete(key);
                } else {
                    entries.set(key, { uri: uriOrEntries, diagnostics: list });
                }
                publishDiagnostics(uriOrEntries, list);
            },
            delete(uri) {
                entries.delete(uri.toString());
                publishDiagnostics(uri, []);
            },
            clear() {
                for (const entry of Array.from(entries.values())) {
                    publishDiagnostics(entry.uri, []);
                }
                entries.clear();
            },
            forEach(callback, thisArgument) {
                for (const entry of entries.values()) {
                    callback.call(thisArgument, entry.uri, entry.diagnostics, collection);
                }
            },
            get(uri) {
                const entry = entries.get(uri.toString());
                return entry ? entry.diagnostics : undefined;
            },
            has(uri) {
                return entries.has(uri.toString());
            },
            dispose() {
                collection.clear();
                diagnosticCollections.delete(collection);
            },
            entries,
        };
        diagnosticCollections.add(collection);
        return collection;
    }

    function provider(kind, optionsFor) {
        return (selector, providerObject, ...extra) => registry.register(kind, selector, providerObject, optionsFor ? optionsFor(extra) : {});
    }

    const languagesApi = {
        registerCompletionItemProvider: (selector, providerObject, ...triggerCharacters) =>
            registry.register('completion', selector, providerObject, { triggerCharacters }),
        registerHoverProvider: provider('hover'),
        registerSignatureHelpProvider: (selector, providerObject, ...rest) => {
            let triggerCharacters = [];
            let metadata = {};
            if (rest.length === 1 && typeof rest[0] === 'object') {
                metadata = rest[0];
                triggerCharacters = metadata.triggerCharacters || [];
            } else {
                triggerCharacters = rest;
            }
            return registry.register('signatureHelp', selector, providerObject, { triggerCharacters, metadata });
        },
        registerDefinitionProvider: provider('definition'),
        registerDeclarationProvider: provider('declaration'),
        registerTypeDefinitionProvider: provider('typeDefinition'),
        registerImplementationProvider: provider('implementation'),
        registerReferenceProvider: provider('references'),
        registerDocumentHighlightProvider: provider('documentHighlight'),
        registerDocumentSymbolProvider: provider('documentSymbol'),
        registerWorkspaceSymbolProvider: (providerObject) => registry.register('workspaceSymbol', '*', providerObject, {}),
        registerCodeActionsProvider: (selector, providerObject, metadata) => registry.register('codeAction', selector, providerObject, { metadata }),
        registerCodeLensProvider: provider('codeLens'),
        registerDocumentLinkProvider: provider('documentLink'),
        registerDocumentFormattingEditProvider: provider('documentFormatting'),
        registerDocumentRangeFormattingEditProvider: provider('documentRangeFormatting'),
        registerOnTypeFormattingEditProvider: (selector, providerObject, firstTriggerCharacter, ...moreTriggerCharacter) =>
            registry.register('onTypeFormatting', selector, providerObject, { firstTriggerCharacter, moreTriggerCharacter }),
        registerRenameProvider: provider('rename'),
        registerFoldingRangeProvider: provider('foldingRange'),
        registerSelectionRangeProvider: provider('selectionRange'),
        registerDocumentSemanticTokensProvider: (selector, providerObject, legend) =>
            registry.register('semanticTokens', selector, providerObject, { legend }),
        registerInlayHintsProvider: provider('inlayHint'),
        registerDocumentRangeSemanticTokensProvider: () => new Disposable(() => {}),
        registerColorProvider: () => new Disposable(() => {}),
        registerCallHierarchyProvider: () => new Disposable(() => {}),
        registerTypeHierarchyProvider: () => new Disposable(() => {}),
        registerLinkedEditingRangeProvider: () => new Disposable(() => {}),
        registerEvaluatableExpressionProvider: () => new Disposable(() => {}),
        registerInlineValuesProvider: () => new Disposable(() => {}),
        registerInlineCompletionItemProvider: () => new Disposable(() => {}),
        registerDocumentDropEditProvider: () => new Disposable(() => {}),
        setLanguageConfiguration: () => new Disposable(() => {}),
        setTextDocumentLanguage: async (document) => document,
        createDiagnosticCollection,
        onDidChangeDiagnostics: diagnosticsEmitter.event,
        getDiagnostics(uri) {
            if (uri) {
                const result = [];
                for (const collection of diagnosticCollections) {
                    result.push(...(collection.get(uri) || []));
                }
                return result;
            }
            const all = new Map();
            for (const collection of diagnosticCollections) {
                for (const entry of collection.entries.values()) {
                    const key = entry.uri.toString();
                    all.set(key, [entry.uri, (all.get(key) ? all.get(key)[1] : []).concat(entry.diagnostics)]);
                }
            }
            return Array.from(all.values());
        },
        async getLanguages() {
            return runtime.languageIds ? runtime.languageIds() : [];
        },
        match: (selector, document) => matchSelector(selector, document),
    };

    // ----- env -----

    const sessionId = `${Date.now()}${Math.random().toString(16).slice(2)}`;
    const envApi = {
        appName: 'Glasswork',
        appRoot: runtime.appRoot || '',
        appHost: 'desktop',
        uriScheme: 'glasswork',
        language: 'en',
        machineId: runtime.machineId || sessionId,
        sessionId,
        remoteName: undefined,
        shell: process.env.SHELL || '/bin/zsh',
        uiKind: types.UIKind.Desktop,
        isNewAppInstall: false,
        isTelemetryEnabled: false,
        onDidChangeTelemetryEnabled: new EventEmitter().event,
        onDidChangeShell: new EventEmitter().event,
        clipboard: {
            readText: async () => (await connection.sendRequest('env/clipboardRead', {})) || '',
            writeText: async (text) => {
                await connection.sendRequest('env/clipboardWrite', { text });
            },
        },
        openExternal: async (target) => {
            await connection.sendRequest('env/openExternal', { uri: target.toString() });
            return true;
        },
        asExternalUri: async (target) => target,
        createTelemetryLogger: () => ({ logUsage() {}, logError() {}, dispose() {}, onDidChangeEnableStates: new EventEmitter().event, isUsageEnabled: false, isErrorsEnabled: false }),
    };

    // ----- extensions -----

    const extensionsApi = {
        get all() {
            return runtime.extensionInfos();
        },
        getExtension(id) {
            const lower = String(id).toLowerCase();
            return runtime.extensionInfos().find((info) => info.id.toLowerCase() === lower);
        },
        onDidChange: new EventEmitter().event,
    };

    // ----- the module -----

    const api = {
        ...types,
        version: '1.95.0',
        commands: withFallback('commands', commandsApi),
        window: withFallback('window', windowApi),
        workspace: withFallback('workspace', workspaceApi),
        languages: withFallback('languages', languagesApi),
        env: withFallback('env', envApi),
        extensions: withFallback('extensions', extensionsApi),
        tasks: inertValue('tasks'),
        debug: inertValue('debug'),
        scm: inertValue('scm'),
        authentication: inertValue('authentication'),
        notebooks: inertValue('notebooks'),
        tests: inertValue('tests'),
        chat: inertValue('chat'),
        lm: inertValue('lm'),
        l10n: {
            t: (message, ...args) => {
                const text = typeof message === 'string' ? message : message.message;
                const values = Array.isArray(args[0]) ? args[0] : args;
                return text.replace(/\{(\d+)\}/g, (match, index) => (values[index] !== undefined ? String(values[index]) : match));
            },
            bundle: undefined,
            uri: undefined,
        },
        // Constructors that extensions use but the editor has no behaviour for yet.
        ShellExecution: class ShellExecution { constructor(commandLine) { this.commandLine = commandLine; } },
        ProcessExecution: class ProcessExecution { constructor(process, args) { this.process = process; this.args = args; } },
        Task: class Task { constructor(definition, scope, name, source, execution) { Object.assign(this, { definition, scope, name, source, execution }); } },
        TaskGroup: { Build: { id: 'build' }, Test: { id: 'test' }, Clean: { id: 'clean' }, Rebuild: { id: 'rebuild' } },
        RelativePattern: class RelativePattern {
            constructor(base, pattern) {
                this.baseUri = typeof base === 'string' ? Uri.file(base) : base.uri || base;
                this.base = this.baseUri.fsPath;
                this.pattern = pattern;
            }
        },
        DebugAdapterExecutable: class DebugAdapterExecutable { constructor(command, args, options) { Object.assign(this, { command, args, options }); } },
        DebugAdapterServer: class DebugAdapterServer { constructor(port, host) { Object.assign(this, { port, host }); } },
        NotebookCellData: class NotebookCellData { constructor(kind, value, languageId) { Object.assign(this, { kind, value, languageId }); } },
        NotebookData: class NotebookData { constructor(cells) { this.cells = cells; } },
        NotebookCellKind: { Markup: 1, Code: 2 },
        LanguageModelChatMessage: { User: () => ({}), Assistant: () => ({}) },
    };
    void os;
    void Position;
    void Range;
    void matchesGlob;
    // Anything else an extension reaches for (an enum or class we have not written) is inert
    // rather than undefined, so `class X extends vscode.Y` and `vscode.Z.Value` do not throw.
    return withFallback('', api);
}

module.exports = { createApi };
