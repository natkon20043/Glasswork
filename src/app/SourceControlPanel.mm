#import "SourceControlPanel.h"
#import "Strings.h"

#import "FileIcons.h"
#import "GitRepository.h"

#include "ClaudeSession.hpp"
#include "Git.hpp"

#include <algorithm>

// ===========================================================================
// Row model

typedef NS_ENUM(NSInteger, GWSCRowKind) {
    GWSCRowKindHeader,
    GWSCRowKindFile,
    GWSCRowKindCommit,
    GWSCRowKindNote,
};

/// One line of the list: a section header, a changed file, a commit, or a note.
@interface GWSCRow : NSObject
@property (nonatomic) GWSCRowKind kind;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *detail;
@property (nonatomic, copy) NSString *path;       // file rows: path relative to the repository
@property (nonatomic, copy) NSString *sectionId;  // "conflicts", "staged", "changes", "commits"
@property (nonatomic) BOOL staged;
@property (nonatomic) NSInteger changeKind;       // a gw::git::ChangeKind
@property (nonatomic) NSInteger count;            // header rows: how many items the section has
@property (nonatomic) BOOL collapsed;
@property (nonatomic, copy) NSString *commitHash; // commit rows
@end

@implementation GWSCRow
@end

// ===========================================================================
// Small helpers

namespace {

NSColor *colorForChange(gw::git::ChangeKind kind) {
    switch (kind) {
        case gw::git::ChangeKind::Modified:
            return [NSColor colorWithSRGBRed:0.90 green:0.68 blue:0.30 alpha:1];
        case gw::git::ChangeKind::Added:
        case gw::git::ChangeKind::Untracked:
            return [NSColor colorWithSRGBRed:0.36 green:0.80 blue:0.45 alpha:1];
        case gw::git::ChangeKind::Deleted:
            return [NSColor colorWithSRGBRed:0.95 green:0.40 blue:0.40 alpha:1];
        case gw::git::ChangeKind::Renamed:
        case gw::git::ChangeKind::Copied:
            return [NSColor colorWithSRGBRed:0.40 green:0.70 blue:0.95 alpha:1];
        case gw::git::ChangeKind::TypeChanged:
            return [NSColor colorWithSRGBRed:0.75 green:0.55 blue:0.95 alpha:1];
        case gw::git::ChangeKind::Conflicted:
            return [NSColor colorWithSRGBRed:1.0 green:0.35 blue:0.45 alpha:1];
        case gw::git::ChangeKind::None:
            break;
    }
    return NSColor.secondaryLabelColor;
}

NSString *letterForChange(gw::git::ChangeKind kind) {
    switch (kind) {
        case gw::git::ChangeKind::Modified:
            return @"M";
        case gw::git::ChangeKind::Added:
            return @"A";
        case gw::git::ChangeKind::Deleted:
            return @"D";
        case gw::git::ChangeKind::Renamed:
            return @"R";
        case gw::git::ChangeKind::Copied:
            return @"C";
        case gw::git::ChangeKind::TypeChanged:
            return @"T";
        case gw::git::ChangeKind::Untracked:
            return @"U";
        case gw::git::ChangeKind::Conflicted:
            return @"!";
        case gw::git::ChangeKind::None:
            break;
    }
    return @"";
}

NSImage *symbolImage(NSString *name, CGFloat size, NSFontWeight weight = NSFontWeightMedium) {
    NSImageSymbolConfiguration *configuration = [NSImageSymbolConfiguration configurationWithPointSize:size weight:weight];
    return [[NSImage imageWithSystemSymbolName:name accessibilityDescription:nil] imageWithSymbolConfiguration:configuration];
}

NSButton *iconButton(NSString *symbol, NSString *tip, id target, SEL action) {
    NSButton *button = [NSButton buttonWithImage:symbolImage(symbol, 12) target:target action:action];
    button.bordered = NO;
    button.toolTip = tip;
    button.contentTintColor = NSColor.secondaryLabelColor;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button.widthAnchor constraintEqualToConstant:22].active = YES;
    [button.heightAnchor constraintEqualToConstant:22].active = YES;
    return button;
}

NSTextField *label(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color) {
    NSTextField *field = [NSTextField labelWithString:text];
    field.font = [NSFont systemFontOfSize:size weight:weight];
    field.textColor = color;
    field.translatesAutoresizingMaskIntoConstraints = NO;
    return field;
}

}  // namespace

// ===========================================================================
// Views

/// A text view that shows a grey hint while empty, and reports ⌘↩.
@interface GWCommitTextView : NSTextView
@property (nonatomic, copy) NSString *placeholder;
@property (nonatomic, copy, nullable) void (^onCommandReturn)(void);
@property (nonatomic, copy, nullable) void (^onTextChange)(void);
@end

@implementation GWCommitTextView

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    if (self.string.length == 0 && self.placeholder.length > 0) {
        NSDictionary *attributes = @{
            NSFontAttributeName: self.font ?: [NSFont systemFontOfSize:13],
            NSForegroundColorAttributeName: NSColor.tertiaryLabelColor,
        };
        NSPoint origin = NSMakePoint(self.textContainerInset.width + self.textContainer.lineFragmentPadding, self.textContainerInset.height);
        [self.placeholder drawAtPoint:origin withAttributes:attributes];
    }
}

- (void)keyDown:(NSEvent *)event {
    BOOL isReturn = event.keyCode == 36 || event.keyCode == 76;
    if (isReturn && (event.modifierFlags & NSEventModifierFlagCommand) != 0 && self.onCommandReturn) {
        self.onCommandReturn();
        return;
    }
    [super keyDown:event];
}

- (void)didChangeText {
    [super didChangeText];
    self.needsDisplay = YES;
    if (self.onTextChange) {
        self.onTextChange();
    }
}

@end

/// The rounded box around the commit message. It repaints its colors when the appearance
/// (light or dark) changes, because layer colors don't adapt on their own.
@interface GWSCCard : NSView
@end

@implementation GWSCCard

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.wantsLayer = YES;
        self.layer.cornerRadius = 12;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.borderWidth = 1;
        [self updateLayerColors];
    }
    return self;
}

- (void)updateLayerColors {
    [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
        self.layer.backgroundColor = [NSColor.labelColor colorWithAlphaComponent:0.06].CGColor;
        self.layer.borderColor = [NSColor.labelColor colorWithAlphaComponent:0.12].CGColor;
    }];
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self updateLayerColors];
}

@end

/// Cells that can show hover-only buttons.
@protocol GWHoverCell <NSObject>
- (void)setHovering:(BOOL)hovering;
@end

/// A list row with a soft rounded selection and hover highlight, and hover tracking.
@interface GWSCRowView : NSTableRowView
@property (nonatomic) BOOL hovering;
@end

@implementation GWSCRowView {
    NSTrackingArea *_tracking;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking) {
        [self removeTrackingArea:_tracking];
    }
    _tracking = [[NSTrackingArea alloc] initWithRect:self.bounds
                                             options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
                                               owner:self
                                            userInfo:nil];
    [self addTrackingArea:_tracking];
}

- (void)setHoveringState:(BOOL)hovering {
    self.hovering = hovering;
    self.needsDisplay = YES;
    NSView *cell = self.numberOfColumns > 0 ? [self viewAtColumn:0] : nil;
    if ([cell conformsToProtocol:@protocol(GWHoverCell)]) {
        [(id<GWHoverCell>)cell setHovering:hovering];
    }
}

- (void)mouseEntered:(NSEvent *)event { [self setHoveringState:YES]; }
- (void)mouseExited:(NSEvent *)event { [self setHoveringState:NO]; }

- (void)drawBackgroundInRect:(NSRect)dirtyRect {
    if (self.hovering && !self.selected) {
        [[NSColor.labelColor colorWithAlphaComponent:0.06] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 4, 1) xRadius:7 yRadius:7] fill];
    }
}

- (void)drawSelectionInRect:(NSRect)dirtyRect {
    [[NSColor.controlAccentColor colorWithAlphaComponent:0.26] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 4, 1) xRadius:7 yRadius:7] fill];
}

- (BOOL)isEmphasized { return NO; }

@end

/// Section header: chevron, title, count, and buttons that appear on hover.
@interface GWSCHeaderCell : NSTableCellView <GWHoverCell>
@property (nonatomic, strong) NSImageView *chevron;
@property (nonatomic, strong) NSTextField *title;
@property (nonatomic, strong) NSTextField *count;
@property (nonatomic, strong) NSStackView *actions;
@end

@implementation GWSCHeaderCell

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _chevron = [NSImageView new];
        _chevron.translatesAutoresizingMaskIntoConstraints = NO;
        _chevron.contentTintColor = NSColor.tertiaryLabelColor;
        _title = label(@"", 10.5, NSFontWeightSemibold, NSColor.secondaryLabelColor);
        _count = label(@"", 10.5, NSFontWeightSemibold, NSColor.tertiaryLabelColor);
        _actions = [NSStackView new];
        _actions.translatesAutoresizingMaskIntoConstraints = NO;
        _actions.spacing = 0;
        _actions.hidden = YES;
        for (NSView *view in @[_chevron, _title, _count, _actions]) {
            [self addSubview:view];
        }
        [NSLayoutConstraint activateConstraints:@[
            [_chevron.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:10],
            [_chevron.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_chevron.widthAnchor constraintEqualToConstant:10],
            [_title.leadingAnchor constraintEqualToAnchor:_chevron.trailingAnchor constant:6],
            [_title.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_count.leadingAnchor constraintEqualToAnchor:_title.trailingAnchor constant:6],
            [_count.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_actions.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-6],
            [_actions.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        ]];
    }
    return self;
}

- (void)setHovering:(BOOL)hovering {
    self.actions.hidden = !hovering;
}

@end

/// A changed file: icon, name and folder, a status letter, and hover buttons.
@interface GWSCFileCell : NSTableCellView <GWHoverCell>
@property (nonatomic, strong) NSImageView *icon;
@property (nonatomic, strong) NSTextField *name;
@property (nonatomic, strong) NSTextField *folder;
@property (nonatomic, strong) NSTextField *badge;
@property (nonatomic, strong) NSStackView *actions;
@property (nonatomic, strong) NSButton *openButton;
@property (nonatomic, strong) NSButton *discardButton;
@property (nonatomic, strong) NSButton *stageButton;
@end

@implementation GWSCFileCell

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _icon = [NSImageView new];
        _icon.translatesAutoresizingMaskIntoConstraints = NO;
        _name = label(@"", 13, NSFontWeightMedium, NSColor.labelColor);
        _name.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [_name setContentCompressionResistancePriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
        _folder = label(@"", 11, NSFontWeightRegular, NSColor.tertiaryLabelColor);
        _folder.lineBreakMode = NSLineBreakByTruncatingHead;
        [_folder setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        _badge = label(@"", 11, NSFontWeightBold, NSColor.secondaryLabelColor);
        _badge.alignment = NSTextAlignmentCenter;

        _actions = [NSStackView new];
        _actions.translatesAutoresizingMaskIntoConstraints = NO;
        _actions.spacing = 0;
        _actions.hidden = YES;

        for (NSView *view in @[_icon, _name, _folder, _badge, _actions]) {
            [self addSubview:view];
        }
        [NSLayoutConstraint activateConstraints:@[
            [_icon.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
            [_icon.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_icon.widthAnchor constraintEqualToConstant:16],
            [_name.leadingAnchor constraintEqualToAnchor:_icon.trailingAnchor constant:7],
            [_name.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_folder.leadingAnchor constraintEqualToAnchor:_name.trailingAnchor constant:6],
            [_folder.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_badge.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
            [_badge.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_badge.widthAnchor constraintEqualToConstant:14],
            [_folder.trailingAnchor constraintLessThanOrEqualToAnchor:_badge.leadingAnchor constant:-8],
            [_actions.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-6],
            [_actions.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        ]];
    }
    return self;
}

- (void)setHovering:(BOOL)hovering {
    self.actions.hidden = !hovering;
    self.badge.hidden = hovering;
}

@end

/// A commit in the history list.
@interface GWSCCommitCell : NSTableCellView
@property (nonatomic, strong) NSImageView *dot;
@property (nonatomic, strong) NSTextField *subject;
@property (nonatomic, strong) NSTextField *meta;
@end

@implementation GWSCCommitCell

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _dot = [NSImageView new];
        _dot.translatesAutoresizingMaskIntoConstraints = NO;
        _dot.image = symbolImage(@"circle.fill", 6);
        _dot.contentTintColor = [NSColor.controlAccentColor colorWithAlphaComponent:0.9];
        _subject = label(@"", 12.5, NSFontWeightMedium, NSColor.labelColor);
        _subject.lineBreakMode = NSLineBreakByTruncatingTail;
        _meta = label(@"", 11, NSFontWeightRegular, NSColor.tertiaryLabelColor);
        _meta.lineBreakMode = NSLineBreakByTruncatingTail;
        for (NSView *view in @[_dot, _subject, _meta]) {
            [self addSubview:view];
        }
        [NSLayoutConstraint activateConstraints:@[
            [_dot.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:13],
            [_dot.topAnchor constraintEqualToAnchor:self.topAnchor constant:9],
            [_subject.leadingAnchor constraintEqualToAnchor:_dot.trailingAnchor constant:9],
            [_subject.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-10],
            [_subject.topAnchor constraintEqualToAnchor:self.topAnchor constant:5],
            [_meta.leadingAnchor constraintEqualToAnchor:_subject.leadingAnchor],
            [_meta.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-10],
            [_meta.topAnchor constraintEqualToAnchor:_subject.bottomAnchor constant:1],
        ]];
    }
    return self;
}

@end

/// A table that lets the panel supply the right-click menu for the row under the pointer.
@interface GWSCTable : NSTableView
@property (nonatomic, copy, nullable) NSMenu * (^menuForRow)(NSInteger row);
@end

@implementation GWSCTable

- (NSMenu *)menuForEvent:(NSEvent *)event {
    NSInteger row = [self rowAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    if (row < 0 || self.menuForRow == nil) {
        return nil;
    }
    [self selectRowIndexes:[NSIndexSet indexSetWithIndex:static_cast<NSUInteger>(row)] byExtendingSelection:NO];
    return self.menuForRow(row);
}

@end

// ===========================================================================
// The panel

@interface GWSourceControlPanel () <NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation GWSourceControlPanel {
    GWGitRepository *_repository;
    NSView *_view;

    // With a repository
    NSView *_content;
    NSButton *_branchButton;
    NSProgressIndicator *_spinner;
    NSTextField *_busyLabel;
    NSButton *_moreButton;
    NSView *_commitCard;
    GWCommitTextView *_message;
    NSButton *_generateButton;
    NSButton *_commitButton;
    NSButton *_syncButton;
    GWSCTable *_table;

    // Without one
    NSView *_emptyState;
    NSImageView *_emptyIcon;
    NSTextField *_emptyTitle;
    NSTextField *_emptyText;
    NSButton *_initializeButton;
    NSButton *_publishButton;

    NSMutableArray<GWSCRow *> *_rows;
    NSMutableSet<NSString *> *_collapsedSections;
    BOOL _generating;
}

- (instancetype)initWithRepository:(GWGitRepository *)repository {
    self = [super init];
    if (self) {
        _repository = repository;
        _rows = [NSMutableArray array];
        _collapsedSections = [NSMutableSet set];
        [self buildViews];
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(repositoryChanged:)
                                                   name:GWGitStatusDidChangeNotification
                                                 object:repository];
        [self reloadFromRepository];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (NSView *)view { return _view; }

// ---------------------------------------------------------------------------
// MARK: Building the interface

- (void)buildViews {
    _view = [NSView new];
    [self buildEmptyState];
    [self buildContent];
    for (NSView *view in @[_content, _emptyState]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [_view addSubview:view];
        [NSLayoutConstraint activateConstraints:@[
            [view.topAnchor constraintEqualToAnchor:_view.topAnchor],
            [view.bottomAnchor constraintEqualToAnchor:_view.bottomAnchor],
            [view.leadingAnchor constraintEqualToAnchor:_view.leadingAnchor],
            [view.trailingAnchor constraintEqualToAnchor:_view.trailingAnchor],
        ]];
    }
}

- (void)buildEmptyState {
    _emptyState = [NSView new];

    _emptyIcon = [NSImageView imageViewWithImage:symbolImage(@"arrow.triangle.branch", 30, NSFontWeightSemibold)];
    _emptyIcon.contentTintColor = NSColor.controlAccentColor;
    _emptyTitle = label(@"", 14, NSFontWeightSemibold, NSColor.labelColor);
    _emptyText = label(@"", 12, NSFontWeightRegular, NSColor.secondaryLabelColor);
    _emptyText.alignment = NSTextAlignmentCenter;
    _emptyText.maximumNumberOfLines = 0;
    _emptyText.lineBreakMode = NSLineBreakByWordWrapping;
    _emptyText.preferredMaxLayoutWidth = 200;

    _initializeButton = [NSButton buttonWithTitle:@"Initialize Repository" target:self action:@selector(initializeRepository)];
    _initializeButton.bezelStyle = NSBezelStyleGlass;
    _initializeButton.bezelColor = NSColor.controlAccentColor;
    _publishButton = [NSButton buttonWithTitle:@"Publish to GitHub…" target:self action:@selector(publishToGitHub)];
    _publishButton.bezelStyle = NSBezelStyleGlass;

    NSStackView *stack = [NSStackView stackViewWithViews:@[_emptyIcon, _emptyTitle, _emptyText, _initializeButton, _publishButton]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeCenterX;
    stack.spacing = 10;
    [stack setCustomSpacing:16 afterView:_emptyText];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [_emptyState addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:_emptyState.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:_emptyState.centerYAnchor constant:-30],
        [stack.widthAnchor constraintLessThanOrEqualToAnchor:_emptyState.widthAnchor constant:-30],
    ]];
}

- (void)buildContent {
    _content = [NSView new];

    // Top row: branch, busy indicator, more.
    _branchButton = [NSButton buttonWithTitle:@"" target:self action:@selector(branchButtonClicked:)];
    _branchButton.bordered = NO;
    _branchButton.alignment = NSTextAlignmentLeft;
    _branchButton.toolTip = @"Switch branch";
    _branchButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_branchButton setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                            forOrientation:NSLayoutConstraintOrientationHorizontal];

    _spinner = [NSProgressIndicator new];
    _spinner.style = NSProgressIndicatorStyleSpinning;
    _spinner.controlSize = NSControlSizeSmall;
    _spinner.displayedWhenStopped = NO;
    _spinner.translatesAutoresizingMaskIntoConstraints = NO;
    _busyLabel = label(@"", 11, NSFontWeightRegular, NSColor.tertiaryLabelColor);

    NSButton *refresh = iconButton(@"arrow.clockwise", @"Refresh", self, @selector(refreshClicked:));
    _moreButton = iconButton(@"ellipsis.circle", @"More actions", self, @selector(moreClicked:));

    NSStackView *top = [NSStackView stackViewWithViews:@[_branchButton, _spinner, _busyLabel, refresh, _moreButton]];
    top.spacing = 4;
    top.translatesAutoresizingMaskIntoConstraints = NO;
    [top setCustomSpacing:8 afterView:_branchButton];

    // The commit card: message box and buttons.
    _commitCard = [GWSCCard new];
    _commitCard.translatesAutoresizingMaskIntoConstraints = NO;

    _message = [[GWCommitTextView alloc] initWithFrame:NSMakeRect(0, 0, 200, 60)];
    _message.font = [NSFont systemFontOfSize:13];
    _message.drawsBackground = NO;
    _message.textColor = NSColor.labelColor;
    _message.insertionPointColor = NSColor.controlAccentColor;
    _message.textContainerInset = NSMakeSize(6, 8);
    _message.allowsUndo = YES;
    _message.richText = NO;
    _message.autoresizingMask = NSViewWidthSizable;
    _message.placeholder = @"Message  (⌘↩ to commit)";
    __weak GWSourceControlPanel *weakSelf = self;
    _message.onCommandReturn = ^{ [weakSelf commit]; };
    _message.onTextChange = ^{ [weakSelf updateButtons]; };

    NSScrollView *messageScroll = [NSScrollView new];
    messageScroll.documentView = _message;
    messageScroll.drawsBackground = NO;
    messageScroll.hasVerticalScroller = NO;
    messageScroll.borderType = NSNoBorder;
    messageScroll.translatesAutoresizingMaskIntoConstraints = NO;

    _generateButton = iconButton(@"sparkles", @"Write the message with Claude", self, @selector(generateClicked:));
    _generateButton.contentTintColor = NSColor.controlAccentColor;
    _commitButton = [NSButton buttonWithTitle:@"Commit" target:self action:@selector(commitClicked:)];
    _commitButton.bezelStyle = NSBezelStyleGlass;
    _commitButton.bezelColor = NSColor.controlAccentColor;
    _commitButton.controlSize = NSControlSizeRegular;
    _commitButton.translatesAutoresizingMaskIntoConstraints = NO;
    NSView *spacer = [NSView new];
    NSStackView *buttons = [NSStackView stackViewWithViews:@[_generateButton, spacer, _commitButton]];
    buttons.translatesAutoresizingMaskIntoConstraints = NO;
    [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];

    [_commitCard addSubview:messageScroll];
    [_commitCard addSubview:buttons];
    [NSLayoutConstraint activateConstraints:@[
        [messageScroll.topAnchor constraintEqualToAnchor:_commitCard.topAnchor constant:2],
        [messageScroll.leadingAnchor constraintEqualToAnchor:_commitCard.leadingAnchor constant:2],
        [messageScroll.trailingAnchor constraintEqualToAnchor:_commitCard.trailingAnchor constant:-2],
        [messageScroll.heightAnchor constraintEqualToConstant:64],
        [buttons.topAnchor constraintEqualToAnchor:messageScroll.bottomAnchor constant:2],
        [buttons.leadingAnchor constraintEqualToAnchor:_commitCard.leadingAnchor constant:6],
        [buttons.trailingAnchor constraintEqualToAnchor:_commitCard.trailingAnchor constant:-6],
        [buttons.bottomAnchor constraintEqualToAnchor:_commitCard.bottomAnchor constant:-6],
    ]];

    // Sync button.
    _syncButton = [NSButton buttonWithTitle:@"" target:self action:@selector(syncClicked:)];
    _syncButton.bezelStyle = NSBezelStyleGlass;
    _syncButton.translatesAutoresizingMaskIntoConstraints = NO;

    // The list.
    _table = [GWSCTable new];
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"row"];
    [_table addTableColumn:column];
    _table.headerView = nil;
    _table.backgroundColor = NSColor.clearColor;
    _table.style = NSTableViewStylePlain;
    _table.intercellSpacing = NSMakeSize(0, 0);
    _table.dataSource = self;
    _table.delegate = self;
    _table.target = self;
    _table.action = @selector(rowClicked:);
    _table.doubleAction = @selector(rowDoubleClicked:);
    _table.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    _table.menuForRow = ^NSMenu *(NSInteger row) { return [weakSelf menuForRow:row]; };

    NSScrollView *scroll = [NSScrollView new];
    scroll.documentView = _table;
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.scrollerStyle = NSScrollerStyleOverlay;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;

    for (NSView *view in @[top, _commitCard, _syncButton, scroll]) {
        [_content addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [top.topAnchor constraintEqualToAnchor:_content.topAnchor constant:2],
        [top.leadingAnchor constraintEqualToAnchor:_content.leadingAnchor constant:12],
        [top.trailingAnchor constraintEqualToAnchor:_content.trailingAnchor constant:-8],
        [_commitCard.topAnchor constraintEqualToAnchor:top.bottomAnchor constant:8],
        [_commitCard.leadingAnchor constraintEqualToAnchor:_content.leadingAnchor constant:10],
        [_commitCard.trailingAnchor constraintEqualToAnchor:_content.trailingAnchor constant:-10],
        [_syncButton.topAnchor constraintEqualToAnchor:_commitCard.bottomAnchor constant:8],
        [_syncButton.leadingAnchor constraintEqualToAnchor:_content.leadingAnchor constant:10],
        [_syncButton.trailingAnchor constraintEqualToAnchor:_content.trailingAnchor constant:-10],
        [scroll.topAnchor constraintEqualToAnchor:_syncButton.bottomAnchor constant:8],
        [scroll.leadingAnchor constraintEqualToAnchor:_content.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:_content.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:_content.bottomAnchor],
    ]];
}

// ---------------------------------------------------------------------------
// MARK: Reading the repository

- (void)repositoryChanged:(NSNotification *)notification {
    [self reloadFromRepository];
}

- (void)reloadFromRepository {
    const gw::git::Status &status = _repository.status;
    BOOL hasFolder = _repository.folder != nil;
    BOOL showContent = hasFolder && status.isRepository;
    _content.hidden = !showContent;
    _emptyState.hidden = showContent;

    if (!showContent) {
        [self configureEmptyState];
        return;
    }
    [self updateBranchButton];
    [self updateBusyIndicator];
    [self rebuildRows];
    [self updateButtons];
}

- (void)configureEmptyState {
    const gw::git::Status &status = _repository.status;
    if (_repository.folder == nil) {
        _emptyTitle.stringValue = @"No Folder Open";
        _emptyText.stringValue = @"Open a folder to see its Git changes here.";
        _initializeButton.hidden = YES;
        _publishButton.hidden = YES;
    } else if (!status.error.empty()) {
        _emptyTitle.stringValue = @"Git isn't available";
        _emptyText.stringValue = StringFromUTF8(status.error);
        _initializeButton.hidden = YES;
        _publishButton.hidden = YES;
    } else {
        _emptyTitle.stringValue = @"Not a Git Repository";
        _emptyText.stringValue = @"Track changes, commit, and push to GitHub. It only takes one step.";
        _initializeButton.hidden = NO;
        _publishButton.hidden = NO;
    }
}

- (void)updateBranchButton {
    const gw::git::Status &status = _repository.status;
    NSString *name = status.branch.empty() ? [NSString stringWithFormat:@"Detached at %@", StringFromUTF8(status.headCommit.substr(0, 7))]
                                           : StringFromUTF8(status.branch);
    if (!status.hasCommits() && status.branch.empty()) {
        name = @"No commits yet";
    }
    NSMutableAttributedString *title = [NSMutableAttributedString new];
    NSTextAttachment *branchIcon = [NSTextAttachment new];
    branchIcon.image = [symbolImage(@"arrow.triangle.branch", 12, NSFontWeightSemibold)
        imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[NSColor.controlAccentColor]]];
    [title appendAttributedString:[NSAttributedString attributedStringWithAttachment:branchIcon]];
    [title appendAttributedString:[[NSAttributedString alloc] initWithString:[@"  " stringByAppendingString:name] attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: NSColor.labelColor,
    }]];
    NSTextAttachment *chevron = [NSTextAttachment new];
    chevron.image = [symbolImage(@"chevron.down", 8, NSFontWeightBold)
        imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[NSColor.tertiaryLabelColor]]];
    [title appendAttributedString:[[NSAttributedString alloc] initWithString:@"  "]];
    [title appendAttributedString:[NSAttributedString attributedStringWithAttachment:chevron]];
    _branchButton.attributedTitle = title;
}

- (void)updateBusyIndicator {
    if (_repository.isBusy) {
        [_spinner startAnimation:nil];
        _busyLabel.stringValue = _repository.busyTitle ?: @"";
    } else {
        [_spinner stopAnimation:nil];
        _busyLabel.stringValue = @"";
    }
}

- (void)updateButtons {
    const gw::git::Status &status = _repository.status;
    BOOL busy = _repository.isBusy;
    BOOL hasMessage = [_message.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length > 0;
    NSUInteger staged = status.stagedCount();
    NSUInteger unstaged = status.unstagedCount();

    _commitButton.title = staged > 0 || unstaged == 0 ? @"Commit" : @"Commit All";
    _commitButton.enabled = !busy && hasMessage && (staged > 0 || unstaged > 0);
    _generateButton.enabled = !busy && !_generating && (staged > 0 || unstaged > 0) && gw::claude::Session::isInstalled();
    _generateButton.toolTip = gw::claude::Session::isInstalled() ? @"Write the message with Claude"
                                                                  : @"Install Claude Code to write messages automatically";

    // The sync button says what pressing it would do.
    NSString *title = nil;
    NSString *symbol = @"arrow.triangle.2.circlepath";
    BOOL emphasize = NO;
    if (!status.hasCommits()) {
        title = @"Commit something to get started";
        _syncButton.enabled = NO;
    } else if (!status.hasRemote) {
        title = @"Publish to GitHub…";
        symbol = @"icloud.and.arrow.up";
        emphasize = YES;
        _syncButton.enabled = !busy;
    } else if (status.upstream.empty()) {
        title = @"Publish Branch";
        symbol = @"icloud.and.arrow.up";
        emphasize = YES;
        _syncButton.enabled = !busy;
    } else if (status.ahead > 0 && status.behind > 0) {
        title = [NSString stringWithFormat:@"Sync Changes   ↑%d  ↓%d", status.ahead, status.behind];
        emphasize = YES;
        _syncButton.enabled = !busy;
    } else if (status.ahead > 0) {
        title = [NSString stringWithFormat:@"Push   ↑%d", status.ahead];
        symbol = @"arrow.up.circle";
        emphasize = YES;
        _syncButton.enabled = !busy;
    } else if (status.behind > 0) {
        title = [NSString stringWithFormat:@"Pull   ↓%d", status.behind];
        symbol = @"arrow.down.circle";
        emphasize = YES;
        _syncButton.enabled = !busy;
    } else {
        title = @"Up to date  ·  Fetch";
        symbol = @"checkmark.circle";
        _syncButton.enabled = !busy;
    }
    _syncButton.title = title;
    _syncButton.image = symbolImage(symbol, 12);
    _syncButton.imagePosition = NSImageLeading;
    _syncButton.bezelColor = emphasize ? NSColor.controlAccentColor : nil;
    _syncButton.hidden = false;
}

// ---------------------------------------------------------------------------
// MARK: Building the rows

- (void)rebuildRows {
    const gw::git::Status &status = _repository.status;
    NSMutableArray<GWSCRow *> *rows = [NSMutableArray array];

    // Gather files by section, sorted by path.
    std::vector<const gw::git::FileChange *> conflicts;
    std::vector<const gw::git::FileChange *> staged;
    std::vector<const gw::git::FileChange *> unstaged;
    for (const gw::git::FileChange &change : status.changes) {
        if (change.isConflicted()) {
            conflicts.push_back(&change);
            continue;
        }
        if (change.hasStagedChange()) {
            staged.push_back(&change);
        }
        if (change.hasUnstagedChange()) {
            unstaged.push_back(&change);
        }
    }
    auto byPath = [](const gw::git::FileChange *a, const gw::git::FileChange *b) { return a->path < b->path; };
    std::sort(conflicts.begin(), conflicts.end(), byPath);
    std::sort(staged.begin(), staged.end(), byPath);
    std::sort(unstaged.begin(), unstaged.end(), byPath);

    auto addSection = ^(NSString *identifier, NSString *title, const std::vector<const gw::git::FileChange *> &files, BOOL isStaged) {
        if (files.empty()) {
            return;
        }
        GWSCRow *header = [GWSCRow new];
        header.kind = GWSCRowKindHeader;
        header.sectionId = identifier;
        header.title = title;
        header.count = static_cast<NSInteger>(files.size());
        header.collapsed = [self->_collapsedSections containsObject:identifier];
        [rows addObject:header];
        if (header.collapsed) {
            return;
        }
        for (const gw::git::FileChange *change : files) {
            GWSCRow *row = [GWSCRow new];
            row.kind = GWSCRowKindFile;
            row.sectionId = identifier;
            row.staged = isStaged;
            row.path = StringFromUTF8(change->path);
            row.title = row.path.lastPathComponent;
            row.detail = row.path.stringByDeletingLastPathComponent;
            gw::git::ChangeKind kind = change->isConflicted() ? gw::git::ChangeKind::Conflicted
                                                              : (isStaged ? change->staged : change->unstaged);
            row.changeKind = static_cast<NSInteger>(kind);
            [rows addObject:row];
        }
    };
    addSection(@"conflicts", @"MERGE CONFLICTS", conflicts, NO);
    addSection(@"staged", @"STAGED CHANGES", staged, YES);
    addSection(@"changes", @"CHANGES", unstaged, NO);

    if (conflicts.empty() && staged.empty() && unstaged.empty()) {
        GWSCRow *note = [GWSCRow new];
        note.kind = GWSCRowKindNote;
        note.title = status.hasCommits() ? @"No changes. Everything is committed." : @"Nothing to commit yet. Add some files.";
        [rows addObject:note];
    }
    if (status.truncated) {
        GWSCRow *note = [GWSCRow new];
        note.kind = GWSCRowKindNote;
        note.title = @"Showing the first 5,000 changes.";
        [rows addObject:note];
    }

    const std::vector<gw::git::LogEntry> &log = _repository.log;
    if (!log.empty()) {
        GWSCRow *header = [GWSCRow new];
        header.kind = GWSCRowKindHeader;
        header.sectionId = @"commits";
        header.title = @"RECENT COMMITS";
        header.count = static_cast<NSInteger>(log.size());
        header.collapsed = [_collapsedSections containsObject:@"commits"];
        [rows addObject:header];
        if (!header.collapsed) {
            for (const gw::git::LogEntry &entry : log) {
                GWSCRow *row = [GWSCRow new];
                row.kind = GWSCRowKindCommit;
                row.sectionId = @"commits";
                row.title = StringFromUTF8(entry.subject);
                row.detail = [NSString stringWithFormat:@"%@  ·  %@  ·  %@", StringFromUTF8(entry.shortHash), StringFromUTF8(entry.author),
                                                        StringFromUTF8(entry.relativeDate)];
                row.commitHash = StringFromUTF8(entry.hash);
                [rows addObject:row];
            }
        }
    }

    _rows = rows;
    [_table reloadData];
}

// ---------------------------------------------------------------------------
// MARK: Table

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return static_cast<NSInteger>(_rows.count);
}

- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row {
    switch (_rows[static_cast<NSUInteger>(row)].kind) {
        case GWSCRowKindHeader:
            return 28;
        case GWSCRowKindFile:
            return 26;
        case GWSCRowKindCommit:
            return 40;
        case GWSCRowKindNote:
            return 34;
    }
    return 26;
}

- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row {
    GWSCRowKind kind = _rows[static_cast<NSUInteger>(row)].kind;
    return kind == GWSCRowKindFile || kind == GWSCRowKindCommit;
}

- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row {
    return [GWSCRowView new];
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    GWSCRow *item = _rows[static_cast<NSUInteger>(row)];
    switch (item.kind) {
        case GWSCRowKindHeader:
            return [self headerCellFor:item];
        case GWSCRowKindFile:
            return [self fileCellFor:item];
        case GWSCRowKindCommit:
            return [self commitCellFor:item];
        case GWSCRowKindNote: {
            NSTableCellView *cell = [NSTableCellView new];
            NSTextField *text = label(item.title, 12, NSFontWeightRegular, NSColor.tertiaryLabelColor);
            text.alignment = NSTextAlignmentCenter;
            [cell addSubview:text];
            [NSLayoutConstraint activateConstraints:@[
                [text.centerXAnchor constraintEqualToAnchor:cell.centerXAnchor],
                [text.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            ]];
            return cell;
        }
    }
    return nil;
}

- (NSView *)headerCellFor:(GWSCRow *)item {
    GWSCHeaderCell *cell = [_table makeViewWithIdentifier:@"header" owner:self];
    if (!cell) {
        cell = [[GWSCHeaderCell alloc] initWithFrame:NSZeroRect];
        cell.identifier = @"header";
    }
    cell.title.stringValue = item.title;
    cell.count.stringValue = [NSString stringWithFormat:@"%ld", static_cast<long>(item.count)];
    cell.chevron.image = symbolImage(item.collapsed ? @"chevron.right" : @"chevron.down", 8, NSFontWeightBold);

    for (NSView *view in cell.actions.arrangedSubviews.copy) {
        [cell.actions removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    if ([item.sectionId isEqualToString:@"staged"]) {
        [cell.actions addArrangedSubview:iconButton(@"minus", @"Unstage All Changes", self, @selector(unstageAllClicked:))];
    } else if ([item.sectionId isEqualToString:@"changes"]) {
        [cell.actions addArrangedSubview:iconButton(@"arrow.uturn.backward", @"Discard All Changes", self, @selector(discardAllClicked:))];
        [cell.actions addArrangedSubview:iconButton(@"plus", @"Stage All Changes", self, @selector(stageAllClicked:))];
    }
    cell.actions.hidden = YES;
    return cell;
}

- (NSView *)fileCellFor:(GWSCRow *)item {
    GWSCFileCell *cell = [_table makeViewWithIdentifier:@"file" owner:self];
    if (!cell) {
        cell = [[GWSCFileCell alloc] initWithFrame:NSZeroRect];
        cell.identifier = @"file";
        cell.openButton = iconButton(@"doc.text", @"Open File", self, @selector(openFileClicked:));
        cell.discardButton = iconButton(@"arrow.uturn.backward", @"Discard Changes", self, @selector(discardFileClicked:));
        cell.stageButton = iconButton(@"plus", @"Stage Changes", self, @selector(stageFileClicked:));
        [cell.actions addArrangedSubview:cell.openButton];
        [cell.actions addArrangedSubview:cell.discardButton];
        [cell.actions addArrangedSubview:cell.stageButton];
    }
    gw::git::ChangeKind kind = static_cast<gw::git::ChangeKind>(item.changeKind);
    cell.name.stringValue = item.title;
    cell.folder.stringValue = item.detail.length > 0 ? item.detail : @"";
    cell.icon.image = symbolImage(GWSymbolForFile(item.title), 12);
    cell.icon.contentTintColor = GWColorForFile(item.title);
    cell.badge.stringValue = letterForChange(kind);
    cell.badge.textColor = colorForChange(kind);
    cell.name.textColor = kind == gw::git::ChangeKind::Deleted ? NSColor.secondaryLabelColor : NSColor.labelColor;

    // Staged files offer "unstage"; conflicts and others offer "stage".
    cell.stageButton.image = symbolImage(item.staged ? @"minus" : @"plus", 12);
    cell.stageButton.toolTip = item.staged ? @"Unstage Changes" : @"Stage Changes";
    cell.stageButton.action = item.staged ? @selector(unstageFileClicked:) : @selector(stageFileClicked:);
    cell.discardButton.hidden = item.staged;
    cell.actions.hidden = YES;
    cell.badge.hidden = NO;
    return cell;
}

- (NSView *)commitCellFor:(GWSCRow *)item {
    GWSCCommitCell *cell = [_table makeViewWithIdentifier:@"commit" owner:self];
    if (!cell) {
        cell = [[GWSCCommitCell alloc] initWithFrame:NSZeroRect];
        cell.identifier = @"commit";
    }
    cell.subject.stringValue = item.title;
    cell.meta.stringValue = item.detail;
    return cell;
}

// ---------------------------------------------------------------------------
// MARK: Clicking rows

- (GWSCRow *)rowForSender:(id)sender {
    NSInteger index = [_table rowForView:sender];
    if (index < 0 || index >= static_cast<NSInteger>(_rows.count)) {
        return nil;
    }
    return _rows[static_cast<NSUInteger>(index)];
}

- (void)rowClicked:(id)sender {
    NSInteger index = _table.clickedRow;
    if (index < 0 || index >= static_cast<NSInteger>(_rows.count)) {
        return;
    }
    GWSCRow *row = _rows[static_cast<NSUInteger>(index)];
    switch (row.kind) {
        case GWSCRowKindHeader:
            if ([_collapsedSections containsObject:row.sectionId]) {
                [_collapsedSections removeObject:row.sectionId];
            } else {
                [_collapsedSections addObject:row.sectionId];
            }
            [self rebuildRows];
            break;
        case GWSCRowKindFile:
            if (self.onShowDiff) {
                self.onShowDiff(row.path, row.staged);
            }
            break;
        case GWSCRowKindCommit:
            if (self.onShowCommit) {
                self.onShowCommit(row.commitHash, row.title);
            }
            break;
        case GWSCRowKindNote:
            break;
    }
}

- (void)rowDoubleClicked:(id)sender {
    NSInteger index = _table.clickedRow;
    if (index < 0 || index >= static_cast<NSInteger>(_rows.count)) {
        return;
    }
    GWSCRow *row = _rows[static_cast<NSUInteger>(index)];
    if (row.kind == GWSCRowKindFile) {
        [self openFile:row];
    }
}

- (void)openFile:(GWSCRow *)row {
    NSString *absolute = [_repository absolutePathForRelative:row.path];
    if (absolute != nil && self.onOpenFile) {
        self.onOpenFile(absolute);
    }
}

- (NSMenu *)menuForRow:(NSInteger)index {
    if (index < 0 || index >= static_cast<NSInteger>(_rows.count)) {
        return nil;
    }
    GWSCRow *row = _rows[static_cast<NSUInteger>(index)];
    if (row.kind != GWSCRowKindFile) {
        return nil;
    }
    NSMenu *menu = [NSMenu new];
    [menu addItemWithTitle:@"Open Changes" action:@selector(menuOpenChanges:) keyEquivalent:@""].target = self;
    [menu addItemWithTitle:@"Open File" action:@selector(menuOpenFile:) keyEquivalent:@""].target = self;
    [menu addItem:NSMenuItem.separatorItem];
    if (row.staged) {
        [menu addItemWithTitle:@"Unstage Changes" action:@selector(menuUnstage:) keyEquivalent:@""].target = self;
    } else {
        [menu addItemWithTitle:@"Stage Changes" action:@selector(menuStage:) keyEquivalent:@""].target = self;
        [menu addItemWithTitle:@"Discard Changes…" action:@selector(menuDiscard:) keyEquivalent:@""].target = self;
    }
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItemWithTitle:@"Reveal in Finder" action:@selector(menuReveal:) keyEquivalent:@""].target = self;
    [menu addItemWithTitle:@"Copy Path" action:@selector(menuCopyPath:) keyEquivalent:@""].target = self;
    return menu;
}

- (GWSCRow *)selectedFileRow {
    NSInteger index = _table.selectedRow;
    if (index < 0 || index >= static_cast<NSInteger>(_rows.count)) {
        return nil;
    }
    GWSCRow *row = _rows[static_cast<NSUInteger>(index)];
    return row.kind == GWSCRowKindFile ? row : nil;
}

- (void)menuOpenChanges:(id)sender {
    GWSCRow *row = [self selectedFileRow];
    if (row && self.onShowDiff) {
        self.onShowDiff(row.path, row.staged);
    }
}
- (void)menuOpenFile:(id)sender {
    GWSCRow *row = [self selectedFileRow];
    if (row) {
        [self openFile:row];
    }
}
- (void)menuStage:(id)sender {
    GWSCRow *row = [self selectedFileRow];
    if (row) {
        [self stagePath:row.path];
    }
}
- (void)menuUnstage:(id)sender {
    GWSCRow *row = [self selectedFileRow];
    if (row) {
        [self unstagePath:row.path];
    }
}
- (void)menuDiscard:(id)sender {
    GWSCRow *row = [self selectedFileRow];
    if (row) {
        [self discardRow:row];
    }
}
- (void)menuReveal:(id)sender {
    GWSCRow *row = [self selectedFileRow];
    NSString *absolute = row ? [_repository absolutePathForRelative:row.path] : nil;
    if (absolute) {
        [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:absolute]]];
    }
}
- (void)menuCopyPath:(id)sender {
    GWSCRow *row = [self selectedFileRow];
    if (row) {
        [NSPasteboard.generalPasteboard clearContents];
        [NSPasteboard.generalPasteboard setString:row.path forType:NSPasteboardTypeString];
    }
}

// ---------------------------------------------------------------------------
// MARK: File actions

- (void)reportError:(const gw::git::CommandResult &)result title:(NSString *)title {
    if (result.ok) {
        return;
    }
    if (self.onError) {
        self.onError(title, StringFromUTF8(result.error));
    }
}

- (void)stagePath:(NSString *)path {
    std::string file = path.UTF8String;
    [_repository perform:@"Staging…" operation:^gw::git::CommandResult(NSString *root) {
        return gw::git::stagePaths(root.UTF8String, {file});
    } completion:^(gw::git::CommandResult result) {
        [self reportError:result title:@"Couldn't stage the file"];
    }];
}

- (void)unstagePath:(NSString *)path {
    std::string file = path.UTF8String;
    bool hasCommits = _repository.status.hasCommits();
    [_repository perform:@"Unstaging…" operation:^gw::git::CommandResult(NSString *root) {
        return gw::git::unstagePaths(root.UTF8String, {file}, hasCommits);
    } completion:^(gw::git::CommandResult result) {
        [self reportError:result title:@"Couldn't unstage the file"];
    }];
}

- (void)stageFileClicked:(id)sender {
    GWSCRow *row = [self rowForSender:sender];
    if (row) {
        [self stagePath:row.path];
    }
}

- (void)unstageFileClicked:(id)sender {
    GWSCRow *row = [self rowForSender:sender];
    if (row) {
        [self unstagePath:row.path];
    }
}

- (void)openFileClicked:(id)sender {
    GWSCRow *row = [self rowForSender:sender];
    if (row) {
        [self openFile:row];
    }
}

- (void)discardFileClicked:(id)sender {
    GWSCRow *row = [self rowForSender:sender];
    if (row) {
        [self discardRow:row];
    }
}

/// Throws away a file's working changes, after asking. New (untracked) files go to the Trash.
- (void)discardRow:(GWSCRow *)row {
    BOOL untracked = static_cast<gw::git::ChangeKind>(row.changeKind) == gw::git::ChangeKind::Untracked;
    NSAlert *alert = [NSAlert new];
    alert.messageText = untracked ? [NSString stringWithFormat:@"Move “%@” to the Trash?", row.title]
                                  : [NSString stringWithFormat:@"Discard changes to “%@”?", row.title];
    alert.informativeText = untracked ? @"This file is new and isn't tracked by Git yet."
                                      : @"Your changes to this file will be lost. This can't be undone.";
    [alert addButtonWithTitle:untracked ? @"Move to Trash" : @"Discard Changes"];
    [alert addButtonWithTitle:@"Cancel"];
    alert.buttons.firstObject.hasDestructiveAction = YES;

    NSString *relative = row.path;
    NSString *absolute = [_repository absolutePathForRelative:relative];
    void (^proceed)(NSModalResponse) = ^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) {
            return;
        }
        if (untracked) {
            [NSFileManager.defaultManager trashItemAtURL:[NSURL fileURLWithPath:absolute] resultingItemURL:nil error:nil];
            [self->_repository refresh];
            return;
        }
        std::string file = relative.UTF8String;
        [self->_repository perform:@"Discarding…" operation:^gw::git::CommandResult(NSString *root) {
            return gw::git::discardPaths(root.UTF8String, {file});
        } completion:^(gw::git::CommandResult result) {
            [self reportError:result title:@"Couldn't discard the changes"];
        }];
    };
    if (_view.window) {
        [alert beginSheetModalForWindow:_view.window completionHandler:proceed];
    } else {
        proceed([alert runModal]);
    }
}

// ---------------------------------------------------------------------------
// MARK: Section actions

- (void)stageAllClicked:(id)sender {
    [_repository perform:@"Staging…" operation:^gw::git::CommandResult(NSString *root) {
        return gw::git::stageAll(root.UTF8String);
    } completion:^(gw::git::CommandResult result) {
        [self reportError:result title:@"Couldn't stage the changes"];
    }];
}

- (void)unstageAllClicked:(id)sender {
    std::vector<std::string> paths;
    for (const gw::git::FileChange &change : _repository.status.changes) {
        if (change.hasStagedChange()) {
            paths.push_back(change.path);
        }
    }
    bool hasCommits = _repository.status.hasCommits();
    [_repository perform:@"Unstaging…" operation:^gw::git::CommandResult(NSString *root) {
        return gw::git::unstagePaths(root.UTF8String, paths, hasCommits);
    } completion:^(gw::git::CommandResult result) {
        [self reportError:result title:@"Couldn't unstage the changes"];
    }];
}

- (void)discardAllClicked:(id)sender {
    std::vector<std::string> paths;
    for (const gw::git::FileChange &change : _repository.status.changes) {
        if (change.unstaged != gw::git::ChangeKind::None && !change.isUntracked() && !change.isConflicted()) {
            paths.push_back(change.path);
        }
    }
    if (paths.empty()) {
        return;
    }
    NSAlert *alert = [NSAlert new];
    alert.messageText = [NSString stringWithFormat:@"Discard changes to %lu files?", static_cast<unsigned long>(paths.size())];
    alert.informativeText = @"Changes to tracked files will be lost. New files are kept. This can't be undone.";
    [alert addButtonWithTitle:@"Discard Changes"];
    [alert addButtonWithTitle:@"Cancel"];
    alert.buttons.firstObject.hasDestructiveAction = YES;
    void (^proceed)(NSModalResponse) = ^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) {
            return;
        }
        [self->_repository perform:@"Discarding…" operation:^gw::git::CommandResult(NSString *root) {
            return gw::git::discardPaths(root.UTF8String, paths);
        } completion:^(gw::git::CommandResult result) {
            [self reportError:result title:@"Couldn't discard the changes"];
        }];
    };
    if (_view.window) {
        [alert beginSheetModalForWindow:_view.window completionHandler:proceed];
    } else {
        proceed([alert runModal]);
    }
}

// ---------------------------------------------------------------------------
// MARK: Committing

- (void)commitClicked:(id)sender { [self commit]; }

- (void)commit {
    [self commitThen:nil];
}

/// Commits (staging everything first if nothing is staged), then optionally pushes.
- (void)commitThen:(void (^_Nullable)(void))afterwards {
    NSString *message = [_message.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (message.length == 0) {
        [_view.window makeFirstResponder:_message];
        NSBeep();
        return;
    }
    if (self.onSaveAll) {
        self.onSaveAll();
    }
    const gw::git::Status &status = _repository.status;
    BOOL stageEverything = status.stagedCount() == 0;
    if (stageEverything && status.unstagedCount() == 0) {
        return;
    }
    std::string text = message.UTF8String;
    [_repository perform:@"Committing…" operation:^gw::git::CommandResult(NSString *root) {
        if (stageEverything) {
            gw::git::CommandResult staged = gw::git::stageAll(root.UTF8String);
            if (!staged.ok) {
                return staged;
            }
        }
        return gw::git::commit(root.UTF8String, text);
    } completion:^(gw::git::CommandResult result) {
        if (!result.ok) {
            [self reportError:result title:@"Couldn't commit"];
            return;
        }
        self->_message.string = @"";
        self->_message.needsDisplay = YES;
        [self updateButtons];
        if (afterwards) {
            afterwards();
        }
    }];
}

- (void)amendLastCommit {
    if (self.onSaveAll) {
        self.onSaveAll();
    }
    NSString *message = [_message.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    std::string text = message.UTF8String;
    const std::vector<gw::git::LogEntry> &log = _repository.log;
    std::string previousSubject = log.empty() ? std::string() : log.front().subject;
    [_repository perform:@"Amending…" operation:^gw::git::CommandResult(NSString *root) {
        std::string finalMessage = text.empty() ? previousSubject : text;
        return gw::git::commit(root.UTF8String, finalMessage, true);
    } completion:^(gw::git::CommandResult result) {
        [self reportError:result title:@"Couldn't amend the commit"];
        if (result.ok) {
            self->_message.string = @"";
        }
    }];
}

// ---------------------------------------------------------------------------
// MARK: Writing the message with Claude

- (void)generateClicked:(id)sender { [self generateMessage]; }

- (void)generateMessage {
    if (_generating) {
        return;
    }
    if (self.onSaveAll) {
        self.onSaveAll();
    }
    _generating = YES;
    [_spinner startAnimation:nil];
    _busyLabel.stringValue = @"Claude is writing…";
    [self updateButtons];

    BOOL staged = _repository.status.stagedCount() > 0;
    NSMutableString *recent = [NSMutableString string];
    for (size_t index = 0; index < std::min<size_t>(_repository.log.size(), 8); ++index) {
        [recent appendFormat:@"- %@\n", StringFromUTF8(_repository.log[index].subject)];
    }

    [_repository read:^id(NSString *root) {
        std::string diff = gw::git::readFullDiff(root.UTF8String, staged);
        return @{@"root": root, @"diff": StringFromUTF8(diff)};
    } completion:^(id result) {
        NSDictionary *info = result;
        NSString *root = info[@"root"];
        NSString *diff = info[@"diff"];
        if (diff.length == 0) {
            [self finishGenerating:nil error:@"There are no changes to describe. New files are only described once they're "
                                             @"staged."];
            return;
        }
        if (diff.length > 40000) {
            diff = [PrefixOfString(diff, 40000) stringByAppendingString:@"\n… (the diff was cut here because it is very long)"];
        }
        NSString *prompt = [NSString stringWithFormat:
            @"Write a git commit message for the change below.\n\n"
            @"Rules:\n"
            @"- First line: an imperative summary of at most 72 characters, no trailing period.\n"
            @"- If the change deserves it, add a blank line and a short body explaining why, wrapped at 72 columns.\n"
            @"- Follow the style of the recent commit subjects listed here:\n%@\n"
            @"- Reply with only the message. No quotes, no markdown, no preface.\n\n"
            @"The change:\n%@", recent.length ? recent : @"(none yet)", diff];
        std::string promptText = prompt.UTF8String;
        std::string folder = root.UTF8String;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            std::string error;
            std::string answer = gw::claude::askOnce(promptText, folder, "haiku", &error);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self finishGenerating:answer.empty() ? nil : StringFromUTF8(answer) error:StringFromUTF8(error)];
            });
        });
    }];
}

- (void)finishGenerating:(NSString *)message error:(NSString *)error {
    _generating = NO;
    [self updateBusyIndicator];
    [self updateButtons];
    if (message.length > 0) {
        // Remove a code fence or quotes if the model added them anyway.
        NSString *cleaned = message;
        if ([cleaned hasPrefix:@"```"]) {
            NSArray<NSString *> *lines = [cleaned componentsSeparatedByString:@"\n"];
            if (lines.count > 2) {
                cleaned = [[lines subarrayWithRange:NSMakeRange(1, lines.count - 2)] componentsJoinedByString:@"\n"];
            }
        }
        _message.string = cleaned;
        _message.needsDisplay = YES;
        [self updateButtons];
        [_view.window makeFirstResponder:_message];
        return;
    }
    if (self.onError) {
        self.onError(@"Claude couldn't write a message", error.length ? error : @"Try again in a moment.");
    }
}

// ---------------------------------------------------------------------------
// MARK: Sync: push, pull, fetch

- (void)syncClicked:(id)sender { [self sync]; }

- (void)sync {
    const gw::git::Status &status = _repository.status;
    if (!status.hasRemote) {
        [self publishToGitHub];
        return;
    }
    if (status.upstream.empty()) {
        [self push];
        return;
    }
    if (status.behind > 0 && status.ahead > 0) {
        [_repository perform:@"Syncing…" operation:^gw::git::CommandResult(NSString *root) {
            gw::git::CommandResult pulled = gw::git::pull(root.UTF8String);
            if (!pulled.ok) {
                return pulled;
            }
            return gw::git::push(root.UTF8String, true);
        } completion:^(gw::git::CommandResult result) {
            [self reportError:result title:@"Couldn't sync"];
        }];
    } else if (status.behind > 0) {
        [self pull];
    } else if (status.ahead > 0) {
        [self push];
    } else {
        [self fetch];
    }
}

- (void)push {
    bool hasUpstream = !_repository.status.upstream.empty();
    [_repository perform:@"Pushing…" operation:^gw::git::CommandResult(NSString *root) {
        return gw::git::push(root.UTF8String, hasUpstream);
    } completion:^(gw::git::CommandResult result) {
        [self reportError:result title:@"Couldn't push"];
    }];
}

- (void)pull {
    [_repository perform:@"Pulling…" operation:^gw::git::CommandResult(NSString *root) {
        return gw::git::pull(root.UTF8String);
    } completion:^(gw::git::CommandResult result) {
        [self reportError:result title:@"Couldn't pull"];
    }];
}

- (void)fetch {
    [_repository perform:@"Fetching…" operation:^gw::git::CommandResult(NSString *root) {
        return gw::git::fetch(root.UTF8String);
    } completion:^(gw::git::CommandResult result) {
        [self reportError:result title:@"Couldn't fetch"];
    }];
}

// ---------------------------------------------------------------------------
// MARK: Repository set-up

- (void)initializeRepository {
    NSString *folder = _repository.folder;
    if (folder == nil) {
        return;
    }
    [_repository perform:@"Initializing…" operation:^gw::git::CommandResult(NSString *root) {
        gw::git::CommandResult created = gw::git::initRepository(root.UTF8String);
        if (created.ok) {
            gw::git::writeGitignoreIfMissing(root.UTF8String, gw::git::suggestedGitignore(root.UTF8String));
        }
        return created;
    } completion:^(gw::git::CommandResult result) {
        [self reportError:result title:@"Couldn't create the repository"];
    }];
}

/// A labelled text field row for the forms below.
- (NSStackView *)formRow:(NSString *)labelText field:(NSView *)field {
    NSTextField *title = label(labelText, 12, NSFontWeightMedium, NSColor.secondaryLabelColor);
    [title.widthAnchor constraintEqualToConstant:84].active = YES;
    NSStackView *row = [NSStackView stackViewWithViews:@[title, field]];
    row.spacing = 8;
    row.alignment = NSLayoutAttributeCenterY;
    return row;
}

- (void)publishToGitHub {
    NSString *folder = _repository.folder;
    if (folder == nil) {
        return;
    }
    const gw::git::GitHubState &github = _repository.github;
    if (!github.ghInstalled || !github.loggedIn) {
        [self explainSignInNeeded:github.ghInstalled];
        return;
    }

    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Publish to GitHub";
    alert.informativeText = [NSString stringWithFormat:@"Creates a repository on GitHub as %@ and uploads this project.",
                                                       StringFromUTF8(github.user)];
    NSTextField *name = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
    name.stringValue = folder.lastPathComponent;
    NSTextField *description = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
    description.placeholderString = @"Optional";
    NSPopUpButton *visibility = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 260, 24) pullsDown:NO];
    [visibility addItemsWithTitles:@[@"Private (only you)", @"Public (anyone)"]];
    NSStackView *form = [NSStackView stackViewWithViews:@[
        [self formRow:@"Name" field:name],
        [self formRow:@"Description" field:description],
        [self formRow:@"Visibility" field:visibility],
    ]];
    form.orientation = NSUserInterfaceLayoutOrientationVertical;
    form.alignment = NSLayoutAttributeLeading;
    form.spacing = 8;
    form.frame = NSMakeRect(0, 0, 360, 96);
    alert.accessoryView = form;
    [alert addButtonWithTitle:@"Publish"];
    [alert addButtonWithTitle:@"Cancel"];

    void (^proceed)(NSModalResponse) = ^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) {
            return;
        }
        std::string repositoryName = name.stringValue.UTF8String;
        std::string repositoryDescription = description.stringValue.UTF8String;
        bool isPrivate = visibility.indexOfSelectedItem == 0;
        [self runPublishWithName:repositoryName description:repositoryDescription isPrivate:isPrivate];
    };
    if (_view.window) {
        [alert beginSheetModalForWindow:_view.window completionHandler:proceed];
    } else {
        proceed([alert runModal]);
    }
}

- (void)runPublishWithName:(std::string)name description:(std::string)description isPrivate:(bool)isPrivate {
    if (self.onSaveAll) {
        self.onSaveAll();
    }
    bool needsInit = !_repository.status.isRepository;
    bool needsCommit = !_repository.status.hasCommits();
    [_repository perform:@"Publishing…" operation:^gw::git::CommandResult(NSString *root) {
        std::string folder = root.UTF8String;
        if (needsInit) {
            gw::git::CommandResult created = gw::git::initRepository(folder);
            if (!created.ok) {
                return created;
            }
            gw::git::writeGitignoreIfMissing(folder, gw::git::suggestedGitignore(folder));
        }
        if (needsInit || needsCommit) {
            gw::git::CommandResult staged = gw::git::stageAll(folder);
            if (!staged.ok) {
                return staged;
            }
            gw::git::CommandResult committed = gw::git::commit(folder, "Initial commit");
            if (!committed.ok) {
                return committed;
            }
        }
        return gw::git::publishToGitHub(folder, name, isPrivate, description);
    } completion:^(gw::git::CommandResult result) {
        [self reportError:result title:@"Couldn't publish to GitHub"];
        if (result.ok) {
            [self->_repository refreshGitHubState];
            [self offerToOpenPublishedRepository:result.output];
        }
    }];
}

- (void)offerToOpenPublishedRepository:(const std::string &)output {
    // `gh` prints the new repository's address.
    NSString *text = StringFromUTF8(output);
    NSRange range = [text rangeOfString:@"https://github.com/[^\\s]+" options:NSRegularExpressionSearch];
    if (range.location == NSNotFound) {
        return;
    }
    NSURL *url = [NSURL URLWithString:[text substringWithRange:range]];
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Published to GitHub";
    alert.informativeText = url.absoluteString;
    [alert addButtonWithTitle:@"Open on GitHub"];
    [alert addButtonWithTitle:@"Done"];
    void (^proceed)(NSModalResponse) = ^(NSModalResponse response) {
        if (response == NSAlertFirstButtonReturn) {
            [NSWorkspace.sharedWorkspace openURL:url];
        }
    };
    if (_view.window) {
        [alert beginSheetModalForWindow:_view.window completionHandler:proceed];
    } else {
        proceed([alert runModal]);
    }
}

- (void)explainSignInNeeded:(BOOL)ghInstalled {
    NSAlert *alert = [NSAlert new];
    if (!ghInstalled) {
        alert.messageText = @"GitHub's command line tool isn't installed";
        alert.informativeText = @"Publishing and pull requests use GitHub's “gh” tool. Install it once with:\n\n"
                                @"    brew install gh\n\nThen come back and try again.";
        [alert addButtonWithTitle:@"OK"];
    } else {
        alert.messageText = @"Sign in to GitHub first";
        alert.informativeText = @"Glasswork uses your GitHub sign-in from the “gh” tool. It opens your browser, and you only "
                                @"do it once.";
        [alert addButtonWithTitle:@"Sign In…"];
        [alert addButtonWithTitle:@"Cancel"];
    }
    void (^proceed)(NSModalResponse) = ^(NSModalResponse response) {
        if (ghInstalled && response == NSAlertFirstButtonReturn) {
            [self signInToGitHub];
        }
    };
    if (_view.window) {
        [alert beginSheetModalForWindow:_view.window completionHandler:proceed];
    } else {
        proceed([alert runModal]);
    }
}

- (void)signInToGitHub {
    if (self.onRunInTerminal) {
        self.onRunInTerminal(@"gh auth login --hostname github.com --git-protocol https --web && gh auth setup-git");
        return;
    }
    if (self.onError) {
        self.onError(@"Sign in from a terminal", @"Run  gh auth login  in a terminal, then try again.");
    }
}

// ---------------------------------------------------------------------------
// MARK: Pull requests

- (void)createPullRequest {
    const gw::git::Status &status = _repository.status;
    const gw::git::GitHubState &github = _repository.github;
    if (!github.ghInstalled || !github.loggedIn) {
        [self explainSignInNeeded:github.ghInstalled];
        return;
    }
    if (!status.hasRemote || status.branch.empty()) {
        if (self.onError) {
            self.onError(@"Can't open a pull request", @"Publish this repository to GitHub and switch to a branch first.");
        }
        return;
    }

    NSAlert *alert = [NSAlert new];
    alert.messageText = [NSString stringWithFormat:@"Open a pull request for “%@”", StringFromUTF8(status.branch)];
    alert.informativeText = @"The branch is pushed first if it needs to be.";
    NSTextField *title = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 300, 24)];
    title.stringValue = _repository.log.empty() ? @"" : StringFromUTF8(_repository.log.front().subject);
    NSTextField *body = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 300, 24)];
    body.placeholderString = @"Optional";
    NSStackView *form = [NSStackView stackViewWithViews:@[[self formRow:@"Title" field:title], [self formRow:@"Description" field:body]]];
    form.orientation = NSUserInterfaceLayoutOrientationVertical;
    form.alignment = NSLayoutAttributeLeading;
    form.spacing = 8;
    form.frame = NSMakeRect(0, 0, 400, 62);
    alert.accessoryView = form;
    [alert addButtonWithTitle:@"Open Pull Request"];
    [alert addButtonWithTitle:@"Cancel"];

    bool hasUpstream = !status.upstream.empty();
    void (^proceed)(NSModalResponse) = ^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) {
            return;
        }
        std::string prTitle = title.stringValue.UTF8String;
        std::string prBody = body.stringValue.UTF8String;
        [self->_repository perform:@"Opening pull request…" operation:^gw::git::CommandResult(NSString *root) {
            gw::git::CommandResult pushed = gw::git::push(root.UTF8String, hasUpstream);
            if (!pushed.ok) {
                return pushed;
            }
            return gw::git::createPullRequest(root.UTF8String, prTitle, prBody);
        } completion:^(gw::git::CommandResult result) {
            [self reportError:result title:@"Couldn't open the pull request"];
            if (result.ok) {
                [self offerToOpenPublishedRepository:result.output];
            }
        }];
    };
    if (_view.window) {
        [alert beginSheetModalForWindow:_view.window completionHandler:proceed];
    } else {
        proceed([alert runModal]);
    }
}

// ---------------------------------------------------------------------------
// MARK: Branches

- (void)branchButtonClicked:(id)sender {
    [self showBranchMenuRelativeToView:_branchButton];
}

- (void)showBranchMenuRelativeToView:(NSView *)view {
    [_repository read:^id(NSString *root) {
        NSMutableArray *branches = [NSMutableArray array];
        for (const gw::git::Branch &branch : gw::git::readBranches(root.UTF8String)) {
            [branches addObject:@{@"name": StringFromUTF8(branch.name), @"current": @(branch.isCurrent), @"remote": @(branch.isRemote)}];
        }
        return branches;
    } completion:^(id result) {
        NSArray<NSDictionary *> *branches = result;
        NSMenu *menu = [NSMenu new];
        NSMenuItem *create = [menu addItemWithTitle:@"Create New Branch…" action:@selector(createBranch) keyEquivalent:@""];
        create.target = self;
        create.image = symbolImage(@"plus", 11);
        [menu addItem:NSMenuItem.separatorItem];

        NSMenu *remoteMenu = [NSMenu new];
        for (NSDictionary *branch in branches) {
            BOOL isRemote = [branch[@"remote"] boolValue];
            NSString *name = branch[@"name"];
            NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:name action:@selector(switchBranchFromMenu:) keyEquivalent:@""];
            item.target = self;
            item.representedObject = name;
            item.state = [branch[@"current"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
            if (isRemote) {
                [remoteMenu addItem:item];
            } else {
                [menu addItem:item];
            }
        }
        if (remoteMenu.numberOfItems > 0) {
            [menu addItem:NSMenuItem.separatorItem];
            NSMenuItem *remotes = [menu addItemWithTitle:@"Remote Branches" action:nil keyEquivalent:@""];
            remotes.submenu = remoteMenu;
        }
        [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSHeight(view.bounds) + 4) inView:view];
    }];
}

- (void)switchBranchFromMenu:(NSMenuItem *)item {
    std::string name = ((NSString *)item.representedObject).UTF8String;
    // A remote branch like "origin/feature" is checked out under its own name.
    size_t slash = name.find('/');
    bool isRemote = slash != std::string::npos && name.rfind("origin/", 0) == 0;
    if (isRemote) {
        name = name.substr(slash + 1);
    }
    [_repository perform:@"Switching branch…" operation:^gw::git::CommandResult(NSString *root) {
        return gw::git::switchBranch(root.UTF8String, name);
    } completion:^(gw::git::CommandResult result) {
        [self reportError:result title:@"Couldn't switch branch"];
    }];
}

- (void)createBranch {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Create a new branch";
    alert.informativeText = @"The new branch starts from where you are now, and you switch to it.";
    NSTextField *name = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 280, 24)];
    name.placeholderString = @"feature/my-change";
    alert.accessoryView = name;
    alert.window.initialFirstResponder = name;
    [alert addButtonWithTitle:@"Create Branch"];
    [alert addButtonWithTitle:@"Cancel"];
    void (^proceed)(NSModalResponse) = ^(NSModalResponse response) {
        NSString *branchName = [name.stringValue stringByReplacingOccurrencesOfString:@" " withString:@"-"];
        if (response != NSAlertFirstButtonReturn || branchName.length == 0) {
            return;
        }
        std::string text = branchName.UTF8String;
        [self->_repository perform:@"Creating branch…" operation:^gw::git::CommandResult(NSString *root) {
            return gw::git::createBranch(root.UTF8String, text);
        } completion:^(gw::git::CommandResult result) {
            [self reportError:result title:@"Couldn't create the branch"];
        }];
    };
    if (_view.window) {
        [alert beginSheetModalForWindow:_view.window completionHandler:proceed];
        [_view.window makeFirstResponder:name];
    } else {
        proceed([alert runModal]);
    }
}

// ---------------------------------------------------------------------------
// MARK: More menu

- (void)refreshClicked:(id)sender {
    [_repository refresh];
    [_repository refreshGitHubState];
}

- (void)moreClicked:(NSButton *)sender {
    const gw::git::Status &status = _repository.status;
    NSMenu *menu = [NSMenu new];
    NSMenuItem *(^add)(NSString *, SEL) = ^NSMenuItem *(NSString *title, SEL action) {
        NSMenuItem *item = [menu addItemWithTitle:title action:action keyEquivalent:@""];
        item.target = self;
        return item;
    };
    add(@"Commit & Push", @selector(menuCommitAndPush:));
    add(@"Amend Last Commit", @selector(menuAmend:)).enabled = status.hasCommits();
    [menu addItem:NSMenuItem.separatorItem];
    add(@"Stage All Changes", @selector(stageAllClicked:));
    add(@"Unstage All Changes", @selector(unstageAllClicked:));
    add(@"Discard All Changes…", @selector(discardAllClicked:));
    [menu addItem:NSMenuItem.separatorItem];
    add(@"Fetch", @selector(menuFetch:));
    add(@"Pull", @selector(menuPull:)).enabled = status.hasRemote;
    add(@"Push", @selector(menuPush:)).enabled = status.hasRemote;
    [menu addItem:NSMenuItem.separatorItem];
    add(@"Create Branch…", @selector(menuCreateBranch:));
    add(@"Open Pull Request…", @selector(menuPullRequest:));
    if (!status.hasRemote) {
        add(@"Publish to GitHub…", @selector(menuPublish:));
    }
    NSString *origin = StringFromUTF8(gw::git::readOriginRepository(status.root));
    if (origin.length > 0) {
        [menu addItem:NSMenuItem.separatorItem];
        NSMenuItem *open = add([NSString stringWithFormat:@"Open %@ on GitHub", origin], @selector(menuOpenOnGitHub:));
        open.representedObject = origin;
    }
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSHeight(sender.bounds) + 4) inView:sender];
}

- (void)menuCommitAndPush:(id)sender {
    [self commitThen:^{
        [self push];
    }];
}
- (void)menuAmend:(id)sender { [self amendLastCommit]; }
- (void)menuFetch:(id)sender { [self fetch]; }
- (void)menuPull:(id)sender { [self pull]; }
- (void)menuPush:(id)sender { [self push]; }
- (void)menuCreateBranch:(id)sender { [self createBranch]; }
- (void)menuPullRequest:(id)sender { [self createPullRequest]; }
- (void)menuPublish:(id)sender { [self publishToGitHub]; }
- (void)menuOpenOnGitHub:(NSMenuItem *)item {
    NSString *address = [@"https://github.com/" stringByAppendingString:item.representedObject];
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:address]];
}

@end
