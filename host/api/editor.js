'use strict';

// vscode.TextEditor: the file in front, its selections, and the ways to change it. Glasswork
// sends the state (`editor/state`) when the tab or the selection changes; edits go back as
// WorkspaceEdits, and selection changes as `editor/setSelections`.

const types = require('./types');
const convert = require('./lspConvert');
const { Uri } = require('./uri');

const { Position, Range, Selection, EventEmitter, WorkspaceEdit, TextEdit } = types;

class TextEditorEdit {
    constructor(document) {
        this.document = document;
        this.edits = [];
    }

    replace(location, value) {
        const range = location instanceof Position ? new Range(location, location) : location;
        this.edits.push(new TextEdit(range, value));
    }

    insert(location, value) {
        this.edits.push(TextEdit.insert(location, value));
    }

    delete(location) {
        const range = location instanceof Position ? new Range(location, location) : location;
        this.edits.push(TextEdit.delete(range));
    }

    setEndOfLine() {}
}

class EditorManager {
    constructor({ connection, documents, applyEdit }) {
        this.connection = connection;
        this.documents = documents;
        this.applyEdit = applyEdit;
        this.editors = new Map(); // uri string → TextEditor
        this.activeUri = null;
        this.activeEmitter = new EventEmitter();
        this.visibleEmitter = new EventEmitter();
        this.selectionEmitter = new EventEmitter();
        this.optionsEmitter = new EventEmitter();
        this.decorationUris = new Map(); // decoration type key → uris it was applied to
        this.nextDecorationKey = 1;
    }

    // vscode.window.createTextEditorDecorationType: a named look that setDecorations applies to ranges.
    createDecorationType(options) {
        const manager = this;
        const key = `decoration-${this.nextDecorationKey++}`;
        return {
            key,
            options: options || {},
            dispose() {
                // Disposing a type takes its decorations off every file they were on.
                for (const uri of manager.decorationUris.get(key) || []) {
                    manager.connection.sendNotification('editor/decorations', { uri, key, options: {}, ranges: [] });
                }
                manager.decorationUris.delete(key);
            },
        };
    }

    noteDecorationApplied(key, uri, hasRanges) {
        if (!key) {
            return;
        }
        let uris = this.decorationUris.get(key);
        if (!uris) {
            uris = new Set();
            this.decorationUris.set(key, uris);
        }
        if (hasRanges) {
            uris.add(uri);
        } else {
            uris.delete(uri);
        }
    }

    get active() {
        return this.activeUri ? this.editors.get(this.activeUri) : undefined;
    }

    get visible() {
        const editor = this.active;
        return editor ? [editor] : [];
    }

    // Glasswork reports the front editor: its file, selections and settings. `state` is null
    // when no text file is showing (an image, a preview, nothing open).
    update(state) {
        const previous = this.active;
        if (!state) {
            if (previous) {
                this.activeUri = null;
                this.activeEmitter.fire(undefined);
                this.visibleEmitter.fire([]);
            }
            return;
        }

        const document = this.documents.get(state.uri);
        if (!document) {
            return; // the document has not reached the host yet; the next state will
        }
        let editor = this.editors.get(state.uri);
        if (!editor || editor.document !== document) {
            editor = this.createEditor(document);
            this.editors.set(state.uri, editor);
        }

        const selections = (state.selections || []).map((item) => {
            const anchor = convert.toPosition(item.anchor);
            const active = convert.toPosition(item.active);
            return new Selection(anchor, active);
        });
        const selectionsChanged = !sameSelections(editor.selections, selections);
        editor.adoptSelections(selections.length > 0 ? selections : [new Selection(new Position(0, 0), new Position(0, 0))]);
        editor.options = {
            tabSize: state.tabSize || 4,
            insertSpaces: state.insertSpaces !== false,
            cursorStyle: 1,
            lineNumbers: 1,
        };
        if (state.visibleRange) {
            editor.visibleRanges = [convert.toRange(state.visibleRange)];
        }

        const becameActive = this.activeUri !== state.uri;
        this.activeUri = state.uri;
        if (becameActive) {
            this.activeEmitter.fire(editor);
            this.visibleEmitter.fire([editor]);
        }
        if (selectionsChanged || becameActive) {
            this.selectionEmitter.fire({ textEditor: editor, selections: editor.selections, kind: undefined });
        }
    }

    forget(uriText) {
        this.editors.delete(uriText);
        if (this.activeUri === uriText) {
            this.activeUri = null;
        }
    }

    createEditor(document) {
        const manager = this;
        let current = [new Selection(new Position(0, 0), new Position(0, 0))];
        const editor = {
            document,
            visibleRanges: [new Range(0, 0, 0, 0)],
            options: { tabSize: 4, insertSpaces: true },
            viewColumn: types.ViewColumn.One,
            get selections() {
                return current;
            },
            // An extension moving the cursors: remember, and tell Glasswork.
            set selections(values) {
                current = values.length > 0 ? values : current;
                manager.connection.sendNotification('editor/setSelections', {
                    uri: document.uri.toString(),
                    selections: current.map(selectionJson),
                });
            },
            get selection() {
                return current[0];
            },
            set selection(value) {
                editor.selections = [value];
            },
            // Glasswork moved the cursors: remember without echoing it back.
            adoptSelections(values) {
                current = values.length > 0 ? values : current;
            },
            async edit(callback) {
                const builder = new TextEditorEdit(document);
                callback(builder);
                if (builder.edits.length === 0) {
                    return true;
                }
                const edit = new WorkspaceEdit();
                edit.set(document.uri, builder.edits);
                return manager.applyEdit(edit);
            },
            async insertSnippet(snippet, location) {
                // No location means "at the cursors"; a Position means an empty range there.
                const asRange = (item) => (item instanceof Position ? new Range(item, item) : item);
                const locations = Array.isArray(location) ? location : [location];
                const targets = location === undefined ? editor.selections : locations.map(asRange);
                const result = await manager.connection.sendRequest('editor/insertSnippet', {
                    uri: document.uri.toString(),
                    snippet: typeof snippet === 'string' ? snippet : snippet.value,
                    ranges: targets.map(convert.fromRange),
                });
                return !!result;
            },
            setDecorations(decorationType, ranges) {
                const list = ranges || [];
                manager.noteDecorationApplied(decorationType && decorationType.key, document.uri.toString(), list.length > 0);
                manager.connection.sendNotification('editor/decorations', {
                    uri: document.uri.toString(),
                    key: decorationType && decorationType.key,
                    options: decorationType && decorationType.options,
                    ranges: list.map((item) =>
                        item instanceof Range
                            ? { range: convert.fromRange(item) }
                            : { range: convert.fromRange(item.range), renderOptions: item.renderOptions }
                    ),
                });
            },
            revealRange(range) {
                manager.connection.sendNotification('editor/reveal', { uri: document.uri.toString(), range: convert.fromRange(range) });
            },
            show() {},
            hide() {},
        };
        return editor;
    }
}

function selectionJson(selection) {
    return { anchor: convert.fromPosition(selection.anchor), active: convert.fromPosition(selection.active) };
}

function sameSelections(first, second) {
    if (first.length !== second.length) {
        return false;
    }
    for (let index = 0; index < first.length; index++) {
        if (!first[index].anchor.isEqual(second[index].anchor) || !first[index].active.isEqual(second[index].active)) {
            return false;
        }
    }
    return true;
}

module.exports = { EditorManager };
void Uri;
