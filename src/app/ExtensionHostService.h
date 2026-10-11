#pragma once

#import <AppKit/AppKit.h>

#import "LanguageService.h"
#import "Palette.h"

#include "LspServer.hpp"

NS_ASSUME_NONNULL_BEGIN

/// What the extension host service needs from its window.
@protocol GWExtensionHostDelegate <NSObject>

// ---- Files
/// Returns whether the edit worked.
- (BOOL)hostApplyWorkspaceEdit:(const gw::lsp::Json &)edit;
- (void)hostOpenFileAtPath:(NSString *)path line:(NSInteger)line character:(NSInteger)character;
- (BOOL)hostSaveFileAtPath:(NSString *)path;
- (void)hostSaveAll;

// ---- Editor
/// Returns whether the command was handled; `identifier` is its VS Code id.
- (BOOL)hostRunBuiltinCommand:(NSString *)identifier arguments:(NSArray *)arguments;
/// Selections are LSP positions (`editor.selections = ...`).
- (void)hostSetSelections:(const gw::lsp::Json &)selections forPath:(NSString *)path;
/// `options` is the decoration type's look; each range may add `renderOptions`. No ranges removes group `key`.
- (void)hostSetDecorationsForPath:(NSString *)path
                              key:(NSString *)key
                          options:(const gw::lsp::Json &)options
                           ranges:(const gw::lsp::Json &)ranges;
- (void)hostRevealRange:(const gw::lsp::Json &)range forPath:(NSString *)path;
/// Replaces the given LSP ranges (`editor.insertSnippet`).
- (BOOL)hostInsertSnippet:(NSString *)snippet atRanges:(const gw::lsp::Json &)ranges forPath:(NSString *)path;
/// Open files should be looked at again.
- (void)hostProvidersChanged;
/// Context key (`setContext`) that keybinding `when` clauses can test.
- (void)hostSetContextKey:(NSString *)key value:(NSString *)value;

// ---- Status bar
/// 0 seconds: until replaced.
- (void)hostShowStatusMessage:(NSString *)text seconds:(NSTimeInterval)seconds;
- (void)hostStatusItemsChanged;

// ---- Properties
@property (nonatomic, readonly, nullable) NSWindow *hostWindow;

@end

/// Where tree views and webviews are shown; receives the host's `view/...` and `webview/...` messages.
@protocol GWExtensionViewsDelegate <NSObject>

- (void)hostViewNotification:(NSString *)method params:(const gw::lsp::Json &)params;
/// The host asks something of a webview (`webview/postMessage`). Call `reply` once.
- (void)hostViewRequest:(NSString *)method
                 params:(const gw::lsp::Json &)params
                  reply:(void (^)(const gw::lsp::Json &result))reply;
/// The host stopped, so its views and webviews are gone.
- (void)hostViewsDidReset;

@end

/// One extension's status bar item.
@interface GWExtensionStatusItem : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *text;
@property (nonatomic, copy, nullable) NSString *tooltip;
@property (nonatomic, copy, nullable) NSString *command;
/// 1 left, 2 right.
@property (nonatomic) NSInteger alignment;
@property (nonatomic) double priority;
@end

/// A sidebar view from `contributes.views`: a tree of its own, or a webview.
@interface GWContributedView : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *containerIdentifier;
@property (nonatomic, copy) NSString *containerTitle;
/// Image file in the extension, if it gave one.
@property (nonatomic, copy, nullable) NSString *containerIcon;
@property (nonatomic, copy) NSString *extensionIdentifier;
@property (nonatomic, copy) NSString *when;
@property (nonatomic) BOOL isWebview;
@end

/// Runs installed VS Code extensions, one extension host per window. The Node.js host starts only
/// when something needs it. Its providers reach the editor as a virtual language server; commands,
/// status items and messages appear in the window and output goes to log files.
@interface GWExtensionHostService : NSObject <GWExtensionLanguageProvider>

// ---- Lifecycle
- (void)startIfExtensionsWantToRun;
/// Stops and forgets the host (extensions installed/removed, or window closing).
- (void)shutdown;
/// Forget what was learned about the old extension set.
- (void)extensionsDidChange;

// ---- Commands
/// Palette rows for extension commands matching `query`.
- (NSArray<GWPaletteItem *> *)commandItemsForQuery:(NSString *)query;
- (void)executeCommand:(NSString *)identifier arguments:(nullable NSArray *)arguments;
/// Manifest title with category, or nil.
- (nullable NSString *)titleForCommand:(NSString *)identifier;

// ---- Views
/// Known before any extension runs.
- (NSArray<GWContributedView *> *)contributedViews;
/// `view/item/context` and `view/title` menu entries as JSON.
- (gw::lsp::Json)contributedViewMenus;
/// Wakes the extension behind a view (`onView:<id>`), starting the host if needed. `done` gets whether it runs.
- (void)activateView:(NSString *)viewIdentifier completion:(void (^)(BOOL ok))done;
/// Starts nothing, so call after `activateView`.
- (void)sendViewRequest:(NSString *)method
                 params:(gw::lsp::Json)params
             completion:(void (^)(const gw::lsp::Json &result, NSString *_Nullable error))completion;
- (void)sendViewNotification:(NSString *)method params:(gw::lsp::Json)params;

// ---- Editor and file state
/// Which file is in front and where its cursors are; null JSON when no text file shows. Send only on change.
- (void)setEditorState:(const gw::lsp::Json &)state;
/// Absolute paths; matching extension file watchers fire.
- (void)filesDidChange:(NSArray<NSString *> *)paths;
- (void)settingsDidChange;

// ---- Settings
/// Dotted name; "python.analysis" gives the whole section. Null JSON when unset.
- (gw::lsp::Json)configurationValueForSection:(NSString *)section;
/// The object language servers get in `workspace/didChangeConfiguration`.
- (gw::lsp::Json)allSettings;

// ---- Logs
- (void)appendLog:(NSString *)text toChannel:(NSString *)channel;
- (nullable NSURL *)logURLForChannel:(NSString *)channel;
- (NSArray<NSString *> *)logChannels;

// ---- Properties
@property (nonatomic, weak, nullable) id<GWExtensionHostDelegate> delegate;
@property (nonatomic, weak, nullable) id<GWExtensionViewsDelegate> viewsDelegate;
@property (nonatomic, copy, nullable) NSString *rootFolder;
/// In display order.
@property (nonatomic, readonly) NSArray<GWExtensionStatusItem *> *statusItems;
/// Any installed extension has code to run.
@property (nonatomic, readonly) BOOL hasRunnableExtensions;
/// Status bar tooltip, e.g. "3 extensions running".
@property (nonatomic, readonly, copy) NSString *summary;

@end

NS_ASSUME_NONNULL_END
