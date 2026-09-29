#import "TerminalSession.h"
#import "Services.h"

#include "Pty.hpp"

#include <memory>
#include <mutex>

/// How much output is fed to the screen in one go before the interface gets a turn.
static const size_t kSliceBytes = 192 * 1024;

@implementation GWTerminalSession {
    std::unique_ptr<gw::term::Screen> _screen;
    std::unique_ptr<gw::Pty> _pty;

    std::mutex _pendingMutex;
    std::string _pending;
    BOOL _drainScheduled;
    BOOL _changeScheduled;
    BOOL _exited;
    NSString *_processName;
    NSString *_initialCommand;  // typed into the shell once it has finished starting up
}

- (instancetype)initWithFolder:(NSString *)folder command:(NSString *)command columns:(int)columns rows:(int)rows {
    self = [super init];
    if (!self) {
        return nil;
    }
    _screen = std::make_unique<gw::term::Screen>(columns, rows, 20000);
    _pty = std::make_unique<gw::Pty>();
    _processName = @"";

    __weak GWTerminalSession *weakSelf = self;
    // Answers to the program's questions (cursor position and so on) go straight back to it.
    _screen->onReply = [weakSelf](const std::string &reply) {
        GWTerminalSession *strongSelf = weakSelf;
        if (strongSelf != nil && strongSelf->_pty) {
            strongSelf->_pty->write(reply);
        }
    };
    _screen->onBell = [weakSelf]() {
        dispatch_async(dispatch_get_main_queue(), ^{
            GWTerminalSession *strongSelf = weakSelf;
            if (strongSelf.onBell) strongSelf.onBell();
        });
    };
    _screen->onTitleChange = [weakSelf](const std::string &) {
        GWTerminalSession *strongSelf = weakSelf;
        if (strongSelf.onTitleChange) strongSelf.onTitleChange();
    };

    _pty->onOutput = [weakSelf](std::string_view bytes) {
        [weakSelf receivedOutput:bytes];
    };
    _pty->onExit = [weakSelf](int code) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf programEndedWithCode:code];
        });
    };

    gw::PtyOptions options;
    options.columns = columns;
    options.rows = rows;
    options.workingDirectory = folder.UTF8String ?: "";
    const std::string &configuredShell = GWServices.shared.settings.terminalShell;
    if (!configuredShell.empty()) {
        options.program = configuredShell;
        options.arguments = {"-l"};
    }
    _initialCommand = [command copy];
    std::string error;
    if (!_pty->start(options, &error)) {
        std::string message = "Couldn't start a shell: " + error + "\r\n";
        _screen->write(message);
    }
    return self;
}

- (gw::term::Screen &)screen { return *_screen; }
- (BOOL)isRunning { return _pty && _pty->isRunning() && !_exited; }

- (NSString *)displayTitle {
    const std::string &title = _screen->title();
    if (!title.empty()) {
        return @(title.c_str());
    }
    return _processName.length > 0 ? _processName : @"shell";
}

// ---------------------------------------------------------------------------
// MARK: Output

/// Called on the pty's thread.
- (void)receivedOutput:(std::string_view)bytes {
    bool schedule = false;
    {
        std::lock_guard<std::mutex> lock(_pendingMutex);
        _pending.append(bytes);
        if (!_drainScheduled) {
            _drainScheduled = true;
            schedule = true;
        }
    }
    if (schedule) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self drain];
        });
    }
}

/// Feeds a slice of waiting output to the screen; if more is waiting, comes back after the
/// interface has had a turn.
- (void)drain {
    std::string slice;
    bool more = false;
    {
        std::lock_guard<std::mutex> lock(_pendingMutex);
        if (_pending.size() <= kSliceBytes) {
            slice.swap(_pending);
            _drainScheduled = false;
        } else {
            slice = _pending.substr(0, kSliceBytes);
            _pending.erase(0, kSliceBytes);
            more = true;
        }
    }
    _screen->write(slice);
    if (_pty) {
        _pty->acknowledge(slice.size());
    }
    [self scheduleChangeNotification];
    if (_initialCommand.length > 0) {
        // The shell is ready when it stops printing (its banner and prompt are done).
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(typeInitialCommand) object:nil];
        [self performSelector:@selector(typeInitialCommand) withObject:nil afterDelay:0.35];
    }
    if (more) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self drain];
        });
    }
}

/// Tells the view to redraw, but not more often than about 120 times a second.
- (void)scheduleChangeNotification {
    if (_changeScheduled) {
        return;
    }
    _changeScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(0.008 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self->_changeScheduled = NO;
        if (self.onChange) {
            self.onChange();
        }
    });
}

- (void)typeInitialCommand {
    NSString *command = _initialCommand;
    _initialCommand = nil;
    if (command.length > 0) {
        [self sendText:[command stringByAppendingString:@"\r"]];
    }
}

- (void)programEndedWithCode:(int)code {
    // Show the last of the output first.
    [self drain];
    _exited = YES;
    if (self.onExit) {
        self.onExit(code);
    }
}

// ---------------------------------------------------------------------------
// MARK: Input

- (void)sendBytes:(const std::string &)bytes {
    if (_pty) {
        _pty->write(bytes);
    }
}

- (void)sendText:(NSString *)text {
    const char *utf8 = text.UTF8String;
    if (utf8 != nullptr) {
        [self sendBytes:std::string(utf8)];
    }
}

- (void)pasteText:(NSString *)text {
    // Line breaks in pasted text are what Return sends.
    NSString *normalized = [text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\r"];
    normalized = [normalized stringByReplacingOccurrencesOfString:@"\n" withString:@"\r"];
    std::string bytes = normalized.UTF8String ?: "";
    if (_screen->bracketedPaste()) {
        bytes = "\x1b[200~" + bytes + "\x1b[201~";
    }
    [self sendBytes:bytes];
}

- (void)resizeToColumns:(int)columns rows:(int)rows pixelWidth:(int)width pixelHeight:(int)height {
    if (columns < 1 || rows < 1) {
        return;
    }
    if (columns == _screen->columns() && rows == _screen->rows()) {
        return;
    }
    _screen->resize(columns, rows);
    if (_pty) {
        _pty->resize(columns, rows, width, height);
    }
    [self scheduleChangeNotification];
}

- (void)terminate {
    if (_pty) {
        _pty->onOutput = nullptr;
        _pty->onExit = nullptr;
        _pty->terminate();
    }
}

- (NSString *)currentDirectory {
    if (!_screen->workingDirectory().empty()) {
        return @(_screen->workingDirectory().c_str());
    }
    std::string directory = _pty ? _pty->currentDirectory() : std::string();
    return directory.empty() ? nil : @(directory.c_str());
}

- (void)refreshProcessName {
    if (!_pty) {
        return;
    }
    std::string name = _pty->foregroundProcessName();
    NSString *text = name.empty() ? @"" : @(name.c_str());
    if (![text isEqualToString:_processName]) {
        _processName = text;
        if (self.onTitleChange) {
            self.onTitleChange();
        }
    }
}

- (void)dealloc {
    if (_pty) {
        _pty->onOutput = nullptr;
        _pty->onExit = nullptr;
    }
}

@end
