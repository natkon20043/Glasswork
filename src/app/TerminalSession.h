#pragma once

#import <Foundation/Foundation.h>

#include "Terminal.hpp"

NS_ASSUME_NONNULL_BEGIN

/// One running terminal: a shell (or other program) in a pseudo-terminal, and the screen that
/// shows what it prints. Output arrives on a background thread and is fed to the screen on the
/// main thread in small slices, so a program that prints a lot never freezes the interface.
@interface GWTerminalSession : NSObject

- (instancetype)initWithFolder:(nullable NSString *)folder
                       command:(nullable NSString *)command
                       columns:(int)columns
                          rows:(int)rows;

@property (nonatomic, readonly) gw::term::Screen &screen;
@property (nonatomic, readonly) BOOL isRunning;
/// What to call this terminal: the title the program set, else the program's name.
@property (nonatomic, readonly, copy) NSString *displayTitle;
/// Called on the main thread (at most a few dozen times a second) when the screen changed.
@property (nonatomic, copy, nullable) void (^onChange)(void);
/// Called when the title or running program changed.
@property (nonatomic, copy, nullable) void (^onTitleChange)(void);
/// Called when the program ended, with its exit code.
@property (nonatomic, copy, nullable) void (^onExit)(int code);
/// Called for the terminal bell.
@property (nonatomic, copy, nullable) void (^onBell)(void);

/// Sends keystrokes or pasted text to the program.
- (void)sendBytes:(const std::string &)bytes;
- (void)sendText:(NSString *)text;
/// Pastes text, marked as a paste if the program asked for that.
- (void)pasteText:(NSString *)text;

- (void)resizeToColumns:(int)columns rows:(int)rows pixelWidth:(int)width pixelHeight:(int)height;
- (void)terminate;

/// The folder the shell is in now, if it can be found.
- (nullable NSString *)currentDirectory;
/// Re-reads the running program's name (for the tab title).
- (void)refreshProcessName;

@end

NS_ASSUME_NONNULL_END
