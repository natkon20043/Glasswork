#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A file or folder on another machine, as the folder tree shows it.
@interface GWRemoteItem : NSObject
@property (nonatomic, copy) NSURL *url;
@property (nonatomic) BOOL isDirectory;
@end

/// Files on another machine are named with ssh:// URLs: ssh://user@host/absolute/path.
NSURL *GWRemoteURL(NSString *destination, NSString *path);
BOOL GWIsRemoteURL(NSURL *_Nullable url);
/// "user@host" (or just "host") of a remote URL.
NSString *GWRemoteDestination(NSURL *url);
/// Where a remote file is kept on this Mac while it is open: a folder per machine, the remote
/// path below it, so the file keeps its name and extension (which choose its language).
NSString *GWLocalCopyPathForRemoteURL(NSURL *url);

/// The entries of a remote folder, or nil with `error` set. Blocks until the machine answers.
NSArray<GWRemoteItem *> *_Nullable GWListRemoteFolder(NSURL *folder, NSString *_Nullable *_Nullable error);
/// The remote file's text, or nil with `error` set.
NSData *_Nullable GWReadRemoteFile(NSURL *file, NSString *_Nullable *_Nullable error);
/// Sends `contents` to replace the remote file. NO with `error` set on failure.
BOOL GWWriteRemoteFile(NSURL *file, NSData *contents, NSString *_Nullable *_Nullable error);
/// A folder given as "~", "~/code" or an absolute path, made absolute on the remote machine.
NSString *_Nullable GWResolveRemotePath(NSString *destination, NSString *path, NSString *_Nullable *_Nullable error);
/// The command line (for a terminal) that opens a shell in a remote folder.
NSString *GWRemoteShellCommand(NSURL *folder);

NS_ASSUME_NONNULL_END
