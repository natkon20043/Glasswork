#pragma once

#import <Foundation/Foundation.h>

#include "Terminal.hpp"

NS_ASSUME_NONNULL_BEGIN

/// A shell (or other program) in a pseudo-terminal plus the screen showing its output. Output arrives
/// on a background thread and reaches the screen on main in small slices, so heavy output never freezes the UI.
@interface GWTerminalSession : NSObject

// ---- Constructors
- (instancetype)initWithFolder:(nullable NSString *)folder
                       command:(nullable NSString *)command
                       columns:(int)columns
                          rows:(int)rows;

// ---- Input
- (void)sendBytes:(const std::string &)bytes;
- (void)sendText:(NSString *)text;
/// Marked as a paste if the program asked for that.
- (void)pasteText:(NSString *)text;

// ---- Lifecycle
- (void)resizeToColumns:(int)columns rows:(int)rows pixelWidth:(int)width pixelHeight:(int)height;
- (void)terminate;

// ---- Getters
/// Nil if it can't be found.
- (nullable NSString *)currentDirectory;
/// Re-reads the running program's name for the tab title.
- (void)refreshProcessName;
/// The shell is waiting for a command.
- (BOOL)isIdleAtShellPrompt;

// ---- Properties
@property (nonatomic, readonly) gw::term::Screen &screen;
@property (nonatomic, readonly) BOOL isRunning;
/// The title the program set, else its name.
@property (nonatomic, readonly, copy) NSString *displayTitle;

// ---- Callbacks
/// Main thread, at most a few dozen times a second.
@property (nonatomic, copy, nullable) void (^onChange)(void);
@property (nonatomic, copy, nullable) void (^onTitleChange)(void);
@property (nonatomic, copy, nullable) void (^onExit)(int code);
@property (nonatomic, copy, nullable) void (^onBell)(void);

@end

NS_ASSUME_NONNULL_END
