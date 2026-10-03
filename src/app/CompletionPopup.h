#pragma once

#import <AppKit/AppKit.h>

#include "LspServer.hpp"

#include <memory>

NS_ASSUME_NONNULL_BEGIN

/// One suggestion from a language server.
@interface GWSuggestion : NSObject
@property (nonatomic, copy) NSString *label;
@property (nonatomic, copy) NSString *detail;
/// What the typed letters are matched against (the label, unless the server says otherwise).
@property (nonatomic, copy) NSString *filterText;
@property (nonatomic, copy) NSString *sortText;
@property (nonatomic) NSInteger kind;  // LSP CompletionItemKind
/// Struck through in the list.
@property (nonatomic) BOOL deprecated;
/// The server's pick for the item most likely wanted when nothing has been typed.
@property (nonatomic) BOOL preselect;
/// Markdown shown beside the list while the item is selected. Often only arrives after the
/// server resolves the item.
@property (nonatomic, copy, nullable) NSString *documentation;
/// Typing one of these letters accepts the item first ("." after a name, "(" and so on).
@property (nonatomic, copy) NSString *commitCharacters;
/// The server's own description of the item, for applying it.
@property (nonatomic) std::shared_ptr<gw::lsp::Json> raw;
/// Whether the server was asked to fill in documentation and extra edits already.
@property (nonatomic) BOOL resolved;
@end

/// The list that appears under the caret while typing: fuzzy-filtered as you keep typing,
/// arrows to move, Return or Tab to accept, Esc to close. It never takes keyboard focus; the
/// editor forwards the keys.
@interface GWSuggestionPopup : NSObject

@property (nonatomic, readonly) BOOL visible;
@property (nonatomic, copy, nullable) void (^onAccept)(GWSuggestion *item);
/// The highlighted item changed (arrows, or the list was refiltered). Used to fetch its documentation.
@property (nonatomic, copy, nullable) void (^onSelectionChanged)(GWSuggestion *item);
/// The row highlighted now, if the list is showing.
@property (nonatomic, readonly, nullable) GWSuggestion *selectedSuggestion;
/// Notes an accepted item so it ranks higher next time.
- (void)recordAccepted:(GWSuggestion *)item;
/// Updates the documentation panel if `item` is still the one highlighted.
- (void)documentationChangedForSuggestion:(GWSuggestion *)item;

/// Replaces the suggestions (unfiltered). Nothing is shown until `showBelowScreenRect:`.
- (void)setItems:(NSArray<GWSuggestion *> *)items;
- (NSUInteger)itemCount;
/// Shows the list under a rectangle given in screen coordinates (the caret).
- (void)showBelowScreenRect:(NSRect)rect parentWindow:(NSWindow *)window;
/// Keeps only items matching the letters typed so far. Hides the list if none match.
- (void)filterWithPrefix:(NSString *)prefix;
- (void)hide;

/// Handles an editor command (moveUp:, moveDown:, insertNewline:, insertTab:, cancelOperation:,
/// pageUp:, pageDown:). Returns YES if the list used it.
- (BOOL)handleSelector:(SEL)selector;

@end

/// What resting the pointer on a word shows: problems on that line, then the server's hover text.
@interface GWHoverPopover : NSObject
+ (void)showMarkdown:(nullable NSString *)markdown
            problems:(NSArray<NSString *> *)problems
      relativeToRect:(NSRect)rect
              ofView:(NSView *)view;
+ (void)hide;
@end

NS_ASSUME_NONNULL_END
