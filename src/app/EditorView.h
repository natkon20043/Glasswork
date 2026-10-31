#pragma once

#import <AppKit/AppKit.h>

#include "Document.hpp"
#include "Extensions.hpp"
#include "Highlighter.hpp"
#include "LineDiff.hpp"
#include "Sections.hpp"
#include "LanguageService.h"

#include "Theme.hpp"
#include "Vim.hpp"

#include <map>
#include <optional>
#include <string>
#include <vector>

NS_ASSUME_NONNULL_BEGIN

/// An extension's look for a stretch of text (`setDecorations`).
struct GWDecoration {
    gw::Range range;
    std::optional<gw::Color> background;
    std::optional<gw::Color> foreground;
    std::optional<gw::Color> border;
    /// The background covers the whole line, not just the range.
    bool wholeLine = false;
    bool bold = false;
    bool italic = false;
    bool underline = false;
    bool strikethrough = false;
    /// A note drawn after the end of the line.
    std::string afterText;
    std::optional<gw::Color> afterColor;
};

/// The code editor: draws a document with CoreText on a translucent backdrop and handles typing,
/// selection and editing commands. Lives in an NSScrollView it gives a line-number ruler, and provides
/// a minimap for the window to place beside it.
@interface GWEditorView : NSView <NSTextInputClient>

// ---- Document
/// Not owned. Resets layout caches.
- (void)setDocument:(gw::Document *_Nullable)document
        highlighter:(gw::Highlighter *_Nullable)highlighter
      configuration:(const gw::LanguageConfiguration &)configuration;
- (gw::Document *_Nullable)currentDocument;
/// Called for every change to any document, so caches for the shown one stay current.
- (void)document:(gw::Document *)document changedFromLine:(size_t)line;
/// The whole change, which soft wrap and folding need for their row counts.
- (void)document:(gw::Document *)document changed:(const gw::Change &)change;
- (void)editDocument:(void (^)(gw::Document &document))edits;
- (void)replaceRange:(gw::Range)range withText:(const std::string &)text;

// ---- Layout and appearance
- (void)updateFrameSize;
/// Re-reads fonts and colors from GWServices.
- (void)reloadAppearance;
/// Call after the document changed from outside the view (e.g. grammar swapped).
- (void)invalidateLayout;
/// `usesTabs`: 1 tabs, 0 spaces, -1 decide from the file. `tabSize` 0 uses settings.json.
- (void)setIndentationOverrideUsesTabs:(int)usesTabs tabSize:(size_t)tabSize;

// ---- Selection and navigation
- (void)selectionDidChange;
- (void)selectRange:(gw::Range)range;
- (void)jumpToLine:(size_t)line;
- (void)jumpToPosition:(gw::Position)position;
- (void)scrollCaretToVisible;
- (void)scrollToLineCentered:(size_t)line;
- (void)flashLines:(size_t)first count:(size_t)count;
- (NSUInteger)cursorCount;

// ---- Queries
- (std::vector<gw::Section>)sections;
/// Innermost first, e.g. "variable.parameter.cpp", ..., "source.cpp".
- (std::vector<std::string>)scopesAtCaret;
/// Empty if the caret isn't on a name.
- (std::string)wordAtCaret;
/// Theme + color rules + rainbow; nullopt if the file isn't highlighted.
- (std::optional<gw::TextStyle>)styleAtCaret;
/// Without rainbow or per-name colors; nullopt if the caret isn't inside `scope`.
- (std::optional<gw::TextStyle>)styleForScopeAtCaret:(const std::string &)scope;
/// The word at the caret if nothing is selected.
- (std::string)selectedText;
- (NSRect)viewRectForRange:(gw::Range)range;
- (NSRect)screenRectForPosition:(gw::Position)position;

// ---- Marks and overlays
/// Lines differing from the last commit, drawn as bars by the line numbers.
- (void)setLineChanges:(std::vector<gw::LineChange>)changes;
/// One color per line, 0 for none (diff tabs).
- (void)setLineTints:(std::vector<gw::Color>)tints;
/// Parameter names and inferred types between characters. Replaces all; empty clears.
- (void)setInlayHints:(std::vector<GWInlayHint>)hints;
/// Grouped by decoration type. Replaces all.
- (void)setDecorationGroups:(const std::map<std::string, std::vector<GWDecoration>> &)groups;
/// Underlined, and marked in the line numbers.
- (void)setDiagnostics:(std::vector<GWDiagnostic>)diagnostics;
/// Empty pointer clears.
- (void)setSemanticTokens:(std::shared_ptr<const gw::SemanticTokenSet>)tokens;
/// Highlights every match behind the text and marks `current` as the current one.
- (void)setFindMatches:(std::vector<gw::Range>)matches current:(long)current;

// ---- Debugging
- (void)toggleBreakpointAtLine:(size_t)line;
/// -1 for none; drawn with an arrow and a soft band.
- (void)setExecutionLine:(NSInteger)line;

// ---- Editing commands (also reachable from the menu bar through the responder chain)
- (IBAction)toggleLineComment:(nullable id)sender;
- (IBAction)indentLines:(nullable id)sender;
- (IBAction)outdentLines:(nullable id)sender;
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

// ---- Multiple cursors
- (IBAction)addCursorAbove:(nullable id)sender;
- (IBAction)addCursorBelow:(nullable id)sender;
- (IBAction)selectAllOccurrences:(nullable id)sender;
- (IBAction)selectNextOccurrence:(nullable id)sender;

// ---- Soft wrap and folding
- (IBAction)toggleWordWrap:(nullable id)sender;
- (IBAction)foldCode:(nullable id)sender;
- (IBAction)unfoldCode:(nullable id)sender;
- (IBAction)foldAllCode:(nullable id)sender;
- (IBAction)unfoldAllCode:(nullable id)sender;

// ---- Properties
/// Scaled-down overview of the file; click or drag to scroll.
@property (nonatomic, readonly) NSView *minimapView;
/// Lines opening the function or class you are in, pinned over the top of the editor (gutter and text),
/// `stickyHeight` tall; hidden at 0.
@property (nonatomic, readonly) NSView *stickyView;
@property (nonatomic, readonly) CGFloat stickyHeight;
/// Line numbers, placed immediately left of the editor's scroll view, `gutterWidth` wide.
@property (nonatomic, readonly) NSView *gutterView;
@property (nonatomic, readonly) CGFloat gutterWidth;

// ---- Callbacks
@property (nonatomic, copy, nullable) void (^onSelectionChange)(void);
@property (nonatomic, copy, nullable) void (^onEdit)(void);
/// MARK / TODO / FIXME comments changed (breadcrumb jump menu).
@property (nonatomic, copy, nullable) void (^onSectionsChange)(void);
/// Right-click: inspect or recolor code.
@property (nonatomic, copy, nullable) void (^onInspectColors)(void);
/// Right-click: jump to where the name at the caret is defined.
@property (nonatomic, copy, nullable) void (^onGoToDefinition)(void);
/// Right-click: list every use of the name at the caret.
@property (nonatomic, copy, nullable) void (^onFindReferences)(void);
/// A change bar was clicked; `rect` is the bar in the view.
@property (nonatomic, copy, nullable) void (^onChangeMarkerClick)(size_t line, NSRect rect);
/// The pointer rested on a word starting at `position`; answer by showing something near it.
@property (nonatomic, copy, nullable) void (^onHoverRequest)(gw::Position position, gw::Range word);
/// The pointer moved away or the editor changed: hide the hover.
@property (nonatomic, copy, nullable) void (^onHoverEnd)(void);
/// For keys the editor would act on (moveUp:, moveDown:, insertNewline:, insertTab:, cancelOperation:).
/// Return YES if the completion list used the key.
@property (nonatomic, copy, nullable) BOOL (^onCompletionKey)(SEL selector);
/// After every edit: what was typed, or nil for a deletion or other change.
@property (nonatomic, copy, nullable) void (^onTypedText)(NSString *_Nullable typed);
/// Breakpoints were added or removed by clicking the line numbers.
@property (nonatomic, copy, nullable) void (^onBreakpointsChange)(void);
/// The pinned lines appeared, disappeared or changed in number.
@property (nonatomic, copy, nullable) void (^onStickyChange)(void);

// ---- Vim
/// "NORMAL", "INSERT", "VISUAL" or "V-LINE", with a command in progress after it ("NORMAL  2d");
/// nil when Vim mode is off.
@property (nonatomic, readonly, nullable) NSString *vimStatus;
/// NO in Vim's normal and visual modes, where keys are commands and nothing is being typed.
@property (nonatomic, readonly) BOOL insertsText;
/// The mode or the command in progress changed.
@property (nonatomic, copy, nullable) void (^onVimStatusChange)(void);
/// A ":" command the editor can't do itself (:w, :q, :wq...), without the colon. Return an error
/// message to show, or nil when it worked.
@property (nonatomic, copy, nullable) NSString *_Nullable (^onVimCommand)(NSString *command);
/// Vim asked for something the window does: the find bar, or the next and previous match.
@property (nonatomic, copy, nullable) void (^onVimAction)(gw::VimAction action);

@end

NS_ASSUME_NONNULL_END
