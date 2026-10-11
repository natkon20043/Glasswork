#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Sidebar folder tree: a transparent outline view for glass. Right-click for New File, Rename, Trash;
/// drag onto folders to move.
@interface GWFileTree : NSObject <NSOutlineViewDataSource, NSOutlineViewDelegate>

// ---- Reloading
/// Keeps expanded folders open.
- (void)reload;
/// Re-reads one already-loaded folder, keeping what is expanded inside it.
- (void)reloadDirectory:(NSURL *)folder;
/// The file icon theme changed.
- (void)refreshIcons;
- (void)collapseAll;

// ---- Creating
/// Asks for the name, then opens it.
- (void)createFileInFolder:(NSURL *)folder;
- (void)createFolderInFolder:(NSURL *)folder;

// ---- Getters
/// Selected folder, else the selected file's folder, else the root.
- (nullable NSURL *)targetFolder;
/// `row` -1 is empty space. Exposed so it can be checked without a mouse.
- (nullable NSMenu *)contextMenuForRow:(NSInteger)row;

// ---- Properties
@property (nonatomic, readonly) NSScrollView *view;
@property (nonatomic, nullable, copy) NSURL *rootURL;

// ---- Callbacks
@property (nonatomic, copy, nullable) void (^onOpenFile)(NSURL *url);
/// Renamed or moved, so open tabs can follow.
@property (nonatomic, copy, nullable) void (^onItemMoved)(NSURL *from, NSURL *to);
/// Put in the Trash, so its tabs can close.
@property (nonatomic, copy, nullable) void (^onItemTrashed)(NSURL *url);
@property (nonatomic, copy, nullable) void (^onOpenInTerminal)(NSURL *folder);
@property (nonatomic, copy, nullable) void (^onAskClaude)(NSURL *url);
@property (nonatomic, copy, nullable) void (^onFindInFolder)(NSURL *folder);
@property (nonatomic, copy, nullable) void (^onError)(NSString *title, NSString *message);

@end

NS_ASSUME_NONNULL_END
