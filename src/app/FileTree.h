#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// The sidebar's folder tree: a transparent outline view meant to sit on glass. Right-click for
/// New File, Rename, Trash and so on; drag items onto folders to move them.
@interface GWFileTree : NSObject <NSOutlineViewDataSource, NSOutlineViewDelegate>

@property (nonatomic, readonly) NSScrollView *view;
@property (nonatomic, nullable, copy) NSURL *rootURL;
@property (nonatomic, copy, nullable) void (^onOpenFile)(NSURL *url);

/// A file or folder was renamed or moved (so open tabs can follow it).
@property (nonatomic, copy, nullable) void (^onItemMoved)(NSURL *from, NSURL *to);
/// A file or folder was put in the Trash (so its tabs can close).
@property (nonatomic, copy, nullable) void (^onItemTrashed)(NSURL *url);
@property (nonatomic, copy, nullable) void (^onOpenInTerminal)(NSURL *folder);
@property (nonatomic, copy, nullable) void (^onAskClaude)(NSURL *url);
@property (nonatomic, copy, nullable) void (^onFindInFolder)(NSURL *folder);
@property (nonatomic, copy, nullable) void (^onError)(NSString *title, NSString *message);

/// Reloads everything (keeps expanded folders open).
- (void)reload;
/// Re-reads one folder that is already loaded, keeping what is expanded inside it.
- (void)reloadDirectory:(NSURL *)folder;

/// Creates a file or folder inside `folder` (asking for the name), then opens it.
- (void)createFileInFolder:(NSURL *)folder;
- (void)createFolderInFolder:(NSURL *)folder;
/// The folder that is selected, else the one containing the selected file, else the root.
- (nullable NSURL *)targetFolder;
- (void)collapseAll;
/// The right-click menu for a row (-1 for empty space). Exposed so it can be checked without a mouse.
- (nullable NSMenu *)contextMenuForRow:(NSInteger)row;

@end

NS_ASSUME_NONNULL_END
