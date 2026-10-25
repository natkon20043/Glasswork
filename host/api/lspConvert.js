'use strict';

// Conversions between the vscode API's value types and LSP JSON. The extension host presents
// the providers an extension registers as a language server, so everything an extension
// returns (CompletionItem, Hover, WorkspaceEdit...) must become the JSON Glasswork expects,
// and the JSON Glasswork sends (positions, diagnostics, contexts) must become vscode types.

const types = require('./types');
const { Uri } = require('./uri');

const {
    Position, Range, Location, Diagnostic, MarkdownString, CodeActionKind, SnippetString,
} = types;

// ---------------------------------------------------------------------------
// LSP → vscode

function toPosition(json) {
    return new Position(json.line, json.character);
}

function toRange(json) {
    return new Range(toPosition(json.start), toPosition(json.end));
}

function toDiagnostic(json) {
    const severityMap = { 1: types.DiagnosticSeverity.Error, 2: types.DiagnosticSeverity.Warning, 3: types.DiagnosticSeverity.Information, 4: types.DiagnosticSeverity.Hint };
    const diagnostic = new Diagnostic(toRange(json.range), json.message, severityMap[json.severity || 1]);
    diagnostic.source = json.source;
    diagnostic.code = json.code;
    if (Array.isArray(json.tags)) {
        diagnostic.tags = json.tags.map((tag) => (tag === 1 ? types.DiagnosticTag.Unnecessary : types.DiagnosticTag.Deprecated));
    }
    return diagnostic;
}

// ---------------------------------------------------------------------------
// vscode → LSP

function fromPosition(position) {
    return { line: position.line, character: position.character };
}

function fromRange(range) {
    return { start: fromPosition(range.start), end: fromPosition(range.end) };
}

function fromLocation(location) {
    if (location.targetUri) {
        return {
            targetUri: location.targetUri.toString(),
            targetRange: fromRange(location.targetRange),
            targetSelectionRange: fromRange(location.targetSelectionRange || location.targetRange),
            originSelectionRange: location.originSelectionRange ? fromRange(location.originSelectionRange) : undefined,
        };
    }
    return { uri: location.uri.toString(), range: fromRange(location.range) };
}

function fromLocations(result) {
    if (!result) {
        return null;
    }
    const list = Array.isArray(result) ? result : [result];
    return list.map(fromLocation);
}

function markupOf(value) {
    if (value === undefined || value === null) {
        return undefined;
    }
    if (typeof value === 'string') {
        return { kind: 'markdown', value };
    }
    if (value instanceof MarkdownString || (typeof value === 'object' && typeof value.value === 'string' && value.language === undefined)) {
        return { kind: 'markdown', value: value.value };
    }
    if (typeof value === 'object' && value.language !== undefined) {
        return { kind: 'markdown', value: '```' + value.language + '\n' + value.value + '\n```' };
    }
    return { kind: 'markdown', value: String(value) };
}

function fromHover(hover) {
    if (!hover) {
        return null;
    }
    const parts = [];
    for (const content of hover.contents || []) {
        const markup = markupOf(content);
        if (markup && markup.value) {
            parts.push(markup.value);
        }
    }
    if (parts.length === 0) {
        return null;
    }
    const result = { contents: { kind: 'markdown', value: parts.join('\n\n') } };
    if (hover.range) {
        result.range = fromRange(hover.range);
    }
    return result;
}

function fromTextEdit(edit) {
    return { range: fromRange(edit.range), newText: edit.newText };
}

function fromCommand(command) {
    if (!command) {
        return undefined;
    }
    return { title: command.title, command: command.command, arguments: command.arguments, tooltip: command.tooltip };
}

function fromWorkspaceEdit(edit) {
    if (!edit) {
        return { changes: {} };
    }
    const changes = {};
    for (const entry of edit.entries) {
        const key = entry.uri.toString();
        changes[key] = (changes[key] || []).concat(entry.edits.map(fromTextEdit));
    }
    if (!edit.fileOperations || edit.fileOperations.length === 0) {
        return { changes };
    }
    // File operations need the documentChanges form.
    const documentChanges = [];
    for (const operation of edit.fileOperations) {
        if (operation.kind === 'create') {
            documentChanges.push({ kind: 'create', uri: operation.uri.toString(), options: operation.options });
        } else if (operation.kind === 'delete') {
            documentChanges.push({ kind: 'delete', uri: operation.uri.toString(), options: operation.options });
        } else if (operation.kind === 'rename') {
            documentChanges.push({ kind: 'rename', oldUri: operation.oldUri.toString(), newUri: operation.newUri.toString(), options: operation.options });
        }
    }
    for (const entry of edit.entries) {
        documentChanges.push({
            textDocument: { uri: entry.uri.toString(), version: null },
            edits: entry.edits.map(fromTextEdit),
        });
    }
    return { documentChanges };
}

function fromDiagnostic(diagnostic) {
    const severityMap = [1, 2, 3, 4];
    let code = diagnostic.code;
    if (code && typeof code === 'object' && code.value !== undefined) {
        code = code.value;
    }
    const result = {
        range: fromRange(diagnostic.range),
        message: diagnostic.message,
        severity: severityMap[diagnostic.severity === undefined ? 0 : diagnostic.severity],
        source: diagnostic.source,
        code,
    };
    if (Array.isArray(diagnostic.tags)) {
        result.tags = diagnostic.tags;
    }
    if (Array.isArray(diagnostic.relatedInformation)) {
        result.relatedInformation = diagnostic.relatedInformation.map((info) => ({
            location: fromLocation(info.location),
            message: info.message,
        }));
    }
    return result;
}

// A completion label can be a string or {label, detail, description}.
function fromCompletionItem(item, dataTag) {
    const result = {};
    if (typeof item.label === 'string') {
        result.label = item.label;
    } else {
        result.label = item.label.label;
        result.labelDetails = { detail: item.label.detail, description: item.label.description };
    }
    if (item.kind !== undefined) {
        result.kind = item.kind + 1; // vscode kinds start at 0, LSP at 1
    }
    if (item.tags && item.tags.includes(types.CompletionItemTag.Deprecated)) {
        result.tags = [1];
    }
    if (item.detail !== undefined) {
        result.detail = item.detail;
    }
    if (item.documentation !== undefined) {
        result.documentation = markupOf(item.documentation);
    }
    if (item.sortText !== undefined) {
        result.sortText = item.sortText;
    }
    if (item.filterText !== undefined) {
        result.filterText = item.filterText;
    }
    if (item.preselect) {
        result.preselect = true;
    }
    if (item.commitCharacters) {
        result.commitCharacters = item.commitCharacters;
    }

    const insertText = item.insertText !== undefined ? item.insertText : undefined;
    let newText = typeof item.label === 'string' ? item.label : item.label.label;
    if (insertText instanceof SnippetString) {
        newText = insertText.value;
        result.insertTextFormat = 2;
    } else if (typeof insertText === 'string') {
        newText = insertText;
    }
    if (item.range) {
        const range = item.range.inserting ? item.range.replacing : item.range;
        result.textEdit = { range: fromRange(range), newText };
    } else {
        result.insertText = newText;
    }
    if (Array.isArray(item.additionalTextEdits) && item.additionalTextEdits.length > 0) {
        result.additionalTextEdits = item.additionalTextEdits.map(fromTextEdit);
    }
    if (item.command) {
        result.command = fromCommand(item.command);
    }
    if (dataTag !== undefined) {
        result.data = { __gwHost: dataTag };
    }
    return result;
}

function fromDocumentSymbol(symbol) {
    if (symbol.location) {
        return {
            name: symbol.name,
            kind: symbol.kind + 1,
            location: fromLocation(symbol.location),
            containerName: symbol.containerName,
            tags: symbol.tags,
        };
    }
    return {
        name: symbol.name,
        detail: symbol.detail,
        kind: symbol.kind + 1,
        range: fromRange(symbol.range),
        selectionRange: fromRange(symbol.selectionRange),
        tags: symbol.tags,
        children: (symbol.children || []).map(fromDocumentSymbol),
    };
}

function fromSignatureHelp(help) {
    if (!help) {
        return null;
    }
    return {
        signatures: (help.signatures || []).map((signature) => ({
            label: signature.label,
            documentation: markupOf(signature.documentation),
            parameters: (signature.parameters || []).map((parameter) => ({
                label: parameter.label,
                documentation: markupOf(parameter.documentation),
            })),
            activeParameter: signature.activeParameter,
        })),
        activeSignature: help.activeSignature || 0,
        activeParameter: help.activeParameter || 0,
    };
}

function fromCodeAction(item, dataTag) {
    // A bare Command (title + command id) is allowed in place of a CodeAction.
    if (typeof item.command === 'string') {
        return { title: item.title, command: fromCommand(item), data: { __gwHost: dataTag } };
    }
    const result = { title: item.title };
    if (item.kind) {
        result.kind = item.kind.value;
    }
    if (item.diagnostics) {
        result.diagnostics = item.diagnostics.map(fromDiagnostic);
    }
    if (item.edit) {
        result.edit = fromWorkspaceEdit(item.edit);
    }
    if (item.command) {
        result.command = fromCommand(item.command);
    }
    if (item.isPreferred) {
        result.isPreferred = true;
    }
    if (item.disabled) result.disabled = { reason: item.disabled.reason };
    result.data = { __gwHost: dataTag };
    return result;
}

function fromCodeLens(lens, dataTag) {
    const result = { range: fromRange(lens.range) };
    if (lens.command) {
        result.command = fromCommand(lens.command);
    }
    result.data = { __gwHost: dataTag };
    return result;
}

function fromFoldingRange(range) {
    const kinds = { 1: 'comment', 2: 'imports', 3: 'region' };
    return { startLine: range.start, endLine: range.end, kind: kinds[range.kind] };
}

function fromSelectionRange(selection) {
    const result = { range: fromRange(selection.range) };
    if (selection.parent) {
        result.parent = fromSelectionRange(selection.parent);
    }
    return result;
}

function fromInlayHint(hint) {
    let label = hint.label;
    if (Array.isArray(label)) {
        label = label.map((part) => ({
            value: part.value,
            tooltip: part.tooltip ? markupOf(part.tooltip) : undefined,
            location: part.location ? fromLocation(part.location) : undefined,
            command: part.command ? fromCommand(part.command) : undefined,
        }));
    }
    return {
        position: fromPosition(hint.position),
        label,
        kind: hint.kind,
        tooltip: hint.tooltip ? markupOf(hint.tooltip) : undefined,
        paddingLeft: hint.paddingLeft,
        paddingRight: hint.paddingRight,
        textEdits: hint.textEdits ? hint.textEdits.map(fromTextEdit) : undefined,
    };
}

function fromDocumentLink(link) {
    return { range: fromRange(link.range), target: link.target ? link.target.toString() : undefined, tooltip: link.tooltip };
}

function fromDocumentHighlight(highlight) {
    return { range: fromRange(highlight.range), kind: (highlight.kind || 0) + 1 };
}

function toCodeActionContext(context) {
    const only = context.only ? new CodeActionKind(context.only[0] || '') : undefined;
    return {
        diagnostics: (context.diagnostics || []).map(toDiagnostic),
        only,
        triggerKind: context.triggerKind === 2 ? types.CodeActionTriggerKind.Automatic : types.CodeActionTriggerKind.Invoke,
    };
}

module.exports = {
    Uri,
    Location,
    toPosition,
    toRange,
    toDiagnostic,
    toCodeActionContext,
    fromPosition,
    fromRange,
    fromLocation,
    fromLocations,
    markupOf,
    fromHover,
    fromTextEdit,
    fromCommand,
    fromWorkspaceEdit,
    fromDiagnostic,
    fromCompletionItem,
    fromDocumentSymbol,
    fromSignatureHelp,
    fromCodeAction,
    fromCodeLens,
    fromFoldingRange,
    fromSelectionRange,
    fromInlayHint,
    fromDocumentLink,
    fromDocumentHighlight,
};
