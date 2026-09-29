#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Watches a folder and everything inside it (through FSEvents), and reports batches of
/// changed paths on the main queue. Used to notice edits made outside the editor: by Claude,
/// a build, `git` in a terminal, and so on.
@interface GWFolderWatcher : NSObject

/// `handler` gets the absolute paths that changed, at most a few times a second.
- (instancetype)initWithFolder:(NSString *)folder handler:(void (^)(NSArray<NSString *> *paths))handler;

- (void)stop;

@end

NS_ASSUME_NONNULL_END
