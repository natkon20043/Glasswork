#pragma once

#import <AppKit/AppKit.h>

#include <memory>
#include <string>
#include <vector>

NS_ASSUME_NONNULL_BEGIN

/// The "Search" tab of the sidebar: find text in every file of the project, with case, whole
/// word and regular expression options, file filters, and replace. Results appear while the
/// search is still running.
@interface GWSearchPanel : NSObject

@property (nonatomic, readonly) NSView *view;

/// The project folder. Results show paths relative to it.
@property (nonatomic, copy, nullable) NSString *rootFolder;

/// The files to search (relative paths). Called at the start of each search.
@property (nonatomic, copy, nullable) std::shared_ptr<const std::vector<std::string>> (^filesProvider)(void);

/// A result was clicked: open the file and select the match. Line and column count from zero;
/// the column is a byte offset in the line.
@property (nonatomic, copy, nullable) void (^onOpenHit)(NSString *relativePath, NSUInteger line, NSUInteger column, NSUInteger length);

/// Files that have unsaved changes in the editor must not be rewritten behind its back.
@property (nonatomic, copy, nullable) BOOL (^isFileDirty)(NSString *absolutePath);

/// Files were rewritten on disk by Replace; the editor should reload any that are open.
@property (nonatomic, copy, nullable) void (^onFilesChanged)(NSArray<NSString *> *absolutePaths);

@property (nonatomic, copy, nullable) void (^onError)(NSString *title, NSString *message);

/// Focuses the search field, optionally filling it in (the selected word).
- (void)focusWithText:(nullable NSString *)text;
/// Limits the search to a folder (a path relative to the project, or empty for everything) and
/// shows the filters. Clears the query field's focus into it, ready to type.
- (void)restrictToFolder:(NSString *)relativeFolder;
/// Runs the search again (files changed).
- (void)rerun;

@end

NS_ASSUME_NONNULL_END
