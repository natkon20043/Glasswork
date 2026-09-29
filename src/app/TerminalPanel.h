#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// The terminal at the bottom of the window: tabs for several shells, and the shell you are
/// looking at.
@interface GWTerminalPanel : NSObject

@property (nonatomic, readonly) NSView *view;

/// New terminals start in this folder (the project).
@property (nonatomic, copy, nullable) NSString *projectFolder;
/// Cmd-click on a file name in the output.
@property (nonatomic, copy, nullable) void (^onOpenPath)(NSString *path, NSInteger line, NSInteger column);
/// The panel wants to be hidden (the last terminal closed, or the hide button).
@property (nonatomic, copy, nullable) void (^onHide)(void);

@property (nonatomic, readonly) NSUInteger terminalCount;

/// Opens a terminal, optionally running a command first, and shows it.
- (void)newTerminalRunning:(nullable NSString *)command;
- (void)closeCurrentTerminal;
- (void)focusTerminal;
/// Types text into the current terminal (no Return).
- (void)sendText:(NSString *)text;

@end

NS_ASSUME_NONNULL_END
