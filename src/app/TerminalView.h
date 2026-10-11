#pragma once

#import <AppKit/AppKit.h>

@class GWTerminalSession;

NS_ASSUME_NONNULL_BEGIN

/// Draws a terminal session and turns keys, mouse and paste into input for it.
@interface GWTerminalView : NSView <NSTextInputClient>

// ---- Actions
/// Re-reads fonts and colors from the theme and settings.
- (void)reloadAppearance;
- (void)scrollToBottom;
/// Clears the screen and scrollback, like Cmd-K in Terminal.
- (IBAction)clearTerminal:(nullable id)sender;

// ---- Properties
/// Setting it starts drawing it and resizes it to fit.
@property (nonatomic, strong, nullable) GWTerminalSession *session;

// ---- Callbacks
/// Cmd-click on "src/main.cpp:42:7"; line and column are 1-based, 0 if absent.
@property (nonatomic, copy, nullable) void (^onOpenPath)(NSString *path, NSInteger line, NSInteger column);
/// What relative paths in the output are relative to.
@property (nonatomic, copy, nullable) NSString * (^baseFolderProvider)(void);

@end

NS_ASSUME_NONNULL_END
