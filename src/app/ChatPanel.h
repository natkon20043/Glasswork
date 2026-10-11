#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// What the editor shows now, so a question can be about "this file" or "this selection".
@interface GWChatContext : NSObject

@property (nonatomic, copy, nullable) NSString *filePath;
@property (nonatomic, copy, nullable) NSString *languageName;
@property (nonatomic, copy, nullable) NSString *selectedText;
/// 1-based lines of the selection; 0 when nothing is selected.
@property (nonatomic) NSInteger startLine;
@property (nonatomic) NSInteger endLine;

@end

/// Side-panel chat driven by the `claude` command running in the project folder. Claude edits files
/// itself; the editor picks changes up as they happen.
@interface GWChatPanel : NSObject

// ---- Actions
- (void)focusComposer;
/// Starts over with an empty conversation.
- (void)newChat;
/// With `includeSelection`, the selected code goes along.
- (void)sendPrompt:(NSString *)prompt includeSelection:(BOOL)includeSelection;
/// Puts text in the message box without sending it.
- (void)prefillComposer:(NSString *)text;
- (void)interrupt;
/// Call when the editor's file or selection changed, to refresh the context chips.
- (void)contextDidChange;

// ---- Properties
@property (nonatomic, readonly) NSView *view;
@property (nonatomic, readonly) BOOL isBusy;
/// Changing it starts a fresh conversation.
@property (nonatomic, copy, nullable) NSString *projectFolder;

// ---- Callbacks
/// Asked for the current file and selection when a message is sent.
@property (nonatomic, copy, nullable) GWChatContext * (^contextProvider)(void);
/// `line` is 0 for none.
@property (nonatomic, copy, nullable) void (^onOpenPath)(NSString *path, NSInteger line);
@property (nonatomic, copy, nullable) void (^onInsertCode)(NSString *code);
/// Called before a message is sent so Claude sees what the editor shows.
@property (nonatomic, copy, nullable) void (^onSaveAll)(void);
/// A reply finished; files may have changed on disk.
@property (nonatomic, copy, nullable) void (^onTurnFinished)(void);
@property (nonatomic, copy, nullable) void (^onClose)(void);
/// Best `@` mention matches, as paths relative to the project.
@property (nonatomic, copy, nullable) NSArray<NSString *> * (^fileSuggestions)(NSString *query);

@end

NS_ASSUME_NONNULL_END
