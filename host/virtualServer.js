'use strict';

// A language server that is not a program: for each language, it answers Language Server
// Protocol messages from Glasswork by calling the providers extensions registered through
// the vscode API (registerCompletionItemProvider and friends). To Glasswork's editor it is
// one more server, so every feature (completion, hover, rename, code actions…) works for
// extension-provided languages exactly as it does for clangd.

const { matchSelector, languagesOfSelector } = require('./api/documents');
const types = require('./api/types');
const convert = require('./api/lspConvert');
const { Uri } = require('./api/uri');

// What each provider kind is called in the protocol, and the capability key it switches on.
const KINDS = {
    completion: { method: 'textDocument/completion' },
    hover: { method: 'textDocument/hover' },
    signatureHelp: { method: 'textDocument/signatureHelp' },
    definition: { method: 'textDocument/definition' },
    declaration: { method: 'textDocument/declaration' },
    typeDefinition: { method: 'textDocument/typeDefinition' },
    implementation: { method: 'textDocument/implementation' },
    references: { method: 'textDocument/references' },
    documentHighlight: { method: 'textDocument/documentHighlight' },
    documentSymbol: { method: 'textDocument/documentSymbol' },
    workspaceSymbol: { method: 'workspace/symbol' },
    codeAction: { method: 'textDocument/codeAction' },
    codeLens: { method: 'textDocument/codeLens' },
    documentLink: { method: 'textDocument/documentLink' },
    documentFormatting: { method: 'textDocument/formatting' },
    documentRangeFormatting: { method: 'textDocument/rangeFormatting' },
    onTypeFormatting: { method: 'textDocument/onTypeFormatting' },
    rename: { method: 'textDocument/rename' },
    foldingRange: { method: 'textDocument/foldingRange' },
    selectionRange: { method: 'textDocument/selectionRange' },
    semanticTokens: { method: 'textDocument/semanticTokens' },
    inlayHint: { method: 'textDocument/inlayHint' },
};

class ProviderRegistry {
    constructor() {
        this.providers = [];
        this.nextId = 1;
        this.listeners = new Set();
    }

    onChange(listener) {
        this.listeners.add(listener);
    }

    register(kind, selector, provider, options) {
        const record = { id: this.nextId++, kind, selector, provider, options: options || {} };
        this.providers.push(record);
        this.changed();
        return new types.Disposable(() => {
            const index = this.providers.indexOf(record);
            if (index >= 0) {
                this.providers.splice(index, 1);
                this.changed();
            }
        });
    }

    changed() {
        for (const listener of this.listeners) {
            listener();
        }
    }

    // Providers of a kind that apply to a document, best match first.
    matching(kind, document) {
        const scored = [];
        for (const record of this.providers) {
            if (record.kind !== kind) {
                continue;
            }
            const score = matchSelector(record.selector, document);
            if (score > 0) {
                scored.push({ record, score });
            }
        }
        scored.sort((a, b) => b.score - a.score);
        return scored.map((entry) => entry.record);
    }

    // Providers that might serve some document in this language (used to register capabilities).
    forLanguage(languageId) {
        return this.providers.filter((record) => {
            const named = languagesOfSelector(record.selector);
            if (named.size === 0 || named.has('*')) {
                return true; // a pattern or scheme only: could match any language
            }
            return named.has(languageId);
        });
    }
}

class VirtualServer {
    constructor({ id, language, rootUri, registry, documents, commands, send, log }) {
        this.id = id;
        this.language = language;
        this.rootUri = rootUri;
        this.registry = registry;
        this.documents = documents;
        this.commands = commands;
        this.sendToClient = send;
        this.log = log;
        this.registered = new Map(); // provider id → protocol method it was registered under
        this.initialized = false;
        this.running = new Map(); // request id → CancellationTokenSource
        this.resolveCache = new Map();
        this.nextTag = 1;
        this.nextRequestId = 1;
        this.changeListener = () => this.syncRegistrations();
        registry.onChange(this.changeListener);
    }

    dispose() {
        this.registry.listeners.delete(this.changeListener);
        for (const source of this.running.values()) {
            source.cancel();
        }
        this.running.clear();
    }

    // ----- Messages from Glasswork -----

    async handle(message) {
        const hasMethod = typeof message.method === 'string';
        const hasId = message.id !== undefined && message.id !== null;
        if (!hasMethod) {
            return; // an answer to one of our requests (registerCapability); nothing to do
        }
        if (!hasId) {
            this.notification(message.method, message.params || {});
            return;
        }
        const source = new types.CancellationTokenSource();
        this.running.set(message.id, source);
        try {
            const result = await this.request(message.method, message.params || {}, source.token);
            this.sendToClient({ jsonrpc: '2.0', id: message.id, result: result === undefined ? null : result });
        } catch (error) {
            this.log(`${this.language}: ${message.method} failed: ${(error && error.stack) || error}`);
            this.sendToClient({ jsonrpc: '2.0', id: message.id, error: { code: -32603, message: (error && error.message) || String(error) } });
        } finally {
            this.running.delete(message.id);
            source.dispose();
        }
    }

    notification(method, params) {
        if (method === '$/cancelRequest') {
            const source = this.running.get(params.id);
            if (source) {
                source.cancel();
            }
        } else if (method === 'initialized') {
            this.initialized = true;
            this.syncRegistrations();
        } else if (method === 'textDocument/didOpen') {
            const item = params.textDocument;
            this.documents.open(item.uri, item.languageId, item.version, item.text);
        } else if (method === 'textDocument/didChange') {
            this.documents.change(params.textDocument.uri, params.textDocument.version, params.contentChanges || []);
        } else if (method === 'textDocument/didSave') {
            this.documents.save(params.textDocument.uri);
        } else if (method === 'textDocument/didClose') {
            this.documents.close(params.textDocument.uri);
        }
    }

    async request(method, params, token) {
        switch (method) {
            case 'initialize':
                return {
                    capabilities: { textDocumentSync: { openClose: true, change: 2, save: {} } },
                    serverInfo: { name: 'Glasswork extension host' },
                };
            case 'shutdown':
                return null;
            case 'textDocument/completion':
                return this.completion(params, token);
            case 'completionItem/resolve':
                return this.resolveCompletion(params, token);
            case 'textDocument/hover':
                return this.hover(params, token);
            case 'textDocument/signatureHelp':
                return this.signatureHelp(params, token);
            case 'textDocument/definition':
                return this.locations('definition', 'provideDefinition', params, token);
            case 'textDocument/declaration':
                return this.locations('declaration', 'provideDeclaration', params, token);
            case 'textDocument/typeDefinition':
                return this.locations('typeDefinition', 'provideTypeDefinition', params, token);
            case 'textDocument/implementation':
                return this.locations('implementation', 'provideImplementation', params, token);
            case 'textDocument/references':
                return this.references(params, token);
            case 'textDocument/documentHighlight':
                return this.documentHighlight(params, token);
            case 'textDocument/documentSymbol':
                return this.documentSymbol(params, token);
            case 'workspace/symbol':
                return this.workspaceSymbol(params, token);
            case 'textDocument/codeAction':
                return this.codeAction(params, token);
            case 'codeAction/resolve':
                return this.resolveCodeAction(params, token);
            case 'textDocument/codeLens':
                return this.codeLens(params, token);
            case 'codeLens/resolve':
                return this.resolveCodeLens(params, token);
            case 'textDocument/documentLink':
                return this.documentLink(params, token);
            case 'textDocument/formatting':
                return this.formatting(params, token, 'documentFormatting', 'provideDocumentFormattingEdits');
            case 'textDocument/rangeFormatting':
                return this.rangeFormatting(params, token);
            case 'textDocument/onTypeFormatting':
                return this.onTypeFormatting(params, token);
            case 'textDocument/prepareRename':
                return this.prepareRename(params, token);
            case 'textDocument/rename':
                return this.rename(params, token);
            case 'textDocument/foldingRange':
                return this.foldingRange(params, token);
            case 'textDocument/selectionRange':
                return this.selectionRange(params, token);
            case 'textDocument/semanticTokens/full':
                return this.semanticTokens(params, token);
            case 'textDocument/inlayHint':
                return this.inlayHint(params, token);
            case 'workspace/executeCommand':
                return this.executeCommand(params);
            default:
                throw new Error(`Method not found: ${method}`);
        }
    }

    // ----- Capabilities -----

    // Tells Glasswork what the providers can do, as dynamic registrations. Run again
    // whenever an extension registers (or disposes) a provider.
    syncRegistrations() {
        if (!this.initialized) {
            return;
        }
        const wanted = new Map();
        for (const record of this.registry.forLanguage(this.language)) {
            wanted.set(record.id, record);
        }

        const registrations = [];
        for (const record of wanted.values()) {
            if (this.registered.has(record.id)) {
                continue;
            }
            const registration = this.registrationFor(record);
            if (registration) {
                registrations.push(registration);
                this.registered.set(record.id, registration.method);
            }
        }
        if (registrations.length > 0) {
            this.sendToClient({
                jsonrpc: '2.0',
                id: `host-${this.nextRequestId++}`,
                method: 'client/registerCapability',
                params: { registrations },
            });
        }

        // Providers that were disposed: take their capabilities back.
        const unregisterations = [];
        for (const [id, method] of Array.from(this.registered)) {
            if (!wanted.has(id)) {
                this.registered.delete(id);
                unregisterations.push({ id: `p${id}`, method });
            }
        }
        if (unregisterations.length > 0) {
            this.sendToClient({
                jsonrpc: '2.0',
                id: `host-${this.nextRequestId++}`,
                method: 'client/unregisterCapability',
                params: { unregisterations },
            });
        }
    }

    registrationFor(record) {
        const info = KINDS[record.kind];
        if (!info) {
            return null;
        }
        const provider = record.provider;
        const options = record.options;
        let registerOptions = {};
        let method = info.method;
        switch (record.kind) {
            case 'completion':
                registerOptions = {
                    triggerCharacters: options.triggerCharacters || [],
                    resolveProvider: typeof provider.resolveCompletionItem === 'function',
                };
                break;
            case 'signatureHelp':
                registerOptions = {
                    triggerCharacters: options.triggerCharacters || (options.metadata && options.metadata.triggerCharacters) || [],
                    retriggerCharacters: (options.metadata && options.metadata.retriggerCharacters) || [],
                };
                break;
            case 'codeAction':
                registerOptions = {
                    codeActionKinds: ((options.metadata && options.metadata.providedCodeActionKinds) || []).map((kind) => kind.value),
                    resolveProvider: typeof provider.resolveCodeAction === 'function',
                };
                break;
            case 'codeLens':
                registerOptions = { resolveProvider: typeof provider.resolveCodeLens === 'function' };
                break;
            case 'rename':
                registerOptions = { prepareProvider: typeof provider.prepareRename === 'function' };
                break;
            case 'onTypeFormatting':
                registerOptions = {
                    firstTriggerCharacter: options.firstTriggerCharacter,
                    moreTriggerCharacter: options.moreTriggerCharacter || [],
                };
                break;
            case 'semanticTokens':
                method = 'textDocument/semanticTokens';
                registerOptions = {
                    legend: { tokenTypes: options.legend.tokenTypes, tokenModifiers: options.legend.tokenModifiers },
                    full: typeof provider.provideDocumentSemanticTokens === 'function',
                    range: typeof provider.provideDocumentRangeSemanticTokens === 'function',
                };
                break;
            case 'inlayHint':
                registerOptions = { resolveProvider: false };
                break;
            default:
                break;
        }
        return { id: `p${record.id}`, method, registerOptions };
    }

    // ----- Helpers -----

    documentFor(params) {
        const uri = params.textDocument.uri;
        const document = this.documents.get(uri);
        if (!document) {
            throw new Error(`Document is not open: ${uri}`);
        }
        return document;
    }

    providersFor(kind, document) {
        return this.registry.matching(kind, document).map((record) => record.provider);
    }

    firstProvider(kind, document) {
        const list = this.providersFor(kind, document);
        return list.length > 0 ? list[0] : undefined;
    }

    remember(entry) {
        const tag = this.nextTag++;
        this.resolveCache.set(tag, entry);
        if (this.resolveCache.size > 4000) {
            const oldest = this.resolveCache.keys().next().value;
            this.resolveCache.delete(oldest);
        }
        return tag;
    }

    recall(item) {
        if (!item || !item.data || item.data.__gwHost === undefined) {
            return undefined;
        }
        return this.resolveCache.get(item.data.__gwHost);
    }

    // ----- Features -----

    async completion(params, token) {
        const document = this.documentFor(params);
        const position = convert.toPosition(params.position);
        const context = params.context || {};
        const triggerKinds = { 1: types.CompletionTriggerKind.Invoke, 2: types.CompletionTriggerKind.TriggerCharacter, 3: types.CompletionTriggerKind.TriggerForIncompleteCompletions };
        const vscodeContext = {
            triggerKind: triggerKinds[context.triggerKind || 1],
            triggerCharacter: context.triggerCharacter,
        };

        const items = [];
        let incomplete = false;
        for (const provider of this.providersFor('completion', document)) {
            if (typeof provider.provideCompletionItems !== 'function') {
                continue;
            }
            const result = await provider.provideCompletionItems(document, position, token, vscodeContext);
            if (!result) {
                continue;
            }
            const list = Array.isArray(result) ? result : result.items || [];
            if (!Array.isArray(result) && result.isIncomplete) {
                incomplete = true;
            }
            for (const item of list) {
                const tag = this.remember({ provider, item });
                items.push(convert.fromCompletionItem(item, tag));
            }
        }
        return { isIncomplete: incomplete, items };
    }

    async resolveCompletion(item, token) {
        const entry = this.recall(item);
        if (!entry || typeof entry.provider.resolveCompletionItem !== 'function') {
            return item;
        }
        const resolved = (await entry.provider.resolveCompletionItem(entry.item, token)) || entry.item;
        return convert.fromCompletionItem(resolved, item.data.__gwHost);
    }

    async hover(params, token) {
        const document = this.documentFor(params);
        const position = convert.toPosition(params.position);
        const parts = [];
        let range;
        for (const provider of this.providersFor('hover', document)) {
            const hover = await provider.provideHover(document, position, token);
            if (!hover) {
                continue;
            }
            const converted = convert.fromHover(hover);
            if (converted) {
                parts.push(converted.contents.value);
                range = range || converted.range;
            }
        }
        if (parts.length === 0) {
            return null;
        }
        return { contents: { kind: 'markdown', value: parts.join('\n\n---\n\n') }, range };
    }

    async signatureHelp(params, token) {
        const document = this.documentFor(params);
        const provider = this.firstProvider('signatureHelp', document);
        if (!provider) {
            return null;
        }
        const context = params.context || {};
        const result = await provider.provideSignatureHelp(document, convert.toPosition(params.position), token, {
            triggerKind: context.triggerKind || types.SignatureHelpTriggerKind.Invoke,
            triggerCharacter: context.triggerCharacter,
            isRetrigger: !!context.isRetrigger,
            activeSignatureHelp: undefined,
        });
        return convert.fromSignatureHelp(result);
    }

    async locations(kind, methodName, params, token) {
        const document = this.documentFor(params);
        const position = convert.toPosition(params.position);
        const all = [];
        for (const provider of this.providersFor(kind, document)) {
            if (typeof provider[methodName] !== 'function') {
                continue;
            }
            const result = await provider[methodName](document, position, token);
            const converted = convert.fromLocations(result);
            if (converted) {
                all.push(...converted);
            }
        }
        return all.length > 0 ? all : null;
    }

    async references(params, token) {
        const document = this.documentFor(params);
        const position = convert.toPosition(params.position);
        const context = { includeDeclaration: !!(params.context && params.context.includeDeclaration) };
        const all = [];
        for (const provider of this.providersFor('references', document)) {
            const result = await provider.provideReferences(document, position, context, token);
            const converted = convert.fromLocations(result);
            if (converted) {
                all.push(...converted);
            }
        }
        return all;
    }

    async documentHighlight(params, token) {
        const document = this.documentFor(params);
        const position = convert.toPosition(params.position);
        const all = [];
        for (const provider of this.providersFor('documentHighlight', document)) {
            const result = await provider.provideDocumentHighlights(document, position, token);
            for (const highlight of result || []) {
                all.push(convert.fromDocumentHighlight(highlight));
            }
        }
        return all;
    }

    async documentSymbol(params, token) {
        const document = this.documentFor(params);
        const all = [];
        for (const provider of this.providersFor('documentSymbol', document)) {
            const result = await provider.provideDocumentSymbols(document, token);
            for (const symbol of result || []) {
                all.push(convert.fromDocumentSymbol(symbol));
            }
        }
        return all;
    }

    async workspaceSymbol(params, token) {
        const all = [];
        for (const record of this.registry.providers) {
            if (record.kind !== 'workspaceSymbol') {
                continue;
            }
            const result = await record.provider.provideWorkspaceSymbols(params.query || '', token);
            for (const symbol of result || []) {
                all.push(convert.fromDocumentSymbol(symbol));
            }
        }
        return all;
    }

    async codeAction(params, token) {
        const document = this.documentFor(params);
        const range = convert.toRange(params.range);
        const context = convert.toCodeActionContext(params.context || {});
        const actions = [];
        for (const provider of this.providersFor('codeAction', document)) {
            const result = await provider.provideCodeActions(document, range, context, token);
            for (const item of result || []) {
                const tag = this.remember({ provider, item });
                actions.push(convert.fromCodeAction(item, tag));
            }
        }
        return actions;
    }

    async resolveCodeAction(action, token) {
        const entry = this.recall(action);
        if (!entry || typeof entry.provider.resolveCodeAction !== 'function') {
            return action;
        }
        const resolved = (await entry.provider.resolveCodeAction(entry.item, token)) || entry.item;
        return convert.fromCodeAction(resolved, action.data.__gwHost);
    }

    async codeLens(params, token) {
        const document = this.documentFor(params);
        const all = [];
        for (const provider of this.providersFor('codeLens', document)) {
            const result = await provider.provideCodeLenses(document, token);
            for (const lens of result || []) {
                const tag = this.remember({ provider, item: lens });
                all.push(convert.fromCodeLens(lens, tag));
            }
        }
        return all;
    }

    async resolveCodeLens(lens, token) {
        const entry = this.recall(lens);
        if (!entry || typeof entry.provider.resolveCodeLens !== 'function') {
            return lens;
        }
        const resolved = (await entry.provider.resolveCodeLens(entry.item, token)) || entry.item;
        return convert.fromCodeLens(resolved, lens.data.__gwHost);
    }

    async documentLink(params, token) {
        const document = this.documentFor(params);
        const all = [];
        for (const provider of this.providersFor('documentLink', document)) {
            const result = await provider.provideDocumentLinks(document, token);
            for (const link of result || []) {
                all.push(convert.fromDocumentLink(link));
            }
        }
        return all;
    }

    async formatting(params, token, kind, methodName) {
        const document = this.documentFor(params);
        const provider = this.firstProvider(kind, document);
        if (!provider) {
            return null;
        }
        const edits = await provider[methodName](document, params.options || {}, token);
        return (edits || []).map(convert.fromTextEdit);
    }

    async rangeFormatting(params, token) {
        const document = this.documentFor(params);
        const provider = this.firstProvider('documentRangeFormatting', document);
        if (!provider) {
            return null;
        }
        const edits = await provider.provideDocumentRangeFormattingEdits(document, convert.toRange(params.range), params.options || {}, token);
        return (edits || []).map(convert.fromTextEdit);
    }

    async onTypeFormatting(params, token) {
        const document = this.documentFor(params);
        const provider = this.firstProvider('onTypeFormatting', document);
        if (!provider) {
            return null;
        }
        const edits = await provider.provideOnTypeFormattingEdits(document, convert.toPosition(params.position), params.ch, params.options || {}, token);
        return (edits || []).map(convert.fromTextEdit);
    }

    async prepareRename(params, token) {
        const document = this.documentFor(params);
        const provider = this.firstProvider('rename', document);
        if (!provider || typeof provider.prepareRename !== 'function') {
            return null;
        }
        const result = await provider.prepareRename(document, convert.toPosition(params.position), token);
        if (!result) {
            return null;
        }
        if (result.range) {
            return { range: convert.fromRange(result.range), placeholder: result.placeholder };
        }
        return convert.fromRange(result);
    }

    async rename(params, token) {
        const document = this.documentFor(params);
        const provider = this.firstProvider('rename', document);
        if (!provider) {
            return null;
        }
        const edit = await provider.provideRenameEdits(document, convert.toPosition(params.position), params.newName, token);
        return edit ? convert.fromWorkspaceEdit(edit) : null;
    }

    async foldingRange(params, token) {
        const document = this.documentFor(params);
        const all = [];
        for (const provider of this.providersFor('foldingRange', document)) {
            const result = await provider.provideFoldingRanges(document, {}, token);
            for (const range of result || []) {
                all.push(convert.fromFoldingRange(range));
            }
        }
        return all;
    }

    async selectionRange(params, token) {
        const document = this.documentFor(params);
        const provider = this.firstProvider('selectionRange', document);
        if (!provider) {
            return null;
        }
        const positions = (params.positions || []).map(convert.toPosition);
        const result = await provider.provideSelectionRanges(document, positions, token);
        return (result || []).map(convert.fromSelectionRange);
    }

    async semanticTokens(params, token) {
        const document = this.documentFor(params);
        const provider = this.firstProvider('semanticTokens', document);
        if (!provider || typeof provider.provideDocumentSemanticTokens !== 'function') {
            return null;
        }
        const result = await provider.provideDocumentSemanticTokens(document, token);
        if (!result) {
            return null;
        }
        return { resultId: result.resultId, data: Array.from(result.data) };
    }

    async inlayHint(params, token) {
        const document = this.documentFor(params);
        const range = convert.toRange(params.range);
        const all = [];
        for (const provider of this.providersFor('inlayHint', document)) {
            const result = await provider.provideInlayHints(document, range, token);
            for (const hint of result || []) {
                all.push(convert.fromInlayHint(hint));
            }
        }
        return all;
    }

    async executeCommand(params) {
        return this.commands.execute(params.command, ...(params.arguments || []));
    }
}

module.exports = { VirtualServer, ProviderRegistry, KINDS, Uri };
