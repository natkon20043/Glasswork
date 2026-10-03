'use strict';

// Plays the part of Glasswork: starts the extension host, loads the sample extension and
// checks the flows that matter. Run with `node tests/host/run.js` (ctest does this too).

const { spawn } = require('child_process');
const path = require('path');
const assert = require('assert');
const { Connection } = require('../../host/rpc');

const root = path.resolve(__dirname, '../..');
const sampleFolder = path.join(__dirname, 'fixtures', 'sample-ext');
const sampleManifest = require(path.join(sampleFolder, 'package.json'));

let failures = 0;
let checks = 0;

async function test(name, body) {
    try {
        await body();
        console.log(`ok   ${name}`);
    } catch (error) {
        failures++;
        console.log(`FAIL ${name}\n     ${(error && error.stack) || error}`);
    }
}

function check(condition, message) {
    checks++;
    assert.ok(condition, message);
}

function waitFor(predicate, what) {
    return new Promise((resolve, reject) => {
        const started = Date.now();
        const timer = setInterval(() => {
            if (predicate()) {
                clearInterval(timer);
                resolve();
            } else if (Date.now() - started > 5000) {
                clearInterval(timer);
                reject(new Error(`Timed out waiting for ${what}`));
            }
        }, 10);
    });
}

async function main() {
    const child = spawn(process.execPath, [path.join(root, 'host', 'main.js')], { stdio: ['pipe', 'pipe', 'inherit'] });
    const connection = new Connection(child.stdout, child.stdin);

    // What Glasswork would show or record.
    const seen = { logs: '', messages: [], statusBar: new Map(), commands: new Map(), serverMessages: [], diagnostics: [], states: {} };
    let messageAnswer = 'Thanks';
    connection.onNotification('ui/log', (p) => { seen.logs += p.text; });
    connection.onNotification('ui/statusBar', (p) => seen.statusBar.set(p.id, p));
    connection.onNotification('commands/registered', (p) => seen.commands.set(p.id, p.title));
    connection.onNotification('host/extensionState', (p) => { seen.states[p.id] = p.state; });
    const pendingServer = new Map();
    connection.onNotification('lsp/message', (p) => {
        const message = p.message;
        seen.serverMessages.push(message);
        if (message.method === 'textDocument/publishDiagnostics') seen.diagnostics.push(message.params);
        if (message.id !== undefined && !message.method && pendingServer.has(message.id)) {
            pendingServer.get(message.id)(message);
            pendingServer.delete(message.id);
        }
    });
    connection.onRequest('ui/showMessage', async (p) => { seen.messages.push(p); return messageAnswer; });
    connection.onRequest('workspace/applyEdit', async () => ({ applied: true }));

    let ready = false;
    connection.onNotification('host/ready', () => { ready = true; });
    await waitFor(() => ready, 'host/ready');

    await test('initialize loads extension manifests and defaults', async () => {
        const result = await connection.sendRequest('initialize', {
            workspaceFolders: ['file:///tmp/project'],
            languageIds: ['fake'],
            configuration: { 'sample.greeting': 'Howdy' },
            storageRoot: path.join(require('os').tmpdir(), `gw-host-test-${process.pid}`),
            extensions: [{ id: 'glasswork-tests.sample', path: sampleFolder, manifest: sampleManifest }],
        });
        check(result.ok, 'initialize ok');
        check(result.extensions[0] === 'glasswork-tests.sample', 'extension listed');
    });

    await test('the extension stays dormant until its activation event', async () => {
        const status = await connection.sendRequest('host/status', {});
        check(status.extensions[0].state === 'inactive', 'not activated yet');
        check(status.providers === 0, 'no providers yet');
    });

    await test('onLanguage activates the extension and registers providers', async () => {
        await connection.sendRequest('host/event', { name: 'onLanguage:fake' });
        const status = await connection.sendRequest('host/status', {});
        check(status.extensions[0].state === 'active', 'activated: ' + JSON.stringify(status));
        check(status.providers >= 4, 'providers registered');
        check(seen.commands.get('sample.hello') === 'Sample: Say Hello', 'command registered with its title');
        check(seen.logs.includes('sample activated'), 'output channel written');
        check(seen.logs.includes('console.log from the extension'), 'console output redirected, not corrupting the stream');
        check(seen.statusBar.get('status-1').text.includes('Sample') && seen.statusBar.get('status-1').visible, 'status bar item shown');
    });

    await test('commands run, read configuration and ask the user', async () => {
        const choice = await connection.sendRequest('commands/execute', { id: 'sample.hello', args: ['Nate'] });
        check(seen.messages.length === 1, 'a message was shown');
        check(seen.messages[0].message === 'Howdy, Nate!', 'configuration value used: ' + seen.messages[0].message);
        check(JSON.stringify(seen.messages[0].items) === '["Thanks","Dismiss"]', 'buttons passed');
        check(choice === 'Thanks', 'chosen button returned');
    });

    // ---- The virtual language server ----
    const serverId = 'ext:fake';
    let nextId = 1;
    function lspRequest(method, params) {
        const id = nextId++;
        return new Promise((resolve, reject) => {
            pendingServer.set(id, (message) => (message.error ? reject(new Error(message.error.message)) : resolve(message.result)));
            connection.sendNotification('lsp/message', { server: serverId, message: { jsonrpc: '2.0', id, method, params } });
        });
    }
    function lspNotify(method, params) {
        connection.sendNotification('lsp/message', { server: serverId, message: { jsonrpc: '2.0', method, params } });
    }

    await test('the virtual server handshakes and registers capabilities', async () => {
        await connection.sendRequest('lsp/open', { server: serverId, language: 'fake', rootUri: 'file:///tmp/project' });
        const init = await lspRequest('initialize', { processId: null, capabilities: {} });
        check(init.capabilities.textDocumentSync.change === 2, 'incremental sync offered');
        lspNotify('initialized', {});
        await waitFor(() => seen.serverMessages.some((m) => m.method === 'client/registerCapability'), 'registerCapability');
        const methods = [];
        for (const message of seen.serverMessages) {
            if (message.method === 'client/registerCapability') {
                for (const registration of message.params.registrations) methods.push(registration.method);
            }
        }
        for (const wanted of ['textDocument/completion', 'textDocument/hover', 'textDocument/definition', 'textDocument/formatting']) {
            check(methods.includes(wanted), `${wanted} registered (${methods.join(', ')})`);
        }
        const completion = seen.serverMessages.flatMap((m) => (m.method === 'client/registerCapability' ? m.params.registrations : [])).find((r) => r.method === 'textDocument/completion');
        check(completion.registerOptions.triggerCharacters[0] === '.', 'trigger characters passed');
        check(completion.registerOptions.resolveProvider === true, 'resolve support advertised');
    });

    const documentUri = 'file:///tmp/project/a.fake';
    await test('opening a document fires events and publishes diagnostics', async () => {
        lspNotify('textDocument/didOpen', { textDocument: { uri: documentUri, languageId: 'fake', version: 1, text: 'hello world   \nTODO fix this\n' } });
        await waitFor(() => seen.diagnostics.length > 0, 'diagnostics');
        const published = seen.diagnostics[0];
        check(published.uri === documentUri, 'for the right document');
        check(published.diagnostics.length === 1, 'one diagnostic');
        check(published.diagnostics[0].message === 'Found a TODO', 'message');
        check(published.diagnostics[0].severity === 2, 'warning converted to LSP severity 2');
        check(published.diagnostics[0].range.start.line === 1 && published.diagnostics[0].range.start.character === 0, 'range');
    });

    await test('completion converts vscode items to LSP', async () => {
        const result = await lspRequest('textDocument/completion', { textDocument: { uri: documentUri }, position: { line: 0, character: 3 }, context: { triggerKind: 1 } });
        check(result.items.length === 2, 'two items');
        const hello = result.items.find((item) => item.label === 'hello');
        check(hello.kind === 3, 'Function kind shifted to LSP numbering');
        check(hello.insertTextFormat === 2 && hello.insertText === 'hello(${1:name})', 'snippet');
        check(hello.documentation.value === 'Greets **someone**.', 'markdown documentation');
        check(hello.detail === 'says hello', 'detail');

        const resolved = await lspRequest('completionItem/resolve', hello);
        check(resolved.additionalTextEdits.length === 1 && resolved.additionalTextEdits[0].newText === '// import hello\n', 'resolve adds the import edit');
    });

    await test('hover, definition and formatting providers answer', async () => {
        const hover = await lspRequest('textDocument/hover', { textDocument: { uri: documentUri }, position: { line: 0, character: 8 } });
        check(hover.contents.value === '`world` is a word', 'hover text: ' + JSON.stringify(hover));
        check(hover.range.start.character === 6 && hover.range.end.character === 11, 'hover range');

        const definition = await lspRequest('textDocument/definition', { textDocument: { uri: documentUri }, position: { line: 0, character: 1 } });
        check(definition[0].uri === documentUri && definition[0].range.start.line === 0, 'definition location');

        const edits = await lspRequest('textDocument/formatting', { textDocument: { uri: documentUri }, options: { tabSize: 4, insertSpaces: true } });
        check(edits.length === 1 && edits[0].range.start.character === 11 && edits[0].newText === '', 'trailing whitespace edit: ' + JSON.stringify(edits));
    });

    await test('incremental document changes reach providers', async () => {
        lspNotify('textDocument/didChange', {
            textDocument: { uri: documentUri, version: 2 },
            contentChanges: [{ range: { start: { line: 0, character: 5 }, end: { line: 0, character: 14 } }, text: '' }],
        });
        const edits = await lspRequest('textDocument/formatting', { textDocument: { uri: documentUri }, options: {} });
        check(edits.length === 0, 'the trailing whitespace is gone after the edit: ' + JSON.stringify(edits));
        const hover = await lspRequest('textDocument/hover', { textDocument: { uri: documentUri }, position: { line: 0, character: 2 } });
        check(hover.contents.value === '`hello` is a word', 'document text updated');
    });

    await test('the active editor can be read, edited and moved', async () => {
        const editedUris = [];
        const selectionsSet = [];
        const snippetRequests = [];
        connection.onRequest('workspace/applyEdit', async (p) => { editedUris.push(p.edit); return { applied: true }; });
        connection.onNotification('editor/setSelections', (p) => selectionsSet.push(p));
        connection.onRequest('editor/insertSnippet', async (p) => { snippetRequests.push(p); return true; });

        // No editor yet.
        check((await connection.sendRequest('commands/execute', { id: 'sample.shout', args: [] })) === 'no editor', 'no editor before the first report');

        // Glasswork reports the file in front with "hello" selected.
        connection.sendNotification('editor/state', {
            uri: documentUri,
            selections: [{ anchor: { line: 0, character: 0 }, active: { line: 0, character: 5 } }],
            tabSize: 2, insertSpaces: true,
        });
        await new Promise((resolve) => setTimeout(resolve, 50));
        const result = await connection.sendRequest('commands/execute', { id: 'sample.shout', args: [] });
        check(result === `shouted in /tmp/project/a.fake`, 'edit applied: ' + result);
        check(editedUris.length === 1, 'one edit sent');
        const edits = editedUris[0].changes[documentUri];
        check(edits.length === 1 && edits[0].newText === 'HELLO', 'the selection upper-cased: ' + JSON.stringify(editedUris[0]));
        check(edits[0].range.end.character === 5, 'over the selected range');
        check(selectionsSet.length === 1 && selectionsSet[0].selections[0].active.line === 0, 'cursor moved back to the start');

        check((await connection.sendRequest('commands/execute', { id: 'sample.snippet', args: [] })) === 'inserted', 'snippet command ran');
        check(snippetRequests[0].snippet === 'x = ${1:value};$0' && snippetRequests[0].ranges.length === 1, 'snippet sent with its target: ' + JSON.stringify(snippetRequests));

        // Events: the first report made the editor active; moving the selection fires again.
        connection.sendNotification('editor/state', {
            uri: documentUri,
            selections: [{ anchor: { line: 1, character: 0 }, active: { line: 1, character: 0 } }, { anchor: { line: 0, character: 1 }, active: { line: 0, character: 1 } }],
        });
        await new Promise((resolve) => setTimeout(resolve, 50));
        const events = await connection.sendRequest('commands/execute', { id: 'sample.editorEvents', args: [] });
        check(events[0] === 'active:fake', 'active editor event: ' + JSON.stringify(events));
        check(events.includes('selection:2'), 'selection event with two cursors: ' + JSON.stringify(events));

        // Nothing showing: the editor goes away.
        connection.sendNotification('editor/state', null);
        await new Promise((resolve) => setTimeout(resolve, 50));
        check((await connection.sendRequest('commands/execute', { id: 'sample.shout', args: [] })) === 'no editor', 'editor cleared');
    });

    await test('decorations are sent with their options and cleared when the type is disposed', async () => {
        const received = [];
        connection.onNotification('editor/decorations', (p) => received.push(p));
        connection.sendNotification('editor/state', {
            uri: documentUri,
            selections: [{ anchor: { line: 0, character: 0 }, active: { line: 0, character: 0 } }],
        });
        await new Promise((resolve) => setTimeout(resolve, 50));
        check((await connection.sendRequest('commands/execute', { id: 'sample.decorate', args: [] })) === 'decorated', 'decorate ran');
        await new Promise((resolve) => setTimeout(resolve, 50));
        check(received.length === 1, 'one batch sent');
        const batch = received[0];
        check(batch.uri === documentUri && batch.key.startsWith('decoration-'), 'for the file, under a key');
        check(batch.options.backgroundColor.id === 'editor.findMatchBackground', 'a theme colour keeps its id: ' + JSON.stringify(batch.options.backgroundColor));
        check(batch.options.after.fontStyle === 'italic', 'type options pass through');
        check(batch.ranges.length === 2 && batch.ranges[0].range.end.character === 5, 'plain range');
        check(batch.ranges[1].renderOptions.after.contentText === ' ← fix this', 'per-range render options pass through');

        check((await connection.sendRequest('commands/execute', { id: 'sample.undecorate', args: [] })) === 'cleared', 'dispose ran');
        await new Promise((resolve) => setTimeout(resolve, 50));
        check(received.length === 2 && received[1].key === batch.key && received[1].ranges.length === 0, 'disposing clears them: ' + JSON.stringify(received[1]));
    });

    await test('file system watchers fire for matching files on disk', async () => {
        connection.sendNotification('workspace/fileEvents', { events: [
            { uri: 'file:///tmp/project/src/new.fake', type: 1 },
            { uri: 'file:///tmp/project/src/a.fake', type: 2 },
            { uri: 'file:///tmp/project/src/b.txt', type: 2 },
            { uri: 'file:///tmp/project/old.fake', type: 3 },
            { uri: 'file:///tmp/project/sub/x.json', type: 1 },
            { uri: 'file:///tmp/project/sub/x.json', type: 2 },   // the relative watcher ignores changes
            { uri: 'file:///tmp/project/other/y.json', type: 1 }, // outside its folder pattern
        ] });
        await new Promise((resolve) => setTimeout(resolve, 50));
        const events = await connection.sendRequest('commands/execute', { id: 'sample.fileEvents', args: [] });
        check(events.length === 4, 'four events: ' + JSON.stringify(events));
        check(events[0] === 'created /tmp/project/src/new.fake' && events[1] === 'changed /tmp/project/src/a.fake', 'create and change: ' + events[0]);
        check(events[2] === 'deleted /tmp/project/old.fake', 'delete');
        check(events[3] === 'relative created /tmp/project/sub/x.json', 'relative pattern, creations only: ' + events[3]);
    });

    await test('settings changes reach extensions', async () => {
        connection.sendNotification('workspace/didChangeConfiguration', { configuration: { 'sample.greeting': 'Ahoy' } });
        await new Promise((resolve) => setTimeout(resolve, 50));
        seen.messages.length = 0;
        await connection.sendRequest('commands/execute', { id: 'sample.hello', args: [] });
        check(seen.messages[0].message === 'Ahoy, world!', seen.messages[0].message);
    });

    await test('closing and shutting down is clean', async () => {
        lspNotify('textDocument/didClose', { textDocument: { uri: documentUri } });
        connection.sendNotification('lsp/close', { server: serverId });
        await connection.sendRequest('shutdown', {});
        connection.sendNotification('exit', {});
        await new Promise((resolve) => child.on('exit', resolve));
    });

    console.log(`\n${checks} checks, ${failures} failed`);
    process.exit(failures === 0 ? 0 : 1);
}

main().catch((error) => {
    console.error(error);
    process.exit(1);
});
