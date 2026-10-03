'use strict';

// vscode.Uri: an immutable resource identifier (scheme://authority/path?query#fragment).

const path = require('path');

function encodeComponent(text) {
    return encodeURIComponent(text).replace(/[!'()*]/g, (character) => '%' + character.charCodeAt(0).toString(16).toUpperCase());
}

function encodePath(text) {
    // Keep the slashes (and the colon of a Windows drive); encode the rest.
    return text
        .split('/')
        .map((segment) => encodeComponent(segment).replace(/%3A/g, ':'))
        .join('/');
}

class Uri {
    constructor(scheme, authority, uriPath, query, fragment) {
        this.scheme = scheme || '';
        this.authority = authority || '';
        this.path = uriPath || '';
        this.query = query || '';
        this.fragment = fragment || '';
    }

    static parse(value) {
        const match = /^([a-zA-Z][a-zA-Z0-9+.-]*):(?:\/\/([^/?#]*))?([^?#]*)(?:\?([^#]*))?(?:#(.*))?$/.exec(value);
        if (!match) {
            return new Uri('file', '', value, '', '');
        }
        const decode = (text) => {
            try {
                return decodeURIComponent(text || '');
            } catch (error) {
                return text || '';
            }
        };
        return new Uri(match[1], decode(match[2]), decode(match[3]), decode(match[4]), decode(match[5]));
    }

    static file(filePath) {
        let normalized = filePath.replace(/\\/g, '/');
        if (!normalized.startsWith('/')) {
            normalized = '/' + normalized;
        }
        return new Uri('file', '', normalized, '', '');
    }

    static from(components) {
        return new Uri(components.scheme, components.authority, components.path, components.query, components.fragment);
    }

    static joinPath(base, ...pieces) {
        return base.with({ path: path.posix.join(base.path, ...pieces) });
    }

    with(change) {
        const pick = (name, current) => (change[name] === undefined ? current : change[name] === null ? '' : change[name]);
        return new Uri(
            pick('scheme', this.scheme),
            pick('authority', this.authority),
            pick('path', this.path),
            pick('query', this.query),
            pick('fragment', this.fragment)
        );
    }

    get fsPath() {
        return this.path;
    }

    toString() {
        let result = this.scheme + ':';
        if (this.authority || this.scheme === 'file') {
            result += '//' + encodeComponent(this.authority).replace(/%3A/g, ':');
        }
        result += encodePath(this.path);
        if (this.query) {
            result += '?' + encodeComponent(this.query);
        }
        if (this.fragment) {
            result += '#' + encodeComponent(this.fragment);
        }
        return result;
    }

    toJSON() {
        return {
            $mid: 1,
            scheme: this.scheme,
            authority: this.authority,
            path: this.path,
            query: this.query,
            fragment: this.fragment,
            fsPath: this.fsPath,
            external: this.toString(),
        };
    }
}

module.exports = { Uri };
