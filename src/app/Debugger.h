#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, GWDebugState) {
    GWDebugStateIdle,      // nothing is being debugged
    GWDebugStateStarting,  // the adapter is starting the program
    GWDebugStateRunning,   // the program is running
    GWDebugStateStopped,   // stopped at a breakpoint or step: frames and variables can be read
};

/// One entry of the call stack.
@interface GWDebugFrame : NSObject
@property (nonatomic) NSInteger frameId;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy, nullable) NSString *path;  // source file, if the frame has one
@property (nonatomic) NSInteger line;                   // from 1
@end

/// A variable, or a piece of one (a field, an element). Children are fetched on demand.
@interface GWDebugVariable : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *value;
@property (nonatomic, copy) NSString *type;
@property (nonatomic) NSInteger reference;                          // 0 if it has no parts
@property (nonatomic, copy, nullable) NSArray<GWDebugVariable *> *children;  // nil until fetched
@end

/// Runs a debugging session through a debug adapter (lldb-dap): starts the program, keeps the
/// breakpoints in step, and reports where it stopped. Everything here is called on the main
/// thread, and callbacks arrive there.
@interface GWDebugger : NSObject

@property (nonatomic, readonly) GWDebugState state;
@property (nonatomic, readonly) NSArray<GWDebugFrame *> *frames;
@property (nonatomic, readonly) NSInteger selectedFrameIndex;

/// State, frames or the selected frame changed.
@property (nonatomic, copy, nullable) void (^onChange)(void);
/// The program stopped (or a different frame was chosen): show this place in the editor.
@property (nonatomic, copy, nullable) void (^onLocation)(GWDebugFrame *frame);
/// Text from the program or the debugger, with the category ("stdout", "stderr", "console").
@property (nonatomic, copy, nullable) void (^onOutput)(NSString *text, NSString *category);
/// Something went wrong that the user should hear about.
@property (nonatomic, copy, nullable) void (^onError)(NSString *message);
/// The session ended (the program exited or was stopped), with the exit code if known.
@property (nonatomic, copy, nullable) void (^onEnded)(NSInteger exitCode);

/// Starts debugging `program`. `breakpoints` maps a file path to the lines (from 0) to stop at.
- (void)startProgram:(NSString *)program
           arguments:(NSArray<NSString *> *)arguments
    workingDirectory:(NSString *)directory
         breakpoints:(NSDictionary<NSString *, NSSet<NSNumber *> *> *)breakpoints;

/// Tells the debugger about the breakpoints of one file (all of them; it replaces the old set).
- (void)setBreakpointLines:(NSSet<NSNumber *> *)lines forPath:(NSString *)path;

- (void)resume;
- (void)pause;
- (void)stepOver;
- (void)stepInto;
- (void)stepOut;
- (void)stop;

- (void)selectFrameAtIndex:(NSInteger)index;
/// The variables of the selected frame, grouped by scope ("Locals", "Registers"…).
- (void)fetchScopes:(void (^)(NSArray<GWDebugVariable *> *scopes))completion;
/// Fills in `variable.children`.
- (void)fetchChildrenOf:(GWDebugVariable *)variable completion:(void (^)(void))completion;
/// Evaluates an expression in the selected frame (for the debug console).
- (void)evaluate:(NSString *)expression completion:(void (^)(NSString *_Nullable result, NSString *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
