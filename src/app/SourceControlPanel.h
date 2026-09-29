#pragma once

#import <AppKit/AppKit.h>

@class GWGitRepository;

NS_ASSUME_NONNULL_BEGIN

/// The "Changes" tab of the sidebar: branch, commit box, staged and unstaged files, and
/// recent commits. Everything it shows comes from a GWGitRepository.
@interface GWSourceControlPanel : NSObject

- (instancetype)initWithRepository:(GWGitRepository *)repository;

@property (nonatomic, readonly) NSView *view;

/// Open a file in the editor.
@property (nonatomic, copy, nullable) void (^onOpenFile)(NSString *absolutePath);
/// Show the changes to a file (staged or not) in a read-only tab.
@property (nonatomic, copy, nullable) void (^onShowDiff)(NSString *relativePath, BOOL staged);
/// Show what a commit changed.
@property (nonatomic, copy, nullable) void (^onShowCommit)(NSString *hash, NSString *subject);
/// Called before something that needs saved files (commit): the window saves every open
/// file that has unsaved changes.
@property (nonatomic, copy, nullable) void (^onSaveAll)(void);
/// Ask for the terminal to run a command (used to sign in to GitHub).
@property (nonatomic, copy, nullable) void (^onRunInTerminal)(NSString *command);
/// Called with an error message the window should show.
@property (nonatomic, copy, nullable) void (^onError)(NSString *title, NSString *message);

/// Actions that the menu bar and status bar also trigger.
- (void)commit;
- (void)push;
- (void)pull;
- (void)sync;
- (void)fetch;
- (void)publishToGitHub;
- (void)createPullRequest;
- (void)createBranch;
- (void)initializeRepository;
- (void)showBranchMenuRelativeToView:(NSView *)view;

@end

NS_ASSUME_NONNULL_END
