'use strict';

// Tree views and webviews: the parts of vscode.window that put an extension's own UI in
// Glasswork's window.
//
// Neither is drawn here. The host keeps what the extension gave (a data provider, some HTML) and
// answers the app's questions about it:
//
//   tree views   host → app   view/registered, view/changed, view/state
//                app → host   tree/children, tree/click, tree/select, tree/expand, tree/collapse,
//                             tree/visibility, tree/runCommand
//   webviews     host → app   webview/create, webview/html, webview/title, webview/message,
//                             webview/reveal, webview/dispose
//                app → host   webview/message, webview/disposed, webview/viewState, view/resolve

const path = require('path');
const { Uri } = require('./uri');
const types = require('./types');

const { Disposable, EventEmitter } = types;

// ---------------------------------------------------------------------------
// Small conversions shared by both kinds of view

/// An icon the extension gave, as something the app can draw:
/// {theme: "folder", color?} for a built-in symbol, {path} for an image file, or null.
function describeIcon(icon) {
    if (!icon) {
        return null;
    }
    if (icon instanceof types.ThemeIcon || (typeof icon === 'object' && typeof icon.id === 'string' && !icon.fsPath)) {
        return { theme: icon.id, color: icon.color && icon.color.id ? icon.color.id : undefined };
    }
    const pick = typeof icon === 'object' && (icon.dark || icon.light) && !icon.fsPath ? icon.dark || icon.light : icon;
    if (typeof pick === 'string') {
        return { path: pick };
    }
    if (pick && pick.fsPath) {
        return { path: pick.fsPath };
    }
    return null;
}

function plainText(value) {
    if (value === undefined || value === null) {
        return undefined;
    }
    if (typeof value === 'string') {
        return value;
    }
    if (typeof value.value === 'string') {
        return value.value; // a MarkdownString: shown as its text
    }
    return String(value);
}

// ---------------------------------------------------------------------------
// Tree views

class TreeViewState {
    constructor(manager, viewId, options) {
        this.manager = manager;
        this.viewId = viewId;
        this.provider = options.treeDataProvider;
        this.options = options;
        this.nextHandle = 1;
        this.elements = new Map(); // handle → {element, item}
        this.selection = [];
        this.visible = false;
        this.title = undefined;
        this.description = undefined;
        this.message = undefined;
        this.badge = undefined;
        this.selectionEmitter = new EventEmitter();
        this.visibilityEmitter = new EventEmitter();
        this.expandEmitter = new EventEmitter();
        this.collapseEmitter = new EventEmitter();
        this.checkboxEmitter = new EventEmitter();
        this.subscription = null;
        if (typeof this.provider.onDidChangeTreeData === 'function') {
            this.subscription = this.provider.onDidChangeTreeData(() => this.changed());
        }
    }

    changed() {
        this.elements.clear();
        this.manager.connection.sendNotification('view/changed', { id: this.viewId });
    }

    sendState() {
        this.manager.connection.sendNotification('view/state', {
            id: this.viewId,
            title: this.title,
            description: this.description,
            message: this.message,
            badge: this.badge ? { value: this.badge.value, tooltip: this.badge.tooltip } : null,
        });
    }

    /// The nodes under an element (or at the top for no handle), described for the app.
    async children(handle) {
        let parent;
        if (handle !== undefined && handle !== null) {
            const known = this.elements.get(handle);
            if (!known) {
                return [];
            }
            parent = known.element;
        }
        let list = await this.provider.getChildren(parent);
        if (!list) {
            return [];
        }
        list = Array.from(list);
        const nodes = [];
        for (const element of list) {
            let item;
            try {
                item = await this.provider.getTreeItem(element);
            } catch (error) {
                this.manager.log('Extension Host', `getTreeItem failed in ${this.viewId}: ${(error && error.stack) || error}`);
                continue;
            }
            if (!item) {
                continue;
            }
            const identifier = item.id !== undefined ? String(item.id) : `n${this.nextHandle++}`;
            this.elements.set(identifier, { element, item });
            nodes.push(this.describe(identifier, item));
        }
        return nodes;
    }

    /// `description: true` means "show the file name of the resource"; anything else is shown as text.
    descriptionOf(item) {
        if (item.description !== true) {
            return plainText(item.description);
        }
        return item.resourceUri ? path.basename(item.resourceUri.fsPath || '') : '';
    }

    describe(handle, item) {
        const label = item.label && typeof item.label === 'object' ? item.label.label : item.label;
        const resource = item.resourceUri;
        let name = label;
        if ((name === undefined || name === null) && resource) {
            name = path.basename(resource.fsPath || resource.path || '');
        }
        return {
            handle,
            label: String(name === undefined || name === null ? '' : name),
            description: this.descriptionOf(item),
            tooltip: plainText(item.tooltip),
            icon: describeIcon(item.iconPath),
            resourcePath: resource ? resource.fsPath : undefined,
            collapsible: item.collapsibleState === 1 || item.collapsibleState === 2,
            expanded: item.collapsibleState === 2,
            hasCommand: !!(item.command && item.command.command),
            contextValue: item.contextValue,
        };
    }

    async click(handle) {
        const known = this.elements.get(handle);
        if (!known || !known.item.command || !known.item.command.command) {
            return;
        }
        const command = known.item.command;
        await this.manager.commands.execute(command.command, ...(command.arguments || []));
    }

    select(handles) {
        const elements = [];
        for (const handle of handles) {
            const known = this.elements.get(handle);
            if (known) {
                elements.push(known.element);
            }
        }
        this.selection = elements;
        this.selectionEmitter.fire({ selection: elements });
    }

    setVisible(visible) {
        if (this.visible !== visible) {
            this.visible = visible;
            this.visibilityEmitter.fire({ visible });
        }
    }

    toggled(handle, expanded) {
        const known = this.elements.get(handle);
        if (known) {
            (expanded ? this.expandEmitter : this.collapseEmitter).fire({ element: known.element });
        }
    }

    /// Runs a command from the view's menus with the clicked element (and the selection) as arguments.
    async runCommand(command, handle) {
        const known = this.elements.get(handle);
        const element = known ? known.element : undefined;
        await this.manager.commands.execute(command, element, element === undefined ? [] : [element]);
    }

    dispose() {
        if (this.subscription && this.subscription.dispose) {
            this.subscription.dispose();
        }
        this.manager.treeViews.delete(this.viewId);
        this.manager.connection.sendNotification('view/unregistered', { id: this.viewId });
    }
}

// ---------------------------------------------------------------------------
// Webviews

const resourceScheme = 'gw-resource';

class WebviewState {
    constructor(manager, handle, options) {
        this.manager = manager;
        this.handle = handle;
        this.disposed = false;
        this.htmlValue = '';
        this.optionsValue = options || {};
        this.messageEmitter = new EventEmitter();
        this.disposeEmitter = new EventEmitter();
        this.viewStateEmitter = new EventEmitter();
        const state = this;
        this.api = {
            get html() {
                return state.htmlValue;
            },
            set html(value) {
                state.htmlValue = String(value);
                manager.connection.sendNotification('webview/html', { handle, html: state.htmlValue });
            },
            get options() {
                return state.optionsValue;
            },
            set options(value) {
                state.optionsValue = value || {};
                manager.connection.sendNotification('webview/options', { handle, options: manager.describeOptions(state.optionsValue) });
            },
            onDidReceiveMessage: this.messageEmitter.event,
            postMessage: async (message) => {
                if (state.disposed) {
                    return false;
                }
                // Only plain data can cross to the app, so the message is copied through JSON.
                const plainMessage = JSON.parse(JSON.stringify(message === undefined ? null : message));
                const answer = await manager.connection.sendRequest('webview/postMessage', { handle, message: plainMessage });
                return !!(answer && answer.delivered);
            },
            asWebviewUri: (uri) => manager.asWebviewUri(uri),
            cspSource: `${resourceScheme}:`,
        };
    }
}

class WebviewManager {
    constructor({ connection, log }) {
        this.connection = connection;
        this.log = log;
        this.panels = new Map(); // handle → {state, panel}
        this.viewProviders = new Map(); // view id → {provider, options}
        this.viewWebviews = new Map(); // handle → {state, view}
        this.serializers = new Map(); // view type → serializer
        this.nextHandle = 1;
    }

    /// `asWebviewUri`: a link a page can load, which the app serves from the local file.
    asWebviewUri(uri) {
        const target = typeof uri === 'string' ? Uri.parse(uri) : uri;
        if (target.scheme && target.scheme !== 'file') {
            return target;
        }
        const encoded = (target.path || '').split('/').map(encodeURIComponent).join('/');
        return Uri.parse(`${resourceScheme}://local${encoded.startsWith('/') ? '' : '/'}${encoded}`);
    }

    describeOptions(options) {
        const roots = (options.localResourceRoots || []).map((root) => (typeof root === 'string' ? root : root.fsPath));
        return {
            enableScripts: !!options.enableScripts,
            localResourceRoots: options.localResourceRoots ? roots : null,
            retainContextWhenHidden: !!options.retainContextWhenHidden,
        };
    }

    createPanel(viewType, title, showOptions, options) {
        const handle = `panel${this.nextHandle++}`;
        const state = new WebviewState(this, handle, options);
        const column = showOptions && typeof showOptions === 'object' ? showOptions.viewColumn : showOptions;
        const preserveFocus = !!(showOptions && typeof showOptions === 'object' && showOptions.preserveFocus);
        const manager = this;
        const record = { state, panel: null, title: String(title), active: true, visible: true };
        const panel = {
            viewType,
            get title() {
                return record.title;
            },
            set title(value) {
                record.title = String(value);
                manager.connection.sendNotification('webview/title', { handle, title: record.title });
            },
            iconPath: undefined,
            webview: state.api,
            options: options || {},
            get viewColumn() {
                return column || 1;
            },
            get active() {
                return record.active;
            },
            get visible() {
                return record.visible;
            },
            onDidDispose: state.disposeEmitter.event,
            onDidChangeViewState: state.viewStateEmitter.event,
            reveal(viewColumn, keepFocus) {
                manager.connection.sendNotification('webview/reveal', { handle, preserveFocus: !!keepFocus });
            },
            dispose() {
                manager.disposePanel(handle, true);
            },
        };
        record.panel = panel;
        this.panels.set(handle, record);
        this.connection.sendNotification('webview/create', {
            handle,
            viewType,
            title: record.title,
            column: column || 1,
            preserveFocus,
            options: this.describeOptions(state.optionsValue),
        });
        return panel;
    }

    disposePanel(handle, notifyApp) {
        const record = this.panels.get(handle);
        if (!record || record.state.disposed) {
            return;
        }
        record.state.disposed = true;
        this.panels.delete(handle);
        record.state.disposeEmitter.fire();
        if (notifyApp) {
            this.connection.sendNotification('webview/dispose', { handle });
        }
    }

    /// The app is about to show a view an extension registered a webview provider for.
    async resolveView(viewId) {
        const entry = this.viewProviders.get(viewId);
        if (!entry) {
            return { ok: false };
        }
        const handle = `view:${viewId}`;
        const existing = this.viewWebviews.get(handle);
        if (existing) {
            return { ok: true, handle, options: this.describeOptions(existing.state.optionsValue), html: existing.state.htmlValue };
        }
        const state = new WebviewState(this, handle, {});
        const visibilityEmitter = new EventEmitter();
        const manager = this;
        const record = { state, view: null, visible: true, title: undefined, description: undefined };
        const view = {
            viewType: viewId,
            webview: state.api,
            get title() {
                return record.title;
            },
            set title(value) {
                record.title = value;
                manager.connection.sendNotification('view/state', { id: viewId, title: value });
            },
            get description() {
                return record.description;
            },
            set description(value) {
                record.description = value;
                manager.connection.sendNotification('view/state', { id: viewId, description: value });
            },
            badge: undefined,
            get visible() {
                return record.visible;
            },
            onDidChangeVisibility: visibilityEmitter.event,
            onDidDispose: state.disposeEmitter.event,
            show(preserveFocus) {
                manager.connection.sendNotification('view/reveal', { id: viewId, preserveFocus: !!preserveFocus });
            },
        };
        record.view = view;
        record.visibilityEmitter = visibilityEmitter;
        this.viewWebviews.set(handle, record);
        const token = new types.CancellationTokenSource().token;
        try {
            await entry.provider.resolveWebviewView(view, { state: undefined }, token);
        } catch (error) {
            this.log('Extension Host', `resolveWebviewView failed for ${viewId}: ${(error && error.stack) || error}`);
        }
        return { ok: true, handle, options: this.describeOptions(state.optionsValue), html: state.htmlValue };
    }

    /// Finds the webview behind a handle, whether a panel or a sidebar view.
    stateFor(handle) {
        const panel = this.panels.get(handle);
        if (panel) {
            return panel.state;
        }
        const view = this.viewWebviews.get(handle);
        return view ? view.state : undefined;
    }

    install(connection) {
        connection.onNotification('webview/message', (params) => {
            const state = this.stateFor(params.handle);
            if (state) {
                state.messageEmitter.fire(params.message);
            }
        });
        connection.onNotification('webview/disposed', (params) => {
            this.disposePanel(params.handle, false);
            const view = this.viewWebviews.get(params.handle);
            if (view) {
                view.state.disposed = true;
                view.state.disposeEmitter.fire();
                this.viewWebviews.delete(params.handle);
            }
        });
        connection.onNotification('webview/viewState', (params) => {
            const panel = this.panels.get(params.handle);
            if (panel) {
                panel.active = !!params.active;
                panel.visible = !!params.visible;
                panel.state.viewStateEmitter.fire({ webviewPanel: panel.panel });
                return;
            }
            const view = this.viewWebviews.get(params.handle);
            if (view && view.visible !== !!params.visible) {
                view.visible = !!params.visible;
                view.visibilityEmitter.fire();
            }
        });
        connection.onRequest('view/resolve', (params) => this.resolveView(params.id));
    }
}

// ---------------------------------------------------------------------------

class ViewManager {
    constructor({ connection, commands, log }) {
        this.connection = connection;
        this.commands = commands;
        this.log = log;
        this.treeViews = new Map();
        this.webviews = new WebviewManager({ connection, log });
    }

    createTreeView(viewId, options) {
        if (!options || !options.treeDataProvider) {
            throw new Error(`createTreeView('${viewId}') needs a treeDataProvider`);
        }
        const existing = this.treeViews.get(viewId);
        if (existing) {
            existing.dispose();
        }
        const state = new TreeViewState(this, viewId, options);
        this.treeViews.set(viewId, state);
        this.connection.sendNotification('view/registered', {
            id: viewId,
            kind: 'tree',
            canSelectMany: !!options.canSelectMany,
            collapseAll: !!options.showCollapseAll,
        });
        const manager = this;
        const view = {
            onDidChangeSelection: state.selectionEmitter.event,
            onDidChangeVisibility: state.visibilityEmitter.event,
            onDidExpandElement: state.expandEmitter.event,
            onDidCollapseElement: state.collapseEmitter.event,
            onDidChangeCheckboxState: state.checkboxEmitter.event,
            get selection() {
                return state.selection;
            },
            get visible() {
                return state.visible;
            },
            get title() {
                return state.title;
            },
            set title(value) {
                state.title = value;
                state.sendState();
            },
            get description() {
                return state.description;
            },
            set description(value) {
                state.description = value;
                state.sendState();
            },
            get message() {
                return state.message;
            },
            set message(value) {
                state.message = value;
                state.sendState();
            },
            get badge() {
                return state.badge;
            },
            set badge(value) {
                state.badge = value;
                state.sendState();
            },
            async reveal(element, revealOptions) {
                for (const [handle, known] of state.elements) {
                    if (known.element === element) {
                        manager.connection.sendNotification('view/reveal', {
                            id: viewId,
                            handle,
                            select: !revealOptions || revealOptions.select !== false,
                            expand: revealOptions && revealOptions.expand,
                        });
                        return;
                    }
                }
            },
            dispose() {
                state.dispose();
            },
        };
        return view;
    }

    registerTreeDataProvider(viewId, provider) {
        const view = this.createTreeView(viewId, { treeDataProvider: provider });
        return new Disposable(() => view.dispose());
    }

    registerWebviewViewProvider(viewId, provider, options) {
        this.webviews.viewProviders.set(viewId, { provider, options });
        const retainContext = !!(options && options.webviewOptions && options.webviewOptions.retainContextWhenHidden);
        this.connection.sendNotification('view/registered', { id: viewId, kind: 'webview', retainContext });
        return new Disposable(() => {
            this.webviews.viewProviders.delete(viewId);
            this.connection.sendNotification('view/unregistered', { id: viewId });
        });
    }

    registerWebviewPanelSerializer(viewType, serializer) {
        this.webviews.serializers.set(viewType, serializer);
        return new Disposable(() => this.webviews.serializers.delete(viewType));
    }

    createWebviewPanel(viewType, title, showOptions, options) {
        return this.webviews.createPanel(viewType, title, showOptions, options);
    }

    install(connection) {
        this.webviews.install(connection);
        const view = (params) => this.treeViews.get(params.id);
        connection.onRequest('tree/children', async (params) => {
            const state = view(params);
            if (!state) {
                return { nodes: [], missing: true };
            }
            try {
                return { nodes: await state.children(params.handle) };
            } catch (error) {
                this.log('Extension Host', `getChildren failed in ${params.id}: ${(error && error.stack) || error}`);
                return { nodes: [], error: String((error && error.message) || error) };
            }
        });
        connection.onRequest('tree/click', async (params) => {
            const state = view(params);
            if (state) {
                await state.click(params.handle);
            }
            return null;
        });
        connection.onRequest('tree/runCommand', async (params) => {
            const state = view(params);
            if (state) {
                await state.runCommand(params.command, params.handle);
            }
            return null;
        });
        connection.onNotification('tree/select', (params) => {
            const state = view(params);
            if (state) {
                state.select(params.handles || []);
            }
        });
        connection.onNotification('tree/expand', (params) => {
            const state = view(params);
            if (state) {
                state.toggled(params.handle, true);
            }
        });
        connection.onNotification('tree/collapse', (params) => {
            const state = view(params);
            if (state) {
                state.toggled(params.handle, false);
            }
        });
        connection.onNotification('tree/visibility', (params) => {
            const state = view(params);
            if (state) {
                state.setVisible(!!params.visible);
            }
        });
    }
}

module.exports = { ViewManager, describeIcon };
