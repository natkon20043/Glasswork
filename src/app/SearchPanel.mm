#import "SearchPanel.h"

#import "FileIcons.h"

#include "ProjectSearch.hpp"

#include <atomic>
#include <fcntl.h>
#include <mutex>
#include <sys/stat.h>
#include <unistd.h>

// ===========================================================================
// Result model

@interface GWSearchHit : NSObject
@property (nonatomic) NSUInteger line;
@property (nonatomic) NSUInteger column;
@property (nonatomic) NSUInteger length;
@property (nonatomic, copy) NSAttributedString *text;
@property (nonatomic, weak) id file;
@end

@implementation GWSearchHit
@end

@interface GWSearchFile : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *folder;
@property (nonatomic, strong) NSMutableArray<GWSearchHit *> *hits;
@property (nonatomic) NSUInteger matchCount;
@property (nonatomic) BOOL truncated;
@end

@implementation GWSearchFile
@end

/// Where the search threads leave results for the main thread to pick up.
struct ResultBox {
    std::mutex mutex;
    std::vector<gw::search::FileResult> pending;
    bool finished = false;
    gw::search::SearchSummary summary;
};

// ===========================================================================
// Views

@interface GWSearchOptionButton : NSButton
@end

@implementation GWSearchOptionButton

- (instancetype)initWithTitle:(NSString *)title tip:(NSString *)tip {
    self = [super initWithFrame:NSZeroRect];
    if (self) {
        self.title = title;
        self.toolTip = tip;
        self.bordered = NO;
        self.buttonType = NSButtonTypePushOnPushOff;
        self.translatesAutoresizingMaskIntoConstraints = NO;
        [self.widthAnchor constraintEqualToConstant:24].active = YES;
        [self.heightAnchor constraintEqualToConstant:22].active = YES;
    }
    return self;
}

- (void)drawRect:(NSRect)dirtyRect {
    BOOL on = self.state == NSControlStateValueOn;
    if (on) {
        [[NSColor.controlAccentColor colorWithAlphaComponent:0.30] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 1, 1) xRadius:6 yRadius:6] fill];
    }
    NSDictionary *attributes = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: on ? NSColor.labelColor : NSColor.secondaryLabelColor,
    };
    NSSize size = [self.title sizeWithAttributes:attributes];
    [self.title drawAtPoint:NSMakePoint(NSMidX(self.bounds) - size.width / 2, NSMidY(self.bounds) - size.height / 2) withAttributes:attributes];
}

@end

/// The rounded box around an input row.
@interface GWSearchCard : NSView
@end

@implementation GWSearchCard

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.wantsLayer = YES;
        self.layer.cornerRadius = 10;
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
        self.layer.borderColor = [NSColor.labelColor colorWithAlphaComponent:0.12].CGColor;
    }];
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self updateColors];
}

@end

@interface GWSearchRowView : NSTableRowView
@property (nonatomic) BOOL hovering;
@end

@implementation GWSearchRowView {
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

- (void)setHoverState:(BOOL)hovering {
    self.hovering = hovering;
    self.needsDisplay = YES;
    for (NSView *view in self.subviews) {
        if ([view respondsToSelector:@selector(setHovering:)]) {
            [(id)view setHovering:hovering];
        }
    }
}

- (void)mouseEntered:(NSEvent *)event { [self setHoverState:YES]; }
- (void)mouseExited:(NSEvent *)event { [self setHoverState:NO]; }

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

/// A result row cell that shows a "replace" button while the pointer is over it.
@interface GWSearchCell : NSTableCellView
@property (nonatomic, strong) NSButton *replaceButton;
@property (nonatomic, strong) NSTextField *badge;
@end

@implementation GWSearchCell
- (void)setHovering:(BOOL)hovering {
    // The replace button takes the place of the match count while the pointer is over the row.
    _replaceButton.hidden = !hovering;
    _badge.hidden = hovering;
}
@end

// ===========================================================================
// The panel

static NSImage *symbolImage(NSString *name, CGFloat size, NSFontWeight weight = NSFontWeightMedium) {
    NSImageSymbolConfiguration *configuration = [NSImageSymbolConfiguration configurationWithPointSize:size weight:weight];
    return [[NSImage imageWithSystemSymbolName:name accessibilityDescription:nil] imageWithSymbolConfiguration:configuration];
}

@interface GWSearchPanel () <NSTextFieldDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate>
@end

@implementation GWSearchPanel {
    NSView *_view;
    NSTextField *_queryField;
    NSTextField *_replaceField;
    NSTextField *_includeField;
    NSTextField *_excludeField;
    GWSearchOptionButton *_caseButton;
    GWSearchOptionButton *_wordButton;
    GWSearchOptionButton *_regexButton;
    NSView *_replaceCard;
    NSView *_filterStack;
    NSButton *_replaceToggle;
    NSButton *_filterToggle;
    NSTextField *_status;
    NSOutlineView *_outline;
    NSLayoutConstraint *_replaceHeight;
    NSLayoutConstraint *_filterHeight;

    NSMutableArray<GWSearchFile *> *_files;
    std::shared_ptr<gw::search::Matcher> _matcher;
    std::shared_ptr<std::atomic<bool>> _cancel;
    std::shared_ptr<ResultBox> _box;
    NSTimer *_pollTimer;
    NSUInteger _generation;
    NSUInteger _totalLines;
    BOOL _showReplace;
    BOOL _showFilters;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _files = [NSMutableArray array];
        [self buildViews];
    }
    return self;
}

- (NSView *)view { return _view; }

- (void)dealloc {
    if (_cancel) {
        _cancel->store(true);
    }
    [_pollTimer invalidate];
}

// ---------------------------------------------------------------------------
// MARK: Building

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
    NSButton *button = [NSButton buttonWithImage:symbolImage(symbol, 12) target:self action:action];
    button.bordered = NO;
    button.contentTintColor = NSColor.secondaryLabelColor;
    button.toolTip = tip;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button.widthAnchor constraintEqualToConstant:22].active = YES;
    [button.heightAnchor constraintEqualToConstant:22].active = YES;
    return button;
}

- (void)buildViews {
    _view = [NSView new];

    // Header
    NSTextField *title = [NSTextField labelWithString:@""];
    title.attributedStringValue = [[NSAttributedString alloc] initWithString:@"SEARCH" attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:10.5 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: NSColor.tertiaryLabelColor,
        NSKernAttributeName: @1.2,
    }];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    _replaceToggle = [self iconButton:@"arrow.left.arrow.right" tip:@"Replace" action:@selector(toggleReplace:)];
    _filterToggle = [self iconButton:@"line.3.horizontal.decrease" tip:@"Which files" action:@selector(toggleFilters:)];
    NSButton *clear = [self iconButton:@"xmark.circle" tip:@"Clear" action:@selector(clearClicked:)];
    NSView *headerSpacer = [NSView new];
    [headerSpacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *header = [NSStackView stackViewWithViews:@[title, headerSpacer, _replaceToggle, _filterToggle, clear]];
    header.spacing = 2;
    header.translatesAutoresizingMaskIntoConstraints = NO;

    // Query
    GWSearchCard *queryCard = [GWSearchCard new];
    _queryField = [self fieldWithPlaceholder:@"Search"];
    _caseButton = [[GWSearchOptionButton alloc] initWithTitle:@"Aa" tip:@"Match case"];
    _wordButton = [[GWSearchOptionButton alloc] initWithTitle:@"ab" tip:@"Whole word"];
    _regexButton = [[GWSearchOptionButton alloc] initWithTitle:@".*" tip:@"Regular expression"];
    for (GWSearchOptionButton *button in @[_caseButton, _wordButton, _regexButton]) {
        button.target = self;
        button.action = @selector(optionChanged:);
    }
    NSStackView *queryRow = [NSStackView stackViewWithViews:@[_queryField, _caseButton, _wordButton, _regexButton]];
    queryRow.spacing = 2;
    queryRow.translatesAutoresizingMaskIntoConstraints = NO;
    [queryCard addSubview:queryRow];
    [NSLayoutConstraint activateConstraints:@[
        [queryRow.topAnchor constraintEqualToAnchor:queryCard.topAnchor constant:4],
        [queryRow.bottomAnchor constraintEqualToAnchor:queryCard.bottomAnchor constant:-4],
        [queryRow.leadingAnchor constraintEqualToAnchor:queryCard.leadingAnchor constant:8],
        [queryRow.trailingAnchor constraintEqualToAnchor:queryCard.trailingAnchor constant:-4],
    ]];

    // Replace
    GWSearchCard *replaceCard = [GWSearchCard new];
    _replaceCard = replaceCard;
    _replaceField = [self fieldWithPlaceholder:@"Replace"];
    NSButton *replaceAll = [self iconButton:@"arrow.triangle.2.circlepath" tip:@"Replace all" action:@selector(replaceAllClicked:)];
    NSStackView *replaceRow = [NSStackView stackViewWithViews:@[_replaceField, replaceAll]];
    replaceRow.spacing = 2;
    replaceRow.translatesAutoresizingMaskIntoConstraints = NO;
    [replaceCard addSubview:replaceRow];
    [NSLayoutConstraint activateConstraints:@[
        [replaceRow.topAnchor constraintEqualToAnchor:replaceCard.topAnchor constant:4],
        [replaceRow.bottomAnchor constraintEqualToAnchor:replaceCard.bottomAnchor constant:-4],
        [replaceRow.leadingAnchor constraintEqualToAnchor:replaceCard.leadingAnchor constant:8],
        [replaceRow.trailingAnchor constraintEqualToAnchor:replaceCard.trailingAnchor constant:-4],
    ]];
    replaceCard.hidden = YES;

    // Filters
    GWSearchCard *includeCard = [GWSearchCard new];
    _includeField = [self fieldWithPlaceholder:@"Files to include  (*.cpp, src/)"];
    [includeCard addSubview:_includeField];
    GWSearchCard *excludeCard = [GWSearchCard new];
    _excludeField = [self fieldWithPlaceholder:@"Files to skip  (build, *.min.js)"];
    [excludeCard addSubview:_excludeField];
    for (NSArray *pair in @[@[includeCard, _includeField], @[excludeCard, _excludeField]]) {
        NSView *card = pair[0];
        NSView *field = pair[1];
        [NSLayoutConstraint activateConstraints:@[
            [field.topAnchor constraintEqualToAnchor:card.topAnchor constant:4],
            [field.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-4],
            [field.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:8],
            [field.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-8],
        ]];
    }
    NSStackView *filterStack = [NSStackView stackViewWithViews:@[includeCard, excludeCard]];
    filterStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    filterStack.spacing = 6;
    filterStack.alignment = NSLayoutAttributeLeading;
    filterStack.translatesAutoresizingMaskIntoConstraints = NO;
    [includeCard.widthAnchor constraintEqualToAnchor:filterStack.widthAnchor].active = YES;
    [excludeCard.widthAnchor constraintEqualToAnchor:filterStack.widthAnchor].active = YES;
    filterStack.hidden = YES;
    _filterStack = filterStack;

    _status = [NSTextField labelWithString:@""];
    _status.font = [NSFont systemFontOfSize:11.5];
    _status.textColor = NSColor.tertiaryLabelColor;
    _status.lineBreakMode = NSLineBreakByTruncatingTail;
    _status.translatesAutoresizingMaskIntoConstraints = NO;

    // Results
    _outline = [NSOutlineView new];
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"result"];
    [_outline addTableColumn:column];
    _outline.outlineTableColumn = column;
    _outline.headerView = nil;
    _outline.style = NSTableViewStylePlain;
    _outline.backgroundColor = NSColor.clearColor;
    _outline.intercellSpacing = NSMakeSize(0, 0);
    _outline.indentationPerLevel = 0;
    _outline.dataSource = self;
    _outline.delegate = self;
    _outline.target = self;
    _outline.action = @selector(rowClicked:);
    _outline.autoresizesOutlineColumn = NO;

    NSScrollView *scroll = [NSScrollView new];
    scroll.documentView = _outline;
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.scrollerStyle = NSScrollerStyleOverlay;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;

    for (NSView *view in @[header, queryCard, replaceCard, filterStack, _status, scroll]) {
        [_view addSubview:view];
    }
    _replaceHeight = [replaceCard.heightAnchor constraintEqualToConstant:0];
    _filterHeight = [filterStack.heightAnchor constraintEqualToConstant:0];
    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:_view.topAnchor constant:2],
        [header.leadingAnchor constraintEqualToAnchor:_view.leadingAnchor constant:18],
        [header.trailingAnchor constraintEqualToAnchor:_view.trailingAnchor constant:-12],
        [queryCard.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:6],
        [queryCard.leadingAnchor constraintEqualToAnchor:_view.leadingAnchor constant:10],
        [queryCard.trailingAnchor constraintEqualToAnchor:_view.trailingAnchor constant:-10],
        [replaceCard.topAnchor constraintEqualToAnchor:queryCard.bottomAnchor constant:6],
        [replaceCard.leadingAnchor constraintEqualToAnchor:_view.leadingAnchor constant:10],
        [replaceCard.trailingAnchor constraintEqualToAnchor:_view.trailingAnchor constant:-10],
        [filterStack.topAnchor constraintEqualToAnchor:replaceCard.bottomAnchor constant:6],
        [filterStack.leadingAnchor constraintEqualToAnchor:_view.leadingAnchor constant:10],
        [filterStack.trailingAnchor constraintEqualToAnchor:_view.trailingAnchor constant:-10],
        [_status.topAnchor constraintEqualToAnchor:filterStack.bottomAnchor constant:8],
        [_status.leadingAnchor constraintEqualToAnchor:_view.leadingAnchor constant:18],
        [_status.trailingAnchor constraintEqualToAnchor:_view.trailingAnchor constant:-12],
        [scroll.topAnchor constraintEqualToAnchor:_status.bottomAnchor constant:4],
        [scroll.leadingAnchor constraintEqualToAnchor:_view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:_view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:_view.bottomAnchor],
    ]];
    [self applyRowVisibility];
}

/// Hidden rows take no room.
- (void)applyRowVisibility {
    // A hidden row takes no room: it is squeezed to zero height as well as hidden.
    _replaceCard.hidden = !_showReplace;
    _replaceHeight.active = !_showReplace;
    _filterStack.hidden = !_showFilters;
    _filterHeight.active = !_showFilters;
    _replaceToggle.contentTintColor = _showReplace ? NSColor.controlAccentColor : NSColor.secondaryLabelColor;
    _filterToggle.contentTintColor = (_showFilters || _includeField.stringValue.length || _excludeField.stringValue.length)
                                         ? NSColor.controlAccentColor
                                         : NSColor.secondaryLabelColor;
}

- (void)toggleReplace:(id)sender {
    _showReplace = !_showReplace;
    [self applyRowVisibility];
    if (_showReplace) {
        [_view.window makeFirstResponder:_replaceField];
    }
}

- (void)toggleFilters:(id)sender {
    _showFilters = !_showFilters;
    [self applyRowVisibility];
}

- (void)clearClicked:(id)sender {
    _queryField.stringValue = @"";
    [self startSearch];
    [_view.window makeFirstResponder:_queryField];
}

- (void)optionChanged:(id)sender { [self scheduleSearch]; }

// ---------------------------------------------------------------------------
// MARK: Public

- (void)focusWithText:(NSString *)text {
    if (text.length > 0 && ![text containsString:@"\n"]) {
        _queryField.stringValue = text;
        [self startSearch];
    }
    [_view.window makeFirstResponder:_queryField];
    [_queryField selectText:nil];
}

- (void)restrictToFolder:(NSString *)relativeFolder {
    if (relativeFolder.length > 0) {
        _includeField.stringValue = [relativeFolder stringByAppendingString:@"/"];
    } else {
        _includeField.stringValue = @"";
    }
    _showFilters = YES;
    [self applyRowVisibility];
    [self focusWithText:nil];
    [self startSearch];
}

- (void)setRootFolder:(NSString *)rootFolder {
    _rootFolder = [rootFolder copy];
    [self clearResults];
}

- (void)rerun {
    if (_queryField.stringValue.length > 0) {
        [self scheduleSearch];
    }
}

// ---------------------------------------------------------------------------
// MARK: Running a search

- (void)controlTextDidChange:(NSNotification *)notification {
    if (notification.object == _replaceField) {
        return;  // only the search inputs restart the search
    }
    [self scheduleSearch];
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)selector {
    if (selector == @selector(insertNewline:) && control != _replaceField) {
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(startSearch) object:nil];
        [self startSearch];
        return YES;
    }
    return NO;
}

- (void)scheduleSearch {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(startSearch) object:nil];
    [self performSelector:@selector(startSearch) withObject:nil afterDelay:0.12];
}

- (void)cancelRunning {
    if (_cancel) {
        _cancel->store(true);
    }
    [_pollTimer invalidate];
    _pollTimer = nil;
    _box = nullptr;
}

- (void)clearResults {
    [self cancelRunning];
    [_files removeAllObjects];
    _totalLines = 0;
    [_outline reloadData];
    _status.stringValue = @"";
}

- (void)startSearch {
    [self cancelRunning];
    NSString *pattern = _queryField.stringValue;
    [_files removeAllObjects];
    _totalLines = 0;
    [_outline reloadData];
    _status.textColor = NSColor.tertiaryLabelColor;
    _status.toolTip = nil;
    [self applyRowVisibility];

    if (pattern.length == 0 || _rootFolder == nil) {
        _status.stringValue = _rootFolder == nil && pattern.length > 0 ? @"Open a folder to search it." : @"";
        return;
    }

    gw::search::Query query;
    query.pattern = pattern.UTF8String;
    query.caseSensitive = _caseButton.state == NSControlStateValueOn;
    query.wholeWord = _wordButton.state == NSControlStateValueOn;
    query.useRegex = _regexButton.state == NSControlStateValueOn;
    _matcher = std::make_shared<gw::search::Matcher>(query);
    if (!_matcher->valid()) {
        _status.stringValue = [NSString stringWithFormat:@"Not a valid pattern: %s", _matcher->error().c_str()];
        _status.textColor = NSColor.systemRedColor;
        return;
    }
    std::shared_ptr<const std::vector<std::string>> files = self.filesProvider ? self.filesProvider() : nullptr;
    if (!files || files->empty()) {
        _status.stringValue = @"No files to search yet.";
        return;
    }

    _status.stringValue = @"Searching…";
    ++_generation;
    NSUInteger generation = _generation;
    auto cancel = std::make_shared<std::atomic<bool>>(false);
    auto box = std::make_shared<ResultBox>();
    _cancel = cancel;
    _box = box;
    std::shared_ptr<gw::search::Matcher> matcher = _matcher;

    gw::search::SearchOptions options;
    options.root = _rootFolder.UTF8String;
    options.include = _includeField.stringValue.UTF8String;
    options.exclude = _excludeField.stringValue.UTF8String;
    std::string root = options.root;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        gw::search::SearchOptions runOptions;
        runOptions.root = root;
        runOptions.include = options.include;
        runOptions.exclude = options.exclude;
        runOptions.files = *files;
        gw::search::SearchSummary summary = gw::search::searchFiles(runOptions, *matcher, cancel.get(), [&](gw::search::FileResult &&result) {
            std::lock_guard<std::mutex> lock(box->mutex);
            box->pending.push_back(std::move(result));
        });
        {
            std::lock_guard<std::mutex> lock(box->mutex);
            box->finished = true;
            box->summary = summary;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self pollResultsForGeneration:generation];
        });
    });

    _pollTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) {
        [self pollResultsForGeneration:generation];
    }];
}

/// Picks up what the search threads found so far.
- (void)pollResultsForGeneration:(NSUInteger)generation {
    if (generation != _generation || !_box) {
        return;
    }
    std::vector<gw::search::FileResult> fresh;
    bool finished = false;
    gw::search::SearchSummary summary;
    {
        std::lock_guard<std::mutex> lock(_box->mutex);
        fresh.swap(_box->pending);
        finished = _box->finished;
        summary = _box->summary;
    }
    if (!fresh.empty()) {
        [self mergeResults:fresh];
    }
    if (finished) {
        [_pollTimer invalidate];
        _pollTimer = nil;
        [self showSummary:summary];
    } else if (_totalLines > 0) {
        _status.stringValue = [NSString stringWithFormat:@"%lu lines in %lu files…", (unsigned long)_totalLines, (unsigned long)_files.count];
    }
}

- (NSAttributedString *)attributedForHit:(const gw::search::LineHit &)hit {
    NSString *text = @(hit.text.c_str()) ?: @"";
    NSMutableParagraphStyle *oneLine = [NSMutableParagraphStyle new];
    oneLine.lineBreakMode = NSLineBreakByTruncatingTail;
    NSMutableAttributedString *attributed = [[NSMutableAttributedString alloc] initWithString:text attributes:@{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:11.5 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: NSColor.secondaryLabelColor,
        NSParagraphStyleAttributeName: oneLine,
    }];
    // The ranges are in UTF-8 bytes; convert them to positions in the string.
    for (const auto &range : hit.ranges) {
        NSString *before = [[NSString alloc] initWithBytes:hit.text.data() length:range.first encoding:NSUTF8StringEncoding];
        NSString *inside = [[NSString alloc] initWithBytes:hit.text.data() + range.first length:range.second encoding:NSUTF8StringEncoding];
        if (before == nil || inside == nil) {
            continue;
        }
        NSRange characters = NSMakeRange(before.length, inside.length);
        if (NSMaxRange(characters) <= attributed.length) {
            [attributed addAttributes:@{
                NSForegroundColorAttributeName: NSColor.labelColor,
                NSBackgroundColorAttributeName: [NSColor.controlAccentColor colorWithAlphaComponent:0.38],
            } range:characters];
        }
    }
    return attributed;
}

- (void)mergeResults:(std::vector<gw::search::FileResult> &)results {
    for (gw::search::FileResult &result : results) {
        GWSearchFile *file = [GWSearchFile new];
        file.path = @(result.path.c_str());
        file.name = file.path.lastPathComponent;
        file.folder = file.path.stringByDeletingLastPathComponent;
        file.matchCount = result.matchCount;
        file.truncated = result.truncated;
        file.hits = [NSMutableArray array];
        for (const gw::search::LineHit &hit : result.hits) {
            GWSearchHit *node = [GWSearchHit new];
            node.line = hit.line;
            node.column = hit.column;
            node.length = hit.ranges.empty() ? 0 : hit.ranges.front().second;
            node.text = [self attributedForHit:hit];
            node.file = file;
            [file.hits addObject:node];
        }
        _totalLines += result.matchCount;
        [_files addObject:file];
    }
    [_files sortUsingComparator:^NSComparisonResult(GWSearchFile *a, GWSearchFile *b) {
        return [a.path localizedStandardCompare:b.path];
    }];
    [_outline reloadData];
    if (_totalLines < 400) {
        [_outline expandItem:nil expandChildren:YES];
    }
}

- (void)showSummary:(const gw::search::SearchSummary &)summary {
    if (_files.count == 0) {
        _status.stringValue = @"No results";
        return;
    }
    NSString *lines = _totalLines == 1 ? @"1 line" : [NSString stringWithFormat:@"%lu lines", (unsigned long)_totalLines];
    NSString *files = _files.count == 1 ? @"1 file" : [NSString stringWithFormat:@"%lu files", (unsigned long)_files.count];
    NSString *text = [NSString stringWithFormat:@"%@ in %@", lines, files];
    if (summary.stoppedEarly) {
        text = [text stringByAppendingString:@"  ·  showing the first ones"];
    } else {
        text = [text stringByAppendingFormat:@"  ·  %.0f ms", summary.seconds * 1000];
    }
    _status.stringValue = text;
}

// ---------------------------------------------------------------------------
// MARK: Outline

- (NSInteger)outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(id)item {
    if (item == nil) {
        return static_cast<NSInteger>(_files.count);
    }
    if ([item isKindOfClass:GWSearchFile.class]) {
        return static_cast<NSInteger>(((GWSearchFile *)item).hits.count);
    }
    return 0;
}

- (id)outlineView:(NSOutlineView *)outlineView child:(NSInteger)index ofItem:(id)item {
    if (item == nil) {
        return _files[static_cast<NSUInteger>(index)];
    }
    return ((GWSearchFile *)item).hits[static_cast<NSUInteger>(index)];
}

- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(id)item {
    return [item isKindOfClass:GWSearchFile.class];
}

- (CGFloat)outlineView:(NSOutlineView *)outlineView heightOfRowByItem:(id)item {
    return [item isKindOfClass:GWSearchFile.class] ? 26 : 22;
}

- (NSTableRowView *)outlineView:(NSOutlineView *)outlineView rowViewForItem:(id)item {
    return [GWSearchRowView new];
}

- (NSView *)outlineView:(NSOutlineView *)outlineView viewForTableColumn:(NSTableColumn *)tableColumn item:(id)item {
    if ([item isKindOfClass:GWSearchFile.class]) {
        return [self fileCellFor:item];
    }
    return [self hitCellFor:item];
}

- (NSView *)fileCellFor:(GWSearchFile *)file {
    GWSearchCell *cell = [GWSearchCell new];
    NSImageView *icon = [NSImageView imageViewWithImage:symbolImage(GWSymbolForFile(file.name), 12)];
    icon.contentTintColor = GWColorForFile(file.name);
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    NSTextField *name = [NSTextField labelWithString:file.name];
    name.font = [NSFont systemFontOfSize:12.5 weight:NSFontWeightMedium];
    name.lineBreakMode = NSLineBreakByTruncatingMiddle;
    name.translatesAutoresizingMaskIntoConstraints = NO;
    [name setContentCompressionResistancePriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSTextField *folder = [NSTextField labelWithString:file.folder];
    folder.font = [NSFont systemFontOfSize:11];
    folder.textColor = NSColor.tertiaryLabelColor;
    folder.lineBreakMode = NSLineBreakByTruncatingHead;
    folder.translatesAutoresizingMaskIntoConstraints = NO;
    [folder setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSTextField *count = [NSTextField labelWithString:[NSString stringWithFormat:@"%lu", (unsigned long)file.matchCount]];
    count.font = [NSFont monospacedDigitSystemFontOfSize:10.5 weight:NSFontWeightSemibold];
    count.textColor = NSColor.secondaryLabelColor;
    count.alignment = NSTextAlignmentCenter;
    count.translatesAutoresizingMaskIntoConstraints = NO;
    cell.badge = count;
    NSButton *replace = [self iconButton:@"arrow.triangle.2.circlepath" tip:@"Replace in this file" action:@selector(replaceFileClicked:)];
    replace.hidden = YES;
    cell.replaceButton = replace;

    for (NSView *view in @[icon, name, folder, count, replace]) {
        [cell addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:12],
        [icon.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:16],
        [name.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:6],
        [name.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        [folder.leadingAnchor constraintEqualToAnchor:name.trailingAnchor constant:6],
        [folder.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        [count.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-12],
        [count.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        [count.widthAnchor constraintGreaterThanOrEqualToConstant:18],
        [folder.trailingAnchor constraintLessThanOrEqualToAnchor:count.leadingAnchor constant:-8],
        [replace.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-8],
        [replace.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
    ]];
    return cell;
}

- (NSView *)hitCellFor:(GWSearchHit *)hit {
    GWSearchCell *cell = [GWSearchCell new];
    NSTextField *number = [NSTextField labelWithString:[NSString stringWithFormat:@"%lu", (unsigned long)hit.line + 1]];
    number.font = [NSFont monospacedDigitSystemFontOfSize:10.5 weight:NSFontWeightRegular];
    number.textColor = NSColor.tertiaryLabelColor;
    number.alignment = NSTextAlignmentRight;
    number.translatesAutoresizingMaskIntoConstraints = NO;
    NSTextField *text = [NSTextField labelWithString:@""];
    text.attributedStringValue = hit.text;
    text.lineBreakMode = NSLineBreakByTruncatingTail;
    text.maximumNumberOfLines = 1;
    text.cell.usesSingleLineMode = YES;
    text.translatesAutoresizingMaskIntoConstraints = NO;
    [text setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSButton *replace = [self iconButton:@"arrow.triangle.2.circlepath" tip:@"Replace on this line" action:@selector(replaceHitClicked:)];
    replace.hidden = YES;
    cell.replaceButton = replace;

    for (NSView *view in @[number, text, replace]) {
        [cell addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [number.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:10],
        [number.widthAnchor constraintEqualToConstant:32],
        [number.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        [text.leadingAnchor constraintEqualToAnchor:number.trailingAnchor constant:8],
        [text.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-8],
        [text.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        [replace.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-8],
        [replace.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
    ]];
    return cell;
}

- (void)rowClicked:(id)sender {
    id item = [_outline itemAtRow:_outline.clickedRow];
    if (item == nil) {
        return;
    }
    if ([item isKindOfClass:GWSearchFile.class]) {
        if ([_outline isItemExpanded:item]) {
            [_outline collapseItem:item];
        } else {
            [_outline expandItem:item];
        }
        return;
    }
    GWSearchHit *hit = item;
    GWSearchFile *file = hit.file;
    if (self.onOpenHit && file != nil) {
        self.onOpenHit(file.path, hit.line, hit.column, hit.length);
    }
}

// ---------------------------------------------------------------------------
// MARK: Replacing

- (id)itemForButton:(NSView *)button {
    NSInteger row = [_outline rowForView:button];
    return row >= 0 ? [_outline itemAtRow:row] : nil;
}

- (void)replaceFileClicked:(NSButton *)sender {
    GWSearchFile *file = [self itemForButton:sender];
    if (file != nil) {
        [self replaceInFiles:@[file] onlyLine:NSNotFound];
    }
}

- (void)replaceHitClicked:(NSButton *)sender {
    GWSearchHit *hit = [self itemForButton:sender];
    GWSearchFile *file = hit.file;
    if (hit != nil && file != nil) {
        [self replaceInFiles:@[file] onlyLine:hit.line];
    }
}

- (void)replaceAllClicked:(id)sender {
    if (_files.count == 0) {
        NSBeep();
        return;
    }
    NSString *replacement = _replaceField.stringValue;
    NSAlert *alert = [NSAlert new];
    alert.messageText = [NSString stringWithFormat:@"Replace %lu lines in %lu files?", (unsigned long)_totalLines, (unsigned long)_files.count];
    alert.informativeText = replacement.length > 0 ? [NSString stringWithFormat:@"Every match of “%@” becomes “%@”. Files with unsaved changes in the editor are skipped.", _queryField.stringValue, replacement]
                                                   : [NSString stringWithFormat:@"Every match of “%@” is deleted. Files with unsaved changes in the editor are skipped.", _queryField.stringValue];
    [alert addButtonWithTitle:@"Replace All"];
    [alert addButtonWithTitle:@"Cancel"];
    NSArray<GWSearchFile *> *files = [_files copy];
    void (^proceed)(NSModalResponse) = ^(NSModalResponse response) {
        if (response == NSAlertFirstButtonReturn) {
            [self replaceInFiles:files onlyLine:NSNotFound];
        }
    };
    if (_view.window) {
        [alert beginSheetModalForWindow:_view.window completionHandler:proceed];
    } else {
        proceed([alert runModal]);
    }
}

/// Rewrites files on disk, one at a time, keeping a file's permissions. With `onlyLine`,
/// only the matches on that line change.
- (void)replaceInFiles:(NSArray<GWSearchFile *> *)files onlyLine:(NSUInteger)onlyLine {
    if (!_matcher || _rootFolder == nil) {
        return;
    }
    std::shared_ptr<gw::search::Matcher> matcher = _matcher;
    std::string replacement = _replaceField.stringValue.UTF8String ?: "";
    NSString *root = _rootFolder;
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSMutableArray<NSString *> *skipped = [NSMutableArray array];
    for (GWSearchFile *file in files) {
        NSString *absolute = [root stringByAppendingPathComponent:file.path];
        if (self.isFileDirty && self.isFileDirty(absolute)) {
            [skipped addObject:file.path];
        } else {
            [paths addObject:file.path];
        }
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray<NSString *> *changed = [NSMutableArray array];
        NSMutableArray<NSString *> *failed = [NSMutableArray array];
        for (NSString *relative in paths) {
            NSString *absolute = [root stringByAppendingPathComponent:relative];
            NSData *data = [NSData dataWithContentsOfFile:absolute];
            if (data == nil) {
                [failed addObject:relative];
                continue;
            }
            std::string text(static_cast<const char *>(data.bytes), data.length);
            std::string replaced;
            size_t count = 0;
            if (onlyLine == NSNotFound) {
                replaced = matcher->replaceAll(text, replacement, &count);
            } else {
                // Only one line: split, replace inside it, put it back.
                replaced.reserve(text.size());
                size_t lineStart = 0;
                size_t lineNumber = 0;
                while (lineStart <= text.size()) {
                    size_t newline = text.find('\n', lineStart);
                    size_t lineEnd = newline == std::string::npos ? text.size() : newline;
                    std::string line = text.substr(lineStart, lineEnd - lineStart);
                    if (lineNumber == onlyLine) {
                        size_t lineCount = 0;
                        line = matcher->replaceAll(line, replacement, &lineCount);
                        count += lineCount;
                    }
                    replaced += line;
                    if (newline == std::string::npos) {
                        break;
                    }
                    replaced += '\n';
                    lineStart = newline + 1;
                    ++lineNumber;
                }
            }
            if (count == 0 || replaced == text) {
                continue;
            }
            // Write beside the file and swap it in, so a failure never damages the original.
            struct stat info;
            stat(absolute.fileSystemRepresentation, &info);
            NSString *temporary = [absolute stringByAppendingString:@".glasswork-replace"];
            NSData *output = [NSData dataWithBytes:replaced.data() length:replaced.size()];
            if (![output writeToFile:temporary atomically:NO]) {
                [failed addObject:relative];
                continue;
            }
            chmod(temporary.fileSystemRepresentation, info.st_mode & 07777);
            if (rename(temporary.fileSystemRepresentation, absolute.fileSystemRepresentation) != 0) {
                unlink(temporary.fileSystemRepresentation);
                [failed addObject:relative];
                continue;
            }
            [changed addObject:absolute];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.onFilesChanged && changed.count > 0) {
                self.onFilesChanged(changed);
            }
            [self startSearch];
            NSMutableArray<NSString *> *problems = [NSMutableArray array];
            if (skipped.count > 0) {
                [problems addObject:[NSString stringWithFormat:@"Skipped because they have unsaved changes: %@", [skipped componentsJoinedByString:@", "]]];
            }
            if (failed.count > 0) {
                [problems addObject:[NSString stringWithFormat:@"Couldn't rewrite: %@", [failed componentsJoinedByString:@", "]]];
            }
            if (problems.count > 0 && self.onError) {
                self.onError(@"Some files weren't changed", [problems componentsJoinedByString:@"\n\n"]);
            }
        });
    });
}

@end
