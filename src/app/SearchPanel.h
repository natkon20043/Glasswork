#pragma once

#import <AppKit/AppKit.h>

#include <memory>
#include <string>
#include <vector>

NS_ASSUME_NONNULL_BEGIN

/// Sidebar "Search" tab: find text across the project with case, whole word, regex, file filters and
/// replace. Results appear while the search runs.
@interface GWSearchPanel : NSObject

// ---- Actions
/// Optionally fills the field (the selected word).
- (void)focusWithText:(nullable NSString *)text;
/// Path relative to the project, or empty for everything. Shows the filters and focuses the query field.
- (void)restrictToFolder:(NSString *)relativeFolder;
/// Call when files changed.
- (void)rerun;

// ---- Properties
@property (nonatomic, readonly) NSView *view;
/// Results show paths relative to it.
@property (nonatomic, copy, nullable) NSString *rootFolder;

// ---- Callbacks
/// Relative paths to search; called at the start of each search.
@property (nonatomic, copy, nullable) std::shared_ptr<const std::vector<std::string>> (^filesProvider)(void);
/// Line and column count from zero; the column is a byte offset.
@property (nonatomic, copy, nullable) void (^onOpenHit)(NSString *relativePath, NSUInteger line, NSUInteger column, NSUInteger length);
/// Files with unsaved editor changes must not be rewritten behind its back.
@property (nonatomic, copy, nullable) BOOL (^isFileDirty)(NSString *absolutePath);
/// Replace rewrote these on disk; the editor should reload any that are open.
@property (nonatomic, copy, nullable) void (^onFilesChanged)(NSArray<NSString *> *absolutePaths);
@property (nonatomic, copy, nullable) void (^onError)(NSString *title, NSString *message);

@end

NS_ASSUME_NONNULL_END
