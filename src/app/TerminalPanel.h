#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Terminal at the bottom of the window: tabs for several shells and the one in view.
@interface GWTerminalPanel : NSObject

// ---- Terminals
/// Optionally runs a command first, and shows it.
- (void)newTerminalRunning:(nullable NSString *)command;
/// Uses the terminal set aside for tasks (builds, runs) if its shell is free, otherwise opens a new one.
- (void)runTaskCommand:(NSString *)command;
- (void)closeCurrentTerminal;
- (void)focusTerminal;
/// Types text into the current terminal without Return.
- (void)sendText:(NSString *)text;

// ---- Properties
@property (nonatomic, readonly) NSView *view;
@property (nonatomic, readonly) NSUInteger terminalCount;
/// New terminals start here.
@property (nonatomic, copy, nullable) NSString *projectFolder;

// ---- Callbacks
/// Cmd-click on a file name in the output.
@property (nonatomic, copy, nullable) void (^onOpenPath)(NSString *path, NSInteger line, NSInteger column);
/// The last terminal closed or the hide button was pressed.
@property (nonatomic, copy, nullable) void (^onHide)(void);

@end

NS_ASSUME_NONNULL_END
