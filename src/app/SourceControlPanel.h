#pragma once

#import <AppKit/AppKit.h>

@class GWGitRepository;

NS_ASSUME_NONNULL_BEGIN

/// Sidebar "Changes" tab: branch, commit box, staged and unstaged files, recent commits, all from a GWGitRepository.
@interface GWSourceControlPanel : NSObject

// ---- Constructors
- (instancetype)initWithRepository:(GWGitRepository *)repository;

// ---- Actions (also triggered from the menu bar and status bar)
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

// ---- Properties
@property (nonatomic, readonly) NSView *view;

// ---- Callbacks
@property (nonatomic, copy, nullable) void (^onOpenFile)(NSString *absolutePath);
/// Shows a file's changes in a read-only tab.
@property (nonatomic, copy, nullable) void (^onShowDiff)(NSString *relativePath, BOOL staged);
@property (nonatomic, copy, nullable) void (^onShowCommit)(NSString *hash, NSString *subject);
/// Before something that needs saved files (commit): save every open file with unsaved changes.
@property (nonatomic, copy, nullable) void (^onSaveAll)(void);
/// Used to sign in to GitHub.
@property (nonatomic, copy, nullable) void (^onRunInTerminal)(NSString *command);
@property (nonatomic, copy, nullable) void (^onError)(NSString *title, NSString *message);

@end

NS_ASSUME_NONNULL_END
