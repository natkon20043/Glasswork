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
/// Runs a command in the terminal set aside for tasks (builds, runs). It reuses that terminal when
/// its shell is free, and opens a new one otherwise.
- (void)runTaskCommand:(NSString *)command;
- (void)closeCurrentTerminal;
- (void)focusTerminal;
/// Types text into the current terminal (no Return).
- (void)sendText:(NSString *)text;

@end

NS_ASSUME_NONNULL_END
