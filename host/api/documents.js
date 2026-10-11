'use strict';

// Text documents as extensions see them (vscode.TextDocument), kept in step with the editor
// by the didOpen/didChange/didClose messages Glasswork sends. Positions are UTF-16 code
// units, which is what JavaScript strings and the Language Server Protocol both count in.

const path = require('path');
const { Uri } = require('./uri');
const { Position, Range, EventEmitter, EndOfLine } = require('./types');

class TextLine {
    constructor(lineNumber, text, isLast) {
        this.lineNumber = lineNumber;
        this.text = text;
        this.range = new Range(lineNumber, 0, lineNumber, text.length);
        this.rangeIncludingLineBreak = isLast ? this.range : new Range(lineNumber, 0, lineNumber + 1, 0);
        const firstNonBlank = /\S/.exec(text);
        this.firstNonWhitespaceCharacterIndex = firstNonBlank ? firstNonBlank.index : text.length;
        this.isEmptyOrWhitespace = this.firstNonWhitespaceCharacterIndex === text.length;
    }
}

const DEFAULT_WORD_PATTERN = /(-?\d*\.\d\w*)|([^\`\~\!\@\#\%\^\&\*\(\)\-\=\+\[\{\]\}\\\|\;\:\'\"\,\.\<\>\/\?\s]+)/g;

class TextDocument {
    constructor(uri, languageId, version, text, manager) {
        this.uri = uri;
        this.languageId = languageId;
        this.version = version;
        this.isDirty = false;
        this.isClosed = false;
        this.isUntitled = uri.scheme === 'untitled';
        this.encoding = 'utf8';
        this.manager = manager;
        this.setText(text);
    }

    get fileName() {
        return this.uri.fsPath;
    }

    get eol() {
        return this.lineBreak === '\r\n' ? EndOfLine.CRLF : EndOfLine.LF;
    }

    get lineCount() {
        return this.lines().length;
    }

    setText(text) {
        this.lineBreak = text.includes('\r\n') ? '\r\n' : '\n';
        this.text = text.replace(/\r\n/g, '\n');
        this.cachedLines = null;
        this.cachedOffsets = null;
    }

    lines() {
        if (!this.cachedLines) {
            this.cachedLines = this.text.split('\n');
        }
        return this.cachedLines;
    }

    lineOffsets() {
        if (!this.cachedOffsets) {
            const offsets = [];
            let offset = 0;
            for (const line of this.lines()) {
                offsets.push(offset);
                offset += line.length + 1;
            }
            this.cachedOffsets = offsets;
        }
        return this.cachedOffsets;
    }

    getText(range) {
        if (!range) {
            return this.lineBreak === '\r\n' ? this.text.replace(/\n/g, '\r\n') : this.text;
        }
        const start = this.offsetAt(range.start);
        const end = this.offsetAt(range.end);
        return this.text.slice(start, end);
    }

    lineAt(lineOrPosition) {
        const line = typeof lineOrPosition === 'number' ? lineOrPosition : lineOrPosition.line;
        const lines = this.lines();
        if (line < 0 || line >= lines.length) {
            throw new Error('Illegal value for `line`');
        }
        return new TextLine(line, lines[line], line === lines.length - 1);
    }

    offsetAt(position) {
        const valid = this.validatePosition(position);
        return this.lineOffsets()[valid.line] + valid.character;
    }

    positionAt(offset) {
        const clamped = Math.max(0, Math.min(offset, this.text.length));
        const offsets = this.lineOffsets();
        let low = 0;
        let high = offsets.length - 1;
        while (low < high) {
            const middle = Math.ceil((low + high) / 2);
            if (offsets[middle] <= clamped) {
                low = middle;
            } else {
                high = middle - 1;
            }
        }
        return new Position(low, clamped - offsets[low]);
    }

    validatePosition(position) {
        const lines = this.lines();
        if (position.line >= lines.length) {
            const last = lines.length - 1;
            return new Position(last, lines[last].length);
        }
        const length = lines[position.line].length;
        if (position.character > length) {
            return new Position(position.line, length);
        }
        return position;
    }

    validateRange(range) {
        const start = this.validatePosition(range.start);
        const end = this.validatePosition(range.end);
        if (start === range.start && end === range.end) {
            return range;
        }
        return new Range(start, end);
    }

    getWordRangeAtPosition(position, regex) {
        const line = this.lineAt(position.line).text;
        // The search walks the line match by match, so the pattern must be global.
        const wanted = regex || DEFAULT_WORD_PATTERN;
        const flags = wanted.flags.includes('g') ? wanted.flags : wanted.flags + 'g';
        const pattern = new RegExp(wanted.source, flags);
        let match;
        while ((match = pattern.exec(line)) !== null) {
            if (match[0].length === 0) {
                pattern.lastIndex++;
                continue;
            }
            const start = match.index;
            const end = start + match[0].length;
            if (position.character >= start && position.character <= end) {
                return new Range(position.line, start, position.line, end);
            }
            if (start > position.character) {
                break;
            }
        }
        return undefined;
    }

    save() {
        return Promise.resolve(this.manager ? this.manager.requestSave(this) : false);
    }

    // Applies one LSP content change ({range, text} or {text} for the whole document).
    applyChange(change) {
        if (!change.range) {
            this.setText(change.text);
            return { range: new Range(0, 0, 0, 0), rangeOffset: 0, rangeLength: 0, text: change.text };
        }
        const start = new Position(change.range.start.line, change.range.start.character);
        const end = new Position(change.range.end.line, change.range.end.character);
        const startOffset = this.offsetAt(start);
        const endOffset = this.offsetAt(end);
        const normalized = change.text.replace(/\r\n/g, '\n');
        this.text = this.text.slice(0, startOffset) + normalized + this.text.slice(endOffset);
        this.cachedLines = null;
        this.cachedOffsets = null;
        return {
            range: new Range(start, end),
            rangeOffset: startOffset,
            rangeLength: endOffset - startOffset,
            text: change.text,
        };
    }
}

class DocumentManager {
    constructor() {
        this.documents = new Map();
        this.openEmitter = new EventEmitter();
        this.changeEmitter = new EventEmitter();
        this.closeEmitter = new EventEmitter();
        this.saveEmitter = new EventEmitter();
        this.languageChangeEmitter = new EventEmitter();
        this.saveRequester = null; // set by the host: asks Glasswork to save a document
    }

    all() {
        return Array.from(this.documents.values());
    }

    get(uri) {
        const key = typeof uri === 'string' ? uri : uri.toString();
        return this.documents.get(key);
    }

    open(uriText, languageId, version, text) {
        const uri = Uri.parse(uriText);
        const key = uri.toString();
        const existing = this.documents.get(key);
        if (existing) {
            existing.version = version;
            existing.setText(text);
            return existing;
        }
        const document = new TextDocument(uri, languageId, version, text, this);
        this.documents.set(key, document);
        this.openEmitter.fire(document);
        return document;
    }

    // An in-memory document that is not open in Glasswork (openTextDocument on a file).
    createDetached(uri, languageId, text) {
        return new TextDocument(uri, languageId, 1, text, this);
    }

    change(uriText, version, changes) {
        const document = this.get(Uri.parse(uriText));
        if (!document) {
            return undefined;
        }
        const contentChanges = [];
        for (const change of changes) {
            contentChanges.push(document.applyChange(change));
        }
        document.version = version;
        document.isDirty = true;
        this.changeEmitter.fire({ document, contentChanges, reason: undefined });
        return document;
    }

    save(uriText) {
        const document = this.get(Uri.parse(uriText));
        if (document) {
            document.isDirty = false;
            this.saveEmitter.fire(document);
        }
        return document;
    }

    close(uriText) {
        const uri = Uri.parse(uriText);
        const document = this.get(uri);
        if (!document) {
            return;
        }
        document.isClosed = true;
        this.documents.delete(uri.toString());
        this.closeEmitter.fire(document);
    }

    requestSave(document) {
        return this.saveRequester ? this.saveRequester(document) : false;
    }
}

// ---------------------------------------------------------------------------
// Document selectors

function globToRegExp(glob) {
    let source = '';
    for (let index = 0; index < glob.length; index++) {
        const character = glob[index];
        if (character === '*') {
            if (glob[index + 1] === '*') {
                index++;
                if (glob[index + 1] === '/') {
                    index++;
                    source += '(?:.*/)?';
                } else {
                    source += '.*';
                }
            } else {
                source += '[^/]*';
            }
        } else if (character === '?') {
            source += '[^/]';
        } else if (character === '{') {
            const close = glob.indexOf('}', index);
            if (close < 0) {
                source += '\\{';
            } else {
                const alternatives = glob.slice(index + 1, close).split(',').map((piece) => globToRegExp(piece).source.slice(1, -1));
                source += '(?:' + alternatives.join('|') + ')';
                index = close;
            }
        } else if (character === '[') {
            const close = glob.indexOf(']', index);
            if (close < 0) {
                source += '\\[';
            } else {
                source += glob.slice(index, close + 1);
                index = close;
            }
        } else if ('\\^$+.()|'.includes(character)) {
            source += '\\' + character;
        } else {
            source += character;
        }
    }
    return new RegExp('^' + source + '$');
}

function matchesGlob(pattern, filePath) {
    const text = typeof pattern === 'string' ? pattern : pattern.pattern;
    // A pattern without a slash matches the file name anywhere, as VS Code does.
    let regex;
    if (!text.includes('/')) {
        regex = globToRegExp('**/' + text);
    } else if (!text.startsWith('/') && !text.startsWith('**')) {
        regex = globToRegExp('**/' + text);
    } else {
        regex = globToRegExp(text);
    }
    return regex.test(filePath) || regex.test(path.basename(filePath));
}

// Scores how well a selector matches a document: 0 for no match, higher is better. A
// language match is worth more than a scheme or a pattern, as in VS Code.
function matchSelector(selector, document) {
    if (!selector) {
        return 0;
    }
    if (Array.isArray(selector)) {
        let best = 0;
        for (const item of selector) {
            best = Math.max(best, matchSelector(item, document));
        }
        return best;
    }
    if (typeof selector === 'string') {
        if (selector === '*') {
            return 5;
        }
        return selector === document.languageId ? 10 : 0;
    }
    let score = 0;
    if (selector.language) {
        if (selector.language === '*') {
            score += 5;
        } else if (selector.language === document.languageId) {
            score += 10;
        } else {
            return 0;
        }
    }
    if (selector.scheme) {
        if (selector.scheme === '*') {
            score += 5;
        } else if (selector.scheme === document.uri.scheme) {
            score += 10;
        } else {
            return 0;
        }
    }
    if (selector.pattern) {
        if (matchesGlob(selector.pattern, document.uri.fsPath)) {
            score += 10;
        } else {
            return 0;
        }
    }
    return score;
}

// Which language ids a selector names outright (patterns and schemes alone name none).
function languagesOfSelector(selector) {
    const names = new Set();
    const visit = (item) => {
        if (!item) {
            return;
        }
        if (Array.isArray(item)) {
            item.forEach(visit);
        } else if (typeof item === 'string') {
            names.add(item);
        } else if (item.language) {
            names.add(item.language);
        }
    };
    visit(selector);
    return names;
}

module.exports = { TextDocument, DocumentManager, matchSelector, languagesOfSelector, matchesGlob, globToRegExp };
