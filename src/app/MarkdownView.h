#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// A text view that sizes itself to its text at any width, so chat text flows inside stacks of views.
@interface GWAutoTextView : NSTextView <NSTextViewDelegate>

// ---- Constructors
- (instancetype)initAutoSizing;

// ---- Content
/// Replaces the text and recomputes the height.
- (void)setAttributedContent:(NSAttributedString *)text;

// ---- Callbacks
/// Return YES if the link was handled.
@property (nonatomic, copy, nullable) BOOL (^onLink)(NSURL *url);

@end

/// Markdown (Claude's replies) as native views: real bold/italic/links/lists, editor-colored code blocks
/// with Copy and Insert, tables and quotes. Cheap while streaming: only changed parts are touched.
@interface GWMarkdownView : NSView

// ---- Content
- (void)setMarkdown:(NSString *)markdown;

// ---- Properties
/// Body text size; code is a little smaller. Default 13.5.
@property (nonatomic) CGFloat fontSize;
/// Turns file names in `code` into links that open the file.
@property (nonatomic, copy, nullable) NSString *projectRoot;

// ---- Callbacks
@property (nonatomic, copy, nullable) void (^onOpenPath)(NSString *path, NSInteger line);
@property (nonatomic, copy, nullable) void (^onInsertCode)(NSString *code);

@end

NS_ASSUME_NONNULL_END
