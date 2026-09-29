#pragma once

#import <AppKit/AppKit.h>

@class GWDebugger;

NS_ASSUME_NONNULL_BEGIN

/// The "Run and Debug" tab of the sidebar: start and step buttons, the call stack, the variables
/// of the selected frame, and a console showing the program's output where you can evaluate
/// expressions.
@interface GWDebugPanel : NSObject

@property (nonatomic, readonly) NSView *view;

- (instancetype)initWithDebugger:(GWDebugger *)debugger;

/// The user pressed "Start Debugging" (there is no session yet).
@property (nonatomic, copy, nullable) void (^onStart)(void);

/// Refreshes everything from the debugger's state (call when it changes).
- (void)reload;
/// Adds text to the console. `category` is "stdout", "stderr" or "console".
- (void)appendConsole:(NSString *)text category:(NSString *)category;
- (void)clearConsole;

@end

NS_ASSUME_NONNULL_END
