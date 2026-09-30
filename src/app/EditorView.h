#pragma once

#import <AppKit/AppKit.h>

#include "Document.hpp"
#include "Extensions.hpp"
#include "Highlighter.hpp"
#include "LineDiff.hpp"
#include "Sections.hpp"
#include "LanguageService.h"

#include "Theme.hpp"

#include <optional>
#include <string>
#include <vector>

NS_ASSUME_NONNULL_BEGIN

/// The code editor: draws a document with CoreText on a translucent backdrop and handles
/// typing, selection and editing commands. It lives inside an NSScrollView, which it gives
/// a line-number ruler; it also provides a minimap for the window to place beside it.
@interface GWEditorView : NSView <NSTextInputClient>

/// The document shown (not owned). Setting it resets layout caches.
- (void)setDocument:(gw::Document *_Nullable)document
        highlighter:(gw::Highlighter *_Nullable)highlighter
      configuration:(const gw::LanguageConfiguration &)configuration;

/// Called for every change to any document, so caches tied to the shown one stay current.
- (void)document:(gw::Document *)document changedFromLine:(size_t)line;
/// The same, with the whole change (lines added or removed, last line touched), which soft wrap
/// and folding need to keep their row counts right.
- (void)document:(gw::Document *)document changed:(const gw::Change &)change;

@property (nonatomic, copy, nullable) void (^onSelectionChange)(void);
@property (nonatomic, copy, nullable) void (^onEdit)(void);
/// Called when MARK / TODO / FIXME comments change (for the breadcrumb's jump menu).
@property (nonatomic, copy, nullable) void (^onSectionsChange)(void);
/// Called when the user asks to inspect or recolour code (right-click menu).
@property (nonatomic, copy, nullable) void (^onInspectColors)(void);

/// The document being shown (not owned), or null.
- (gw::Document *_Nullable)currentDocument;

/// MARK / TODO / FIXME comments in the document, top to bottom.
- (std::vector<gw::Section>)sections;
/// Moves the caret to the start of `line` and centres it on screen.
- (void)jumpToLine:(size_t)line;
- (void)jumpToPosition:(gw::Position)position;
/// Call after changing the selection from outside (scrolls to the caret and redraws).
- (void)selectionDidChange;
/// Sizes the text area to the visible area and the text. The window calls this after laying out.
- (void)updateFrameSize;
/// Runs several edits to the document as one undo step (used by Replace All).
- (void)editDocument:(void (^)(gw::Document &document))edits;
/// Applies a language-server completion as one undoable edit.
- (void)replaceRange:(gw::Range)range withText:(const std::string &)text;
/// TextMate scopes at the caret, innermost first (e.g. "variable.parameter.cpp", …, "source.cpp").
- (std::vector<std::string>)scopesAtCaret;
/// The identifier at the caret, or an empty string if the caret isn't on a name.
- (std::string)wordAtCaret;
/// How the text under the caret currently looks (theme + colour rules + rainbow), or
/// nullopt if the file isn't highlighted.
- (std::optional<gw::TextStyle>)styleAtCaret;
/// How the theme and colour rules style `scope` where it appears at the caret (without the
/// rainbow or per-name colours), or nullopt if the caret isn't inside that scope.
- (std::optional<gw::TextStyle>)styleForScopeAtCaret:(const std::string &)scope;

// MARK: Version control marks

/// Lines that differ from the last commit, drawn as coloured bars next to the line numbers.
- (void)setLineChanges:(std::vector<gw::LineChange>)changes;
/// Called when a change bar is clicked, with the line and the bar's rectangle in the view.
@property (nonatomic, copy, nullable) void (^onChangeMarkerClick)(size_t line, NSRect rect);
/// Tints whole lines (one colour per line, 0 for none). Used to colour added and removed
/// lines in diff tabs.
- (void)setLineTints:(std::vector<gw::Color>)tints;

// MARK: Language intelligence

/// Problems to underline (and mark in the line numbers).
- (void)setDiagnostics:(std::vector<GWDiagnostic>)diagnostics;
/// The pointer rested on a word: `position` is its start. Answer by showing something near it.
@property (nonatomic, copy, nullable) void (^onHoverRequest)(gw::Position position, gw::Range word);
/// The pointer moved away (or the editor changed): hide what the hover showed.
@property (nonatomic, copy, nullable) void (^onHoverEnd)(void);
/// Called for keys the editor would act on (moveUp:, moveDown:, insertNewline:, insertTab:,
/// cancelOperation:). Return YES to say the completion list used the key.
@property (nonatomic, copy, nullable) BOOL (^onCompletionKey)(SEL selector);
/// Called after every edit: what was typed, or nil for a deletion or other change.
@property (nonatomic, copy, nullable) void (^onTypedText)(NSString *_Nullable typed);
/// Colours from a language server's semantic highlighting (types, functions, macros…); pass an
/// empty pointer to clear them.
- (void)setSemanticTokens:(std::shared_ptr<const gw::SemanticTokenSet>)tokens;
/// The rectangle covered by a stretch of one line, in the editor's own coordinates.
- (NSRect)viewRectForRange:(gw::Range)range;
/// The rectangle of a position on screen (for placing popups).
- (NSRect)screenRectForPosition:(gw::Position)position;

// MARK: Debugging

/// Adds or removes a breakpoint on a line (the lines live in the document, so they follow edits).
- (void)toggleBreakpointAtLine:(size_t)line;
/// Called after breakpoints were added or removed by clicking the line numbers.
@property (nonatomic, copy, nullable) void (^onBreakpointsChange)(void);
/// Marks the line the debugger is stopped on (-1 for none) with an arrow and a soft band.
- (void)setExecutionLine:(NSInteger)line;

// MARK: Find

/// Highlights every match of a search (behind the text) and marks one as the current match.
- (void)setFindMatches:(std::vector<gw::Range>)matches current:(long)current;
/// Selects a range and scrolls it into view (centred if it is off screen).
- (void)selectRange:(gw::Range)range;
/// The selected text, or the word at the caret if nothing is selected.
- (std::string)selectedText;
/// Briefly glows the given lines, fading out. Shows where Claude just made changes.
- (void)flashLines:(size_t)first count:(size_t)count;

/// A scaled-down overview of the whole file; click or drag it to scroll.
@property (nonatomic, readonly) NSView *minimapView;
/// The lines that open the function or class you are scrolled into, pinned above the code. Place it
/// over the top of the editor (gutter and text), `stickyHeight` tall; hidden when the height is 0.
@property (nonatomic, readonly) NSView *stickyView;
@property (nonatomic, readonly) CGFloat stickyHeight;
/// Called when the pinned lines appear, disappear or change in number.
@property (nonatomic, copy, nullable) void (^onStickyChange)(void);
/// Line numbers, to be placed immediately left of the editor's scroll view, `gutterWidth` wide.
@property (nonatomic, readonly) NSView *gutterView;
@property (nonatomic, readonly) CGFloat gutterWidth;

/// Re-reads fonts and colours from GWServices.
- (void)reloadAppearance;
/// Call after the document changed from outside the view (e.g. grammar swapped).
- (void)invalidateLayout;
- (void)scrollCaretToVisible;
- (void)scrollToLineCentered:(size_t)line;

// Editing commands (also reachable from the menu bar through the responder chain).
- (IBAction)toggleLineComment:(nullable id)sender;
- (IBAction)indentLines:(nullable id)sender;
- (IBAction)expandSelection:(nullable id)sender;
- (IBAction)shrinkSelection:(nullable id)sender;
- (IBAction)goToMatchingBracket:(nullable id)sender;
- (IBAction)makeUpperCase:(nullable id)sender;
- (IBAction)makeLowerCase:(nullable id)sender;
- (IBAction)makeTitleCase:(nullable id)sender;
- (IBAction)sortLinesAscending:(nullable id)sender;
- (IBAction)sortLinesDescending:(nullable id)sender;
- (IBAction)removeDuplicateLines:(nullable id)sender;
- (IBAction)joinSelectedLines:(nullable id)sender;
- (IBAction)outdentLines:(nullable id)sender;

/// Overrides how this file is indented (from its .editorconfig): `usesTabs` is 1 for tabs, 0 for
/// spaces, -1 to decide from the file; `tabSize` of 0 means the setting from settings.json.
- (void)setIndentationOverrideUsesTabs:(int)usesTabs tabSize:(size_t)tabSize;

// Multiple cursors.
/// How many cursors there are (1 normally).
- (NSUInteger)cursorCount;
- (IBAction)addCursorAbove:(nullable id)sender;
- (IBAction)addCursorBelow:(nullable id)sender;
- (IBAction)selectAllOccurrences:(nullable id)sender;
- (IBAction)selectNextOccurrence:(nullable id)sender;

// Soft wrap and folding.
- (IBAction)toggleWordWrap:(nullable id)sender;
- (IBAction)foldCode:(nullable id)sender;
- (IBAction)unfoldCode:(nullable id)sender;
- (IBAction)foldAllCode:(nullable id)sender;
- (IBAction)unfoldAllCode:(nullable id)sender;

@end

NS_ASSUME_NONNULL_END
