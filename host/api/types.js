'use strict';

// The value types of the vscode API: positions, ranges, edits, diagnostics and the enums
// extensions compare against. They follow VS Code's behaviour closely, because extensions
// call methods like Range.contains or Position.translate and rely on the exact results.

const { Uri } = require('./uri');

// ---------------------------------------------------------------------------
// Disposables and events

class Disposable {
    constructor(callOnDispose) {
        this.callOnDispose = callOnDispose;
    }

    static from(...disposables) {
        return new Disposable(() => {
            for (const disposable of disposables) {
                if (disposable && typeof disposable.dispose === 'function') {
                    disposable.dispose();
                }
            }
        });
    }

    dispose() {
        if (this.callOnDispose) {
            const callback = this.callOnDispose;
            this.callOnDispose = undefined;
            callback();
        }
    }
}

class EventEmitter {
    constructor() {
        this.listeners = new Set();
        this.event = (listener, thisArgument, disposables) => {
            const bound = thisArgument ? listener.bind(thisArgument) : listener;
            this.listeners.add(bound);
            const subscription = new Disposable(() => this.listeners.delete(bound));
            if (Array.isArray(disposables)) {
                disposables.push(subscription);
            }
            return subscription;
        };
    }

    fire(value) {
        for (const listener of Array.from(this.listeners)) {
            try {
                listener(value);
            } catch (error) {
                process.stderr.write(`[host] event listener failed: ${(error && error.stack) || error}\n`);
            }
        }
    }

    dispose() {
        this.listeners.clear();
    }
}

class CancellationTokenSource {
    constructor() {
        this.emitter = new EventEmitter();
        this.cancelled = false;
        const source = this;
        this.token = {
            get isCancellationRequested() {
                return source.cancelled;
            },
            onCancellationRequested: this.emitter.event,
        };
    }

    cancel() {
        if (!this.cancelled) {
            this.cancelled = true;
            this.emitter.fire();
        }
    }

    dispose() {
        this.emitter.dispose();
    }
}

const CancellationToken = {
    None: { isCancellationRequested: false, onCancellationRequested: () => new Disposable(() => {}) },
    Cancelled: { isCancellationRequested: true, onCancellationRequested: () => new Disposable(() => {}) },
};

class CancellationError extends Error {
    constructor() {
        super('Canceled');
        this.name = 'Canceled';
    }
}

// ---------------------------------------------------------------------------
// Positions and ranges

class Position {
    constructor(line, character) {
        if (line < 0) {
            throw new Error('line must be non-negative');
        }
        if (character < 0) {
            throw new Error('character must be non-negative');
        }
        this.line = line;
        this.character = character;
    }

    isBefore(other) {
        return this.compareTo(other) < 0;
    }

    isBeforeOrEqual(other) {
        return this.compareTo(other) <= 0;
    }

    isAfter(other) {
        return this.compareTo(other) > 0;
    }

    isAfterOrEqual(other) {
        return this.compareTo(other) >= 0;
    }

    isEqual(other) {
        return this.compareTo(other) === 0;
    }

    compareTo(other) {
        if (this.line !== other.line) {
            return this.line < other.line ? -1 : 1;
        }
        if (this.character !== other.character) {
            return this.character < other.character ? -1 : 1;
        }
        return 0;
    }

    translate(lineDeltaOrChange, characterDelta) {
        let lineDelta = lineDeltaOrChange;
        let delta = characterDelta;
        if (typeof lineDeltaOrChange === 'object' && lineDeltaOrChange !== null) {
            lineDelta = lineDeltaOrChange.lineDelta;
            delta = lineDeltaOrChange.characterDelta;
        }
        return new Position(this.line + (lineDelta || 0), this.character + (delta || 0));
    }

    with(lineOrChange, character) {
        let line = this.line;
        let newCharacter = this.character;
        if (typeof lineOrChange === 'object' && lineOrChange !== null) {
            if (lineOrChange.line !== undefined) {
                line = lineOrChange.line;
            }
            if (lineOrChange.character !== undefined) {
                newCharacter = lineOrChange.character;
            }
        } else {
            if (lineOrChange !== undefined) {
                line = lineOrChange;
            }
            if (character !== undefined) {
                newCharacter = character;
            }
        }
        return new Position(line, newCharacter);
    }

    toJSON() {
        return { line: this.line, character: this.character };
    }
}

class Range {
    constructor(startOrLine, endOrCharacter, endLine, endCharacter) {
        let start;
        let end;
        if (typeof startOrLine === 'number') {
            start = new Position(startOrLine, endOrCharacter);
            end = new Position(endLine, endCharacter);
        } else {
            start = startOrLine;
            end = endOrCharacter;
        }
        if (start.isAfter(end)) {
            [start, end] = [end, start];
        }
        this.start = start;
        this.end = end;
    }

    get isEmpty() {
        return this.start.isEqual(this.end);
    }

    get isSingleLine() {
        return this.start.line === this.end.line;
    }

    contains(positionOrRange) {
        if (positionOrRange instanceof Range) {
            return this.contains(positionOrRange.start) && this.contains(positionOrRange.end);
        }
        return positionOrRange.isAfterOrEqual(this.start) && positionOrRange.isBeforeOrEqual(this.end);
    }

    isEqual(other) {
        return this.start.isEqual(other.start) && this.end.isEqual(other.end);
    }

    intersection(other) {
        const start = this.start.isAfter(other.start) ? this.start : other.start;
        const end = this.end.isBefore(other.end) ? this.end : other.end;
        if (start.isAfter(end)) {
            return undefined;
        }
        return new Range(start, end);
    }

    union(other) {
        const start = this.start.isBefore(other.start) ? this.start : other.start;
        const end = this.end.isAfter(other.end) ? this.end : other.end;
        return new Range(start, end);
    }

    with(startOrChange, end) {
        let newStart = this.start;
        let newEnd = this.end;
        // `with` takes a Position as the new start, or a change object like `{ end: position }`.
        const isPosition = startOrChange && startOrChange.start === undefined && startOrChange.end === undefined && startOrChange.line !== undefined;
        const isChange = startOrChange && (startOrChange.start !== undefined || startOrChange.end !== undefined) && !(startOrChange instanceof Range && end);
        if (isPosition) {
            newStart = startOrChange;
            newEnd = end || this.end;
        } else if (isChange) {
            if (startOrChange.start !== undefined) {
                newStart = startOrChange.start;
            }
            if (startOrChange.end !== undefined) {
                newEnd = startOrChange.end;
            }
        } else if (startOrChange) {
            newStart = startOrChange;
            if (end) {
                newEnd = end;
            }
        }
        return new Range(newStart, newEnd);
    }

    toJSON() {
        return [this.start, this.end];
    }
}

class Selection extends Range {
    constructor(anchorOrLine, activeOrCharacter, activeLine, activeCharacter) {
        let anchor;
        let active;
        if (typeof anchorOrLine === 'number') {
            anchor = new Position(anchorOrLine, activeOrCharacter);
            active = new Position(activeLine, activeCharacter);
        } else {
            anchor = anchorOrLine;
            active = activeOrCharacter;
        }
        super(anchor, active);
        this.anchor = anchor;
        this.active = active;
    }

    get isReversed() {
        return this.anchor.isAfter(this.active);
    }
}

class Location {
    constructor(uri, rangeOrPosition) {
        this.uri = uri;
        if (rangeOrPosition instanceof Range) {
            this.range = rangeOrPosition;
        } else if (rangeOrPosition instanceof Position) {
            this.range = new Range(rangeOrPosition, rangeOrPosition);
        }
    }
}

// ---------------------------------------------------------------------------
// Edits

class TextEdit {
    constructor(range, newText) {
        this.range = range;
        this.newText = newText;
    }

    static replace(range, newText) {
        return new TextEdit(range, newText);
    }

    static insert(position, newText) {
        return new TextEdit(new Range(position, position), newText);
    }

    static delete(range) {
        return new TextEdit(range, '');
    }

    static setEndOfLine() {
        return new TextEdit(new Range(new Position(0, 0), new Position(0, 0)), '');
    }
}

class SnippetString {
    constructor(value) {
        this.value = value || '';
    }

    appendText(text) {
        this.value += text.replace(/[\\$}]/g, '\\$&');
        return this;
    }

    appendTabstop(number) {
        this.value += number === undefined ? '$0' : `$${number}`;
        return this;
    }

    appendPlaceholder(value, number) {
        let text = value;
        if (typeof value === 'function') {
            // A function builds the placeholder's content with a nested snippet.
            const inner = new SnippetString();
            value(inner);
            text = inner.value;
        }
        this.value += `\${${number === undefined ? 1 : number}:${text}}`;
        return this;
    }

    appendChoice(values, number) {
        this.value += `\${${number === undefined ? 1 : number}|${values.join(',')}|}`;
        return this;
    }

    appendVariable(name, defaultValue) {
        this.value += defaultValue === undefined ? `\${${name}}` : `\${${name}:${defaultValue}}`;
        return this;
    }
}

class WorkspaceEdit {
    constructor() {
        this.entries = []; // {uri, edits: TextEdit[]} plus file operations
        this.fileOperations = [];
    }

    get size() {
        return this.entries.reduce((total, entry) => total + entry.edits.length, 0) + this.fileOperations.length;
    }

    entriesFor(uri) {
        const key = uri.toString();
        let entry = this.entries.find((candidate) => candidate.uri.toString() === key);
        if (!entry) {
            entry = { uri, edits: [] };
            this.entries.push(entry);
        }
        return entry;
    }

    replace(uri, range, newText) {
        this.entriesFor(uri).edits.push(new TextEdit(range, newText));
    }

    insert(uri, position, newText) {
        this.entriesFor(uri).edits.push(TextEdit.insert(position, newText));
    }

    delete(uri, range) {
        this.entriesFor(uri).edits.push(TextEdit.delete(range));
    }

    has(uri) {
        return this.entries.some((entry) => entry.uri.toString() === uri.toString());
    }

    set(uri, edits) {
        const entry = this.entriesFor(uri);
        entry.edits = edits.slice();
    }

    get(uri) {
        const entry = this.entries.find((candidate) => candidate.uri.toString() === uri.toString());
        return entry ? entry.edits : [];
    }

    createFile(uri, options) {
        this.fileOperations.push({ kind: 'create', uri, options });
    }

    deleteFile(uri, options) {
        this.fileOperations.push({ kind: 'delete', uri, options });
    }

    renameFile(oldUri, newUri, options) {
        this.fileOperations.push({ kind: 'rename', oldUri, newUri, options });
    }

    // [uri, edits] pairs, as VS Code returns them.
    all() {
        return this.entries.map((entry) => [entry.uri, entry.edits]);
    }
}

class MarkdownString {
    constructor(value, supportThemeIcons) {
        this.value = value || '';
        this.isTrusted = undefined;
        this.supportThemeIcons = supportThemeIcons;
        this.supportHtml = false;
    }

    appendText(text) {
        this.value += text.replace(/[\\`*_{}[\]()#+\-.!|<>]/g, '\\$&');
        return this;
    }

    appendMarkdown(text) {
        this.value += text;
        return this;
    }

    appendCodeblock(code, language) {
        this.value += '\n```' + (language || '') + '\n' + code + '\n```\n';
        return this;
    }
}

class ThemeColor {
    constructor(id) {
        this.id = id;
    }
}

class ThemeIcon {
    constructor(id, color) {
        this.id = id;
        this.color = color;
    }
}
ThemeIcon.File = new ThemeIcon('file');
ThemeIcon.Folder = new ThemeIcon('folder');

// ---------------------------------------------------------------------------
// Diagnostics

const DiagnosticSeverity = { Error: 0, Warning: 1, Information: 2, Hint: 3, 0: 'Error', 1: 'Warning', 2: 'Information', 3: 'Hint' };
const DiagnosticTag = { Unnecessary: 1, Deprecated: 2, 1: 'Unnecessary', 2: 'Deprecated' };

class Diagnostic {
    constructor(range, message, severity) {
        this.range = range;
        this.message = message;
        this.severity = severity === undefined ? DiagnosticSeverity.Error : severity;
        this.source = undefined;
        this.code = undefined;
        this.tags = undefined;
        this.relatedInformation = undefined;
    }
}

class DiagnosticRelatedInformation {
    constructor(location, message) {
        this.location = location;
        this.message = message;
    }
}

// ---------------------------------------------------------------------------
// Language feature results

const CompletionItemKind = {
    Text: 0, Method: 1, Function: 2, Constructor: 3, Field: 4, Variable: 5, Class: 6, Interface: 7, Module: 8,
    Property: 9, Unit: 10, Value: 11, Enum: 12, Keyword: 13, Snippet: 14, Color: 15, File: 16, Reference: 17,
    Folder: 18, EnumMember: 19, Constant: 20, Struct: 21, Event: 22, Operator: 23, TypeParameter: 24, User: 25, Issue: 26,
};
const CompletionItemTag = { Deprecated: 1 };
const CompletionTriggerKind = { Invoke: 0, TriggerCharacter: 1, TriggerForIncompleteCompletions: 2 };

class CompletionItem {
    constructor(label, kind) {
        this.label = label;
        this.kind = kind;
    }
}

class CompletionList {
    constructor(items, isIncomplete) {
        this.items = items || [];
        this.isIncomplete = !!isIncomplete;
    }
}

class Hover {
    constructor(contents, range) {
        this.contents = Array.isArray(contents) ? contents : [contents];
        this.range = range;
    }
}

const SymbolKind = {
    File: 0, Module: 1, Namespace: 2, Package: 3, Class: 4, Method: 5, Property: 6, Field: 7, Constructor: 8, Enum: 9,
    Interface: 10, Function: 11, Variable: 12, Constant: 13, String: 14, Number: 15, Boolean: 16, Array: 17, Object: 18,
    Key: 19, Null: 20, EnumMember: 21, Struct: 22, Event: 23, Operator: 24, TypeParameter: 25,
};
const SymbolTag = { Deprecated: 1 };

class SymbolInformation {
    constructor(name, kind, containerNameOrRange, locationOrUri, range) {
        this.name = name;
        this.kind = kind;
        if (typeof containerNameOrRange === 'string') {
            this.containerName = containerNameOrRange;
            this.location = locationOrUri instanceof Location ? locationOrUri : new Location(locationOrUri, range);
        } else {
            this.containerName = '';
            this.location = new Location(locationOrUri, containerNameOrRange);
        }
    }
}

class DocumentSymbol {
    constructor(name, detail, kind, range, selectionRange) {
        this.name = name;
        this.detail = detail;
        this.kind = kind;
        this.range = range;
        this.selectionRange = selectionRange;
        this.children = [];
    }
}

class ParameterInformation {
    constructor(label, documentation) {
        this.label = label;
        this.documentation = documentation;
    }
}

class SignatureInformation {
    constructor(label, documentation) {
        this.label = label;
        this.documentation = documentation;
        this.parameters = [];
    }
}

class SignatureHelp {
    constructor() {
        this.signatures = [];
        this.activeSignature = 0;
        this.activeParameter = 0;
    }
}
const SignatureHelpTriggerKind = { Invoke: 1, TriggerCharacter: 2, ContentChange: 3 };

const CodeActionKindValues = {};
class CodeActionKind {
    constructor(value) {
        this.value = value;
    }

    append(part) {
        return new CodeActionKind(this.value ? this.value + '.' + part : part);
    }

    contains(other) {
        return other.value === this.value || other.value.startsWith(this.value + '.');
    }

    intersects(other) {
        return this.contains(other) || other.contains(this);
    }
}
CodeActionKind.Empty = new CodeActionKind('');
CodeActionKind.QuickFix = new CodeActionKind('quickfix');
CodeActionKind.Refactor = new CodeActionKind('refactor');
CodeActionKind.RefactorExtract = new CodeActionKind('refactor.extract');
CodeActionKind.RefactorInline = new CodeActionKind('refactor.inline');
CodeActionKind.RefactorMove = new CodeActionKind('refactor.move');
CodeActionKind.RefactorRewrite = new CodeActionKind('refactor.rewrite');
CodeActionKind.Source = new CodeActionKind('source');
CodeActionKind.SourceOrganizeImports = new CodeActionKind('source.organizeImports');
CodeActionKind.SourceFixAll = new CodeActionKind('source.fixAll');
CodeActionKind.Notebook = new CodeActionKind('notebook');
void CodeActionKindValues;

const CodeActionTriggerKind = { Invoke: 1, Automatic: 2 };

class CodeAction {
    constructor(title, kind) {
        this.title = title;
        this.kind = kind;
    }
}

class CodeLens {
    constructor(range, command) {
        this.range = range;
        this.command = command;
        this.isResolved = !!command;
    }
}

class FoldingRange {
    constructor(start, end, kind) {
        this.start = start;
        this.end = end;
        this.kind = kind;
    }
}
const FoldingRangeKind = { Comment: 1, Imports: 2, Region: 3 };

class DocumentLink {
    constructor(range, target) {
        this.range = range;
        this.target = target;
    }
}

class SelectionRange {
    constructor(range, parent) {
        this.range = range;
        this.parent = parent;
    }
}

class InlayHint {
    constructor(position, label, kind) {
        this.position = position;
        this.label = label;
        this.kind = kind;
    }
}
const InlayHintKind = { Type: 1, Parameter: 2 };

class InlayHintLabelPart {
    constructor(value) {
        this.value = value;
    }
}

class Color {
    constructor(red, green, blue, alpha) {
        this.red = red;
        this.green = green;
        this.blue = blue;
        this.alpha = alpha;
    }
}

class ColorInformation {
    constructor(range, color) {
        this.range = range;
        this.color = color;
    }
}

class ColorPresentation {
    constructor(label) {
        this.label = label;
    }
}

class DocumentHighlight {
    constructor(range, kind) {
        this.range = range;
        this.kind = kind === undefined ? 0 : kind;
    }
}
const DocumentHighlightKind = { Text: 0, Read: 1, Write: 2 };

class SemanticTokensLegend {
    constructor(tokenTypes, tokenModifiers) {
        this.tokenTypes = tokenTypes;
        this.tokenModifiers = tokenModifiers || [];
    }
}

class SemanticTokens {
    constructor(data, resultId) {
        this.data = data;
        this.resultId = resultId;
    }
}

class SemanticTokensBuilder {
    constructor(legend) {
        this.legend = legend;
        this.tokens = [];
        this.previousLine = 0;
        this.previousStart = 0;
        this.data = [];
    }

    push(lineOrRange, startOrType, lengthOrModifiers, tokenType, tokenModifiers) {
        let line;
        let start;
        let length;
        let type;
        let modifiers;
        if (lineOrRange instanceof Range) {
            line = lineOrRange.start.line;
            start = lineOrRange.start.character;
            length = lineOrRange.end.character - lineOrRange.start.character;
            type = startOrType;
            modifiers = lengthOrModifiers;
        } else {
            line = lineOrRange;
            start = startOrType;
            length = lengthOrModifiers;
            type = tokenType;
            modifiers = tokenModifiers;
        }
        let typeIndex = type || 0;
        if (typeof type === 'string' && this.legend) {
            typeIndex = Math.max(0, this.legend.tokenTypes.indexOf(type));  // an unknown name becomes the first type
        }
        let modifierBits = 0;
        if (Array.isArray(modifiers) && this.legend) {
            for (const modifier of modifiers) {
                const index = this.legend.tokenModifiers.indexOf(modifier);
                if (index >= 0) {
                    modifierBits |= 1 << index;
                }
            }
        } else if (typeof modifiers === 'number') {
            modifierBits = modifiers;
        }
        const deltaLine = line - this.previousLine;
        const deltaStart = deltaLine === 0 ? start - this.previousStart : start;
        this.data.push(deltaLine, deltaStart, length, typeIndex, modifierBits);
        this.previousLine = line;
        this.previousStart = start;
    }

    build(resultId) {
        return new SemanticTokens(new Uint32Array(this.data), resultId);
    }
}

// ---------------------------------------------------------------------------
// Enums used by the window and workspace namespaces

const StatusBarAlignment = { Left: 1, Right: 2 };
const ViewColumn = { Active: -1, Beside: -2, One: 1, Two: 2, Three: 3, Four: 4, Five: 5, Six: 6, Seven: 7, Eight: 8, Nine: 9 };
const ConfigurationTarget = { Global: 1, Workspace: 2, WorkspaceFolder: 3 };
const EndOfLine = { LF: 1, CRLF: 2 };
const TextDocumentSaveReason = { Manual: 1, AfterDelay: 2, FocusOut: 3 };
const ProgressLocation = { SourceControl: 1, Window: 10, Notification: 15 };
const UIKind = { Desktop: 1, Web: 2 };
const ExtensionMode = { Production: 1, Development: 2, Test: 3 };
const FileType = { Unknown: 0, File: 1, Directory: 2, SymbolicLink: 64 };
const TextEditorRevealType = { Default: 0, InCenter: 1, InCenterIfOutsideViewport: 2, AtTop: 3 };
const DecorationRangeBehavior = { OpenOpen: 0, ClosedClosed: 1, OpenClosed: 2, ClosedOpen: 3 };
const OverviewRulerLane = { Left: 1, Center: 2, Right: 4, Full: 7 };
const TaskScope = { Global: 1, Workspace: 2 };
const LogLevel = { Off: 0, Trace: 1, Debug: 2, Info: 3, Warning: 4, Error: 5 };
const ExtensionKind = { UI: 1, Workspace: 2 };
const QuickPickItemKind = { Separator: -1, Default: 0 };
const TreeItemCollapsibleState = { None: 0, Collapsed: 1, Expanded: 2 };

class FileSystemError extends Error {
    constructor(messageOrUri) {
        super(typeof messageOrUri === 'string' ? messageOrUri : String(messageOrUri));
        this.name = 'FileSystemError';
        this.code = 'Unknown';
    }

    static FileNotFound(messageOrUri) {
        const error = new FileSystemError(messageOrUri);
        error.code = 'FileNotFound';
        return error;
    }

    static FileExists(messageOrUri) {
        const error = new FileSystemError(messageOrUri);
        error.code = 'FileExists';
        return error;
    }

    static NoPermissions(messageOrUri) {
        const error = new FileSystemError(messageOrUri);
        error.code = 'NoPermissions';
        return error;
    }
}

// A function rather than a `class`: extensions compiled for older JavaScript subclass it with
// `TreeItem.call(this, ...)`, which a class refuses.
function TreeItem(labelOrUri, collapsibleState) {
    if (typeof labelOrUri === 'string' || (labelOrUri && labelOrUri.label !== undefined)) {
        this.label = labelOrUri;
    } else {
        this.resourceUri = labelOrUri;
    }
    this.collapsibleState = collapsibleState === undefined ? TreeItemCollapsibleState.None : collapsibleState;
}

class TabInputText {
    constructor(uri) {
        this.uri = uri;
    }
}

// ---------------------------------------------------------------------------
// Smaller data classes. Language client libraries subclass several of these.

class CallHierarchyItem {
    constructor(kind, name, detail, uri, range, selectionRange) {
        Object.assign(this, { kind, name, detail, uri, range, selectionRange });
    }
}

class CallHierarchyIncomingCall {
    constructor(item, fromRanges) {
        this.from = item;
        this.fromRanges = fromRanges;
    }
}

class CallHierarchyOutgoingCall {
    constructor(item, fromRanges) {
        this.to = item;
        this.fromRanges = fromRanges;
    }
}

class TypeHierarchyItem {
    constructor(kind, name, detail, uri, range, selectionRange) {
        Object.assign(this, { kind, name, detail, uri, range, selectionRange });
    }
}

class LinkedEditingRanges {
    constructor(ranges, wordPattern) {
        this.ranges = ranges;
        this.wordPattern = wordPattern;
    }
}

class EvaluatableExpression {
    constructor(range, expression) {
        this.range = range;
        this.expression = expression;
    }
}

class InlineValueText {
    constructor(range, text) {
        this.range = range;
        this.text = text;
    }
}

class InlineValueVariableLookup {
    constructor(range, variableName, caseSensitiveLookup) {
        this.range = range;
        this.variableName = variableName;
        this.caseSensitiveLookup = caseSensitiveLookup === undefined ? true : caseSensitiveLookup;
    }
}

class InlineValueEvaluatableExpression {
    constructor(range, expression) {
        this.range = range;
        this.expression = expression;
    }
}

class InlineCompletionItem {
    constructor(insertText, range, command) {
        Object.assign(this, { insertText, range, command });
    }
}

class InlineCompletionList {
    constructor(items) {
        this.items = items;
    }
}

class DocumentDropEdit {
    constructor(insertText) {
        this.insertText = insertText;
    }
}

class DocumentPasteEdit {
    constructor(insertText, title, kind) {
        Object.assign(this, { insertText, title, kind });
    }
}

class LocationLink {
    constructor(targetUri, targetRange, targetSelectionRange, originSelectionRange) {
        Object.assign(this, { targetUri, targetRange, targetSelectionRange, originSelectionRange });
    }
}

const FileChangeType = { Changed: 1, Created: 2, Deleted: 3 };
const TextEditorSelectionChangeKind = { Keyboard: 1, Mouse: 2, Command: 3 };
const LanguageStatusSeverity = { Information: 0, Warning: 1, Error: 2 };
const InlineCompletionTriggerKind = { Invoke: 0, Automatic: 1 };
const CommentThreadCollapsibleState = { Collapsed: 0, Expanded: 1 };
const CommentMode = { Editing: 0, Preview: 1 };
const DebugConsoleMode = { Separate: 0, MergeWithParent: 1 };
const TerminalLocation = { Panel: 1, Editor: 2 };
const NotebookEditorRevealType = { Default: 0, InCenter: 1, InCenterIfOutsideViewport: 2, AtTop: 3 };
const SyntaxTokenType = { Other: 0, Comment: 1, String: 2, RegEx: 3 };
const TextEditorLineNumbersStyle = { Off: 0, On: 1, Relative: 2 };
const InputBoxValidationSeverity = { Info: 1, Warning: 2, Error: 3 };

module.exports = {
    CallHierarchyItem,
    CallHierarchyIncomingCall,
    CallHierarchyOutgoingCall,
    TypeHierarchyItem,
    LinkedEditingRanges,
    EvaluatableExpression,
    InlineValueText,
    InlineValueVariableLookup,
    InlineValueEvaluatableExpression,
    InlineCompletionItem,
    InlineCompletionList,
    DocumentDropEdit,
    DocumentPasteEdit,
    LocationLink,
    FileChangeType,
    TextEditorSelectionChangeKind,
    LanguageStatusSeverity,
    InlineCompletionTriggerKind,
    CommentThreadCollapsibleState,
    CommentMode,
    DebugConsoleMode,
    TerminalLocation,
    NotebookEditorRevealType,
    SyntaxTokenType,
    TextEditorLineNumbersStyle,
    InputBoxValidationSeverity,
    Uri,
    Disposable,
    EventEmitter,
    CancellationTokenSource,
    CancellationToken,
    CancellationError,
    Position,
    Range,
    Selection,
    Location,
    TextEdit,
    SnippetString,
    WorkspaceEdit,
    MarkdownString,
    ThemeColor,
    ThemeIcon,
    TabInputText,
    DiagnosticSeverity,
    DiagnosticTag,
    Diagnostic,
    DiagnosticRelatedInformation,
    CompletionItemKind,
    CompletionItemTag,
    CompletionTriggerKind,
    CompletionItem,
    CompletionList,
    Hover,
    SymbolKind,
    SymbolTag,
    SymbolInformation,
    DocumentSymbol,
    ParameterInformation,
    SignatureInformation,
    SignatureHelp,
    SignatureHelpTriggerKind,
    CodeActionKind,
    CodeActionTriggerKind,
    CodeAction,
    CodeLens,
    FoldingRange,
    FoldingRangeKind,
    DocumentLink,
    SelectionRange,
    InlayHint,
    InlayHintKind,
    InlayHintLabelPart,
    Color,
    ColorInformation,
    ColorPresentation,
    DocumentHighlight,
    DocumentHighlightKind,
    SemanticTokensLegend,
    SemanticTokens,
    SemanticTokensBuilder,
    StatusBarAlignment,
    ViewColumn,
    ConfigurationTarget,
    EndOfLine,
    TextDocumentSaveReason,
    ProgressLocation,
    UIKind,
    ExtensionMode,
    FileType,
    TextEditorRevealType,
    DecorationRangeBehavior,
    OverviewRulerLane,
    TaskScope,
    LogLevel,
    ExtensionKind,
    QuickPickItemKind,
    TreeItemCollapsibleState,
    FileSystemError,
    TreeItem,
};
