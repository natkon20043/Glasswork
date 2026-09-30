#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// A Glasswork window: glass sidebar with a folder tree, tabs, the editor and a status bar.
@interface GWMainWindowController : NSWindowController <NSWindowDelegate>

/// Opens a file in a tab, or a folder in the sidebar.
- (void)openURL:(NSURL *)url;
/// Shows the open panel for a folder (or file) and opens what is chosen in this window.
- (IBAction)openFolder:(nullable id)sender;
- (IBAction)goBack:(nullable id)sender;
- (IBAction)goForward:(nullable id)sender;
/// Asks about unsaved changes. Returns NO if the user cancelled.
- (BOOL)confirmCloseAll;
/// Debugging aid: renders the editor straight from its drawing code into a PNG.
- (void)writeEditorSnapshotTo:(NSString *)path;
/// For development: opens the chat and sends a message (see GLASSWORK_PROMPT).
- (void)debugSendChatPrompt:(NSString *)prompt;
/// For development: times typing, scrolling and jumping in the open file, prints the results
/// and quits (see GLASSWORK_BENCH).
- (void)runInteractionBenchmark;

- (BOOL)debugPerformEditorAction:(SEL)action;

@end

NS_ASSUME_NONNULL_END
