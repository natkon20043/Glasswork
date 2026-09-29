# Glasswork

A native macOS code editor with a C++20 core and an Objective-C++ AppKit interface using Liquid Glass. It has a built-in Claude chat, Git, project search and a terminal. Requires macOS 26 or newer.

Everything is native: no Electron, no web view, no JavaScript runtime. The text engine, TextMate tokenizer, diff, terminal emulator and Git layer are plain C++20 in `src/core`, tested without any UI.

## Build and check

Install Xcode, CMake and Ninja, then:

```sh
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build
ctest --test-dir build --output-on-failure
open build/Glasswork.app
```

`scripts/package.sh` builds a release, ad-hoc signs it and writes `dist/Glasswork.zip`.

The first configuration downloads nlohmann/json and Oniguruma. A from-scratch build takes about 15 seconds on an M-series Mac.

## Features

**Editing**
- TextMate grammars and themes from Open VSX (Extensions menu), declarative language configuration.
- Quick Open (⌘P), command palette (⇧⌘P), section picker (⌃6), go to line (⌃G).
- Line commands: move (⌥↑/⌥↓), duplicate (⇧⌥↑/⇧⌥↓), delete (⇧⌘K), insert line below/above (⌘↩ / ⇧⌘↩), toggle comment (⌘/), indent/outdent, select next occurrence (⌘D). Brackets and quotes close themselves and wrap a selection.
- Find and replace in the file (⌘F, ⌥⌘F) and across the project (⇧⌘F), with case, whole word and regular expression options and file filters.
- MARK dividers, TODO/FIXME markers, rainbow brackets, indent guides, rainbow variable names, occurrence highlighting, a colour inspector and per-name colours.
- Files changed outside the editor (by Claude, a build, git) reload straight away; the changed lines flash. Unsaved edits are never overwritten without asking.
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

Inside Glasswork, on that file (`GLASSWORK_BENCH=1`): typing a character and redrawing takes 3.1 ms, a screenful of scrolling 2.8 ms, and jumping to a far line 16 ms. The tokenizer runs at about 20,000 lines per second, so a jump highlights a small stretch around the target first and the rest is filled in behind it.

Typing and scrolling latency of Zed could not be measured from outside the app (it needs the Accessibility permission), so there is no side-by-side figure for those. Run `./build/glasswork_bench` for the core numbers (search, fuzzy matching, diff, undo).

## C-family code intelligence

Use the **Go** menu while editing a saved C/C++/Objective-C/Objective-C++ file:

| Command | Shortcut |
| --- | --- |
| Complete Code | Control–Space |
| Go to Definition | Control–Command–D |
| Find References | Control–Command–R |
| Check File for Problems | Shift–Command–M |

The commands lazily start one local clangd process, off the UI thread. Open unsaved buffers are synchronized before each request; you do not have to save each change. Definitions open at the exact symbol column. References and diagnostics appear in the glass picker and navigate to their source locations. Completion insertion is undoable. If macOS reserves a shortcut (such as Control–Space), use the Go menu.

Open the project folder and provide a `compile_commands.json` for accurate includes and compiler flags. CMake users can enable `CMAKE_EXPORT_COMPILE_COMMANDS`; clangd searches normal locations such as the project's `build` directory. Without compiler flags, fallback parsing may report missing includes or misleading diagnostics.

Current boundaries:

- Completion and diagnostics are requested explicitly; no automatic popup or live gutter diagnostics yet.
- Only the active Xcode clangd is configured. Other language servers need a server configuration layer.
- Snippet completions and completion items with additional edits are not offered yet.
- Requests have a timeout, run serially and ignore results after document/caret changes. A failed server is restarted on the next command.
- The client supports UTF-16 LSP positions, full-document synchronization and framed JSON-RPC. It does not run downloaded extension JavaScript.
- Idle servers can retain project indexes in memory until the window/controller closes or the app exits.

## Developer hooks

Environment variables for checking the interface without clicking:

- `GLASSWORK_ACTIONS="showSourceControl:,quickOpen:"` runs those actions in order after launch. Actions that the window does not handle are sent to the editor (for example `moveLinesDown:`).
- `GLASSWORK_PROMPT="text"` sends a message to Claude a few seconds after launch.
- `GLASSWORK_BENCH=1` runs the interaction benchmark on the file opened at launch, then quits.
- `GLASSWORK_TIMING=1` prints a startup timeline.

## Next milestones

1. Continuous diagnostics, inline completion UI, hover documentation and signature help.
2. Workspace edits: rename, code actions, formatting.
3. Configurable language servers and semantic tokens.
4. Soft wrap and code folding.
5. Debug Adapter Protocol.

VS Code extension compatibility currently means themes, grammars and declarative language configuration. Running its general JavaScript extension ecosystem requires an extension host/API compatibility project; it is not provided by LSP alone.
