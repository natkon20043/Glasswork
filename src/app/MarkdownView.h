#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// A text view that sizes itself to its text at whatever width it is given. Used wherever
/// chat text has to flow inside a stack of views.
@interface GWAutoTextView : NSTextView <NSTextViewDelegate>
/// Called when a link is clicked. Return YES if handled.
@property (nonatomic, copy, nullable) BOOL (^onLink)(NSURL *url);
- (instancetype)initAutoSizing;
/// Replaces the text and recomputes the height.
- (void)setAttributedContent:(NSAttributedString *)text;
@end

/// Draws Markdown (Claude's replies) as native views: text with real bold, italic, links and
/// lists; code blocks coloured like the editor with Copy and Insert buttons; tables; quotes.
/// Cheap to update while a reply streams in, because only the parts that changed are
/// touched.
@interface GWMarkdownView : NSView

/// Text size for body text (code is a little smaller). Default 13.5.
@property (nonatomic) CGFloat fontSize;
/// The project folder, used to turn file names in `code` into links that open the file.
@property (nonatomic, copy, nullable) NSString *projectRoot;
@property (nonatomic, copy, nullable) void (^onOpenPath)(NSString *path, NSInteger line);
@property (nonatomic, copy, nullable) void (^onInsertCode)(NSString *code);

- (void)setMarkdown:(NSString *)markdown;

@end

NS_ASSUME_NONNULL_END
