#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// What the editor is showing right now, so a question can be about "this file" or "this
/// selection" without the user pasting anything.
@interface GWChatContext : NSObject
@property (nonatomic, copy, nullable) NSString *filePath;
@property (nonatomic, copy, nullable) NSString *languageName;
@property (nonatomic, copy, nullable) NSString *selectedText;
/// 1-based lines of the selection, or 0 when nothing is selected.
@property (nonatomic) NSInteger startLine;
@property (nonatomic) NSInteger endLine;
@end

/// The chat with Claude: a conversation in the side panel, driven by the `claude` command
/// (Claude Code) running in the project folder. Claude reads and edits the project's files
/// itself; the editor picks the changes up as they happen.
@interface GWChatPanel : NSObject

@property (nonatomic, readonly) NSView *view;

/// The folder Claude works in. Changing it starts a fresh conversation.
@property (nonatomic, copy, nullable) NSString *projectFolder;

/// Asked for the editor's current file and selection when a message is sent.
@property (nonatomic, copy, nullable) GWChatContext * (^contextProvider)(void);
/// Open a file (with a line, 0 for none) in the editor.
@property (nonatomic, copy, nullable) void (^onOpenPath)(NSString *path, NSInteger line);
/// Put code from a reply into the editor at the caret.
@property (nonatomic, copy, nullable) void (^onInsertCode)(NSString *code);
/// Save every file with unsaved changes; called before a message is sent, so Claude sees
/// what the editor shows.
@property (nonatomic, copy, nullable) void (^onSaveAll)(void);
/// A reply finished (files may have changed on disk).
@property (nonatomic, copy, nullable) void (^onTurnFinished)(void);
@property (nonatomic, copy, nullable) void (^onClose)(void);
/// Best matches for `@` mentions: paths relative to the project.
@property (nonatomic, copy, nullable) NSArray<NSString *> * (^fileSuggestions)(NSString *query);

@property (nonatomic, readonly) BOOL isBusy;

- (void)focusComposer;
/// Starts over with an empty conversation.
- (void)newChat;
/// Sends a message right away. With `includeSelection`, the selected code goes with it.
- (void)sendPrompt:(NSString *)prompt includeSelection:(BOOL)includeSelection;
/// Puts text in the message box without sending it.
- (void)prefillComposer:(NSString *)text;
/// Stops what Claude is doing now.
- (void)interrupt;
/// Call when the editor's file or selection changed, to refresh the context chips.
- (void)contextDidChange;

@end

NS_ASSUME_NONNULL_END
