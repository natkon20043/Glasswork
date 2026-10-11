#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Watches a folder tree with FSEvents and reports batches of changed paths on the main queue, to
/// notice edits from outside the editor (Claude, builds, `git`).
@interface GWFolderWatcher : NSObject

// ---- Constructors
/// `handler` gets absolute changed paths, at most a few times a second.
- (instancetype)initWithFolder:(NSString *)folder handler:(void (^)(NSArray<NSString *> *paths))handler;

// ---- Lifecycle
- (void)stop;

@end

NS_ASSUME_NONNULL_END
