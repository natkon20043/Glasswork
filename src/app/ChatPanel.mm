#import "ChatPanel.h"

#import "ChatViews.h"
#import "FileIcons.h"
#import "Services.h"

#include "ClaudeProtocol.hpp"
#include "ClaudeSession.hpp"

#include <memory>
#include <mutex>
#include <vector>

@implementation GWChatContext
@end

// ===========================================================================
// Small controls

/// A small rounded button that pops a menu (the mode and model pickers).
@interface GWPill : NSView
@property (nonatomic, copy, nullable) NSMenu * (^menuBuilder)(void);
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *symbol;
@end

@implementation GWPill {
    NSTextField *_label;
    NSImageView *_icon;
    NSImageView *_chevron;
    BOOL _hovered;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) {
        return nil;
    }
    self.wantsLayer = YES;
    self.layer.cornerRadius = 11;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.translatesAutoresizingMaskIntoConstraints = NO;

    _icon = [NSImageView new];
    _icon.translatesAutoresizingMaskIntoConstraints = NO;
    _icon.contentTintColor = NSColor.secondaryLabelColor;
    _label = [NSTextField labelWithString:@""];
    _label.font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium];
    _label.textColor = NSColor.secondaryLabelColor;
    _label.translatesAutoresizingMaskIntoConstraints = NO;
    _chevron = [NSImageView new];
    _chevron.image = [[NSImage imageWithSystemSymbolName:@"chevron.down" accessibilityDescription:nil]
        imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:7.5 weight:NSFontWeightBold]];
    _chevron.contentTintColor = NSColor.tertiaryLabelColor;
    _chevron.translatesAutoresizingMaskIntoConstraints = NO;

    for (NSView *view in @[_icon, _label, _chevron]) {
        [self addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [self.heightAnchor constraintEqualToConstant:22],
        [_icon.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:8],
        [_icon.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_icon.widthAnchor constraintEqualToConstant:12],
        [_label.leadingAnchor constraintEqualToAnchor:_icon.trailingAnchor constant:4],
        [_label.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_chevron.leadingAnchor constraintEqualToAnchor:_label.trailingAnchor constant:4],
        [_chevron.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8],
        [_chevron.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    ]];
    [self updateColors];
    return self;
}

- (void)updateColors {
    [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
        CGFloat alpha = self->_hovered ? 0.14 : 0.07;
        self.layer.backgroundColor = [NSColor.labelColor colorWithAlphaComponent:alpha].CGColor;
    }];
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self updateColors];
}

- (void)setTitle:(NSString *)title {
    _title = [title copy];
    _label.stringValue = title;
}

- (void)setSymbol:(NSString *)symbol {
    _symbol = [symbol copy];
    _icon.image = [[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil]
        imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:10.5 weight:NSFontWeightMedium]];
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *area in self.trackingAreas.copy) {
        [self removeTrackingArea:area];
    }
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:self.bounds
                                                       options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
                                                         owner:self
                                                      userInfo:nil]];
}

- (void)mouseEntered:(NSEvent *)event { _hovered = YES; [self updateColors]; }
- (void)mouseExited:(NSEvent *)event { _hovered = NO; [self updateColors]; }

- (void)mouseDown:(NSEvent *)event {
    if (self.menuBuilder == nil) {
        return;
    }
    NSMenu *menu = self.menuBuilder();
    // Pops upward, because the composer sits at the bottom of the window.
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, -4) inView:self];
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

@end

/// A removable label for something attached to the next message.
@interface GWChip : NSView
@property (nonatomic, copy, nullable) void (^onRemove)(void);
- (instancetype)initWithSymbol:(NSString *)symbol title:(NSString *)title tint:(NSColor *)tint;
@end

@implementation GWChip

- (instancetype)initWithSymbol:(NSString *)symbol title:(NSString *)title tint:(NSColor *)tint {
    self = [super initWithFrame:NSZeroRect];
    if (!self) {
        return nil;
    }
    self.wantsLayer = YES;
    self.layer.cornerRadius = 9;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.translatesAutoresizingMaskIntoConstraints = NO;

    NSImageView *icon = [NSImageView imageViewWithImage:[[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil]
        imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:10 weight:NSFontWeightMedium]]];
    icon.contentTintColor = tint;
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    NSTextField *label = [NSTextField labelWithString:title];
    label.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    label.textColor = NSColor.secondaryLabelColor;
    label.lineBreakMode = NSLineBreakByTruncatingMiddle;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    NSButton *remove = [NSButton buttonWithImage:[[NSImage imageWithSystemSymbolName:@"xmark" accessibilityDescription:@"Remove"]
        imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:8 weight:NSFontWeightBold]]
                                          target:self action:@selector(removeClicked:)];
    remove.bordered = NO;
    remove.contentTintColor = NSColor.tertiaryLabelColor;
    remove.translatesAutoresizingMaskIntoConstraints = NO;

    for (NSView *view in @[icon, label, remove]) {
        [self addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [self.heightAnchor constraintEqualToConstant:20],
        [icon.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:7],
        [icon.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [label.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:4],
        [label.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [label.widthAnchor constraintLessThanOrEqualToConstant:170],
        [remove.leadingAnchor constraintEqualToAnchor:label.trailingAnchor constant:2],
        [remove.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-4],
        [remove.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [remove.widthAnchor constraintEqualToConstant:14],
    ]];
    [self updateColors];
    return self;
}

- (void)updateColors {
    [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
        self.layer.backgroundColor = [NSColor.labelColor colorWithAlphaComponent:0.08].CGColor;
    }];
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self updateColors];
}

- (void)removeClicked:(id)sender {
    if (self.onRemove) {
        self.onRemove();
    }
}

@end

/// The message box: Return sends, Shift-Return starts a new line, and a hint shows while
/// it is empty.
@interface GWComposerTextView : NSTextView
@property (nonatomic, copy) NSString *placeholder;
@property (nonatomic, copy, nullable) void (^onSend)(void);
@property (nonatomic, copy, nullable) void (^onEscape)(void);
@property (nonatomic, copy, nullable) void (^onTextChange)(void);
/// Offers arrow keys, Tab, Return and Escape to the completion list first; return YES if used.
@property (nonatomic, copy, nullable) BOOL (^completionKeyHandler)(NSEvent *event);
@property (nonatomic, copy, nullable) void (^onRecallHistory)(BOOL older);
@end

@implementation GWComposerTextView

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    if (self.string.length == 0 && self.placeholder.length > 0 && !self.hasMarkedText) {
        NSDictionary *attributes = @{NSFontAttributeName: self.font ?: [NSFont systemFontOfSize:13.5],
                                     NSForegroundColorAttributeName: NSColor.tertiaryLabelColor};
        NSPoint origin = NSMakePoint(self.textContainerInset.width + self.textContainer.lineFragmentPadding, self.textContainerInset.height);
        [self.placeholder drawAtPoint:origin withAttributes:attributes];
    }
}

- (void)keyDown:(NSEvent *)event {
    if (!self.hasMarkedText) {
        if (self.completionKeyHandler != nil && self.completionKeyHandler(event)) {
            return;
        }
        // Up and down at the very start or end recall earlier messages.
        BOOL plain = (event.modifierFlags & (NSEventModifierFlagShift | NSEventModifierFlagOption | NSEventModifierFlagCommand |
                                            NSEventModifierFlagControl)) == 0;
        if (plain && event.keyCode == 126 && self.selectedRange.location == 0 && self.onRecallHistory) {
            self.onRecallHistory(YES);
            return;
        }
        if (plain && event.keyCode == 125 && self.selectedRange.location == self.string.length && self.onRecallHistory) {
            self.onRecallHistory(NO);
            return;
        }
        if (event.keyCode == 53 && self.onEscape) {  // Escape
            self.onEscape();
            return;
        }
    }
    [super keyDown:event];
}

- (void)insertNewline:(id)sender {
    NSEventModifierFlags flags = NSApp.currentEvent.modifierFlags;
    BOOL wantsNewLine = (flags & (NSEventModifierFlagShift | NSEventModifierFlagOption)) != 0;
    if (wantsNewLine) {
        [self insertNewlineIgnoringFieldEditor:sender];
        return;
    }
    if (self.onSend) {
        self.onSend();
    }
}

- (void)didChangeText {
    [super didChangeText];
    self.needsDisplay = YES;
    if (self.onTextChange) {
        self.onTextChange();
    }
}

@end

/// The card behind the message box.
@interface GWComposerCard : NSView
@end

@implementation GWComposerCard

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.wantsLayer = YES;
        self.layer.cornerRadius = 16;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.borderWidth = 1;
        self.translatesAutoresizingMaskIntoConstraints = NO;
        [self updateColors];
    }
    return self;
}

- (void)updateColors {
    [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
        self.layer.backgroundColor = [NSColor.labelColor colorWithAlphaComponent:0.06].CGColor;
        self.layer.borderColor = [NSColor.labelColor colorWithAlphaComponent:0.14].CGColor;
    }];
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self updateColors];
}

@end

/// The transcript's document view: flipped, so content starts at the top.
@interface GWFlippedView : NSView
@end

@implementation GWFlippedView
- (BOOL)isFlipped { return YES; }
@end

// ===========================================================================
// Completion list for @files and /commands

@interface GWCompletionItem : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, copy) NSString *symbol;
@property (nonatomic, copy) NSString *replacement;
@end

@implementation GWCompletionItem
@end

@interface GWCompletionPanel : NSPanel
@end

@implementation GWCompletionPanel
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

@interface GWCompletionList : NSObject <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, copy, nullable) void (^onPick)(GWCompletionItem *item);
@property (nonatomic, readonly) BOOL isVisible;
- (void)showItems:(NSArray<GWCompletionItem *> *)items aboveView:(NSView *)view;
- (void)hide;
- (void)moveSelection:(NSInteger)delta;
- (nullable GWCompletionItem *)selectedItem;
@end

@implementation GWCompletionList {
    GWCompletionPanel *_panel;
    NSTableView *_table;
    NSArray<GWCompletionItem *> *_items;
}

- (BOOL)isVisible { return _panel.isVisible; }

- (void)build {
    _panel = [[GWCompletionPanel alloc] initWithContentRect:NSMakeRect(0, 0, 300, 200)
                                                  styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
    _panel.opaque = NO;
    _panel.backgroundColor = NSColor.clearColor;
    _panel.hasShadow = YES;
    _panel.level = NSFloatingWindowLevel;

    _table = [NSTableView new];
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"item"];
    [_table addTableColumn:column];
    _table.headerView = nil;
    _table.rowHeight = 26;
    _table.backgroundColor = NSColor.clearColor;
    _table.style = NSTableViewStylePlain;
    _table.dataSource = self;
    _table.delegate = self;
    _table.target = self;
    _table.action = @selector(clicked:);

    NSScrollView *scroll = [NSScrollView new];
    scroll.documentView = _table;
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = NO;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *content = [NSView new];
    [content addSubview:scroll];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:content.topAnchor constant:4],
        [scroll.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-4],
        [scroll.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:4],
        [scroll.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-4],
    ]];
    NSGlassEffectView *glass = [NSGlassEffectView new];
    glass.cornerRadius = 14;
    glass.contentView = content;
    _panel.contentView = glass;
}

- (void)showItems:(NSArray<GWCompletionItem *> *)items aboveView:(NSView *)view {
    if (items.count == 0) {
        [self hide];
        return;
    }
    if (_panel == nil) {
        [self build];
    }
    _items = items;
    [_table reloadData];
    [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];

    NSRect inWindow = [view convertRect:view.bounds toView:nil];
    NSRect onScreen = [view.window convertRectToScreen:inWindow];
    CGFloat height = MIN(items.count, 7UL) * 26 + 8;
    NSRect frame = NSMakeRect(NSMinX(onScreen), NSMaxY(onScreen) + 6, NSWidth(onScreen), height);
    [_panel setFrame:frame display:YES];
    _panel.appearance = view.effectiveAppearance;
    if (_panel.parentWindow != view.window) {
        [view.window addChildWindow:_panel ordered:NSWindowAbove];
    }
    [_panel orderFront:nil];
}

- (void)hide {
    [_panel.parentWindow removeChildWindow:_panel];
    [_panel orderOut:nil];
}

- (void)moveSelection:(NSInteger)delta {
    if (_items.count == 0) {
        return;
    }
    NSInteger count = static_cast<NSInteger>(_items.count);
    NSInteger row = (_table.selectedRow + delta + count) % count;
    [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:static_cast<NSUInteger>(row)] byExtendingSelection:NO];
    [_table scrollRowToVisible:row];
}

- (GWCompletionItem *)selectedItem {
    NSInteger row = _table.selectedRow;
    if (row < 0 || row >= static_cast<NSInteger>(_items.count)) {
        return nil;
    }
    return _items[static_cast<NSUInteger>(row)];
}

- (void)clicked:(id)sender {
    GWCompletionItem *item = [self selectedItem];
    if (item != nil && self.onPick) {
        self.onPick(item);
    }
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return static_cast<NSInteger>(_items.count); }

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    GWCompletionItem *item = _items[static_cast<NSUInteger>(row)];
    NSTableCellView *cell = [NSTableCellView new];
    NSImageView *icon = [NSImageView imageViewWithImage:[[NSImage imageWithSystemSymbolName:item.symbol accessibilityDescription:nil]
        imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightMedium]]];
    icon.contentTintColor = NSColor.controlAccentColor;
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    NSTextField *title = [NSTextField labelWithString:item.title];
    title.font = [NSFont systemFontOfSize:12.5 weight:NSFontWeightMedium];
    title.lineBreakMode = NSLineBreakByTruncatingMiddle;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    NSTextField *subtitle = [NSTextField labelWithString:item.subtitle ?: @""];
    subtitle.font = [NSFont systemFontOfSize:11];
    subtitle.textColor = NSColor.tertiaryLabelColor;
    subtitle.lineBreakMode = NSLineBreakByTruncatingHead;
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    [subtitle setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    for (NSView *view in @[icon, title, subtitle]) {
        [cell addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:8],
        [icon.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:16],
        [title.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:8],
        [title.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        [subtitle.leadingAnchor constraintEqualToAnchor:title.trailingAnchor constant:8],
        [subtitle.trailingAnchor constraintLessThanOrEqualToAnchor:cell.trailingAnchor constant:-8],
        [subtitle.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
    ]];
    return cell;
}

@end

// ===========================================================================
// The panel

namespace {

/// "claude-sonnet-5-5" → "Sonnet 5.5"; "claude-haiku-4-5-20251001" → "Haiku 4.5".
NSString *friendlyModelName(const std::string &model) {
    if (model.empty()) {
        return @"";
    }
    NSString *text = @(model.c_str());
    if ([text hasPrefix:@"claude-"]) {
        text = [text substringFromIndex:7];
    }
    NSMutableArray<NSString *> *parts = [[text componentsSeparatedByString:@"-"] mutableCopy];
    NSString *family = parts.firstObject.capitalizedString ?: @"";
    [parts removeObjectAtIndex:0];
    NSMutableArray<NSString *> *version = [NSMutableArray array];
    for (NSString *part in parts) {
        BOOL isNumber = part.length > 0 && [part rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location == NSNotFound;
        if (isNumber && part.length <= 2) {
            [version addObject:part];
        }
    }
    if (version.count == 0) {
        return family;
    }
    return [NSString stringWithFormat:@"%@ %@", family, [version componentsJoinedByString:@"."]];
}

struct PendingEvent {
    NSUInteger generation;
    gw::claude::Event event;
};

/// The modes people can pick, with the words we show and the value Claude Code wants.
struct ModeChoice {
    NSString *label;
    NSString *detail;
    NSString *value;
    NSString *symbol;
};

const std::vector<ModeChoice> &modeChoices() {
    static const std::vector<ModeChoice> choices = {
        {@"Ask before changes", @"Claude asks before editing files or running commands.", @"manual", @"hand.raised"},
        {@"Accept edits", @"File edits go through; commands still ask.", @"acceptEdits", @"pencil.line"},
        {@"Plan first", @"Claude only reads and plans. Nothing is changed.", @"plan", @"list.bullet.clipboard"},
        {@"Auto", @"Claude decides what is safe to run on its own.", @"auto", @"wand.and.stars"},
        {@"Full access", @"Nothing asks. Only use in projects you trust.", @"bypassPermissions", @"bolt.trianglebadge.exclamationmark"},
    };
    return choices;
}

struct ModelChoice {
    NSString *label;
    NSString *value;  // what `--model` takes; empty for the account default
};

const std::vector<ModelChoice> &modelChoices() {
    static const std::vector<ModelChoice> choices = {
        {@"Default", @""},
        {@"Sonnet", @"sonnet"},
        {@"Opus", @"opus"},
        {@"Fable", @"fable"},
        {@"Haiku", @"haiku"},
    };
    return choices;
}

}  // namespace

@interface GWChatPanel () <NSTextViewDelegate, NSTableViewDelegate>
@end

@implementation GWChatPanel {
    NSView *_view;

    // Header
    NSTextField *_titleLabel;
    NSTextField *_subtitleLabel;

    // Transcript
    NSScrollView *_scroll;
    GWFlippedView *_document;
    NSStackView *_messageStack;
    NSMutableArray<NSView *> *_messageViews;
    GWChatWorkingView *_workingView;
    NSView *_emptyState;
    BOOL _pinnedToBottom;

    // Composer
    GWComposerCard *_composer;
    NSStackView *_chipRow;
    GWComposerTextView *_input;
    NSScrollView *_inputScroll;
    NSLayoutConstraint *_inputHeight;
    GWPill *_modePill;
    GWPill *_modelPill;
    NSButton *_sendButton;
    GWCompletionList *_completions;
    NSMutableArray<NSString *> *_sentHistory;
    NSInteger _historyPosition;

    // Context chips
    BOOL _includeFile;
    BOOL _includeSelection;
    NSString *_lastContextFile;
    NSMutableArray<NSString *> *_attachedFiles;
    NSMutableArray<NSString *> *_mentionedFiles;

    // Conversation
    std::unique_ptr<gw::claude::Session> _session;
    gw::claude::Transcript _transcript;
    NSUInteger _generation;
    NSString *_resumeSessionId;
    NSString *_mode;
    NSString *_model;
    std::string _reportedModel;
    std::vector<std::string> _slashCommands;
    double _fiveHourUsage;
    BOOL _endedByUser;

    // Events from the session arrive on another thread and are handled in batches.
    std::mutex _queueMutex;
    std::vector<PendingEvent> _queue;
    BOOL _drainScheduled;
}

// ---------------------------------------------------------------------------
// MARK: Setup

- (instancetype)init {
    self = [super init];
    if (self) {
        _messageViews = [NSMutableArray array];
        _sentHistory = [NSMutableArray array];
        _attachedFiles = [NSMutableArray array];
        _mentionedFiles = [NSMutableArray array];
        _historyPosition = -1;
        _pinnedToBottom = YES;
        _includeFile = YES;
        _includeSelection = YES;
        _fiveHourUsage = -1;

        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        _mode = [defaults stringForKey:@"chatMode"] ?: @"manual";
        _model = [defaults stringForKey:@"chatModel"] ?: @"";
        [self buildViews];
        [self updateModeAndModelPills];
        [self showEmptyStateIfNeeded];
        [self updateSendButton];
    }
    return self;
}

- (NSView *)view { return _view; }
- (BOOL)isBusy { return _transcript.isBusy(); }

- (NSButton *)headerButton:(NSString *)symbol tip:(NSString *)tip action:(SEL)action {
    NSImage *image = [[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:tip]
        imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightMedium]];
    NSButton *button = [NSButton buttonWithImage:image target:self action:action];
    button.bordered = NO;
    button.contentTintColor = NSColor.secondaryLabelColor;
    button.toolTip = tip;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button.widthAnchor constraintEqualToConstant:26].active = YES;
    [button.heightAnchor constraintEqualToConstant:26].active = YES;
    return button;
}

- (void)buildViews {
    _view = [NSView new];

    // Header: name, model, and buttons.
    NSImageView *sparkle = [NSImageView imageViewWithImage:[[NSImage imageWithSystemSymbolName:@"sparkles" accessibilityDescription:nil]
        imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:15 weight:NSFontWeightSemibold]]];
    sparkle.contentTintColor = NSColor.controlAccentColor;
    sparkle.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel = [NSTextField labelWithString:@"Claude"];
    _titleLabel.font = [NSFont systemFontOfSize:14 weight:NSFontWeightBold];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _subtitleLabel = [NSTextField labelWithString:@""];
    _subtitleLabel.font = [NSFont systemFontOfSize:11];
    _subtitleLabel.textColor = NSColor.tertiaryLabelColor;
    _subtitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    NSStackView *titles = [NSStackView stackViewWithViews:@[_titleLabel, _subtitleLabel]];
    titles.orientation = NSUserInterfaceLayoutOrientationVertical;
    titles.alignment = NSLayoutAttributeLeading;
    titles.spacing = 0;
    titles.translatesAutoresizingMaskIntoConstraints = NO;

    NSButton *history = [self headerButton:@"clock.arrow.circlepath" tip:@"Earlier chats" action:@selector(historyClicked:)];
    NSButton *newChat = [self headerButton:@"square.and.pencil" tip:@"New chat" action:@selector(newChatClicked:)];
    NSButton *close = [self headerButton:@"xmark" tip:@"Hide chat" action:@selector(closeClicked:)];
    NSStackView *buttons = [NSStackView stackViewWithViews:@[history, newChat, close]];
    buttons.spacing = 0;
    buttons.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *header = [NSView new];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSView *view in @[sparkle, titles, buttons]) {
        [header addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [sparkle.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:18],
        [sparkle.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [titles.leadingAnchor constraintEqualToAnchor:sparkle.trailingAnchor constant:8],
        [titles.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [titles.trailingAnchor constraintLessThanOrEqualToAnchor:buttons.leadingAnchor constant:-8],
        [buttons.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-10],
        [buttons.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
    ]];

    // Transcript.
    _messageStack = [NSStackView new];
    _messageStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    _messageStack.alignment = NSLayoutAttributeLeading;
    _messageStack.spacing = 14;
    _messageStack.edgeInsets = NSEdgeInsetsMake(6, 16, 16, 16);
    _messageStack.translatesAutoresizingMaskIntoConstraints = NO;

    _document = [GWFlippedView new];
    _document.translatesAutoresizingMaskIntoConstraints = NO;
    [_document addSubview:_messageStack];
    [NSLayoutConstraint activateConstraints:@[
        [_messageStack.topAnchor constraintEqualToAnchor:_document.topAnchor],
        [_messageStack.bottomAnchor constraintEqualToAnchor:_document.bottomAnchor],
        [_messageStack.leadingAnchor constraintEqualToAnchor:_document.leadingAnchor],
        [_messageStack.trailingAnchor constraintEqualToAnchor:_document.trailingAnchor],
    ]];

    _scroll = [NSScrollView new];
    _scroll.drawsBackground = NO;
    _scroll.hasVerticalScroller = YES;
    _scroll.autohidesScrollers = YES;
    _scroll.scrollerStyle = NSScrollerStyleOverlay;
    _scroll.borderType = NSNoBorder;
    _scroll.automaticallyAdjustsContentInsets = NO;
    _scroll.documentView = _document;
    _scroll.contentView.postsBoundsChangedNotifications = YES;
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [_document.leadingAnchor constraintEqualToAnchor:_scroll.contentView.leadingAnchor],
        [_document.trailingAnchor constraintEqualToAnchor:_scroll.contentView.trailingAnchor],
        [_document.topAnchor constraintEqualToAnchor:_scroll.contentView.topAnchor],
    ]];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(scrolled:)
                                               name:NSViewBoundsDidChangeNotification object:_scroll.contentView];

    [self buildEmptyState];
    [self buildComposer];

    for (NSView *view in @[header, _scroll, _emptyState, _composer]) {
        [_view addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:_view.topAnchor],
        [header.leadingAnchor constraintEqualToAnchor:_view.leadingAnchor],
        [header.trailingAnchor constraintEqualToAnchor:_view.trailingAnchor],
        [header.heightAnchor constraintEqualToConstant:50],
        [_scroll.topAnchor constraintEqualToAnchor:header.bottomAnchor],
        [_scroll.leadingAnchor constraintEqualToAnchor:_view.leadingAnchor],
        [_scroll.trailingAnchor constraintEqualToAnchor:_view.trailingAnchor],
        [_scroll.bottomAnchor constraintEqualToAnchor:_composer.topAnchor constant:-6],
        [_emptyState.topAnchor constraintEqualToAnchor:header.bottomAnchor],
        [_emptyState.leadingAnchor constraintEqualToAnchor:_view.leadingAnchor],
        [_emptyState.trailingAnchor constraintEqualToAnchor:_view.trailingAnchor],
        [_emptyState.bottomAnchor constraintEqualToAnchor:_composer.topAnchor constant:-6],
        [_composer.leadingAnchor constraintEqualToAnchor:_view.leadingAnchor constant:10],
        [_composer.trailingAnchor constraintEqualToAnchor:_view.trailingAnchor constant:-10],
        [_composer.bottomAnchor constraintEqualToAnchor:_view.bottomAnchor constant:-10],
    ]];
}

- (void)buildEmptyState {
    _emptyState = [NSView new];
    _emptyState.translatesAutoresizingMaskIntoConstraints = NO;

    NSImageView *icon = [NSImageView imageViewWithImage:[[NSImage imageWithSystemSymbolName:@"sparkles" accessibilityDescription:nil]
        imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:34 weight:NSFontWeightSemibold]]];
    icon.contentTintColor = NSColor.controlAccentColor;
    NSTextField *title = [NSTextField labelWithString:@"What are we building?"];
    title.font = [NSFont systemFontOfSize:17 weight:NSFontWeightBold];
    NSTextField *subtitle = [NSTextField wrappingLabelWithString:@"Ask about your code, or tell Claude what to change. It reads and edits the files in your project, and you watch the edits appear."];
    subtitle.font = [NSFont systemFontOfSize:12.5];
    subtitle.textColor = NSColor.secondaryLabelColor;
    subtitle.alignment = NSTextAlignmentCenter;
    subtitle.preferredMaxLayoutWidth = 280;

    NSMutableArray<NSView *> *rows = [NSMutableArray arrayWithObjects:icon, title, subtitle, nil];
    NSArray<NSArray<NSString *> *> *suggestions = @[
        @[@"doc.text.magnifyingglass", @"Explain this file"],
        @[@"ladybug", @"Find bugs in my changes"],
        @[@"checkmark.seal", @"Write tests for this code"],
        @[@"map", @"What does this project do?"],
    ];
    for (NSArray<NSString *> *suggestion in suggestions) {
        NSButton *button = [NSButton buttonWithTitle:suggestion[1] target:self action:@selector(suggestionClicked:)];
        button.image = [[NSImage imageWithSystemSymbolName:suggestion[0] accessibilityDescription:nil]
            imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightMedium]];
        button.imagePosition = NSImageLeading;
        button.bezelStyle = NSBezelStyleGlass;
        button.controlSize = NSControlSizeLarge;
        button.identifier = suggestion[1];
        [rows addObject:button];
    }
    NSStackView *stack = [NSStackView stackViewWithViews:rows];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeCenterX;
    stack.spacing = 8;
    [stack setCustomSpacing:6 afterView:icon];
    [stack setCustomSpacing:16 afterView:subtitle];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [_emptyState addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:_emptyState.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:_emptyState.centerYAnchor constant:-20],
        [stack.widthAnchor constraintLessThanOrEqualToAnchor:_emptyState.widthAnchor constant:-30],
    ]];
}

- (void)buildComposer {
    _composer = [GWComposerCard new];

    _chipRow = [NSStackView new];
    _chipRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    _chipRow.spacing = 6;
    _chipRow.alignment = NSLayoutAttributeCenterY;
    _chipRow.translatesAutoresizingMaskIntoConstraints = NO;
    _chipRow.hidden = YES;

    _input = [[GWComposerTextView alloc] initWithFrame:NSMakeRect(0, 0, 300, 24)];
    _input.font = [NSFont systemFontOfSize:13.5];
    _input.drawsBackground = NO;
    _input.textColor = NSColor.labelColor;
    _input.insertionPointColor = NSColor.controlAccentColor;
    _input.textContainerInset = NSMakeSize(2, 3);
    _input.allowsUndo = YES;
    _input.richText = NO;
    _input.automaticQuoteSubstitutionEnabled = NO;
    _input.automaticDashSubstitutionEnabled = NO;
    _input.autoresizingMask = NSViewWidthSizable;
    _input.horizontallyResizable = NO;
    _input.verticallyResizable = YES;
    _input.textContainer.widthTracksTextView = YES;
    _input.placeholder = @"Ask Claude…   @ to add a file";
    _input.delegate = self;
    __weak GWChatPanel *weakSelf = self;
    _input.onSend = ^{ [weakSelf sendClicked:nil]; };
    _input.onEscape = ^{ [weakSelf escapePressed]; };
    _input.onTextChange = ^{ [weakSelf composerTextChanged]; };
    _input.completionKeyHandler = ^BOOL(NSEvent *event) { return [weakSelf handleCompletionKey:event]; };
    _input.onRecallHistory = ^(BOOL older) { [weakSelf recallHistoryOlder:older]; };

    _inputScroll = [NSScrollView new];
    _inputScroll.documentView = _input;
    _inputScroll.drawsBackground = NO;
    _inputScroll.hasVerticalScroller = YES;
    _inputScroll.autohidesScrollers = YES;
    _inputScroll.scrollerStyle = NSScrollerStyleOverlay;
    _inputScroll.borderType = NSNoBorder;
    _inputScroll.translatesAutoresizingMaskIntoConstraints = NO;
    _inputHeight = [_inputScroll.heightAnchor constraintEqualToConstant:26];

    NSButton *plus = [NSButton buttonWithImage:[[NSImage imageWithSystemSymbolName:@"plus" accessibilityDescription:@"Add"]
        imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightSemibold]]
                                        target:self action:@selector(plusClicked:)];
    plus.bordered = NO;
    plus.contentTintColor = NSColor.secondaryLabelColor;
    plus.toolTip = @"Add context";
    plus.translatesAutoresizingMaskIntoConstraints = NO;
    [plus.widthAnchor constraintEqualToConstant:24].active = YES;

    _modePill = [GWPill new];
    _modePill.menuBuilder = ^NSMenu *{ return [weakSelf buildModeMenu]; };
    _modelPill = [GWPill new];
    _modelPill.menuBuilder = ^NSMenu *{ return [weakSelf buildModelMenu]; };
    _modelPill.symbol = @"cpu";

    _sendButton = [NSButton buttonWithTitle:@"" target:self action:@selector(sendClicked:)];
    _sendButton.bezelStyle = NSBezelStyleGlass;
    _sendButton.bezelColor = NSColor.controlAccentColor;
    _sendButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_sendButton.widthAnchor constraintEqualToConstant:34].active = YES;

    NSView *spacer = [NSView new];
    [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *bottom = [NSStackView stackViewWithViews:@[plus, _modePill, _modelPill, spacer, _sendButton]];
    bottom.spacing = 6;
    bottom.alignment = NSLayoutAttributeCenterY;
    bottom.translatesAutoresizingMaskIntoConstraints = NO;

    for (NSView *view in @[_chipRow, _inputScroll, bottom]) {
        [_composer addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [_chipRow.topAnchor constraintEqualToAnchor:_composer.topAnchor constant:10],
        [_chipRow.leadingAnchor constraintEqualToAnchor:_composer.leadingAnchor constant:12],
        [_chipRow.trailingAnchor constraintLessThanOrEqualToAnchor:_composer.trailingAnchor constant:-12],
        [_inputScroll.leadingAnchor constraintEqualToAnchor:_composer.leadingAnchor constant:12],
        [_inputScroll.trailingAnchor constraintEqualToAnchor:_composer.trailingAnchor constant:-12],
        _inputHeight,
        [bottom.topAnchor constraintEqualToAnchor:_inputScroll.bottomAnchor constant:4],
        [bottom.leadingAnchor constraintEqualToAnchor:_composer.leadingAnchor constant:8],
        [bottom.trailingAnchor constraintEqualToAnchor:_composer.trailingAnchor constant:-8],
        [bottom.bottomAnchor constraintEqualToAnchor:_composer.bottomAnchor constant:-8],
    ]];
    // The message box sits below the chips, or at the top when there are none.
    NSLayoutConstraint *belowChips = [_inputScroll.topAnchor constraintEqualToAnchor:_chipRow.bottomAnchor constant:6];
    NSLayoutConstraint *atTop = [_inputScroll.topAnchor constraintEqualToAnchor:_composer.topAnchor constant:10];
    belowChips.priority = NSLayoutPriorityDefaultHigh;
    atTop.priority = NSLayoutPriorityDefaultLow;
    [NSLayoutConstraint activateConstraints:@[belowChips, atTop]];
    [_chipRow setHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationVertical];

    _completions = [GWCompletionList new];
    _completions.onPick = ^(GWCompletionItem *item) { [weakSelf acceptCompletion:item]; };
}

// ---------------------------------------------------------------------------
// MARK: Pills

- (NSString *)labelForMode:(NSString *)value {
    for (const ModeChoice &choice : modeChoices()) {
        if ([choice.value isEqualToString:value]) {
            return choice.label;
        }
    }
    return value;
}

- (void)updateModeAndModelPills {
    for (const ModeChoice &choice : modeChoices()) {
        if ([choice.value isEqualToString:_mode]) {
            _modePill.title = choice.label;
            _modePill.symbol = choice.symbol;
        }
    }
    NSString *modelTitle = @"Default";
    for (const ModelChoice &choice : modelChoices()) {
        if ([choice.value isEqualToString:_model]) {
            modelTitle = choice.label;
        }
    }
    _modelPill.title = modelTitle;
}

- (NSMenu *)buildModeMenu {
    NSMenu *menu = [NSMenu new];
    for (const ModeChoice &choice : modeChoices()) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:choice.label action:@selector(modeChosen:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = choice.value;
        item.toolTip = choice.detail;
        item.state = [choice.value isEqualToString:_mode] ? NSControlStateValueOn : NSControlStateValueOff;
        item.image = [[NSImage imageWithSystemSymbolName:choice.symbol accessibilityDescription:nil]
            imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightMedium]];
        [menu addItem:item];
    }
    return menu;
}

- (NSMenu *)buildModelMenu {
    NSMenu *menu = [NSMenu new];
    for (const ModelChoice &choice : modelChoices()) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:choice.label action:@selector(modelChosen:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = choice.value;
        item.state = [choice.value isEqualToString:_model] ? NSControlStateValueOn : NSControlStateValueOff;
        [menu addItem:item];
    }
    return menu;
}

- (void)modeChosen:(NSMenuItem *)item {
    [self setMode:item.representedObject];
}

- (void)setMode:(NSString *)mode {
    if ([mode isEqualToString:@"bypassPermissions"] && ![_mode isEqualToString:mode]) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Give Claude full access?";
        alert.informativeText = @"In this mode Claude edits files and runs commands without asking. Only use it in projects you trust and keep under version control.";
        alert.alertStyle = NSAlertStyleWarning;
        [alert addButtonWithTitle:@"Use Full Access"];
        [alert addButtonWithTitle:@"Cancel"];
        if ([alert runModal] != NSAlertFirstButtonReturn) {
            return;
        }
    }
    _mode = [mode copy];
    [NSUserDefaults.standardUserDefaults setObject:_mode forKey:@"chatMode"];
    [self updateModeAndModelPills];
    if (_session && _session->isRunning()) {
        _session->setPermissionMode(mode.UTF8String);
    }
}

- (void)modelChosen:(NSMenuItem *)item {
    _model = [item.representedObject copy];
    [NSUserDefaults.standardUserDefaults setObject:_model forKey:@"chatModel"];
    [self updateModeAndModelPills];
    if (_session && _session->isRunning() && _model.length > 0) {
        _session->setModel(_model.UTF8String);
    }
}

// ---------------------------------------------------------------------------
// MARK: Public

- (void)setProjectFolder:(NSString *)projectFolder {
    if ((projectFolder == nil && _projectFolder == nil) || [projectFolder isEqualToString:_projectFolder]) {
        return;
    }
    _projectFolder = [projectFolder copy];
    [self newChat];
}

- (void)focusComposer {
    [_view.window makeFirstResponder:_input];
    [self contextDidChange];
}

- (void)prefillComposer:(NSString *)text {
    _input.string = text;
    [self composerTextChanged];
    [self focusComposer];
    _input.selectedRange = NSMakeRange(text.length, 0);
}

- (void)sendPrompt:(NSString *)prompt includeSelection:(BOOL)includeSelection {
    _includeSelection = includeSelection;
    [self submitText:prompt];
}

- (void)interrupt {
    if (_session && _session->isRunning() && _transcript.isBusy()) {
        _session->interrupt();
    }
}

- (void)contextDidChange {
    GWChatContext *context = self.contextProvider ? self.contextProvider() : nil;
    NSString *file = context.filePath;
    if (![file isEqualToString:_lastContextFile] && !(file == nil && _lastContextFile == nil)) {
        // A different file: offer it again.
        _lastContextFile = [file copy];
        _includeFile = YES;
    }
    if (context.selectedText.length == 0) {
        _includeSelection = YES;  // ready for the next selection
    }
    [self rebuildChips:context];
}

// ---------------------------------------------------------------------------
// MARK: Chips

- (void)rebuildChips:(GWChatContext *)context {
    for (NSView *view in _chipRow.arrangedSubviews.copy) {
        [_chipRow removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    __weak GWChatPanel *weakSelf = self;

    if (context.filePath.length > 0 && _includeFile) {
        NSString *name = context.filePath.lastPathComponent;
        GWChip *chip = [[GWChip alloc] initWithSymbol:GWSymbolForFile(name) title:name tint:GWColorForFile(name)];
        chip.onRemove = ^{
            GWChatPanel *strongSelf = weakSelf;
            strongSelf->_includeFile = NO;
            [strongSelf contextDidChange];
        };
        [_chipRow addArrangedSubview:chip];
    }
    if (context.selectedText.length > 0 && _includeSelection) {
        NSString *title = context.startLine == context.endLine
            ? [NSString stringWithFormat:@"Line %ld", static_cast<long>(context.startLine)]
            : [NSString stringWithFormat:@"Lines %ld–%ld", static_cast<long>(context.startLine), static_cast<long>(context.endLine)];
        GWChip *chip = [[GWChip alloc] initWithSymbol:@"text.cursor" title:title tint:NSColor.controlAccentColor];
        chip.onRemove = ^{
            GWChatPanel *strongSelf = weakSelf;
            strongSelf->_includeSelection = NO;
            [strongSelf contextDidChange];
        };
        [_chipRow addArrangedSubview:chip];
    }
    for (NSString *path in _attachedFiles.copy) {
        GWChip *chip = [[GWChip alloc] initWithSymbol:GWSymbolForFile(path.lastPathComponent) title:path.lastPathComponent
                                                 tint:GWColorForFile(path.lastPathComponent)];
        chip.onRemove = ^{
            GWChatPanel *strongSelf = weakSelf;
            [strongSelf->_attachedFiles removeObject:path];
            [strongSelf contextDidChange];
        };
        [_chipRow addArrangedSubview:chip];
    }
    _chipRow.hidden = _chipRow.arrangedSubviews.count == 0;
}

- (void)plusClicked:(NSButton *)sender {
    NSMenu *menu = [NSMenu new];
    NSMenuItem *file = [menu addItemWithTitle:@"Attach a File…" action:@selector(attachFileClicked:) keyEquivalent:@""];
    file.target = self;
    NSMenuItem *mention = [menu addItemWithTitle:@"Mention a File  (@)" action:@selector(mentionClicked:) keyEquivalent:@""];
    mention.target = self;
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, -4) inView:sender];
}

- (void)attachFileClicked:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowsMultipleSelection = YES;
    panel.canChooseDirectories = NO;
    if (_projectFolder != nil) {
        panel.directoryURL = [NSURL fileURLWithPath:_projectFolder];
    }
    [panel beginSheetModalForWindow:_view.window completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK) {
            return;
        }
        for (NSURL *url in panel.URLs) {
            if (![self->_attachedFiles containsObject:url.path]) {
                [self->_attachedFiles addObject:url.path];
            }
        }
        [self contextDidChange];
    }];
}

- (void)mentionClicked:(id)sender {
    [self focusComposer];
    [_input insertText:@"@" replacementRange:_input.selectedRange];
}

// ---------------------------------------------------------------------------
// MARK: Composer behaviour

- (void)composerTextChanged {
    [self resizeComposer];
    [self updateCompletions];
    [self updateSendButton];
}

- (void)resizeComposer {
    [_input.layoutManager ensureLayoutForTextContainer:_input.textContainer];
    NSRect used = [_input.layoutManager usedRectForTextContainer:_input.textContainer];
    CGFloat height = ceil(used.size.height) + _input.textContainerInset.height * 2;
    _inputHeight.constant = MIN(MAX(height, 26), 170);
}

- (void)updateSendButton {
    BOOL busy = _transcript.isBusy();
    NSString *symbol = busy ? @"stop.fill" : @"arrow.up";
    _sendButton.image = [[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:busy ? @"Stop" : @"Send"]
        imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightBold]];
    _sendButton.toolTip = busy ? @"Stop" : @"Send  (Return)";
    BOOL hasText = [_input.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length > 0;
    _sendButton.enabled = busy || hasText;
}

- (void)escapePressed {
    if (_completions.isVisible) {
        [_completions hide];
        return;
    }
    if (_transcript.isBusy()) {
        [self interrupt];
    }
}

- (void)sendClicked:(id)sender {
    if (_transcript.isBusy()) {
        [self interrupt];
        return;
    }
    NSString *text = [_input.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (text.length == 0) {
        return;
    }
    [self submitText:text];
}

- (void)recallHistoryOlder:(BOOL)older {
    if (_sentHistory.count == 0) {
        return;
    }
    if (older) {
        if (_historyPosition < 0) {
            _historyPosition = static_cast<NSInteger>(_sentHistory.count);
        }
        _historyPosition = MAX(0, _historyPosition - 1);
    } else {
        if (_historyPosition < 0) {
            return;
        }
        ++_historyPosition;
    }
    if (_historyPosition >= static_cast<NSInteger>(_sentHistory.count)) {
        _historyPosition = -1;
        _input.string = @"";
    } else {
        _input.string = _sentHistory[static_cast<NSUInteger>(_historyPosition)];
    }
    [self composerTextChanged];
    _input.selectedRange = NSMakeRange(_input.string.length, 0);
}

// ---------------------------------------------------------------------------
// MARK: @ mentions and / commands

- (void)updateCompletions {
    NSString *text = _input.string;
    NSUInteger caret = _input.selectedRange.location;
    NSString *beforeCaret = [text substringToIndex:MIN(caret, text.length)];

    // "@partial/path" right before the caret.
    NSRange at = [beforeCaret rangeOfString:@"@" options:NSBackwardsSearch];
    if (at.location != NSNotFound) {
        NSString *query = [beforeCaret substringFromIndex:at.location + 1];
        BOOL startsToken = at.location == 0 || [[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:[beforeCaret characterAtIndex:at.location - 1]];
        BOOL hasBreak = [query rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound;
        if (startsToken && !hasBreak && self.fileSuggestions != nil) {
            NSArray<NSString *> *paths = self.fileSuggestions(query);
            NSMutableArray<GWCompletionItem *> *items = [NSMutableArray array];
            for (NSString *path in paths) {
                GWCompletionItem *item = [GWCompletionItem new];
                item.title = path.lastPathComponent;
                item.subtitle = path.stringByDeletingLastPathComponent;
                item.symbol = GWSymbolForFile(path.lastPathComponent);
                item.replacement = [NSString stringWithFormat:@"@%@ ", path];
                [items addObject:item];
            }
            [_completions showItems:items aboveView:_composer];
            return;
        }
    }

    // "/command" at the start of the message.
    if ([text hasPrefix:@"/"] && [text rangeOfString:@" "].location == NSNotFound && [text rangeOfString:@"\n"].location == NSNotFound) {
        NSString *prefix = [text substringFromIndex:1].lowercaseString;
        NSMutableArray<GWCompletionItem *> *items = [NSMutableArray array];
        NSMutableArray<NSString *> *commands = [NSMutableArray arrayWithObjects:@"new", @"clear", nil];
        for (const std::string &command : _slashCommands) {
            [commands addObject:@(command.c_str())];
        }
        for (NSString *command in commands) {
            if (prefix.length > 0 && ![command.lowercaseString hasPrefix:prefix]) {
                continue;
            }
            GWCompletionItem *item = [GWCompletionItem new];
            item.title = [@"/" stringByAppendingString:command];
            BOOL local = [command isEqualToString:@"new"] || [command isEqualToString:@"clear"];
            item.subtitle = local ? @"Start a new chat" : @"";
            item.symbol = @"slash.circle";
            item.replacement = [NSString stringWithFormat:@"/%@ ", command];
            [items addObject:item];
            if (items.count >= 8) {
                break;
            }
        }
        [_completions showItems:items aboveView:_composer];
        return;
    }
    [_completions hide];
}

- (BOOL)handleCompletionKey:(NSEvent *)event {
    if (!_completions.isVisible) {
        return NO;
    }
    switch (event.keyCode) {
        case 125:  // down
            [_completions moveSelection:1];
            return YES;
        case 126:  // up
            [_completions moveSelection:-1];
            return YES;
        case 48:   // tab
        case 36:   // return
        case 76: { // enter
            GWCompletionItem *item = [_completions selectedItem];
            if (item != nil) {
                [self acceptCompletion:item];
                return YES;
            }
            return NO;
        }
        case 53:   // escape
            [_completions hide];
            return YES;
        default:
            return NO;
    }
}

- (void)acceptCompletion:(GWCompletionItem *)item {
    NSString *text = _input.string;
    NSUInteger caret = _input.selectedRange.location;
    NSString *beforeCaret = [text substringToIndex:MIN(caret, text.length)];
    NSRange replace;
    if ([item.replacement hasPrefix:@"@"]) {
        NSRange at = [beforeCaret rangeOfString:@"@" options:NSBackwardsSearch];
        replace = NSMakeRange(at.location, caret - at.location);
        NSString *path = [item.replacement substringWithRange:NSMakeRange(1, item.replacement.length - 2)];
        if (![_mentionedFiles containsObject:path]) {
            [_mentionedFiles addObject:path];
        }
    } else {
        replace = NSMakeRange(0, text.length);
    }
    [_input insertText:item.replacement replacementRange:replace];
    [_completions hide];
    [self composerTextChanged];
}

// ---------------------------------------------------------------------------
// MARK: Sending

/// What the editor shows, put in front of the question so Claude knows what "this" is.
- (NSString *)promptWithContextForText:(NSString *)text {
    GWChatContext *context = self.contextProvider ? self.contextProvider() : nil;
    NSMutableString *lines = [NSMutableString string];

    if (_includeFile && context.filePath.length > 0) {
        [lines appendFormat:@"The file open in the editor: %@", context.filePath];
        if (context.languageName.length > 0) {
            [lines appendFormat:@" (%@)", context.languageName];
        }
        [lines appendString:@"\n"];
    }
    if (_includeSelection && context.selectedText.length > 0 && context.startLine > 0) {
        NSString *selection = context.selectedText;
        if (selection.length > 20000) {
            selection = [[selection substringToIndex:20000] stringByAppendingString:@"\n… (cut off)"];
        }
        [lines appendFormat:@"The user has this selected (lines %ld–%ld of that file):\n```\n%@\n```\n",
                            static_cast<long>(context.startLine), static_cast<long>(context.endLine), selection];
    }
    NSMutableOrderedSet<NSString *> *files = [NSMutableOrderedSet orderedSetWithArray:_attachedFiles];
    for (NSString *mention in _mentionedFiles) {
        if ([text containsString:[@"@" stringByAppendingString:mention]]) {
            NSString *absolute = [mention hasPrefix:@"/"] ? mention : [(_projectFolder ?: @"") stringByAppendingPathComponent:mention];
            [files addObject:absolute];
        }
    }
    if (files.count > 0) {
        [lines appendFormat:@"Files the user pointed at (read them as needed): %@\n", [files.array componentsJoinedByString:@", "]];
    }
    if (lines.length == 0) {
        return text;
    }
    return [NSString stringWithFormat:@"<ide_context>\n%@</ide_context>\n\n%@", lines, text];
}

- (BOOL)ensureSession {
    if (_session && _session->isRunning()) {
        return YES;
    }
    if (!gw::claude::Session::isInstalled()) {
        [self appendNotice:@"Claude Code isn't installed. Install it from claude.com/claude-code, then sign in by running “claude” once in a terminal." isError:YES];
        return NO;
    }
    _session = std::make_unique<gw::claude::Session>();
    NSUInteger generation = _generation;
    __weak GWChatPanel *weakSelf = self;
    _session->onEvent = [weakSelf, generation](const gw::claude::Event &event) {
        [weakSelf enqueueEvent:event generation:generation];
    };
    _session->onExit = [weakSelf, generation](int code, const std::string &errorText) {
        NSString *text = @(errorText.c_str()) ?: @"";
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf sessionEndedWithCode:code errorText:text generation:generation];
        });
    };

    gw::claude::SessionOptions options;
    options.workingDirectory = (_projectFolder ?: NSHomeDirectory()).UTF8String;
    options.permissionMode = _mode.UTF8String;
    options.model = _model.UTF8String;
    if (_resumeSessionId.length > 0) {
        options.resumeSessionId = _resumeSessionId.UTF8String;
    }
    options.appendSystemPrompt =
        "You are running inside the Glasswork IDE, a native macOS code editor. The user reads your replies in a side "
        "panel next to their code, and any file you edit reloads in the editor immediately. Keep replies concise. When "
        "you mention a file, write its path relative to the project in `backticks`, optionally with a line number "
        "(`src/main.cpp:42`); those become clickable. The user cannot answer structured multiple-choice questions here, "
        "so ask in plain text when you need a decision.";
    std::string error;
    if (!_session->start(options, &error)) {
        _session.reset();
        [self appendNotice:[NSString stringWithFormat:@"Couldn't start Claude: %s", error.c_str()] isError:YES];
        return NO;
    }
    _endedByUser = NO;
    return YES;
}

- (void)submitText:(NSString *)text {
    if ([text isEqualToString:@"/new"] || [text isEqualToString:@"/clear"]) {
        _input.string = @"";
        [self composerTextChanged];
        [self newChat];
        return;
    }
    if (![self ensureSession]) {
        return;
    }
    if (self.onSaveAll) {
        self.onSaveAll();
    }
    NSString *prompt = [self promptWithContextForText:text];

    [_sentHistory addObject:text];
    _historyPosition = -1;
    _input.string = @"";
    [_mentionedFiles removeAllObjects];
    [_attachedFiles removeAllObjects];
    [_completions hide];
    [self composerTextChanged];

    gw::claude::TranscriptChange change = _transcript.addUserMessage(text.UTF8String);
    _transcript.setBusy(true);
    _pinnedToBottom = YES;
    [self applyChange:change];
    [self refreshWorkingIndicator];
    [self updateSendButton];
    [self contextDidChange];

    if (!_session->sendUserMessage(prompt.UTF8String)) {
        _transcript.setBusy(false);
        [self appendNotice:@"Couldn't send the message. Try again." isError:YES];
        [self refreshWorkingIndicator];
        [self updateSendButton];
    }
}

- (void)suggestionClicked:(NSButton *)sender {
    NSString *title = sender.identifier;
    NSString *prompt = title;
    if ([title isEqualToString:@"Explain this file"]) {
        prompt = @"Explain what this file does and how it is put together.";
    } else if ([title isEqualToString:@"Find bugs in my changes"]) {
        prompt = @"Look at my uncommitted changes (use git diff) and point out bugs, risky spots, or anything I missed.";
    } else if ([title isEqualToString:@"Write tests for this code"]) {
        prompt = @"Write tests for the code in the open file. Follow how tests are done in this project.";
    } else if ([title isEqualToString:@"What does this project do?"]) {
        prompt = @"Give me a short tour of this project: what it does and how the code is organised.";
    }
    [self submitText:prompt];
}

// ---------------------------------------------------------------------------
// MARK: Events from Claude

/// Called on the session's thread.
- (void)enqueueEvent:(const gw::claude::Event &)event generation:(NSUInteger)generation {
    bool schedule = false;
    {
        std::lock_guard<std::mutex> lock(_queueMutex);
        _queue.push_back({generation, event});
        if (!_drainScheduled) {
            _drainScheduled = true;
            schedule = true;
        }
    }
    if (schedule) {
        // A short delay lets a burst of streamed words arrive as one update.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(0.025 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self drainEvents];
        });
    }
}

- (void)drainEvents {
    std::vector<PendingEvent> events;
    {
        std::lock_guard<std::mutex> lock(_queueMutex);
        events.swap(_queue);
        _drainScheduled = false;
    }
    NSMutableIndexSet *touched = [NSMutableIndexSet indexSet];
    BOOL turnFinished = NO;
    BOOL needsAttention = NO;

    for (const PendingEvent &pending : events) {
        if (pending.generation != _generation) {
            continue;
        }
        const gw::claude::Event &event = pending.event;
        switch (event.kind) {
            case gw::claude::EventKind::SessionInit:
                _reportedModel = event.model;
                _slashCommands = event.slashCommands;
                if (!event.sessionId.empty()) {
                    _resumeSessionId = @(event.sessionId.c_str());
                }
                break;
            case gw::claude::EventKind::RateLimit:
                _fiveHourUsage = event.fiveHourUtilization;
                break;
            case gw::claude::EventKind::PermissionRequest:
                if (event.toolName == "AskUserQuestion") {
                    // Structured questions can't be answered here; Claude is told to ask in words.
                    if (_session) {
                        _session->answerPermission(event.requestId, false, event.toolInput,
                                                   "The user can't answer multiple-choice prompts in this editor. Ask your question in plain text instead.");
                    }
                    continue;
                }
                needsAttention = YES;
                break;
            case gw::claude::EventKind::TurnResult:
                turnFinished = YES;
                break;
            default:
                break;
        }
        gw::claude::TranscriptChange change = _transcript.apply(event);
        if (change.changed) {
            [touched addIndex:change.messageIndex];
        }
    }

    // Views for new messages first, then refresh everything that changed.
    [self syncMessageViews];
    [touched enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) {
        [self refreshMessageAtIndex:index];
    }];
    [self refreshWorkingIndicator];
    [self updateSendButton];
    [self updateHeader];
    [self showEmptyStateIfNeeded];
    [self scrollToBottomIfPinned];

    if (needsAttention && !NSApp.isActive) {
        [NSApp requestUserAttention:NSInformationalRequest];
    }
    if (turnFinished) {
        if (self.onTurnFinished) {
            self.onTurnFinished();
        }
        if (!NSApp.isActive) {
            [NSApp requestUserAttention:NSInformationalRequest];
        }
    }
}

- (void)sessionEndedWithCode:(int)code errorText:(NSString *)errorText generation:(NSUInteger)generation {
    if (generation != _generation) {
        return;
    }
    // Get anything still queued first.
    [self drainEvents];
    BOOL wasBusy = _transcript.isBusy();
    _transcript.setBusy(false);
    _session.reset();
    if (!_endedByUser && (code != 0 || wasBusy)) {
        NSString *detail = [errorText stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (detail.length > 400) {
            detail = [detail substringToIndex:400];
        }
        NSString *message = detail.length > 0 ? [NSString stringWithFormat:@"Claude stopped: %@", detail] : @"Claude stopped. Send another message to continue.";
        [self appendNotice:message isError:code != 0];
    }
    [self refreshWorkingIndicator];
    [self updateSendButton];
}

- (void)stopSession {
    ++_generation;  // ignore anything the old session still says
    _endedByUser = YES;
    if (_session) {
        _session->onEvent = nullptr;
        _session->onExit = nullptr;
        _session->stop();
        _session.reset();
    }
    {
        std::lock_guard<std::mutex> lock(_queueMutex);
        _queue.clear();
    }
}

// ---------------------------------------------------------------------------
// MARK: Permission answers

- (void)permissionChosen:(GWPermissionChoice)choice forRequest:(NSString *)requestId message:(NSString *)message {
    if (!_session) {
        return;
    }
    gw::claude::Json input = gw::claude::Json::object();
    for (const gw::claude::ToolCall *tool : _transcript.pendingPermissions()) {
        if (tool->permissionRequestId == requestId.UTF8String) {
            input = tool->input;
            break;
        }
    }
    BOOL allow = choice != GWPermissionChoiceDeny;
    _session->answerPermission(requestId.UTF8String, allow, input, message.UTF8String ?: "");
    _transcript.resolvePermission(requestId.UTF8String, allow);
    if (choice == GWPermissionChoiceAllowAllEdits) {
        [self setMode:@"acceptEdits"];
    }
    [self refreshAllAssistantViews];
}

// ---------------------------------------------------------------------------
// MARK: Views for messages

- (NSView *)makeViewForMessageAtIndex:(size_t)index {
    const gw::claude::Message &message = _transcript.messages()[index];
    __weak GWChatPanel *weakSelf = self;
    switch (message.role) {
        case gw::claude::Message::Role::User: {
            GWChatUserView *view = [GWChatUserView new];
            return view;
        }
        case gw::claude::Message::Role::Assistant: {
            GWChatAssistantView *view = [GWChatAssistantView new];
            view.projectRoot = _projectFolder;
            view.onOpenPath = ^(NSString *path, NSInteger line) {
                if (weakSelf.onOpenPath) {
                    weakSelf.onOpenPath(path, line);
                }
            };
            view.onInsertCode = ^(NSString *code) {
                if (weakSelf.onInsertCode) {
                    weakSelf.onInsertCode(code);
                }
            };
            view.onPermission = ^(NSString *requestId, GWPermissionChoice choice, NSString *denyMessage) {
                [weakSelf permissionChosen:choice forRequest:requestId message:denyMessage];
            };
            return view;
        }
        case gw::claude::Message::Role::Notice:
            return [GWChatNoticeView new];
    }
    return nil;
}

/// Makes sure every message has a view, in order.
- (void)syncMessageViews {
    while (_messageViews.count < _transcript.size()) {
        size_t index = _messageViews.count;
        NSView *view = [self makeViewForMessageAtIndex:index];
        // Before the working indicator, which stays last.
        if (_workingView.superview != nil) {
            [_messageStack removeArrangedSubview:_workingView];
            [_workingView removeFromSuperview];
        }
        [_messageStack addArrangedSubview:view];
        [view.widthAnchor constraintEqualToAnchor:_messageStack.widthAnchor constant:-32].active = YES;
        [_messageViews addObject:view];
        [self refreshMessageAtIndex:index];
    }
}

- (void)refreshMessageAtIndex:(NSUInteger)index {
    if (index >= _messageViews.count || index >= _transcript.size()) {
        return;
    }
    const gw::claude::Message &message = _transcript.messages()[index];
    NSView *view = _messageViews[index];
    BOOL running = _transcript.isBusy();
    switch (message.role) {
        case gw::claude::Message::Role::User:
            [(GWChatUserView *)view setText:message.blocks.empty() ? @"" : (@(message.blocks[0].text.c_str()) ?: @"")];
            break;
        case gw::claude::Message::Role::Assistant:
            ((GWChatAssistantView *)view).projectRoot = _projectFolder;
            [(GWChatAssistantView *)view updateWithMessage:message turnIsRunning:running];
            break;
        case gw::claude::Message::Role::Notice:
            [(GWChatNoticeView *)view setText:message.blocks.empty() ? @"" : (@(message.blocks[0].text.c_str()) ?: @"")
                                      isError:message.isError];
            break;
    }
}

- (void)refreshAllAssistantViews {
    for (NSUInteger index = 0; index < _messageViews.count; ++index) {
        [self refreshMessageAtIndex:index];
    }
}

- (void)applyChange:(gw::claude::TranscriptChange)change {
    [self syncMessageViews];
    if (change.changed) {
        [self refreshMessageAtIndex:change.messageIndex];
    }
    [self showEmptyStateIfNeeded];
    [self scrollToBottomIfPinned];
}

- (void)appendNotice:(NSString *)text isError:(BOOL)isError {
    gw::claude::TranscriptChange change = _transcript.addNotice(text.UTF8String, isError);
    [self applyChange:change];
}

- (void)refreshWorkingIndicator {
    BOOL busy = _transcript.isBusy();
    if (!busy) {
        [_workingView stopAnimating];
        if (_workingView.superview != nil) {
            [_messageStack removeArrangedSubview:_workingView];
            [_workingView removeFromSuperview];
        }
        return;
    }
    if (_workingView == nil) {
        _workingView = [GWChatWorkingView new];
    }
    // What Claude is doing right now: the tool that has no result yet, else "Thinking".
    NSString *text = @"Working…";
    if (_transcript.size() > 0) {
        const gw::claude::Message &last = _transcript.messages().back();
        for (size_t index = last.blocks.size(); index-- > 0;) {
            const gw::claude::Block &block = last.blocks[index];
            if (block.kind == gw::claude::Block::Kind::Tool && !block.tool.hasResult) {
                if (block.tool.approval == gw::claude::Approval::Pending) {
                    text = @"Waiting for your answer…";
                } else {
                    text = [NSString stringWithFormat:@"%s…", block.tool.summary().c_str()];
                }
                break;
            }
            if (block.kind == gw::claude::Block::Kind::Text && !block.finished) {
                text = @"Writing…";
                break;
            }
        }
    }
    [_workingView setText:text];
    [_workingView startAnimating];
    if (_workingView.superview == nil) {
        [_messageStack addArrangedSubview:_workingView];
        [_workingView.widthAnchor constraintEqualToAnchor:_messageStack.widthAnchor constant:-32].active = YES;
    }
}

- (void)showEmptyStateIfNeeded {
    BOOL empty = _transcript.size() == 0;
    _emptyState.hidden = !empty;
    _scroll.hidden = empty;
}

- (void)updateHeader {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSString *model = friendlyModelName(_reportedModel);
    if (model.length > 0) {
        [parts addObject:model];
    }
    if (_transcript.lastTurn().costUsd > 0) {
        [parts addObject:[NSString stringWithFormat:@"$%.2f", _transcript.lastTurn().costUsd]];
    }
    if (_fiveHourUsage >= 0) {
        [parts addObject:[NSString stringWithFormat:@"%.0f%% of 5h limit", _fiveHourUsage * 100]];
    }
    _subtitleLabel.stringValue = [parts componentsJoinedByString:@"  ·  "];
}

// ---------------------------------------------------------------------------
// MARK: Scrolling

- (void)scrolled:(NSNotification *)notification {
    NSClipView *clip = _scroll.contentView;
    CGFloat bottom = NSMaxY(clip.bounds);
    CGFloat total = NSHeight(_document.frame);
    _pinnedToBottom = total - bottom < 48;
}

- (void)scrollToBottomIfPinned {
    if (!_pinnedToBottom) {
        return;
    }
    // Wait for the new content to be laid out, then follow it.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_document layoutSubtreeIfNeeded];
        CGFloat total = NSHeight(self->_document.frame);
        CGFloat visible = NSHeight(self->_scroll.contentView.bounds);
        CGFloat target = MAX(0, total - visible);
        [self->_scroll.contentView scrollToPoint:NSMakePoint(0, target)];
        [self->_scroll reflectScrolledClipView:self->_scroll.contentView];
        self->_pinnedToBottom = YES;
    });
}

// ---------------------------------------------------------------------------
// MARK: New chat and history

- (void)newChatClicked:(id)sender { [self newChat]; }
- (void)closeClicked:(id)sender {
    if (self.onClose) {
        self.onClose();
    }
}

- (void)newChat {
    [self stopSession];
    _transcript.clear();
    _resumeSessionId = nil;
    _reportedModel.clear();
    for (NSView *view in _messageViews) {
        [_messageStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    [_messageViews removeAllObjects];
    if (_workingView.superview != nil) {
        [_messageStack removeArrangedSubview:_workingView];
        [_workingView removeFromSuperview];
    }
    _pinnedToBottom = YES;
    [self showEmptyStateIfNeeded];
    [self updateHeader];
    [self updateSendButton];
}

- (void)historyClicked:(NSButton *)sender {
    NSString *folder = _projectFolder ?: NSHomeDirectory();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        std::vector<gw::claude::SavedSession> sessions = gw::claude::listSavedSessions(folder.UTF8String, 25);
        dispatch_async(dispatch_get_main_queue(), ^{
            NSMenu *menu = [NSMenu new];
            if (sessions.empty()) {
                NSMenuItem *none = [menu addItemWithTitle:@"No earlier chats in this project" action:nil keyEquivalent:@""];
                none.enabled = NO;
            }
            NSDateComponentsFormatter *formatter = [NSDateComponentsFormatter new];
            formatter.unitsStyle = NSDateComponentsFormatterUnitsStyleAbbreviated;
            formatter.maximumUnitCount = 1;
            formatter.allowedUnits = NSCalendarUnitDay | NSCalendarUnitHour | NSCalendarUnitMinute;
            for (const gw::claude::SavedSession &session : sessions) {
                NSTimeInterval age = NSDate.date.timeIntervalSince1970 - session.modifiedSeconds;
                NSString *ago = age < 60 ? @"now" : [formatter stringFromTimeInterval:age];
                NSString *title = [NSString stringWithFormat:@"%@   ·   %@", @(session.title.c_str()), ago];
                NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:@selector(openSavedSession:) keyEquivalent:@""];
                item.target = self;
                item.representedObject = @[@(session.id.c_str()), @(session.path.c_str())];
                [menu addItem:item];
            }
            [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSHeight(sender.bounds) + 4) inView:sender];
        });
    });
}

- (void)openSavedSession:(NSMenuItem *)item {
    NSArray<NSString *> *info = item.representedObject;
    NSString *identifier = info[0];
    NSString *path = info[1];
    [self stopSession];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        gw::claude::Transcript loaded = gw::claude::loadSavedSession(path.UTF8String);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showLoadedTranscript:std::move(loaded) resumeIdentifier:identifier];
        });
    });
}

- (void)showLoadedTranscript:(gw::claude::Transcript)loaded resumeIdentifier:(NSString *)identifier {
    [self newChat];
    ++_generation;
    _transcript = std::move(loaded);
    _transcript.setBusy(false);
    _resumeSessionId = [identifier copy];
    _pinnedToBottom = YES;
    [self syncMessageViews];
    [self showEmptyStateIfNeeded];
    [self scrollToBottomIfPinned];
    [self focusComposer];
}

@end
