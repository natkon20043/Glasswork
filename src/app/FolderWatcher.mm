#import "FolderWatcher.h"

#import <CoreServices/CoreServices.h>

@interface GWFolderWatcher ()
- (void)receivedPaths:(NSArray<NSString *> *)paths;
@end

@implementation GWFolderWatcher {
    FSEventStreamRef _stream;
    void (^_handler)(NSArray<NSString *> *);
}

/// Called by FSEvents on the main queue (the stream is attached to it).
static void watcherCallback(ConstFSEventStreamRef stream, void *info, size_t count, void *paths,
                            const FSEventStreamEventFlags flags[], const FSEventStreamEventId ids[]) {
    GWFolderWatcher *watcher = (__bridge GWFolderWatcher *)info;
    NSArray<NSString *> *changed = (__bridge NSArray<NSString *> *)paths;
    [watcher receivedPaths:changed];
}

- (instancetype)initWithFolder:(NSString *)folder handler:(void (^)(NSArray<NSString *> *))handler {
    self = [super init];
    if (!self) {
        return nil;
    }
    _handler = [handler copy];

    FSEventStreamContext context = {0, (__bridge void *)self, NULL, NULL, NULL};
    FSEventStreamCreateFlags flags = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes |
                                     kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot;
    _stream = FSEventStreamCreate(kCFAllocatorDefault, watcherCallback, &context, (__bridge CFArrayRef) @[folder],
                                  kFSEventStreamEventIdSinceNow, 0.25, flags);
    if (_stream == NULL) {
        return self;
    }
    FSEventStreamSetDispatchQueue(_stream, dispatch_get_main_queue());
    FSEventStreamStart(_stream);
    return self;
}

- (void)receivedPaths:(NSArray<NSString *> *)paths {
    if (_handler != nil && paths.count > 0) {
        _handler(paths);
    }
}

- (void)stop {
    if (_stream != NULL) {
        FSEventStreamStop(_stream);
        FSEventStreamInvalidate(_stream);
        FSEventStreamRelease(_stream);
        _stream = NULL;
    }
    _handler = nil;
}

- (void)dealloc {
    [self stop];
}

@end
