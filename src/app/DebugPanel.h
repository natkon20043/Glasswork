#pragma once

#import <AppKit/AppKit.h>

@class GWDebugger;

NS_ASSUME_NONNULL_BEGIN

/// "Run and Debug" sidebar tab: start/step buttons, call stack, variables of the selected frame, and a
/// console for program output and expression evaluation.
@interface GWDebugPanel : NSObject

// ---- Constructors
- (instancetype)initWithDebugger:(GWDebugger *)debugger;

// ---- Updating
/// Call when the debugger's state changes.
- (void)reload;
/// `category` is "stdout", "stderr" or "console".
- (void)appendConsole:(NSString *)text category:(NSString *)category;
- (void)clearConsole;
/// Bitmap mode's colors changed: restyle with the new ones.
- (void)refreshLook;

// ---- Properties
@property (nonatomic, readonly) NSView *view;
/// Pixel text, light on bitmap mode's blue panel.
@property (nonatomic) BOOL retro;

// ---- Callbacks
/// "Start Debugging" pressed with no session yet.
@property (nonatomic, copy, nullable) void (^onStart)(void);

@end

NS_ASSUME_NONNULL_END
