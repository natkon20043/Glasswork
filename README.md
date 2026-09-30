# Glasswork

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
- Quick Open (⌘P), command palette (⇧⌘P), section picker (⌃6), go to line (⌃G).
- Line commands: move (⌥↑/⌥↓), duplicate (⇧⌥↑/⇧⌥↓), delete (⇧⌘K), insert line below/above (⌘↩ / ⇧⌘↩), toggle comment (⌘/), indent/outdent. Brackets and quotes close themselves and wrap a selection.
- Multiple cursors: ⌥-click, ⌘D for the next occurrence, ⌃⌘G for every occurrence, ⌥⌘↑/⌥⌘↓ for cursors above and below. Typing, deleting, Return, cut, copy, paste and movement act at every cursor as one undo step; Esc goes back to one.
- `.editorconfig` files set the indent style and size per file type, and `files.trimTrailingWhitespace` / `files.insertFinalNewline` (or the same keys in `.editorconfig`) clean up on save.
- Markdown files open a live rendered preview beside the tab (⇧⌘V); images (png, jpg, gif, svg, pdf…) open in their own tab.
- Find and replace in the file (⌘F, ⌥⌘F) and across the project (⇧⌘F), with case, whole word and regular expression options and file filters.
- MARK dividers, TODO/FIXME markers, rainbow brackets, indent guides, rainbow variable names, occurrence highlighting, a colour inspector and per-name colours.
- Files changed outside the editor (by Claude, a build, git) reload straight away; the changed lines flash. Unsaved edits are never overwritten without asking.
- Soft word wrap (⌥Z, or `editor.wordWrap`) breaks at words and keeps a line's indentation on the rows below it. Code folding (⌥⌘[ and ⌥⌘], Fold All / Unfold All in the Edit menu, or the arrows in the line numbers) folds by indentation in every language.
- Several windows: New Window (⇧⌘N) or Open Folder in New Window (⌥⇧⌘O), each with its own folder, tabs, terminal and chat.
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
- ⌃` toggles a real terminal (xterm-256color, true colour, mouse, alternate screen, scrollback, wide characters). Vim, htop, tmux and `claude` itself work in it.

**Settings**
- ⌘, opens `~/Library/Application Support/Glasswork/settings.json` (JSON with comments). Changes apply as you save. Keys include `editor.fontSize`, `editor.fontFamily`, `editor.tabSize`, `editor.opacity`, `workbench.colorTheme`, `files.autoSave`, `terminal.fontSize` and `terminal.shell`.

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
| TypeScript, JavaScript | typescript-language-server | `npm install -g typescript typescript-language-server` |
| Rust | rust-analyzer | `rustup component add rust-analyzer` |
| Go | gopls | `go install golang.org/x/tools/gopls@latest` |

If a server isn't installed, the status bar says so and the menu commands tell you how to install it. Turn everything off with `"lsp.enabled": false`.

What you get:

- **Problems** as you type: wavy underlines, a dot in the line numbers, the message at the end of the line (`editor.inlineDiagnostics`), and error and warning counts in the status bar. ⇧⌘M lists the problems in the file.
- **Hover** (rest the pointer on a name): the declaration and documentation, plus any problems on it.
- **Completion** as you type, fuzzy-filtered, with ↑↓, ↩ or ⇥ to accept and ⎋ to close. ⌃Space opens it on demand.
- **Signature help** while typing a call: the function's signature with the current argument in bold.
- **Quick Fix** (⌘.) applies the fixes a server offers for the problems at the caret.
- **Go to Symbol in File** (⌘R) and **in Project** (⌘T).
- **Go to Definition** (⌃⌘D), **Find References** (⌃⌘R), **Rename Symbol** (F2, across all files) and **Format Document** (⇧⌥F), all in the Go menu.

Open the project folder and provide a `compile_commands.json` for accurate C-family includes. CMake users can set `CMAKE_EXPORT_COMPILE_COMMANDS`; clangd searches normal places such as the project's `build` folder.

Current boundaries:

- Snippet completions insert their placeholder text without tab stops.
- Documents over 4 MB aren't sent to servers.
- Files are sent whole after each pause in typing, not as incremental edits.
- The client does not run downloaded extension JavaScript, and semantic-token colouring isn't used yet.

## Developer hooks

Environment variables for checking the interface without clicking:

- `GLASSWORK_ACTIONS="showSourceControl:,quickOpen:"` runs those actions in order after launch. Actions that the window does not handle are sent to the editor (for example `moveLinesDown:`).
- `GLASSWORK_PROMPT="text"` sends a message to Claude a few seconds after launch.
- `GLASSWORK_BENCH=1` runs the interaction benchmark on the file opened at launch, then quits.
- `GLASSWORK_TIMING=1` prints a startup timeline.
- `GLASSWORK_LSP_TRACE=1` prints every message to and from the language servers.
- `GLASSWORK_LSP_CLANGD=1 ./build/glasswork_lsp_server_tests` also runs the checks against the real clangd; `GLASSWORK_DAP_LIVE=1 ./build/glasswork_dap_tests` runs a real debugging session with lldb-dap.

## Next milestones

1. Refactoring code actions that need the server to run commands, and semantic-token colours.
2. Incremental document sync, column selection and split editors.
3. Debugging other languages through their own adapters, conditional breakpoints and watch expressions.

VS Code extension compatibility currently means themes, grammars and declarative language configuration. Running its general JavaScript extension ecosystem requires an extension host/API compatibility project; it is not provided by LSP alone.

## License

MIT. See [LICENSE](LICENSE). Oniguruma and nlohmann/json are fetched at build time under their own licenses.
