# Glasswork architecture

Welcome to Nates Glasswork ide. I created this ide because I wanted a beautiful nice and pretty
and fun ide I can use and play with. I love liquid glass on mac and I wanted more stuff with it.
Also mac only has that stupid half ide thats meant for swift and nobody likes swift. WE WANT C!

Since Claude wanted me to use rust to program this (and I didnt want to have to tell everyone I use
rust)
Glasswork is two layers:

- **`src/core`** – plain C++20. No Apple frameworks, no UI. Everything here has tests that run
  without a window.
- **`src/app`** – Objective-C++ (AppKit). Windows, drawing, menus. It calls the core and never
  the other way round.
(Because for some reason stinky apple doesnt like real mans C++ libraries)

`tests/` holds one test program per area (`ctest` runs them all); `bench/` holds the speed
measurements.
I intentionally made this app to be faster than zed and prettier than any vscode build. I have been trying to add in
vsx but its hard :/
## The text

| File | What it is |
| --- | --- |
| `core/FileBytes.*` | A file's bytes, frozen when it was opened. Files of 64 KB or more are **cloned** (APFS shares the disk blocks, nothing is copied) and the clone is memory-mapped, so another program rewriting or shortening the original can't crash us or change the open text. Smaller files, and ones on volumes that can't clone, are read. |
| `core/LineStore.*` | Where the lines live. Each line is an 8-byte `LineRef {offset, length}` into the `FileBytes`. Lines are split by up to 8 threads (count, allocate once, fill). A line is copied into its own `std::string` only when edited (kept in a `deque` so other lines' views stay valid). Every line keeps its own break (`\n` or `\r\n`): an unedited line reads it from the byte after it, an edited one stores it, so files with mixed endings and binary bytes save byte for byte. `static_assert`s pin `sizeof(LineRef) == 8`. |
| `core/TextBuffer.*` | The editing interface over a `LineStore`: insert, erase, cursor movement, word/character boundaries (UTF-8 aware). `line(i)` returns a `std::string_view`. |
| `core/Document.*` | A `TextBuffer` plus file path, undo/redo, selection(s), dirty flag, breakpoints. Every edit goes through `Document::replace`, which records undo, moves extra cursors and breakpoints, and calls `onChange`. |
| `core/Highlighter.*` | Runs the TextMate tokenizer top-down, one line at a time, keeping each line's end state. After an edit it re-tokenizes only until the state matches what it was. "Islands" tokenize a small stretch for far jumps. Its arrays grow with the lines tokenized, not with the file. |
| `core/textmate/*` | The TextMate engine: grammar loading, scope matching, Oniguruma wrapper (with a first-byte prefilter that skips impossible matches). |

**Memory for a 25 MB, 634k-line file** (measured with `ps`, app alone is ~134 MB):
file block 25 MB + line references 5 MB + a few small per-line arrays ≈ 43 MB above the empty app.
Since files are mapped, the 25 MB of file bytes are the system's file cache rather than the app's
own memory (macOS can drop them under pressure); a 185 MB file costs 38 MB instead of 224 MB.

Saving writes the exact bytes to a temporary file, waits until they are stored on the disk itself
(`F_FULLFSYNC`; plain `fsync` on macOS stops at the drive's cache) and renames it over the original,
so after a crash or power cut the file holds the old or the new contents, never a half-written or empty file.

## Layout helpers (used by the editor view)

- `core/RowMap.*` – a **Fenwick tree** mapping document lines to screen rows and back in
  O(log n). Only exists while word wrap or folding is on; otherwise row == line.
- `core/Wrap.*` – soft wrapping by character cells (tabs, wide characters).
- `core/Folding.*` – indentation folding and `FoldSet`, the sorted list of folded blocks.
- `core/SemanticTokens.*`, `core/EditorConfig.*`, `core/Tasks.*` – small, self-contained parsers.

## Talking to other programs

- `core/Process.*` – `posix_spawn` wrappers: run-to-completion (`runProcess`) and streaming
  (`ChildProcess`, with a reader thread).
- `core/LanguageServer.*` + `core/LspServer.*` – LSP framing (`Decoder`) and an asynchronous
  client (`LanguageServer`). `app/LanguageService.*` decides which server a file uses, keeps
  documents in sync (debounced), and turns answers into editor features.
- `core/Dap.*` – Debug Adapter Protocol client (`lldb-dap`). `app/Debugger.*` is the session
  logic; `app/DebugPanel.*` is the sidebar.
- `core/ClaudeProtocol.*`, `core/ClaudeSession.*` – the `claude` CLI's streaming JSON protocol.
  `app/ChatPanel.*` is the chat UI.
- `core/Git.*` – git through the `git` and `gh` commands. `core/LineDiff.*` is the in-process
  diff behind the gutter change bars.
- `core/Terminal.*`, `core/Pty.*` – terminal emulator and pseudo-terminal.

## The app layer

- `MainWindow.mm` – the window controller: tabs, sidebar modes, status bar, and the glue between
  every panel. It is big on purpose: one place that knows about all the parts.
- `EditorView.mm` – draws and edits the text: layouts (CoreText), selections and multiple
  cursors, wrap/fold rows, gutter, minimap, sticky scroll, completion/hover hooks.
- `Palette.mm`, `CompletionPopup.mm`, `ShadowedGlass.*` – floating panels (the shadow is drawn
  by `ShadowedGlass` so rounded corners have no outline).
- `Services.mm` – settings, themes, extensions (shared by all windows).

## Ideas for further optimisation

- `Highlighter::tokens_` is a `vector<vector<Token>>`: one heap allocation per tokenized line.
  A single arena of tokens with `(start, count)` per line would remove them.
- `tm::State` holds a `std::vector<Frame>` per line; most lines share the same state, so
  interning states (a pointer or index per line) would save memory and make the "did the state
  change?" comparison a pointer compare.
- `Minimap` and `_depthAt` keep per-line arrays for the whole file (2.5 MB each here).
- Files are read into memory with `read()` rather than `mmap`: a file another program shrinks
  while it is mapped would crash the editor (SIGBUS), and Claude and build tools rewrite files
  constantly.
