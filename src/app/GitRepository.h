#pragma once

#import <Foundation/Foundation.h>

#include "Git.hpp"

#include <memory>
#include <string>

NS_ASSUME_NONNULL_BEGIN

/// Posted on the main thread whenever the status has been re-read.
extern NSNotificationName const GWGitStatusDidChangeNotification;

/// Git state of the open folder, kept fresh in the background. Every git command runs on one serial
/// queue, so the interface never waits for git.
@interface GWGitRepository : NSObject

// ---- Lifecycle
/// Nil watches nothing.
- (void)openFolder:(nullable NSString *)folder;
/// Cheap to call often: calls during a run merge into one more run.
- (void)refresh;
/// After signing in or publishing.
- (void)refreshGitHubState;

// ---- Running git
/// Runs in the background, then refreshes. `completion` runs on the main thread.
- (void)perform:(NSString *)title
      operation:(gw::git::CommandResult (^)(NSString *root))operation
     completion:(void (^_Nullable)(gw::git::CommandResult result))completion;
/// Runs any block on the git queue (reads such as diffs), then delivers on main.
- (void)read:(id _Nullable (^)(NSString *root))work completion:(void (^)(id _Nullable result))completion;
/// File content at HEAD, or nullptr if untracked; cached until the commit changes. Completion runs on main.
- (void)headTextForPath:(NSString *)absolutePath
             completion:(void (^)(std::shared_ptr<const std::string> text))completion;

// ---- Getters (main thread only)
- (const gw::git::Status &)status;
/// Signed-in GitHub user (through `gh`), checked in the background.
- (const gw::git::GitHubState &)github;
/// Refreshed together with the status.
- (const std::vector<gw::git::LogEntry> &)log;
- (nullable NSString *)relativePathForAbsolute:(NSString *)path;
- (nullable NSString *)absolutePathForRelative:(NSString *)path;

// ---- Properties
/// The opened folder, which may be inside a repository or not in one.
@property (nonatomic, readonly, copy, nullable) NSString *folder;
/// Top folder of the repository, nil if not in one.
@property (nonatomic, readonly, copy, nullable) NSString *root;
@property (nonatomic, readonly) BOOL isRepository;
/// A command is running.
@property (nonatomic, readonly) BOOL isBusy;
/// Describes the running command, such as "Pushing...".
@property (nonatomic, readonly, copy, nullable) NSString *busyTitle;

@end

NS_ASSUME_NONNULL_END
