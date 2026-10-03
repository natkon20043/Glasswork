#!/usr/bin/env node
'use strict';

// Developer tool: downloads an extension from Open VSX, activates it in the extension host
// and prints what happened (logs, registered commands and providers, failures).
//
//   node host/tools/try-extension.js redhat.vscode-yaml [onLanguage:yaml ...]

const { spawn, execFileSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');
const https = require('https');
const { Connection } = require('../rpc');

function download(url, destination) {
    return new Promise((resolve, reject) => {
        https.get(url, { headers: { 'User-Agent': 'glasswork' } }, (response) => {
            if (response.statusCode >= 300 && response.statusCode < 400 && response.headers.location) {
                return resolve(download(response.headers.location, destination));
            }
            if (response.statusCode !== 200) {
                return reject(new Error(`HTTP ${response.statusCode} for ${url}`));
            }
            const file = fs.createWriteStream(destination);
            response.pipe(file);
            file.on('finish', () => file.close(resolve));
        }).on('error', reject);
    });
}

function getJson(url) {
    return new Promise((resolve, reject) => {
        https.get(url, { headers: { 'User-Agent': 'glasswork' } }, (response) => {
            let body = '';
            response.on('data', (chunk) => (body += chunk));
            response.on('end', () => {
                try { resolve(JSON.parse(body)); } catch (error) { reject(error); }
            });
        }).on('error', reject);
    });
}

async function main() {
    const [id, ...events] = process.argv.slice(2);
    if (!id) {
        console.error('usage: try-extension.js publisher.name [event ...]');
        process.exit(2);
    }
    const [publisher, name] = id.split('.');
    const cache = path.join(os.tmpdir(), 'gw-try-extension');
    const folder = path.join(cache, id);
    if (!fs.existsSync(path.join(folder, 'package.json'))) {
        fs.mkdirSync(folder, { recursive: true });
        const meta = await getJson(`https://open-vsx.org/api/${publisher}/${name}`);
        const url = meta.files && meta.files.download;
        if (!url) throw new Error('not found on Open VSX: ' + JSON.stringify(meta).slice(0, 200));
        const vsix = path.join(cache, `${id}.vsix`);
        await download(url, vsix);
        const unpack = path.join(cache, `${id}-unpack`);
        fs.rmSync(unpack, { recursive: true, force: true });
        execFileSync('unzip', ['-q', '-o', vsix, '-d', unpack]);
        fs.cpSync(path.join(unpack, 'extension'), folder, { recursive: true });
    }
    const manifest = JSON.parse(fs.readFileSync(path.join(folder, 'package.json'), 'utf8'));
    console.log(`== ${id} ${manifest.version}  main=${manifest.main}  activation=${JSON.stringify(manifest.activationEvents)}`);

    const child = spawn(process.execPath, [path.join(__dirname, '..', 'main.js')], { stdio: ['pipe', 'pipe', 'inherit'] });
    const connection = new Connection(child.stdout, child.stdin);
    const registered = [];
    connection.onNotification('ui/log', (p) => process.stdout.write(`[${p.channel}] ${p.text}`));
    connection.onNotification('commands/registered', (p) => registered.push(p.id));
    connection.onNotification('host/extensionState', (p) => console.log('state:', p.id, p.state, p.error ? '\n' + p.error : ''));
    connection.onNotification('lsp/message', (p) => {
        if (p.message.method === 'client/registerCapability') {
            console.log('capabilities:', p.message.params.registrations.map((r) => r.method).join(', '));
        }
    });
    for (const method of ['ui/showMessage', 'ui/quickPick', 'ui/inputBox', 'env/openExternal', 'workspace/applyEdit', 'commands/executeBuiltin', 'workspace/updateConfiguration', 'workspace/saveAll', 'ui/openDocument']) {
        connection.onRequest(method, async (params) => { console.log(`request ${method}`, JSON.stringify(params).slice(0, 160)); return null; });
    }
    await new Promise((resolve) => connection.onNotification('host/ready', resolve));

    const workspace = fs.mkdtempSync(path.join(os.tmpdir(), 'gw-try-workspace-'));
    await connection.sendRequest('initialize', {
        workspaceFolders: ['file://' + workspace],
        languageIds: [],
        configuration: {},
        storageRoot: path.join(cache, 'state'),
        extensions: [{ id, path: folder, manifest }],
    });
    for (const event of events.length ? events : ['onStartupFinished']) {
        await connection.sendRequest('host/event', { name: event });
    }
    // Activation by language: open a virtual server and let providers register.
    await new Promise((resolve) => setTimeout(resolve, 1500));
    const status = await connection.sendRequest('host/status', {});
    console.log('status:', JSON.stringify(status.extensions), 'providers:', status.providers, 'commands:', status.commands.length, registered.slice(0, 8).join(' '));
    await connection.sendRequest('shutdown', {});
    connection.sendNotification('exit', {});
}

main().catch((error) => {
    console.error(error);
    process.exit(1);
});
