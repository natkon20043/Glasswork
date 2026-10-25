# Glasswork
##
 Fully vibecoded slop! I wanted a nice and cool ide and I am working on other stuff. I have been sloping this project and just like how it looks! I think its cool, hope you do too!
##
A native macOS code editor with a C++20 core and an Objective-C++ AppKit interface using Liquid Glass. It has a built-in Claude chat, Git, project search and a terminal. Requires macOS 26 or newer.

Everything is native: no Electron, no web view, no JavaScript runtime. The text engine, TextMate tokenizer, diff, terminal emulator and Git layer are plain C++20 in `src/core`, tested without any UI.

## Build and check

Install Xcode, CMake and Ninja, then:

```sh
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build
ctest --test-dir build --output-on-failure
open build/app.noindex/Glasswork.app
```

`scripts/package.sh` builds a release, ad-hoc signs it and writes `dist/Glasswork.zip`. `scripts/install.sh` does that and installs the one `Glasswork.app` into `/Applications`. Development builds go into `build/app.noindex/`, which Spotlight ignores, so only the installed app shows up.

The first configuration downloads nlohmann/json and Oniguruma. A from-scratch build takes about 15 seconds on an M-series Mac.

## Features

**Editing**
- TextMate grammars and themes from Open VSX (Extensions menu), declarative language configuration.
- Quick Open (⌘P), command palette (⇧⌘P), section picker (⌃6), go to line (⌃G). Go ▸ Back and Forward (⌃- and ⌃⇧-) return to where you jumped from, like a browser, across files. File ▸ Open Recent lists folders and files you opened lately.
- Edit ▸ Transform: upper, lower and title case, sort lines up or down, remove duplicate lines; Join Lines (⌃J).
- Line commands: move (⌥↑/⌥↓), duplicate (⇧⌥↑/⇧⌥↓), delete (⇧⌘K), insert line below/above (⌘↩ / ⇧⌘↩), toggle comment (⌘/), indent/outdent. Brackets and quotes close themselves and wrap a selection.
- Expand Selection (⌃⇧⌘→) grows the selection from the word to the brackets around it, the line, the next brackets out and finally the whole file; Shrink Selection (⌃⇧⌘←) steps back. Go to Matching Bracket (⇧⌘\\) jumps to the other end of the bracket at the caret.
- Column selection: ⇧⌥-drag selects the same columns on every row you cross.
- Multiple cursors: ⌥-click, ⌘D for the next occurrence, ⌃⌘G for every occurrence, ⌥⌘↑/⌥⌘↓ for cursors above and below. Typing, deleting, Return, cut, copy, paste and movement act at every cursor as one undo step; Esc goes back to one.
- `.editorconfig` files set the indent style and size per file type, and `files.trimTrailingWhitespace` / `files.insertFinalNewline` (or the same keys in `.editorconfig`) clean up on save.
- Markdown files open a live rendered preview beside the tab (⇧⌘V); images (png, jpg, gif, svg, pdf…) open in their own tab.
- Find and replace in the file (⌘F, ⌥⌘F) and across the project (⇧⌘F), with case, whole word and regular expression options and file filters.
- MARK dividers, TODO/FIXME markers, rainbow brackets, indent guides, rainbow variable names, occurrence highlighting, a color inspector and per-name colors.
- Files changed outside the editor (by Claude, a build, git) reload straight away; the changed lines flash. Unsaved edits are never overwritten without asking.
- Soft word wrap (⌥Z, or `editor.wordWrap`) breaks at words and keeps a line's indentation on the rows below it. Code folding (⌥⌘[ and ⌥⌘], Fold All / Unfold All in the Edit menu, or the arrows in the line numbers) folds by indentation in every language.
- Several windows: New Window (⇧⌘N) or Open Folder in New Window (⌥⇧⌘O), each with its own folder, tabs, terminal and chat.
- Save All (⌥⌘S), Close Other Tabs (⌥⌘T) and Reopen Closed Tab (⇧⌘T, several deep, back to the line you left).
- Optional auto-save, and the open files, caret and scroll position of each folder come back when you reopen it.

**File tree**
- Right-click for New File, New Folder, Rename, Duplicate, Move to Trash, Copy (relative) Path, Reveal in Finder, Open in Terminal, Find in Folder and Ask Claude. Drag files to move them, hold ⌥ to copy; drop files from Finder to copy them in. Open tabs follow renames and moves.

**Git**
- Source Control tab: stage, unstage and discard files, commit, commit and push, amend, fetch, pull, push, switch and create branches, browse history, and have Claude write the commit message. Publish a new repository to GitHub or open a pull request through the `gh` CLI.
- Live change bars in the gutter (added, modified, removed) with a popover to revert or stage a single hunk; ⌃⌥↓ / ⌃⌥↑ step through changes.

**Claude**
- ⌘L opens a chat with Claude Code running in your project folder, using your own Claude Code login. It streams answers, shows tool calls and diffs of the files it edits, asks permission before running tools, and offers Ask, Accept Edits, Plan and Auto modes plus a model picker.
- ⇧⌘L sends the selected code as context; Explain, Find Problems, Write Tests and Improve are in the Claude menu.
- Earlier conversations are listed from Claude Code's own saved sessions and can be resumed.

**Debugger**
- Click the line numbers (or press F9) to set breakpoints; they move with your edits and are remembered per folder. F5 builds the file in front (C or C++) with debug symbols and runs it under LLDB; for a project, Run › Debug Executable… picks the program once and F5 reuses it.
- The Run and Debug tab (⇧⌘D) shows the call stack, the variables of the selected frame (expandable), and a console with the program's output where you can evaluate expressions. Step Over F10, Step Into F11, Step Out ⇧F11, Continue F5, Stop ⇧F5. The line the program is stopped on is marked in the editor. It uses `lldb-dap` from Xcode through the Debug Adapter Protocol.

**Tasks**
- Build (⇧⌘B), Run Task… (⌥⌘B) and Run Current File (⌥⌘R) find what your project can do — CMake, Swift packages, Cargo, Go modules, Xcode projects, npm/pnpm/yarn scripts, Makefile targets — and run it in a terminal set aside for tasks, after saving your files. Scripts (Python, JavaScript, Swift, shell, Ruby, Go…) and single C, C++ and Rust files run directly. File names in the output are clickable.

**Terminal**
- ⌃` toggles a real terminal (xterm-256color, true color, mouse, alternate screen, scrollback, wide characters). Vim, htop, tmux and `claude` itself work in it.

**Keyboard shortcuts**
- Beyond the menus' shortcuts, Glasswork reads VS Code keybindings: the ones extensions declare (`contributes.keybindings`) and your own in `~/Library/Application Support/Glasswork/keybindings.json` (Glasswork ▸ Keyboard Shortcuts (JSON)…, in VS Code's format: `{ "key": "cmd+shift+u", "command": "editor.action.transformToUppercase", "when": "editorTextFocus" }`). Saving the file applies it.
- Keys can be sequences (`cmd+k cmd+s`: the status bar says it is waiting for the next key), commands are VS Code's ids (about a hundred editor, file, search, debug and view commands are understood) or an extension's own, `args` are passed on, and a command starting with `-` removes a binding. `when` clauses support `&&`, `||`, `!`, `==`, `!=`, `=~` and the keys `editorTextFocus`, `terminalFocus`, `inputFocus`, `editorLangId`, `resourceExtname`, `resourceFilename`, `editorHasSelection`, `editorHasMultipleSelections`, `editorReadonly`, plus keys extensions set with `setContext`.

**Settings**
- ⌘, opens `~/Library/Application Support/Glasswork/settings.json` (JSON with comments). Changes apply as you save. Keys include `editor.fontSize`, `editor.fontFamily`, `editor.tabSize`, `editor.opacity`, `window.glassTint`, `window.frostedBackdrop`, `window.glassStyle`, `workbench.colorTheme`, `files.autoSave`, `files.formatOnSave`, `terminal.fontSize` and `terminal.shell`.
- **Look:** the panels are real Liquid Glass, which bends and blurs whatever is behind the window. `window.glassTint` (0 clear .. 1 heavy) sets how much color sits in the glass, `editor.opacity` how see-through the code background is, and `window.glassStyle` (`regular` or `clear`) picks the bar material. `window.frostedBackdrop` (default off) adds a blur behind the whole window; leaving it off keeps the refraction sharp and idle CPU near zero.

## Speed

Measured on this Mac (Apple silicon, macOS 26), opening the same 25 MB, 658,552-line C++ file:

| | Glasswork | Zed |
| --- | --- | --- |
| Window on screen, median of 5 launches | 452 ms | 664 ms |
| Memory after start | 249 MB | 981 MB |

(`bench/launch_bench.m` measures both the same way. Zed keeps working in the background for about 28 seconds after start, so its "idle" time is not compared here.)

Inside Glasswork, on that file (`GLASSWORK_BENCH=1`): typing a character and redrawing takes 1.3 ms, pressing Return 2.2 ms, a screenful of scrolling 2.0 ms, and jumping to a far line 11 ms. The tokenizer runs at about 20,000 lines per second, so a jump highlights a small stretch around the target first and the rest is filled in behind it.

Typing and scrolling latency of Zed could not be measured from outside the app (it needs the Accessibility permission), so there is no side-by-side figure for those. Run `./build/glasswork_bench` for the core numbers (search, fuzzy matching, diff, undo).

## Language servers

Glasswork talks to language servers over LSP, in the background, so typing never waits on them. A server starts the first time you open a file in its language and stops when you quit.

| Language | Server | Where it comes from |
| --- | --- | --- |
| C, C++, Objective-C(++) | clangd | Xcode (nothing to install) |
| Swift | sourcekit-lsp | Xcode (nothing to install) |
| Python | pyright-langserver | `npm install -g pyright` |
| TypeScript, JavaScript | typescript-language-server | `npm install -g typescript-language-server`, plus TypeScript 6 for it to use (TypeScript 7 has no `tsserver.js`): `npm install --prefix "$HOME/Library/Application Support/Glasswork/typescript" typescript@6`. A project's own `node_modules/typescript` is used first. |
| Rust | rust-analyzer | `rustup component add rust-analyzer` |
| Go | gopls | `go install golang.org/x/tools/gopls@latest` |

In files without a language server (plain text, Markdown, a new file, or while one is still starting) completion offers the words already in the file, after three letters or on ⌃Space.

If a server isn't installed, the status bar says so and the menu commands tell you how to install it. Turn everything off with `"lsp.enabled": false`.

What you get:

- **Problems** as you type: wavy underlines, a dot in the line numbers, the message at the end of the line (`editor.inlineDiagnostics`), and error and warning counts in the status bar. ⇧⌘M lists the problems in the file.
- **Inlay hints**: parameter names before arguments (`add(left: 3, right: 4)`), inferred types after `auto` and `let` variables, and the like, drawn inline as small chips from any language server that offers them (clangd, rust-analyzer, gopls, TypeScript…). `editor.inlayHints.enabled` turns them off. Hints make room in the line without changing the text, so the caret, selections and clicks stay where they should.
- **Snippets** from extensions (`contributes.snippets`: the language packs bring `for`, `class`, `log`…) and your own (`~/Library/Application Support/Glasswork/snippets/<language>.json`, or `*.code-snippets` files with a `scope`) join the completion list. They support VS Code's variables (`$TM_FILENAME`, `$CURRENT_YEAR`, `$CLIPBOARD`, `$UUID`…), tab stops, placeholders and mirrors.
- **Server messages and settings**: a server's `showMessage` appears in the status bar (and its log under Extensions ▸ Show Extension Output…), progress such as "clangd: Indexing 30%" shows while it lasts, questions with buttons open a sheet, and your settings answer the server's `workspace/configuration` requests (`python.analysis.*`, `rust-analyzer.*`, `gopls.*`… in settings.json, flat or nested) and are re-sent when they change.
- **Hover** (rest the pointer on a name): the declaration and documentation, plus any problems on it.
- **Completion** as you type, ranked the way VS Code does it (names that start with what you typed, word starts and camelCase humps, the case you typed, recently accepted names first, deprecated ones struck through and last), with ↑↓, ↩ or ⇥ to accept and ⎋ to close. The highlighted item's signature and documentation show in a panel beside the list. Servers that add imports when an item is chosen are asked first (`completionItem/resolve`), typing a commit character such as `.` or `(` accepts the item, and partial lists are re-requested as you keep typing. ⌃Space opens it on demand. Snippet completions (such as a function call with its arguments) select the first placeholder; ⇥ moves to the next one, ⇧⇥ back, and the same placeholder written twice is typed in both places at once. ⎋ or moving away ends it.
- **Signature help** while typing a call: the function's signature with the current argument in bold.
- **Quick Fix** (⌘.) lists the fixes and refactorings a server offers at the caret (extract variable, inline, convert…) and applies them, including ones the server carries out itself by running a command.
- **Go to Symbol in File** (⌘R) and **in Project** (⌘T).
- **Go to Definition** (⌃⌘D), **Find References** (⌃⌘R), **Rename Symbol** (F2, across all files) and **Format Document** (⇧⌥F), all in the Go menu.

Open the project folder and provide a `compile_commands.json` for accurate C-family includes. CMake users can set `CMAKE_EXPORT_COMPILE_COMMANDS`; clangd searches normal places such as the project's `build` folder.

Current boundaries:

- Documents over 4 MB aren't sent to servers.
- Edits are sent to the server as small ranges after each pause in typing (whole-file sync is the fallback for servers that ask for it and after very large bursts of edits).
- The client does not run downloaded extension JavaScript.

## Vim mode

View ▸ Vim Mode (or `"editor.vim": true` in settings.json) turns on Vim's modal editing. The status bar shows the mode and any command in progress; normal and visual modes draw a block cursor.

- **Modes:** normal, insert (`i a I A o O`, `Esc` or `⌃[` to leave), visual (`v`) and visual line (`V`).
- **Motions:** `h j k l`, `w b e` and `W B E`, `0 ^ $`, `gg G`, `f F t T` with `;` and `,`, `%`, `{ }`, and counts such as `3j` or `10w`.
- **Operators:** `d c y > <` with a motion (`dw`, `c$`, `y}`), doubled for lines (`dd`, `cc`, `yy`, `>>`), and with text objects (`iw aw`, quotes, `i( a( i{ a{ i[ a[ i< a<`). Also `x X D C s S Y`, `p P`, `r`, `~`, `J`, `u`, `⌃R` and `.`.
- **Visual mode:** the same motions and text objects extend the selection; `d y c > < J ~ u U r p` act on it.
- **Registers:** one register, shared with the system clipboard.
- **Search:** `/`, `?`, `n` and `N` use the find bar.
- **Command line:** `:w` saves; `:q` closes the file (refusing with unsaved changes, as Vim does; `:q!` closes anyway); `:wq` and `:x` save and close; `:wa`, `:qa` and `:wqa` do the same for every file. `:42` goes to line 42 (`:$` is the last line), and `:s/old/new/g` replaces on the current line, `:%s/old/new/g` everywhere, `:2,5s/…/…/` or `:'<,'>s/…/…/` on a range (the pattern is a regular expression in JavaScript's flavor; `g` is every match, `i` ignores case). In visual mode `:` starts on the selected lines.
- **Cursor smear:** when the cursor jumps it leaves a trail: a copy of the box right behind it at half strength, then a tail that narrows to a point, weaker still. The tail grows the longer the cursor keeps moving (hold `j` to see it build up). `"editor.vimCursorSmear": false` turns it off.

Marks, macros, named registers and split windows aren't there; the usual ⌘ shortcuts keep working in every mode. This is Glasswork's own implementation (`src/core/Vim.*`), not the VS Code Vim extension.

## VS Code extensions

Glasswork runs real VS Code extensions. Install one from the Extensions menu (Open VSX), and it works the way it does in VS Code: its commands appear in the command palette, its language features (completion, hover, formatting, diagnostics, code actions, rename…) appear in the editor, and its status bar items and messages appear in the window.

Extensions run in an **extension host**, a Node.js process Glasswork starts only when something needs it (a file in a language an installed extension serves, an extension that runs at startup, or one of its commands). It needs Node.js 18 or newer: the app made by `scripts/package.sh` carries its own copy (set `GLASSWORK_BUNDLE_NODE=0` to leave it out, or `GLASSWORK_NODE_BINARY` to choose which Node goes in); a development build uses the one on your PATH (`brew install node`). Each extension runs only when one of the events in its `package.json` fires (`onLanguage:…`, `onCommand:…`, `*`, `onStartupFinished`, `workspaceContains:…`), so installed extensions that aren't in use cost nothing.

How it fits together:

- `host/` is the host (JavaScript). `host/api/` implements the `vscode` module extensions `require` (or `import`): `commands`, `window`, `workspace`, `languages`, `env`, `extensions`, configuration, text documents, and the value types (`Position`, `Range`, `Uri`, `Diagnostic`, `CompletionItem`…). Tree views and webviews are real (`host/api/views.js`, shown by `app/ExtensionViews.*` and `app/WebviewController.*`): extensions' views appear under *Show Extension Views* (⌃⇧E) in the sidebar, webview panels open as editor tabs, and pages load their local files through a `gw-resource:` scheme. APIs without a Glasswork counterpart yet (notebooks, tests, debug adapters, terminals) exist but do nothing, so extensions that only touch them still activate; the first use of each is written to the Extension Host log.
- The providers an extension registers are presented to the editor as a **virtual language server** (`host/virtualServer.js`): requests such as `textDocument/completion` are answered by calling the extension's provider and converting the result to protocol JSON. So every language feature that works with clangd works with an extension, and an extension's server (such as the one the Red Hat YAML extension starts) is reached through its own language client, running unmodified.
- A file can follow several servers at once. Completion, hover, code actions, definitions and the like ask every server that supports them and merge the answers; formatting asks the extension first, so Prettier and similar formatters take over; everything else goes to the first server that supports it.
- `core/ExtensionHost.*` starts and supervises the host and gives each language a transport, `app/ExtensionHostService.*` connects it to the window.

**File icon themes**: install one such as Material Icon Theme, then Extensions ▸ Select File Icon Theme… (or `"workbench.iconTheme"` in settings.json). The file tree and the tabs draw the theme's SVG icons, chosen the way VS Code chooses them (exact file name, then the longest matching extension, then the language, then the default; folders by name, open or closed; separate icons for light color themes).

**Managing extensions**: Extensions ▸ Manage Extensions… lists everything installed; choose one to disable it (`extensions.disabled` in settings.json: its grammars, themes, snippets, icons, keybindings and code all stop), enable it again, or uninstall it.

**Finding extensions**: Extensions ▸ Search Extensions… (⇧⌘X) searches Open VSX live as you type (the most downloaded show first) and Return installs; Install by ID… takes a `publisher.name`.

Extensions can decorate text (`createTextEditorDecorationType` and `setDecorations`): background and border colors, text color, bold, italic, underline and strikethrough, whole-line highlights, theme colors, light and dark variants, and a note drawn after the end of the line (the way Error Lens shows messages). Decorations belong to the extension that made them and go away when it disposes the type.

Extensions can read and change the file in front (`window.activeTextEditor`: its document, selections and options, `edit`, `insertSnippet`, moving the cursors, and the active-editor and selection events), react to documents opening, changing and saving, and watch files on disk (`createFileSystemWatcher` gets real create, change and delete events). The same file events go to language servers that asked for them (`workspace/didChangeWatchedFiles`), so a new source file or an edited build file is noticed without reopening anything.

Extension output channels are plain log files (`~/Library/Application Support/Glasswork/extension-logs/`), opened from Extensions ▸ Show Extension Output…. Extensions ▸ Restart Extensions restarts the host. Settings an extension saves go to `extension-settings.json` next to `settings.json`, which is never rewritten.

Vim keys come from Glasswork itself (see **Vim mode**), not from the Vim extension, which can't take over key handling here.

Tried against the real extensions: Red Hat YAML (its language server runs and reports schema errors), Prettier (an ES module), Even Better TOML (WASM server), ESLint, Go and Vim activate; extensions that depend on features not listed above (Vim's key handling) load but those parts do nothing yet.

`node host/tools/try-extension.js publisher.name onLanguage:xyz` downloads an extension, activates it in a host of its own and prints what happened, which is the quickest way to see what an extension needs.

## Developer hooks

Environment variables for checking the interface without clicking:

- `GLASSWORK_ACTIONS="showSourceControl:,quickOpen:"` runs those actions in order after launch. Actions that the window does not handle are sent to the editor (for example `moveLinesDown:`).
- `GLASSWORK_PROMPT="text"` sends a message to Claude a few seconds after launch.
- `GLASSWORK_BENCH=1` runs the interaction benchmark on the file opened at launch, then quits.
- `GLASSWORK_TIMING=1` prints a startup timeline.
- `GLASSWORK_LSP_TRACE=1` prints every message to and from the language servers.
- `GLASSWORK_LSP_CLANGD=1 ./build/glasswork_lsp_server_tests` also runs the checks against the real clangd; `GLASSWORK_DAP_LIVE=1 ./build/glasswork_dap_tests` runs a real debugging session with lldb-dap.

## Next milestones

1. Split editors.
2. Conditional breakpoints and watch expressions.
3. Debugging other languages through their own adapters.

VS Code extension compatibility covers themes, grammars, language configuration and, through the extension host above, extensions' code. The parts of the `vscode` API that need new interface (terminals, notebooks, the test and debug UIs) are the remaining work.

## License

MIT. See [LICENSE](LICENSE). Oniguruma and nlohmann/json are fetched at build time under their own licenses.
