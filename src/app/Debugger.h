#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Debug adapter events -> session state the UI reads:
//   Idle: nothing debugged. Starting: adapter launching the program. Running: program running.
//   Stopped: at a breakpoint or step, so frames and variables can be read.
typedef NS_ENUM(NSInteger, GWDebugState) {
    GWDebugStateIdle,
    GWDebugStateStarting,
    GWDebugStateRunning,
    GWDebugStateStopped,
};

/// One call-stack entry.
@interface GWDebugFrame : NSObject
@property (nonatomic) NSInteger frameId;
@property (nonatomic, copy) NSString *name;
/// Source file, if the frame has one.
@property (nonatomic, copy, nullable) NSString *path;
/// From 1.
@property (nonatomic) NSInteger line;
@end

/// A variable or a piece of one (field, element); children are fetched on demand.
@interface GWDebugVariable : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *value;
@property (nonatomic, copy) NSString *type;
/// 0 if it has no parts.
@property (nonatomic) NSInteger reference;
/// Nil until fetched.
@property (nonatomic, copy, nullable) NSArray<GWDebugVariable *> *children;
@end

/// A debugging session through a debug adapter (lldb-dap). Called on the main thread; callbacks
/// arrive there too.
@interface GWDebugger : NSObject

// ---- Session control
/// `breakpoints` maps a file path to zero-based lines to stop at.
- (void)startProgram:(NSString *)program
           arguments:(NSArray<NSString *> *)arguments
    workingDirectory:(NSString *)directory
         breakpoints:(NSDictionary<NSString *, NSSet<NSNumber *> *> *)breakpoints;
- (void)stop;
- (void)resume;
- (void)pause;
- (void)stepOver;
- (void)stepInto;
- (void)stepOut;

// ---- Breakpoints
/// Replaces the whole set for one file.
- (void)setBreakpointLines:(NSSet<NSNumber *> *)lines forPath:(NSString *)path;

// ---- Inspecting
- (void)selectFrameAtIndex:(NSInteger)index;
/// Variables of the selected frame, grouped by scope ("Locals", "Registers"...).
- (void)fetchScopes:(void (^)(NSArray<GWDebugVariable *> *scopes))completion;
/// Fills in `variable.children`.
- (void)fetchChildrenOf:(GWDebugVariable *)variable completion:(void (^)(void))completion;
/// Evaluates in the selected frame (debug console).
- (void)evaluate:(NSString *)expression completion:(void (^)(NSString *_Nullable result, NSString *_Nullable error))completion;

// ---- Properties
@property (nonatomic, readonly) GWDebugState state;
@property (nonatomic, readonly) NSArray<GWDebugFrame *> *frames;
@property (nonatomic, readonly) NSInteger selectedFrameIndex;

// ---- Callbacks
/// State, frames or the selected frame changed.
@property (nonatomic, copy, nullable) void (^onChange)(void);
/// Stopped or a different frame chosen: show this place in the editor.
@property (nonatomic, copy, nullable) void (^onLocation)(GWDebugFrame *frame);
/// `category` is "stdout", "stderr" or "console".
@property (nonatomic, copy, nullable) void (^onOutput)(NSString *text, NSString *category);
@property (nonatomic, copy, nullable) void (^onError)(NSString *message);
/// Program exited or was stopped; exit code if known.
@property (nonatomic, copy, nullable) void (^onEnded)(NSInteger exitCode);

@end

NS_ASSUME_NONNULL_END
