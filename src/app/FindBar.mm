#import "FindBar.h"
#import "Strings.h"

#import "EditorView.h"
#import "PixelArt.h"
#import "Services.h"

#include "ProjectSearch.hpp"

#include <cmath>
#include <memory>
#include <vector>

// ===========================================================================
// A small on/off button that lights up when on

@interface GWOptionButton : NSButton
/// Pixel text, lit with the bitmap scheme's highlight.
@property (nonatomic) BOOL retro;
@end

@implementation GWOptionButton

- (instancetype)initWithTitle:(NSString *)title tip:(NSString *)tip {
    self = [super initWithFrame:NSZeroRect];
    if (self) {
        self.title = title;
        self.toolTip = tip;
        self.bordered = NO;
        self.buttonType = NSButtonTypePushOnPushOff;
        self.translatesAutoresizingMaskIntoConstraints = NO;
        [self.widthAnchor constraintEqualToConstant:26].active = YES;
        [self.heightAnchor constraintEqualToConstant:22].active = YES;
    }
    return self;
}

- (void)drawRect:(NSRect)dirtyRect {
    BOOL on = self.state == NSControlStateValueOn;
    if (_retro) {
        const gw::bitmap::Scheme &colors = GWServices.shared.bitmapScheme;
        if (on) {
            [GWColor(colors.barHighlight) setFill];
            NSRectFill(self.bounds);
        }
        CGFloat pixel = GWChromePixel();
        CGFloat width = GWPixelTextWidth(self.title, pixel);
        CGFloat line = 12 * pixel;
        NSPoint origin = NSMakePoint(std::floor((NSWidth(self.bounds) - width) / 2), std::floor((NSHeight(self.bounds) - line) / 2));
        GWDrawPixelText(self.title, origin, pixel, GWColor(on ? colors.barHighlightText : colors.barText), NO);
        return;
    }
    if (on) {
        [[NSColor.controlAccentColor colorWithAlphaComponent:0.30] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 1, 1) xRadius:6 yRadius:6] fill];
    }
    NSDictionary *attributes = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:11.5 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: on ? NSColor.labelColor : NSColor.secondaryLabelColor,
    };
    NSSize size = [self.title sizeWithAttributes:attributes];
    [self.title drawAtPoint:NSMakePoint(NSMidX(self.bounds) - size.width / 2, NSMidY(self.bounds) - size.height / 2)
             withAttributes:attributes];
}

@end

// ===========================================================================
// The bar

@interface GWFindBar () <NSTextFieldDelegate>
@end

@implementation GWFindBar {
    NSGlassEffectView *_glass;
    NSTextField *_findField;
    NSTextField *_replaceField;
    NSTextField *_countLabel;
    GWOptionButton *_caseButton;
    GWOptionButton *_wordButton;
    GWOptionButton *_regexButton;
    NSButton *_toggleReplace;
    NSArray<NSButton *> *_iconButtons;
    NSArray<NSButton *> *_replaceButtons;
    NSStackView *_stack;
    GWRetroBox *_retroBox;
    NSStackView *_replaceRow;
    NSLayoutConstraint *_replaceRowHeight;
    BOOL _replaceVisible;

    std::unique_ptr<gw::search::Matcher> _matcher;
    std::vector<gw::Range> _matches;
    long _current;
    gw::Position _anchor;  // where the search started; matches are picked at or after it
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _current = -1;
        self.hidden = YES;
        [self build];
    }
    return self;
}

- (NSTextField *)fieldWithPlaceholder:(NSString *)placeholder {
    NSTextField *field = [NSTextField new];
    field.placeholderString = placeholder;
    field.bezeled = NO;
    field.drawsBackground = NO;
    field.focusRingType = NSFocusRingTypeNone;
    field.font = [NSFont systemFontOfSize:13];
    field.delegate = self;
    field.cell.scrollable = YES;
    field.cell.wraps = NO;
    field.translatesAutoresizingMaskIntoConstraints = NO;
    return field;
}

- (NSButton *)iconButton:(NSString *)symbol tip:(NSString *)tip action:(SEL)action {
    NSImage *image = [[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:tip]
        imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:11 weight:NSFontWeightSemibold]];
    NSButton *button = [NSButton buttonWithImage:image target:self action:action];
    button.bordered = NO;
    button.contentTintColor = NSColor.secondaryLabelColor;
    button.toolTip = tip;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button.widthAnchor constraintEqualToConstant:22].active = YES;
    [button.heightAnchor constraintEqualToConstant:22].active = YES;
    return button;
}

- (void)build {
    _glass = [NSGlassEffectView new];
    _glass.cornerRadius = 14;
    _glass.translatesAutoresizingMaskIntoConstraints = NO;

    _toggleReplace = [self iconButton:@"chevron.right" tip:@"Show replace" action:@selector(toggleReplaceClicked:)];
    _findField = [self fieldWithPlaceholder:@"Find"];
    _caseButton = [[GWOptionButton alloc] initWithTitle:@"Aa" tip:@"Match case"];
    _wordButton = [[GWOptionButton alloc] initWithTitle:@"ab" tip:@"Whole word"];
    _regexButton = [[GWOptionButton alloc] initWithTitle:@".*" tip:@"Regular expression"];
    for (GWOptionButton *button in @[_caseButton, _wordButton, _regexButton]) {
        button.target = self;
        button.action = @selector(optionChanged:);
    }
    _countLabel = [NSTextField labelWithString:@""];
    _countLabel.font = [NSFont monospacedDigitSystemFontOfSize:11.5 weight:NSFontWeightMedium];
    _countLabel.textColor = NSColor.secondaryLabelColor;
    _countLabel.alignment = NSTextAlignmentRight;
    _countLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_countLabel.widthAnchor constraintGreaterThanOrEqualToConstant:64].active = YES;
    NSButton *previous = [self iconButton:@"chevron.up" tip:@"Previous match  ⇧⌘G" action:@selector(previousClicked:)];
    NSButton *next = [self iconButton:@"chevron.down" tip:@"Next match  ⌘G" action:@selector(nextClicked:)];
    NSButton *close = [self iconButton:@"xmark" tip:@"Close  ⎋" action:@selector(closeClicked:)];

    NSStackView *findRow = [NSStackView stackViewWithViews:@[_toggleReplace, _findField, _caseButton, _wordButton, _regexButton, _countLabel, previous, next, close]];
    findRow.spacing = 4;
    findRow.alignment = NSLayoutAttributeCenterY;
    findRow.translatesAutoresizingMaskIntoConstraints = NO;

    _replaceField = [self fieldWithPlaceholder:@"Replace"];
    NSButton *replace = [NSButton buttonWithTitle:@"Replace" target:self action:@selector(replaceClicked:)];
    NSButton *replaceAll = [NSButton buttonWithTitle:@"All" target:self action:@selector(replaceAllClicked:)];
    for (NSButton *button in @[replace, replaceAll]) {
        button.bezelStyle = NSBezelStyleGlass;
        button.controlSize = NSControlSizeSmall;
        button.translatesAutoresizingMaskIntoConstraints = NO;
    }
    NSView *indent = [NSView new];
    indent.translatesAutoresizingMaskIntoConstraints = NO;
    [indent.widthAnchor constraintEqualToConstant:22].active = YES;
    _replaceRow = [NSStackView stackViewWithViews:@[indent, _replaceField, replace, replaceAll]];
    _replaceRow.spacing = 6;
    _replaceRow.alignment = NSLayoutAttributeCenterY;
    _replaceRow.translatesAutoresizingMaskIntoConstraints = NO;
    _replaceRow.hidden = YES;

    NSStackView *stack = [NSStackView stackViewWithViews:@[findRow, _replaceRow]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 4;
    stack.edgeInsets = NSEdgeInsetsMake(8, 8, 8, 10);
    [findRow.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-18].active = YES;
    [_replaceRow.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-18].active = YES;
    _glass.contentView = stack;
    _stack = stack;
    _iconButtons = @[_toggleReplace, previous, next, close];
    _replaceButtons = @[replace, replaceAll];

    [self addSubview:_glass];
    [NSLayoutConstraint activateConstraints:@[
        [_glass.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_glass.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_glass.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_glass.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    ]];
}

/// The match count's color: `glass` normally, the box's own text (hotkey color for a problem) in bitmap mode.
- (NSColor *)countColor:(NSColor *)glass {
    if (!_retro) {
        return glass;
    }
    const gw::bitmap::Scheme &colors = GWServices.shared.bitmapScheme;
    BOOL problem = glass == NSColor.systemRedColor || glass == NSColor.systemOrangeColor;
    return GWColor(problem ? colors.barHotkey : colors.barText);
}

- (CGFloat)preferredHeight {
    CGFloat extra = _retro ? GWRetroBox.shadowSize : 0;  // the box's shadow is part of the bar
    return (_replaceVisible ? 78 : 44) + extra;
}

// ---------------------------------------------------------------------------
// MARK: Look

- (void)setRetro:(BOOL)retro {
    _retro = retro;
    const gw::bitmap::Scheme &colors = GWServices.shared.bitmapScheme;
    CGFloat pixel = GWChromePixel();
    [_stack removeFromSuperview];
    if (retro) {
        if (_retroBox == nil) {
            _retroBox = [GWRetroBox new];
            _retroBox.translatesAutoresizingMaskIntoConstraints = NO;
            [self addSubview:_retroBox];
            [NSLayoutConstraint activateConstraints:@[
                [_retroBox.topAnchor constraintEqualToAnchor:self.topAnchor],
                [_retroBox.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
                [_retroBox.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
                [_retroBox.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            ]];
        }
        _retroBox.fillColor = GWColor(colors.bar);
        _retroBox.lineColor = GWColor(colors.barText);
        _retroBox.needsDisplay = YES;
        _glass.contentView = nil;
        [_retroBox addSubview:_stack];
        CGFloat shadow = GWRetroBox.shadowSize;
        [NSLayoutConstraint activateConstraints:@[
            [_stack.topAnchor constraintEqualToAnchor:_retroBox.topAnchor],
            [_stack.bottomAnchor constraintEqualToAnchor:_retroBox.bottomAnchor constant:-shadow],
            [_stack.leadingAnchor constraintEqualToAnchor:_retroBox.leadingAnchor],
            [_stack.trailingAnchor constraintEqualToAnchor:_retroBox.trailingAnchor constant:-shadow],
        ]];
    } else {
        _glass.contentView = _stack;
    }
    _glass.hidden = retro;
    _retroBox.hidden = !retro;

    NSColor *ink = retro ? GWColor(colors.barText) : NSColor.labelColor;
    for (NSTextField *field in @[_findField, _replaceField]) {
        field.font = retro ? GWPixelFont(pixel) : [NSFont systemFontOfSize:13];
        field.textColor = ink;
        NSString *placeholder = field.placeholderString ?: field.placeholderAttributedString.string ?: @"";
        if (retro) {
            field.placeholderAttributedString = [[NSAttributedString alloc] initWithString:placeholder
                                                                                attributes:GWPixelPlainAttributes(pixel, GWColor(colors.barDim))];
        } else {
            field.placeholderAttributedString = nil;
            field.placeholderString = placeholder;
        }
    }
    _countLabel.font = retro ? GWPixelFont(pixel) : [NSFont monospacedDigitSystemFontOfSize:11.5 weight:NSFontWeightMedium];
    _countLabel.textColor = [self countColor:NSColor.secondaryLabelColor];
    for (GWOptionButton *button in @[_caseButton, _wordButton, _regexButton]) {
        button.retro = retro;
        button.needsDisplay = YES;
    }
    for (NSButton *button in _iconButtons) {
        button.contentTintColor = retro ? ink : NSColor.secondaryLabelColor;
    }
    for (NSButton *button in _replaceButtons) {
        NSString *title = button.title.length > 0 ? button.title : button.attributedTitle.string;
        title = [title stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"[] "]];
        button.bordered = !retro;
        if (retro) {
            button.attributedTitle = [[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"[%@]", title]
                                                                     attributes:GWPixelPlainAttributes(pixel, ink)];
        } else {
            button.title = title;
            button.bezelStyle = NSBezelStyleGlass;
        }
    }
    if (self.onResize) {
        self.onResize();
    }
}

// ---------------------------------------------------------------------------
// MARK: Showing

- (void)showWithText:(NSString *)text replace:(BOOL)showReplace {
    self.hidden = NO;
    if (text.length > 0 && ![text containsString:@"\n"]) {
        _findField.stringValue = text;
    }
    [self setReplaceVisible:showReplace || _replaceVisible];
    gw::Document *document = _editor.currentDocument;
    _anchor = document ? document->selection.range().start : gw::Position{0, 0};
    [self recomputeAndSelect:YES];
    [self.window makeFirstResponder:_findField];
    [_findField selectText:nil];
}

- (void)setSearchText:(NSString *)text {
    _findField.stringValue = text;
    gw::Document *document = _editor.currentDocument;
    _anchor = document ? document->selection.range().start : gw::Position{0, 0};
    [self recomputeAndSelect:NO];
}

- (void)close {
    self.hidden = YES;
    [_editor setFindMatches:{} current:-1];
    if (self.onClose) {
        self.onClose();
    }
    [self.window makeFirstResponder:_editor];
}

- (void)setReplaceVisible:(BOOL)visible {
    _replaceVisible = visible;
    _replaceRow.hidden = !visible;
    _toggleReplace.image = [[NSImage imageWithSystemSymbolName:visible ? @"chevron.down" : @"chevron.right" accessibilityDescription:nil]
        imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:11 weight:NSFontWeightSemibold]];
    if (self.onResize) {
        self.onResize();
    }
}

// ---------------------------------------------------------------------------
// MARK: Searching

- (gw::search::Query)currentQuery {
    gw::search::Query query;
    query.pattern = _findField.stringValue.UTF8String ?: "";
    query.caseSensitive = _caseButton.state == NSControlStateValueOn;
    query.wholeWord = _wordButton.state == NSControlStateValueOn;
    query.useRegex = _regexButton.state == NSControlStateValueOn;
    return query;
}

- (void)documentChanged {
    if (self.hidden) {
        return;
    }
    gw::Document *document = _editor.currentDocument;
    if (document != nullptr) {
        _anchor = document->buffer().clamp(_anchor);
    }
    [self recomputeAndSelect:NO];
}

/// Finds every match in the open document and marks them. With `select`, jumps to the
/// first one at or after where the search began.
- (void)recomputeAndSelect:(BOOL)select {
    _matches.clear();
    _current = -1;
    gw::Document *document = _editor.currentDocument;
    NSString *pattern = _findField.stringValue;
    _matcher = std::make_unique<gw::search::Matcher>([self currentQuery]);

    if (document == nullptr || pattern.length == 0) {
        _countLabel.stringValue = @"";
        _countLabel.textColor = [self countColor:NSColor.secondaryLabelColor];
        [_editor setFindMatches:{} current:-1];
        return;
    }
    if (!_matcher->valid()) {
        _countLabel.stringValue = @"Invalid";
        _countLabel.textColor = [self countColor:NSColor.systemRedColor];
        _countLabel.toolTip = StringFromUTF8(_matcher->error());
        [_editor setFindMatches:{} current:-1];
        return;
    }
    _countLabel.toolTip = nil;

    const gw::TextBuffer &buffer = document->buffer();
    const size_t limit = 50000;
    for (size_t line = 0; line < buffer.lineCount() && _matches.size() < limit; ++line) {
        _matcher->forEachInLine(buffer.line(line), [&](size_t start, size_t length) {
            if (_matches.size() < limit) {
                _matches.push_back({{line, start}, {line, start + length}});
            }
        });
    }

    // The match to start on: the first at or after the anchor, else wrap to the top.
    if (!_matches.empty()) {
        _current = 0;
        for (size_t index = 0; index < _matches.size(); ++index) {
            if (!(_matches[index].start < _anchor)) {
                _current = static_cast<long>(index);
                break;
            }
        }
    }
    [self updateCount];
    [_editor setFindMatches:_matches current:_current];
    if (select && _current >= 0) {
        [_editor selectRange:_matches[static_cast<size_t>(_current)]];
    }
}

- (void)updateCount {
    if (_matches.empty()) {
        _countLabel.stringValue = @"No results";
        _countLabel.textColor = [self countColor:NSColor.systemOrangeColor];
        return;
    }
    NSString *total = _matches.size() >= 50000 ? @"50000+" : [NSString stringWithFormat:@"%zu", _matches.size()];
    _countLabel.stringValue = [NSString stringWithFormat:@"%ld of %@", _current + 1, total];
    _countLabel.textColor = [self countColor:NSColor.secondaryLabelColor];
}

- (void)step:(int)direction {
    if (self.hidden) {
        // ⌘G with the bar closed: use the last search without showing anything.
        gw::Document *document = _editor.currentDocument;
        _anchor = gw::Position{0, 0};
        if (document != nullptr) {
            gw::Range selected = document->selection.range();
            _anchor = direction > 0 ? selected.end : selected.start;
        }
        [self recomputeAndSelect:NO];
        if (_matches.empty()) {
            NSBeep();
            return;
        }
        // Start from the match after (or before) the caret rather than at it.
        long count = static_cast<long>(_matches.size());
        if (direction > 0) {
            _current = -1;
            for (long index = 0; index < count; ++index) {
                if (!(_matches[static_cast<size_t>(index)].start < _anchor)) {
                    _current = index;
                    break;
                }
            }
            if (_current < 0) {
                _current = 0;
            }
        } else {
            _current = count - 1;
            for (long index = count - 1; index >= 0; --index) {
                if (_matches[static_cast<size_t>(index)].start < _anchor) {
                    _current = index;
                    break;
                }
            }
        }
    } else {
        if (_matches.empty()) {
            NSBeep();
            return;
        }
        long count = static_cast<long>(_matches.size());
        _current = (_current + direction + count) % count;
    }
    [self updateCount];
    [_editor setFindMatches:_matches current:_current];
    [_editor selectRange:_matches[static_cast<size_t>(_current)]];
    _anchor = _matches[static_cast<size_t>(_current)].start;
}

- (void)findNext { [self step:1]; }
- (void)findPrevious { [self step:-1]; }

// ---------------------------------------------------------------------------
// MARK: Replacing

/// The replacement for one match, with $1 groups filled in for regular expressions.
- (std::string)replacementFor:(const gw::Range &)match document:(gw::Document *)document {
    std::string template_ = _replaceField.stringValue.UTF8String ?: "";
    std::string_view line = document->buffer().line(match.start.line);
    return _matcher->expand(line, match.start.column, match.end.column - match.start.column, template_);
}

- (void)replaceClicked:(id)sender {
    gw::Document *document = _editor.currentDocument;
    if (document == nullptr || _matches.empty() || _current < 0 || document->readOnly) {
        NSBeep();
        return;
    }
    gw::Range match = _matches[static_cast<size_t>(_current)];
    std::string replacement = [self replacementFor:match document:document];
    _anchor = match.start;
    [_editor editDocument:^(gw::Document &doc) {
        doc.replace(match, replacement);
    }];
    // Move past what was inserted, then on to the next match.
    _anchor = gw::endOfInsertion(match.start, replacement);
    [self recomputeAndSelect:YES];
}

- (void)replaceAllClicked:(id)sender {
    gw::Document *document = _editor.currentDocument;
    if (document == nullptr || _matches.empty() || document->readOnly) {
        NSBeep();
        return;
    }
    std::vector<gw::Range> matches = _matches;
    std::vector<std::string> replacements;
    replacements.reserve(matches.size());
    for (const gw::Range &match : matches) {
        replacements.push_back([self replacementFor:match document:document]);
    }
    // From the end backwards, so earlier positions stay valid. One undo step.
    [_editor editDocument:^(gw::Document &doc) {
        for (size_t index = matches.size(); index-- > 0;) {
            doc.replace(matches[index], replacements[index]);
        }
    }];
    [self recomputeAndSelect:NO];
}

// ---------------------------------------------------------------------------
// MARK: Controls

- (void)optionChanged:(id)sender { [self recomputeAndSelect:YES]; }
- (void)nextClicked:(id)sender { [self step:1]; }
- (void)previousClicked:(id)sender { [self step:-1]; }
- (void)closeClicked:(id)sender { [self close]; }
- (void)toggleReplaceClicked:(id)sender { [self setReplaceVisible:!_replaceVisible]; }

- (void)controlTextDidChange:(NSNotification *)notification {
    if (notification.object == _findField) {
        // Typing refines the search from where it started.
        [self recomputeAndSelect:YES];
    }
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)selector {
    BOOL shift = (NSApp.currentEvent.modifierFlags & NSEventModifierFlagShift) != 0;
    if (selector == @selector(insertNewline:)) {
        if (control == _findField) {
            [self step:shift ? -1 : 1];
        } else {
            [self replaceClicked:nil];
        }
        return YES;
    }
    if (selector == @selector(cancelOperation:)) {
        [self close];
        return YES;
    }
    return NO;
}

@end
