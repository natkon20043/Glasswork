#pragma once

#import <AppKit/AppKit.h>

#import "LanguageService.h"
#import "Palette.h"

#include "LspServer.hpp"

NS_ASSUME_NONNULL_BEGIN

/// What the extension host service needs from the window it belongs to.
@protocol GWExtensionHostDelegate <NSObject>
@property (nonatomic, readonly, nullable) NSWindow *hostWindow;
/// Applies a WorkspaceEdit (from an extension, or a language feature that uses one). Returns whether it worked.
- (BOOL)hostApplyWorkspaceEdit:(const gw::lsp::Json &)edit;
- (void)hostOpenFileAtPath:(NSString *)path line:(NSInteger)line character:(NSInteger)character;
- (BOOL)hostSaveFileAtPath:(NSString *)path;
- (void)hostSaveAll;
/// Shows a line of text in the status bar for a while (0 seconds: until replaced).
- (void)hostShowStatusMessage:(NSString *)text seconds:(NSTimeInterval)seconds;
/// Extension status bar items or commands changed.
- (void)hostStatusItemsChanged;
/// An editor command an extension asked for by its VS Code id. Returns whether it was handled.
- (BOOL)hostRunBuiltinCommand:(NSString *)identifier arguments:(NSArray *)arguments;
/// The extensions now provide features for other languages: open files should be looked at again.
- (void)hostProvidersChanged;
/// An extension set a context key (`setContext`), which keybinding `when` clauses can test.
- (void)hostSetContextKey:(NSString *)key value:(NSString *)value;
/// An extension moved the cursors of a file (`editor.selections = …`). Selections are LSP positions.
- (void)hostSetSelections:(const gw::lsp::Json &)selections forPath:(NSString *)path;
/// An extension decorated text (`editor.setDecorations`): `options` is the decoration type's look,
/// each range may add `renderOptions`. No ranges removes the group `key`.
- (void)hostSetDecorationsForPath:(NSString *)path key:(NSString *)key options:(const gw::lsp::Json &)options ranges:(const gw::lsp::Json &)ranges;
/// An extension wants a range of a file in view.
- (void)hostRevealRange:(const gw::lsp::Json &)range forPath:(NSString *)path;
/// An extension inserts a snippet (`editor.insertSnippet`), replacing the given LSP ranges.
- (BOOL)hostInsertSnippet:(NSString *)snippet atRanges:(const gw::lsp::Json &)ranges forPath:(NSString *)path;
@end

/// One extension in the status bar.
@interface GWExtensionStatusItem : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *text;
@property (nonatomic, copy, nullable) NSString *tooltip;
@property (nonatomic, copy, nullable) NSString *command;
@property (nonatomic) NSInteger alignment;  // 1 left, 2 right
@property (nonatomic) double priority;
@end

/// Runs the VS Code extensions installed in Glasswork, one extension host per window.
///
/// The host is a Node.js process started only when something needs it: a file in a language an
/// extension serves, an extension that wants to run at startup, or one of its commands. Its
/// providers (completion, hover, formatting…) reach the editor as a virtual language server, so
/// they work through the same code as clangd's. Its commands appear in the command palette,
/// its status bar items and messages in the window, and its output in log files.
@interface GWExtensionHostService : NSObject <GWExtensionLanguageProvider>

@property (nonatomic, weak, nullable) id<GWExtensionHostDelegate> delegate;
/// The project folder.
@property (nonatomic, copy, nullable) NSString *rootFolder;
/// Status bar items extensions have shown, in the order they should appear.
@property (nonatomic, readonly) NSArray<GWExtensionStatusItem *> *statusItems;
/// Whether any installed extension has code to run.
@property (nonatomic, readonly) BOOL hasRunnableExtensions;
/// A short description for the status bar tooltip, e.g. "3 extensions running".
@property (nonatomic, readonly, copy) NSString *summary;

/// Starts the host now if an installed extension wants to run at startup.
- (void)startIfExtensionsWantToRun;
/// Palette rows for extension commands that match `query`.
- (NSArray<GWPaletteItem *> *)commandItemsForQuery:(NSString *)query;
/// Runs an extension command by id (from a status bar item, say).
- (void)executeCommand:(NSString *)identifier arguments:(nullable NSArray *)arguments;
/// Appends text to an output channel's log file (also used for language servers' own logs).
- (void)appendLog:(NSString *)text toChannel:(NSString *)channel;
/// A setting from settings.json (and what extensions saved), by dotted name: "python.analysis"
/// gives the whole section as an object. Null JSON when it isn't set.
- (gw::lsp::Json)configurationValueForSection:(NSString *)section;
/// All settings, as the object language servers get in `workspace/didChangeConfiguration`.
- (gw::lsp::Json)allSettings;
/// Opens an extension output channel's log file.
- (nullable NSURL *)logURLForChannel:(NSString *)channel;
- (NSArray<NSString *> *)logChannels;
/// Stops and forgets the host (extensions were installed or removed, or the window is closing).
- (void)shutdown;
/// Extensions were installed or removed: forget what was learned about the old set.
- (void)extensionsDidChange;
/// Tells the extensions which file is in front and where its cursors are (null JSON: no text file
/// is showing). Sent only when something changed.
- (void)setEditorState:(const gw::lsp::Json &)state;
/// Files changed on disk (absolute paths): extensions' file watchers fire for the matching ones.
- (void)filesDidChange:(NSArray<NSString *> *)paths;
/// Settings changed: tell the extensions.
- (void)settingsDidChange;

@end

NS_ASSUME_NONNULL_END
