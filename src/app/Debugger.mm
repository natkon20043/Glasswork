#import "Debugger.h"

#include "Dap.hpp"

#include <memory>

@implementation GWDebugFrame
@end

@implementation GWDebugVariable
@end

@implementation GWDebugger {
    std::unique_ptr<gw::dap::Connection> _connection;
    GWDebugState _state;
    NSMutableArray<GWDebugFrame *> *_frames;
    NSInteger _selectedFrame;
    NSInteger _threadId;
    NSMutableDictionary<NSString *, NSSet<NSNumber *> *> *_breakpoints;
    NSUInteger _generation;  // ignores answers from a session that has since ended
    BOOL _endedReported;
    NSInteger _exitCode;
}

- (instancetype)init {
    if ((self = [super init])) {
        _frames = [NSMutableArray array];
        _breakpoints = [NSMutableDictionary dictionary];
        _threadId = 0;
    }
    return self;
}

- (void)dealloc {
    _connection.reset();
}

- (GWDebugState)state { return _state; }
- (NSArray<GWDebugFrame *> *)frames { return _frames; }
- (NSInteger)selectedFrameIndex { return _selectedFrame; }

- (void)setState:(GWDebugState)state {
    _state = state;
    if (self.onChange) self.onChange();
}

// ---------------------------------------------------------------------------
// MARK: Starting and ending

- (void)startProgram:(NSString *)program
           arguments:(NSArray<NSString *> *)arguments
    workingDirectory:(NSString *)directory
         breakpoints:(NSDictionary<NSString *, NSSet<NSNumber *> *> *)breakpoints {
    if (_state != GWDebugStateIdle) {
        return;
    }
    [_breakpoints setDictionary:breakpoints];
    [_frames removeAllObjects];
    _selectedFrame = 0;
    _threadId = 0;
    _endedReported = NO;
    NSUInteger generation = ++_generation;
    [self setState:GWDebugStateStarting];

    _connection = std::make_unique<gw::dap::Connection>();
    __weak GWDebugger *weakSelf = self;
    _connection->onEvent = [weakSelf, generation](const std::string &event, const gw::dap::Json &body) {
        auto sharedBody = std::make_shared<gw::dap::Json>(body);
        std::string eventName = event;
        dispatch_async(dispatch_get_main_queue(), ^{
            GWDebugger *strongSelf = weakSelf;
            if (strongSelf != nil && strongSelf->_generation == generation) {
                [strongSelf handleEvent:@(eventName.c_str()) body:*sharedBody];
            }
        });
    };
    _connection->onExit = [weakSelf, generation](int) {
        dispatch_async(dispatch_get_main_queue(), ^{
            GWDebugger *strongSelf = weakSelf;
            if (strongSelf != nil && strongSelf->_generation == generation) {
                [strongSelf sessionEndedWithCode:-1];
            }
        });
    };
    std::string error;
    if (!_connection->start(gw::dap::defaultAdapterCommand(), directory.UTF8String, &error)) {
        _connection.reset();
        [self setState:GWDebugStateIdle];
        if (self.onError) self.onError([NSString stringWithFormat:@"Couldn't start the debugger: %s", error.c_str()]);
        return;
    }

    gw::dap::Json initialize = {
        {"adapterID", "lldb-dap"}, {"clientID", "glasswork"}, {"clientName", "Glasswork"},
        {"linesStartAt1", true}, {"columnsStartAt1", true}, {"pathFormat", "path"},
        {"supportsRunInTerminalRequest", false},
    };
    _connection->request("initialize", initialize, [weakSelf, generation, program, arguments, directory](bool success, const gw::dap::Json &, const std::string &message) {
        std::string text = message;
        dispatch_async(dispatch_get_main_queue(), ^{
            GWDebugger *strongSelf = weakSelf;
            if (strongSelf == nil || strongSelf->_generation != generation) {
                return;
            }
            if (!success) {
                [strongSelf failWithMessage:[NSString stringWithFormat:@"The debugger didn't start: %s", text.c_str()]];
                return;
            }
            [strongSelf sendLaunch:program arguments:arguments directory:directory];
        });
    });
}

- (void)sendLaunch:(NSString *)program arguments:(NSArray<NSString *> *)arguments directory:(NSString *)directory {
    if (!_connection) {
        return;
    }
    gw::dap::Json args = gw::dap::Json::array();
    for (NSString *argument in arguments) {
        args.push_back(argument.UTF8String);
    }
    gw::dap::Json launch = {
        {"program", program.UTF8String}, {"args", args}, {"cwd", directory.UTF8String},
        {"stopOnEntry", false},
    };
    NSUInteger generation = _generation;
    __weak GWDebugger *weakSelf = self;
    // The answer to launch only comes after configurationDone, so it is just watched for errors.
    _connection->request("launch", launch, [weakSelf, generation](bool success, const gw::dap::Json &, const std::string &message) {
        if (success) {
            return;
        }
        std::string text = message;
        dispatch_async(dispatch_get_main_queue(), ^{
            GWDebugger *strongSelf = weakSelf;
            if (strongSelf != nil && strongSelf->_generation == generation) {
                [strongSelf failWithMessage:[NSString stringWithFormat:@"The program couldn't be started: %s", text.c_str()]];
            }
        });
    });
}

- (void)failWithMessage:(NSString *)message {
    if (self.onError) self.onError(message);
    [self endSessionWithExitCode:-1 report:NO];
}

/// Everything is done: forget the session.
- (void)endSessionWithExitCode:(NSInteger)code report:(BOOL)report {
    ++_generation;
    if (_connection) {
        _connection->stop();
        _connection.reset();
    }
    [_frames removeAllObjects];
    _selectedFrame = 0;
    [self setState:GWDebugStateIdle];
    if (report && !_endedReported && self.onEnded) {
        _endedReported = YES;
        self.onEnded(code);
    }
}

- (void)sessionEndedWithCode:(NSInteger)code {
    [self endSessionWithExitCode:code report:YES];
}

- (void)stop {
    if (_state == GWDebugStateIdle) {
        return;
    }
    [self endSessionWithExitCode:-1 report:YES];
}

// ---------------------------------------------------------------------------
// MARK: Events

- (void)handleEvent:(NSString *)event body:(const gw::dap::Json &)body {
    if ([event isEqualToString:@"initialized"]) {
        [self sendAllBreakpointsThenConfigurationDone];
    } else if ([event isEqualToString:@"stopped"]) {
        _threadId = body.value("threadId", static_cast<int>(_threadId));
        [self loadStackAfterStop];
    } else if ([event isEqualToString:@"continued"]) {
        [_frames removeAllObjects];
        [self setState:GWDebugStateRunning];
    } else if ([event isEqualToString:@"output"]) {
        std::string text = body.value("output", "");
        std::string category = body.value("category", "console");
        if (self.onOutput && !text.empty()) {
            self.onOutput(@(text.c_str()), @(category.c_str()));
        }
    } else if ([event isEqualToString:@"exited"]) {
        NSInteger code = body.value("exitCode", 0);
        if (self.onOutput) {
            self.onOutput([NSString stringWithFormat:@"The program exited with code %ld.\n", (long)code], @"console");
        }
        _exitCode = code;
    } else if ([event isEqualToString:@"terminated"]) {
        [self sessionEndedWithCode:_exitCode];
    }
}

- (void)sendAllBreakpointsThenConfigurationDone {
    if (!_connection) {
        return;
    }
    for (NSString *path in _breakpoints) {
        [self sendBreakpointsForPath:path];
    }
    NSUInteger generation = _generation;
    __weak GWDebugger *weakSelf = self;
    _connection->request("configurationDone", gw::dap::Json::object(), [weakSelf, generation](bool, const gw::dap::Json &, const std::string &) {
        dispatch_async(dispatch_get_main_queue(), ^{
            GWDebugger *strongSelf = weakSelf;
            if (strongSelf != nil && strongSelf->_generation == generation && strongSelf->_state == GWDebugStateStarting) {
                [strongSelf setState:GWDebugStateRunning];
            }
        });
    });
}

- (void)sendBreakpointsForPath:(NSString *)path {
    if (!_connection) {
        return;
    }
    gw::dap::Json list = gw::dap::Json::array();
    for (NSNumber *line in _breakpoints[path]) {
        list.push_back({{"line", line.integerValue + 1}});
    }
    _connection->request("setBreakpoints", {{"source", {{"path", path.UTF8String}}}, {"breakpoints", list}},
                         [](bool, const gw::dap::Json &, const std::string &) {});
}

- (void)setBreakpointLines:(NSSet<NSNumber *> *)lines forPath:(NSString *)path {
    if (lines.count == 0) {
        [_breakpoints removeObjectForKey:path];
        if (_connection && _state != GWDebugStateIdle) {
            // An empty list clears the file's breakpoints on the adapter.
            _breakpoints[path] = [NSSet set];
            [self sendBreakpointsForPath:path];
            [_breakpoints removeObjectForKey:path];
        }
        return;
    }
    _breakpoints[path] = lines;
    if (_connection && _state != GWDebugStateIdle) {
        [self sendBreakpointsForPath:path];
    }
}

// ---------------------------------------------------------------------------
// MARK: Where are we?

- (void)loadStackAfterStop {
    if (!_connection) {
        return;
    }
    NSUInteger generation = _generation;
    __weak GWDebugger *weakSelf = self;
    // The event may not name a thread; use the first one in that case.
    void (^loadStack)(NSInteger) = ^(NSInteger threadId) {
        GWDebugger *strongSelf = weakSelf;
        if (strongSelf == nil || !strongSelf->_connection) {
            return;
        }
        strongSelf->_threadId = threadId;
        strongSelf->_connection->request("stackTrace", {{"threadId", threadId}, {"levels", 60}},
            [weakSelf, generation](bool success, const gw::dap::Json &body, const std::string &) {
            auto sharedBody = std::make_shared<gw::dap::Json>(body);
            dispatch_async(dispatch_get_main_queue(), ^{
                GWDebugger *inner = weakSelf;
                if (inner == nil || inner->_generation != generation) {
                    return;
                }
                [inner->_frames removeAllObjects];
                if (success && sharedBody->contains("stackFrames")) {
                    for (const gw::dap::Json &item : (*sharedBody)["stackFrames"]) {
                        GWDebugFrame *frame = [GWDebugFrame new];
                        frame.frameId = item.value("id", 0);
                        frame.name = @(item.value("name", "").c_str());
                        frame.line = item.value("line", 0);
                        if (item.contains("source") && item["source"].contains("path")) {
                            frame.path = @(item["source"]["path"].get<std::string>().c_str());
                        }
                        [inner->_frames addObject:frame];
                    }
                }
                // Stop on the first frame that has source code we can show.
                inner->_selectedFrame = 0;
                for (NSUInteger index = 0; index < inner->_frames.count; ++index) {
                    if (inner->_frames[index].path.length > 0) {
                        inner->_selectedFrame = static_cast<NSInteger>(index);
                        break;
                    }
                }
                [inner setState:GWDebugStateStopped];
                if (inner->_frames.count > 0 && inner.onLocation) {
                    inner.onLocation(inner->_frames[static_cast<NSUInteger>(inner->_selectedFrame)]);
                }
            });
        });
    };
    if (_threadId != 0) {
        loadStack(_threadId);
        return;
    }
    _connection->request("threads", gw::dap::Json::object(), [weakSelf, generation, loadStack](bool success, const gw::dap::Json &body, const std::string &) {
        NSInteger first = 1;
        if (success && body.contains("threads") && !body["threads"].empty()) {
            first = body["threads"][0].value("id", 1);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            GWDebugger *strongSelf = weakSelf;
            if (strongSelf != nil && strongSelf->_generation == generation) {
                loadStack(first);
            }
        });
    });
}

- (void)selectFrameAtIndex:(NSInteger)index {
    if (index < 0 || index >= static_cast<NSInteger>(_frames.count)) {
        return;
    }
    _selectedFrame = index;
    if (self.onChange) self.onChange();
    if (self.onLocation) self.onLocation(_frames[static_cast<NSUInteger>(index)]);
}

// ---------------------------------------------------------------------------
// MARK: Running

- (void)sendStepCommand:(const char *)command {
    if (!_connection || _state != GWDebugStateStopped) {
        return;
    }
    [_frames removeAllObjects];
    [self setState:GWDebugStateRunning];
    _connection->request(command, {{"threadId", _threadId}}, [](bool, const gw::dap::Json &, const std::string &) {});
}

- (void)resume { [self sendStepCommand:"continue"]; }
- (void)stepOver { [self sendStepCommand:"next"]; }
- (void)stepInto { [self sendStepCommand:"stepIn"]; }
- (void)stepOut { [self sendStepCommand:"stepOut"]; }

- (void)pause {
    if (!_connection || _state != GWDebugStateRunning) {
        return;
    }
    _connection->request("pause", {{"threadId", _threadId == 0 ? 1 : _threadId}}, [](bool, const gw::dap::Json &, const std::string &) {});
}

// ---------------------------------------------------------------------------
// MARK: Variables

- (GWDebugVariable *)variableFromJson:(const gw::dap::Json &)item {
    GWDebugVariable *variable = [GWDebugVariable new];
    variable.name = @(item.value("name", "").c_str());
    variable.value = @(item.value("value", "").c_str());
    variable.type = @(item.value("type", "").c_str());
    variable.reference = item.value("variablesReference", 0);
    return variable;
}

- (void)fetchScopes:(void (^)(NSArray<GWDebugVariable *> *))completion {
    if (!_connection || _state != GWDebugStateStopped || _frames.count == 0) {
        completion(@[]);
        return;
    }
    NSInteger frameId = _frames[static_cast<NSUInteger>(_selectedFrame)].frameId;
    NSUInteger generation = _generation;
    __weak GWDebugger *weakSelf = self;
    void (^copiedCompletion)(NSArray<GWDebugVariable *> *) = [completion copy];
    _connection->request("scopes", {{"frameId", frameId}}, [weakSelf, generation, copiedCompletion](bool success, const gw::dap::Json &body, const std::string &) {
        auto sharedBody = std::make_shared<gw::dap::Json>(body);
        dispatch_async(dispatch_get_main_queue(), ^{
            GWDebugger *strongSelf = weakSelf;
            if (strongSelf == nil || strongSelf->_generation != generation) {
                return;
            }
            NSMutableArray<GWDebugVariable *> *scopes = [NSMutableArray array];
            if (success && sharedBody->contains("scopes")) {
                for (const gw::dap::Json &item : (*sharedBody)["scopes"]) {
                    GWDebugVariable *scope = [strongSelf variableFromJson:item];
                    scope.value = @"";
                    [scopes addObject:scope];
                }
            }
            copiedCompletion(scopes);
        });
    });
}

- (void)fetchChildrenOf:(GWDebugVariable *)variable completion:(void (^)(void))completion {
    if (!_connection || variable.reference == 0) {
        variable.children = @[];
        completion();
        return;
    }
    NSUInteger generation = _generation;
    __weak GWDebugger *weakSelf = self;
    void (^copiedCompletion)(void) = [completion copy];
    _connection->request("variables", {{"variablesReference", variable.reference}}, [weakSelf, generation, variable, copiedCompletion](bool success, const gw::dap::Json &body, const std::string &) {
        auto sharedBody = std::make_shared<gw::dap::Json>(body);
        dispatch_async(dispatch_get_main_queue(), ^{
            GWDebugger *strongSelf = weakSelf;
            if (strongSelf == nil || strongSelf->_generation != generation) {
                return;
            }
            NSMutableArray<GWDebugVariable *> *children = [NSMutableArray array];
            if (success && sharedBody->contains("variables")) {
                for (const gw::dap::Json &item : (*sharedBody)["variables"]) {
                    [children addObject:[strongSelf variableFromJson:item]];
                }
            }
            variable.children = children;
            copiedCompletion();
        });
    });
}

- (void)evaluate:(NSString *)expression completion:(void (^)(NSString *, NSString *))completion {
    if (!_connection || _state == GWDebugStateIdle) {
        completion(nil, @"Start debugging first.");
        return;
    }
    gw::dap::Json arguments = {{"expression", expression.UTF8String}, {"context", "repl"}};
    if (_state == GWDebugStateStopped && _frames.count > 0) {
        arguments["frameId"] = _frames[static_cast<NSUInteger>(_selectedFrame)].frameId;
    }
    NSUInteger generation = _generation;
    __weak GWDebugger *weakSelf = self;
    void (^copiedCompletion)(NSString *, NSString *) = [completion copy];
    _connection->request("evaluate", arguments, [weakSelf, generation, copiedCompletion](bool success, const gw::dap::Json &body, const std::string &message) {
        std::string result = body.value("result", "");
        std::string error = message;
        dispatch_async(dispatch_get_main_queue(), ^{
            GWDebugger *strongSelf = weakSelf;
            if (strongSelf == nil || strongSelf->_generation != generation) {
                return;
            }
            if (success) {
                copiedCompletion(@(result.c_str()), nil);
            } else {
                copiedCompletion(nil, error.empty() ? @"The expression couldn't be evaluated." : @(error.c_str()));
            }
        });
    });
}

@end
