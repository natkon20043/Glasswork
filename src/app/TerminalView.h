#pragma once

#import <AppKit/AppKit.h>

@class GWTerminalSession;

NS_ASSUME_NONNULL_BEGIN

/// Draws a terminal session and turns keys, mouse and pasting into input for it.
@interface GWTerminalView : NSView <NSTextInputClient>

/// The session shown. Setting it starts drawing it and resizes it to fit.
@property (nonatomic, strong, nullable) GWTerminalSession *session;

/// Cmd-click on something like "src/main.cpp:42:7" opens it. Line and column are 1-based, 0 if absent.
@property (nonatomic, copy, nullable) void (^onOpenPath)(NSString *path, NSInteger line, NSInteger column);
/// Where relative paths in the output are relative to.
@property (nonatomic, copy, nullable) NSString * (^baseFolderProvider)(void);

/// Re-reads fonts and colours from the theme and settings.
- (void)reloadAppearance;
- (void)scrollToBottom;
/// Clears the screen and the scrollback, like Cmd-K in Terminal.
- (IBAction)clearTerminal:(nullable id)sender;

@end

NS_ASSUME_NONNULL_END
