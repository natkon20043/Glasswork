const vscode = require('vscode');

function activate(context) {
    const output = vscode.window.createOutputChannel('Sample');
    output.appendLine('sample activated');

    const diagnostics = vscode.languages.createDiagnosticCollection('sample');
    context.subscriptions.push(diagnostics);

    context.subscriptions.push(
        vscode.commands.registerCommand('sample.hello', async (name) => {
            const greeting = vscode.workspace.getConfiguration('sample').get('greeting');
            const choice = await vscode.window.showInformationMessage(`${greeting}, ${name || 'world'}!`, 'Thanks', 'Dismiss');
            return choice;
        })
    );

    context.subscriptions.push(
        vscode.languages.registerCompletionItemProvider(
            'fake',
            {
                provideCompletionItems(document, position) {
                    const prefix = document.lineAt(position.line).text.slice(0, position.character);
                    const first = new vscode.CompletionItem('hello', vscode.CompletionItemKind.Function);
                    first.detail = 'says hello';
                    first.insertText = new vscode.SnippetString('hello(${1:name})');
                    first.documentation = new vscode.MarkdownString('Greets **someone**.');
                    const second = new vscode.CompletionItem('world', vscode.CompletionItemKind.Variable);
                    second.sortText = 'z';
                    void prefix;
                    return [first, second];
                },
                resolveCompletionItem(item) {
                    item.additionalTextEdits = [vscode.TextEdit.insert(new vscode.Position(0, 0), '// import hello\n')];
                    return item;
                },
            },
            '.'
        )
    );

    context.subscriptions.push(
        vscode.languages.registerHoverProvider('fake', {
            provideHover(document, position) {
                const range = document.getWordRangeAtPosition(position);
                if (!range) {
                    return undefined;
                }
                return new vscode.Hover(new vscode.MarkdownString('`' + document.getText(range) + '` is a word'), range);
            },
        })
    );

    context.subscriptions.push(
        vscode.languages.registerDefinitionProvider('fake', {
            provideDefinition(document, position) {
                return new vscode.Location(document.uri, new vscode.Position(0, 0));
            },
        })
    );

    context.subscriptions.push(
        vscode.languages.registerDocumentFormattingEditProvider('fake', {
            provideDocumentFormattingEdits(document) {
                const edits = [];
                for (let line = 0; line < document.lineCount; line++) {
                    const text = document.lineAt(line).text;
                    const trimmed = text.replace(/\s+$/, '');
                    if (trimmed !== text) {
                        edits.push(vscode.TextEdit.replace(new vscode.Range(line, trimmed.length, line, text.length), ''));
                    }
                }
                return edits;
            },
        })
    );

    context.subscriptions.push(
        vscode.workspace.onDidOpenTextDocument((document) => {
            if (document.languageId !== 'fake') {
                return;
            }
            const problems = [];
            const lines = document.getText().split('\n');
            lines.forEach((text, index) => {
                const column = text.indexOf('TODO');
                if (column >= 0) {
                    const diagnostic = new vscode.Diagnostic(new vscode.Range(index, column, index, column + 4), 'Found a TODO', vscode.DiagnosticSeverity.Warning);
                    diagnostic.source = 'sample';
                    problems.push(diagnostic);
                }
            });
            diagnostics.set(document.uri, problems);
        })
    );

    // Acts on the front editor: upper-cases every selection, and moves the cursor to the start.
    context.subscriptions.push(
        vscode.commands.registerCommand('sample.shout', async () => {
            const editor = vscode.window.activeTextEditor;
            if (!editor) {
                return 'no editor';
            }
            const applied = await editor.edit((builder) => {
                for (const selection of editor.selections) {
                    builder.replace(selection, editor.document.getText(selection).toUpperCase());
                }
            });
            editor.selection = new vscode.Selection(0, 0, 0, 0);
            return applied ? `shouted in ${editor.document.fileName}` : 'edit refused';
        })
    );
    context.subscriptions.push(
        vscode.commands.registerCommand('sample.snippet', async () => {
            const editor = vscode.window.activeTextEditor;
            await editor.insertSnippet(new vscode.SnippetString('x = ${1:value};$0'));
            return 'inserted';
        })
    );
    const editorEvents = [];
    context.subscriptions.push(vscode.window.onDidChangeActiveTextEditor((editor) => editorEvents.push('active:' + (editor ? editor.document.languageId : 'none'))));
    context.subscriptions.push(vscode.window.onDidChangeTextEditorSelection((event) => editorEvents.push('selection:' + event.selections.length)));
    context.subscriptions.push(vscode.commands.registerCommand('sample.editorEvents', () => editorEvents.slice()));

    const marker = vscode.window.createTextEditorDecorationType({
        backgroundColor: new vscode.ThemeColor('editor.findMatchBackground'),
        isWholeLine: false,
        after: { color: '#888888', fontStyle: 'italic' },
    });
    context.subscriptions.push(
        vscode.commands.registerCommand('sample.decorate', () => {
            const editor = vscode.window.activeTextEditor;
            editor.setDecorations(marker, [
                new vscode.Range(0, 0, 0, 5),
                { range: new vscode.Range(1, 0, 1, 4), renderOptions: { after: { contentText: ' ← fix this' } } },
            ]);
            return 'decorated';
        })
    );
    context.subscriptions.push(vscode.commands.registerCommand('sample.undecorate', () => { marker.dispose(); return 'cleared'; }));

    context.subscriptions.push(vscode.commands.registerCommand('sample.tabs', () => vscode.window.tabGroups.all.map((group) => group.tabs.map((tab) => tab.label + (tab.isActive ? '*' : '')))));

    // A tree view: fruit with varieties underneath, and a command that changes the data.
    const treeChanged = new vscode.EventEmitter();
    let fruit = ['Apple', 'Banana'];
    const clicked = [];
    const treeView = vscode.window.createTreeView('sample.tree', {
        treeDataProvider: {
            onDidChangeTreeData: treeChanged.event,
            getTreeItem(name) {
                const parent = name.includes(':');
                const item = new vscode.TreeItem(parent ? name.split(':')[1] : name, parent ? vscode.TreeItemCollapsibleState.None : vscode.TreeItemCollapsibleState.Collapsed);
                item.description = parent ? 'variety' : undefined;
                item.contextValue = parent ? 'variety' : 'fruit';
                item.iconPath = new vscode.ThemeIcon(parent ? 'leaf' : 'circle-filled');
                if (parent) item.command = { command: 'sample.picked', title: 'Pick', arguments: [name] };
                return item;
            },
            getChildren(element) {
                if (!element) {
                    return fruit;
                }
                return [element + ':Red ' + element, element + ':Green ' + element];
            },
        },
    });
    context.subscriptions.push(treeView);
    context.subscriptions.push(vscode.commands.registerCommand('sample.picked', (name) => { clicked.push(name); }));
    context.subscriptions.push(vscode.commands.registerCommand('sample.treeClicked', () => clicked.slice()));
    context.subscriptions.push(vscode.commands.registerCommand('sample.treeRefresh', () => { fruit = ['Cherry']; treeChanged.fire(); }));
    context.subscriptions.push(vscode.commands.registerCommand('sample.treeTitle', () => { treeView.title = 'Fruit'; treeView.message = 'Pick one'; }));
    const selections = [];
    context.subscriptions.push(treeView.onDidChangeSelection((event) => selections.push(event.selection.join(','))));
    context.subscriptions.push(vscode.commands.registerCommand('sample.treeSelections', () => selections.slice()));

    // A webview panel that echoes what the page sends, and a sidebar webview view.
    const received = [];
    context.subscriptions.push(
        vscode.commands.registerCommand('sample.openWebview', () => {
            const panel = vscode.window.createWebviewPanel('sample.page', 'Sample Page', vscode.ViewColumn.Beside, { enableScripts: true });
            panel.webview.html = '<h1>Hello page</h1>' + panel.webview.asWebviewUri(vscode.Uri.file('/tmp/a b/style.css')).toString();
            panel.webview.onDidReceiveMessage((message) => {
                received.push(message);
                panel.webview.postMessage({ echo: message });
            });
            panel.onDidDispose(() => received.push('disposed'));
            panel.title = 'Renamed';
            return 'opened';
        })
    );
    context.subscriptions.push(vscode.commands.registerCommand('sample.webviewReceived', () => received.slice()));
    context.subscriptions.push(
        vscode.window.registerWebviewViewProvider('sample.webviewView', {
            resolveWebviewView(view) {
                view.webview.options = { enableScripts: true };
                view.webview.html = '<p>side view</p>';
                view.webview.onDidReceiveMessage((message) => received.push('view:' + message));
            },
        })
    );

    context.subscriptions.push(vscode.commands.registerCommand('sample.crash', () => process.exit(7)));

    const fileEvents = [];
    const watcher = vscode.workspace.createFileSystemWatcher('**/*.fake');
    context.subscriptions.push(watcher.onDidCreate((uri) => fileEvents.push('created ' + uri.fsPath)));
    context.subscriptions.push(watcher.onDidChange((uri) => fileEvents.push('changed ' + uri.fsPath)));
    context.subscriptions.push(watcher.onDidDelete((uri) => fileEvents.push('deleted ' + uri.fsPath)));
    const relative = vscode.workspace.createFileSystemWatcher(new vscode.RelativePattern('/tmp/project', 'sub/*.json'), false, true, true);
    context.subscriptions.push(relative.onDidCreate((uri) => fileEvents.push('relative created ' + uri.fsPath)));
    context.subscriptions.push(relative.onDidChange((uri) => fileEvents.push('relative changed ' + uri.fsPath)));
    context.subscriptions.push(vscode.commands.registerCommand('sample.fileEvents', () => fileEvents.slice()));

    const status = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Right, 10);
    status.text = '$(smiley) Sample';
    status.command = 'sample.hello';
    status.show();

    console.log('console.log from the extension');
    return { answer: 42 };
}

function deactivate() {}

module.exports = { activate, deactivate };
