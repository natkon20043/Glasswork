#pragma once

#import <Foundation/Foundation.h>

#include "Git.hpp"

#include <memory>
#include <string>

NS_ASSUME_NONNULL_BEGIN

/// Posted (on the main thread) whenever the repository's status has been re-read.
extern NSNotificationName const GWGitStatusDidChangeNotification;

/// The git state of the folder that is open, kept fresh in the background. Every git
/// command runs on one serial background queue, so the interface never waits for git.
@interface GWGitRepository : NSObject

/// The folder that was opened (which may be inside a repository, or not in one at all).
@property (nonatomic, readonly, copy, nullable) NSString *folder;
/// The repository's top folder, or nil if the folder isn't in a repository.
@property (nonatomic, readonly, copy, nullable) NSString *root;
@property (nonatomic, readonly) BOOL isRepository;
/// True while a command is running.
@property (nonatomic, readonly) BOOL isBusy;
/// Text describing the running command, such as "Pushing…".
@property (nonatomic, readonly, copy, nullable) NSString *busyTitle;

/// The latest status. Only read it on the main thread.
- (const gw::git::Status &)status;
/// Who is signed in to GitHub (through `gh`), checked in the background.
- (const gw::git::GitHubState &)github;
/// Recent commits, refreshed together with the status.
- (const std::vector<gw::git::LogEntry> &)log;

/// Re-checks who is signed in to GitHub (after signing in or publishing).
- (void)refreshGitHubState;

/// Starts watching a new folder, or none.
- (void)openFolder:(nullable NSString *)folder;

/// Re-reads the status in the background. Cheap to call often: calls made while one is
/// already running are merged into one more run.
- (void)refresh;

/// Runs a change (stage, commit, push…) in the background, then refreshes. `completion`
/// runs on the main thread with the result.
- (void)perform:(NSString *)title
      operation:(gw::git::CommandResult (^)(NSString *root))operation
     completion:(void (^_Nullable)(gw::git::CommandResult result))completion;

/// The content of a file at HEAD (the last commit), or nullptr if it isn't tracked. Cached
/// until the commit changes. `completion` runs on the main thread.
- (void)headTextForPath:(NSString *)absolutePath
             completion:(void (^)(std::shared_ptr<const std::string> text))completion;

/// Runs any block on the git queue (for reads such as diffs), then delivers on main.
- (void)read:(id _Nullable (^)(NSString *root))work completion:(void (^)(id _Nullable result))completion;

/// Paths, relative to the repository and absolute.
- (nullable NSString *)relativePathForAbsolute:(NSString *)path;
- (nullable NSString *)absolutePathForRelative:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
