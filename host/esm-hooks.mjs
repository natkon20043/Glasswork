// Module hooks for extensions written as ES modules (`import * as vscode from 'vscode'`).
// CommonJS extensions are handled by main.js overriding require(); ES module imports take a
// different path, so this file teaches the module loader that "vscode" is the API object.

let exportNames = [];
const API_URL = 'file:///glasswork-vscode-api.mjs'; // never read from disk: load() answers for it

export async function initialize(data) {
    exportNames = data.names || [];
}

export async function resolve(specifier, context, nextResolve) {
    if (specifier === 'vscode') {
        return { url: API_URL, shortCircuit: true };
    }
    return nextResolve(specifier, context);
}

export async function load(url, context, nextLoad) {
    if (url !== API_URL) {
        return nextLoad(url, context);
    }
    // The API object lives in the main thread; a tiny CommonJS require fetches it, and each
    // name is re-exported so both `import vscode from` and `import { window } from` work.
    const lines = [
        "import { createRequire } from 'node:module';",
        "const api = createRequire(import.meta.url)('vscode');",
        'export default api;',
    ];
    for (const name of exportNames) {
        lines.push(`export const ${name} = api[${JSON.stringify(name)}];`);
    }
    return { format: 'module', source: lines.join('\n'), shortCircuit: true };
}
