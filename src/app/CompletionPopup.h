#pragma once

#import <AppKit/AppKit.h>

#include "LspServer.hpp"

#include <memory>

NS_ASSUME_NONNULL_BEGIN

/// One suggestion from a language server.
@interface GWSuggestion : NSObject

@property (nonatomic, copy) NSString *label;
@property (nonatomic, copy) NSString *detail;
/// What typed letters match against (the label unless the server says otherwise).
@property (nonatomic, copy) NSString *filterText;
@property (nonatomic, copy) NSString *sortText;
/// LSP CompletionItemKind.
@property (nonatomic) NSInteger kind;
/// Struck through in the list.
@property (nonatomic) BOOL deprecated;
/// The server's pick when nothing has been typed.
@property (nonatomic) BOOL preselect;
/// Markdown beside the list; often arrives only after the server resolves the item.
@property (nonatomic, copy, nullable) NSString *documentation;
/// Typing one of these accepts the item first (".", "(").
@property (nonatomic, copy) NSString *commitCharacters;
/// The server's own description, for applying the item.
@property (nonatomic) std::shared_ptr<gw::lsp::Json> raw;
/// The server was already asked for documentation and extra edits.
@property (nonatomic) BOOL resolved;

@end

/// Fuzzy-filtered list under the caret. Never takes keyboard focus; the editor forwards the keys.
@interface GWSuggestionPopup : NSObject

// ---- Showing
/// Nothing shows until `showBelowScreenRect:`.
- (void)setItems:(NSArray<GWSuggestion *> *)items;
/// `rect` is the caret in screen coordinates.
- (void)showBelowScreenRect:(NSRect)rect parentWindow:(NSWindow *)window;
/// Keeps items matching the typed letters; hides the list if none match.
- (void)filterWithPrefix:(NSString *)prefix;
- (void)hide;

// ---- Selection
/// Handles moveUp:, moveDown:, insertNewline:, insertTab:, cancelOperation:, pageUp:, pageDown:.
/// Returns YES if the list used it.
- (BOOL)handleSelector:(SEL)selector;
/// Ranks the item higher next time.
- (void)recordAccepted:(GWSuggestion *)item;
- (void)documentationChangedForSuggestion:(GWSuggestion *)item;

// ---- Getters
- (NSUInteger)itemCount;

// ---- Properties
@property (nonatomic, readonly) BOOL visible;
@property (nonatomic, readonly, nullable) GWSuggestion *selectedSuggestion;

// ---- Callbacks
@property (nonatomic, copy, nullable) void (^onAccept)(GWSuggestion *item);
/// Arrows moved or the list was refiltered; used to fetch documentation.
@property (nonatomic, copy, nullable) void (^onSelectionChanged)(GWSuggestion *item);

@end

/// Pointer rested on a word: problems on that line, then the server's hover text.
@interface GWHoverPopover : NSObject
+ (void)showMarkdown:(nullable NSString *)markdown
            problems:(NSArray<NSString *> *)problems
      relativeToRect:(NSRect)rect
              ofView:(NSView *)view;
+ (void)hide;
@end

NS_ASSUME_NONNULL_END
