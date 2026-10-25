#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// A Glasswork window: glass sidebar with folder tree, tabs, editor and status bar.
@interface GWMainWindowController : NSWindowController <NSWindowDelegate>

// ---- Opening
/// A file opens in a tab, a folder in the sidebar.
- (void)openURL:(NSURL *)url;
- (IBAction)openFolder:(nullable id)sender;
/// Opens a folder on another machine over SSH.
- (IBAction)openRemoteFolder:(nullable id)sender;
/// For development (see GLASSWORK_REMOTE): opens a remote folder and/or file given as "host:/path".
- (void)debugOpenRemoteFolder:(nullable NSString *)folder file:(nullable NSString *)file;

// ---- Tabs and navigation
- (IBAction)goBack:(nullable id)sender;
- (IBAction)goForward:(nullable id)sender;
- (IBAction)reopenClosedTab:(nullable id)sender;
- (IBAction)closeOtherTabs:(nullable id)sender;
- (IBAction)saveAllDocuments:(nullable id)sender;
/// Asks about unsaved changes. NO if the user cancelled.
- (BOOL)confirmCloseAll;

// ---- Debugging and development
/// Renders the editor from its drawing code into a PNG.
- (void)writeEditorSnapshotTo:(NSString *)path;
/// Opens the chat and sends a message (GLASSWORK_PROMPT).
- (void)debugSendChatPrompt:(NSString *)prompt;
/// GLASSWORK_COMMANDS.
- (void)debugRunExtensionCommand:(NSString *)identifier;
- (BOOL)debugPerformEditorAction:(SEL)action;
/// Times typing, scrolling and jumping in the open file, prints results and quits (GLASSWORK_BENCH).
- (void)runInteractionBenchmark;

@end

NS_ASSUME_NONNULL_END
