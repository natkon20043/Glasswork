#import "MainWindow.h"

#import "ChangePopover.h"
#import "ChatPanel.h"
#import "ColorInspector.h"
#import "EditorView.h"
#import "FileIcons.h"
#import "FileTree.h"
#import "FindBar.h"
#import "FolderWatcher.h"
#import "GitRepository.h"
#import "Palette.h"
#import "SearchPanel.h"
#import "Services.h"
#import "LanguageService.h"
#import "CompletionPopup.h"
#import "SidebarSwitcher.h"
#import "SourceControlPanel.h"
#import "StartupTiming.h"
#import "TabBar.h"
#import "TerminalPanel.h"

#import <QuartzCore/QuartzCore.h>

#include "Document.hpp"
#include "Fuzzy.hpp"
#include "Highlighter.hpp"
#include "LanguageServer.hpp"
#include "LineDiff.hpp"
#include "Sections.hpp"

#include <algorithm>
#include <chrono>
#include <fstream>
#include <memory>
#include <vector>

namespace {

struct Tab {
    /// Never reused, so a background result can find out whether its tab still exists.
    uint64_t identifier = 0;
    std::unique_ptr<gw::Document> document;
    std::unique_ptr<gw::Highlighter> highlighter;
    gw::LanguageConfiguration configuration;
    NSPoint scroll = NSZeroPoint;

    /// Read-only tabs made by the app (a diff, a commit). `key` finds one again to refresh it.
    bool isVirtual = false;
    std::string realPath;  // the path with symbolic links resolved, to match file system events
    std::string key;
    std::string forcedLanguage;
    std::vector<gw::Color> lineTints;

    // How this file differs from the last commit, for the change bars in the gutter.
    std::shared_ptr<const std::string> headText;
    bool headLoaded = false;
    std::string headCommit;
    std::vector<gw::DiffHunk> hunks;
    std::vector<gw::LineChange> changes;
};

/// Colours for the lines of a unified diff: green for added, red for removed.
std::vector<gw::Color> tintsForDiff(const std::string &text) {
    std::vector<gw::Color> tints;
    const gw::Color added = 0x3FB95030;
    const gw::Color removed = 0xF8514930;
    const gw::Color hunk = 0x58A6FF1E;
    const gw::Color header = 0xFFFFFF0C;
    size_t start = 0;
    while (start <= text.size()) {
        size_t end = text.find('\n', start);
        if (end == std::string::npos) {
            end = text.size();
        }
        std::string_view line(text.data() + start, end - start);
        gw::Color color = 0;
        if (line.rfind("+++", 0) == 0 || line.rfind("---", 0) == 0 || line.rfind("diff ", 0) == 0 || line.rfind("index ", 0) == 0) {
            color = header;
        } else if (line.rfind("@@", 0) == 0) {
            color = hunk;
        } else if (!line.empty() && line[0] == '+') {
            color = added;
        } else if (!line.empty() && line[0] == '-') {
            color = removed;
        }
        tints.push_back(color);
        if (end == text.size()) {
            break;
        }
        start = end + 1;
    }
    return tints;
}

constexpr CGFloat kMargin = 8;
constexpr CGFloat kSidebarWidth = 250;
constexpr CGFloat kTabBarHeight = 38;
constexpr CGFloat kStatusHeight = 28;
constexpr CGFloat kBreadcrumbHeight = 30;
constexpr CGFloat kMinimapWidth = 92;

/// The project's files, with where each name starts (for matching names above folders).
struct FileIndex {
    std::vector<std::string> paths;
    std::vector<size_t> nameStarts;
};

/// True if the file looks binary (has a NUL byte near the start), which the editor can't show.
bool looksBinary(const char *path) {
    std::ifstream file(path, std::ios::binary);
    char buffer[8192];
    file.read(buffer, sizeof buffer);
    std::streamsize count = file.gcount();
    for (std::streamsize index = 0; index < count; ++index) {
        if (buffer[index] == '\0') return true;
    }
    return false;
}

}  // namespace

// MARK: - Aurora

/// Soft washes of the theme's accent colours behind all the glass, so colour and light
/// come through the panels. Static layers: they cost nothing once drawn.
@interface GWAuroraView : NSView
- (void)setColors:(NSArray<NSColor *> *)colors strength:(CGFloat)strength;
@end

@implementation GWAuroraView {
    NSArray<CAGradientLayer *> *_blobs;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        NSMutableArray *blobs = [NSMutableArray array];
        for (int index = 0; index < 3; ++index) {
            CAGradientLayer *blob = [CAGradientLayer layer];
            blob.type = kCAGradientLayerRadial;
            blob.startPoint = CGPointMake(0.5, 0.5);
            blob.endPoint = CGPointMake(1, 1);
            [self.layer addSublayer:blob];
            [blobs addObject:blob];
        }
        _blobs = blobs;
    }
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)setColors:(NSArray<NSColor *> *)colors strength:(CGFloat)strength {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (NSUInteger index = 0; index < _blobs.count; ++index) {
        NSColor *color = colors[index % colors.count];
        _blobs[index].colors = @[(id)[color colorWithAlphaComponent:strength].CGColor, (id)[color colorWithAlphaComponent:0].CGColor];
    }
    [CATransaction commit];
}

- (void)layout {
    [super layout];
    CGFloat width = NSWidth(self.bounds), height = NSHeight(self.bounds);
    CGFloat size = std::max(width, height);
    // Top-left under the sidebar, lower right, and a softer one mid-right.
    CGRect frames[] = {
        CGRectMake(-size * 0.35, -size * 0.40, size * 0.95, size * 0.95),
        CGRectMake(width - size * 0.55, height - size * 0.50, size * 0.95, size * 0.95),
        CGRectMake(width * 0.45, -size * 0.30, size * 0.70, size * 0.70),
    };
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (NSUInteger index = 0; index < _blobs.count; ++index) _blobs[index].frame = frames[index];
    [CATransaction commit];
}

@end

// MARK: - Editor card

/// The rounded card holding the breadcrumb bar, the code and the minimap.
@interface GWEditorCard : NSView
@property (nonatomic, weak) GWEditorView *editor;
@property (nonatomic, strong) NSView *breadcrumbBar;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) NSView *minimap;
@property (nonatomic, strong) GWFindBar *findBar;
@end

@implementation GWEditorCard

- (BOOL)isFlipped { return YES; }

/// Where the zoom (green) button ends, in this view's coordinates.
- (CGFloat)rightEdgeOfWindowButtons {
    NSButton *zoom = [self.window standardWindowButton:NSWindowZoomButton];
    if (!zoom || !zoom.superview) {
        return 90;  // a sensible guess before the window is on screen
    }
    NSRect frame = [self convertRect:zoom.bounds fromView:zoom];
    return NSMaxX(frame);
}

- (void)layout {
    [super layout];
    CGFloat width = NSWidth(self.bounds), height = NSHeight(self.bounds);
    self.breadcrumbBar.frame = NSMakeRect(0, 0, width, kBreadcrumbHeight);
    CGFloat top = kBreadcrumbHeight;
    CGFloat gutter = self.editor.gutterWidth;
    BOOL showMinimap = GWServices.shared.settings.showMinimap;
    CGFloat minimapWidth = showMinimap ? kMinimapWidth : 0;
    self.minimap.hidden = !showMinimap;

    self.editor.gutterView.frame = NSMakeRect(0, top, gutter, height - top);
    self.scrollView.frame = NSMakeRect(gutter, top, width - minimapWidth - gutter, height - top);
    self.minimap.frame = NSMakeRect(width - kMinimapWidth, top + 4, kMinimapWidth - 6, height - top - 8);

    // The find bar floats over the top right of the code.
    CGFloat barWidth = MIN(500, width - 40);
    CGFloat barHeight = self.findBar.preferredHeight;
    self.findBar.frame = NSMakeRect(width - minimapWidth - barWidth - 16, top + 8, barWidth, barHeight);
}

@end

// MARK: - Resize handles

/// A thin strip between panels that you drag to resize one of them.
@interface GWSplitHandle : NSView
/// YES for a strip you drag left and right, NO for up and down.
@property (nonatomic) BOOL horizontal;
/// Called while dragging, with how far the pointer moved since the last call.
@property (nonatomic, copy) void (^onDrag)(CGFloat delta);
@property (nonatomic, copy) void (^onFinish)(void);
@end

@implementation GWSplitHandle {
    BOOL _hovered;
}

- (void)resetCursorRects {
    [self addCursorRect:self.bounds cursor:self.horizontal ? NSCursor.resizeLeftRightCursor : NSCursor.resizeUpDownCursor];
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

- (void)mouseEntered:(NSEvent *)event { _hovered = YES; self.needsDisplay = YES; }
- (void)mouseExited:(NSEvent *)event { _hovered = NO; self.needsDisplay = YES; }

- (void)drawRect:(NSRect)dirtyRect {
    if (!_hovered) {
        return;
    }
    // A short rounded grip in the middle, to show it can be dragged.
    NSRect grip = self.horizontal ? NSMakeRect(NSMidX(self.bounds) - 1.5, NSMidY(self.bounds) - 22, 3, 44)
                                  : NSMakeRect(NSMidX(self.bounds) - 22, NSMidY(self.bounds) - 1.5, 44, 3);
    [[NSColor.labelColor colorWithAlphaComponent:0.35] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:grip xRadius:1.5 yRadius:1.5] fill];
}

- (void)mouseDown:(NSEvent *)event {
    while (true) {
        NSEvent *next = [self.window nextEventMatchingMask:NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp
                                                 untilDate:NSDate.distantFuture
                                                    inMode:NSEventTrackingRunLoopMode
                                                   dequeue:YES];
        if (next.type == NSEventTypeLeftMouseUp) {
            break;
        }
        if (self.onDrag) {
            self.onDrag(self.horizontal ? next.deltaX : next.deltaY);
        }
    }
    if (self.onFinish) {
        self.onFinish();
    }
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }

@end

// MARK: - Root layout

/// Lays out the glass panels. Flipped so frames read top-down.
@interface GWRootView : NSView
@property (nonatomic, strong) NSVisualEffectView *backdrop;
@property (nonatomic, strong) GWAuroraView *aurora;
@property (nonatomic, strong) NSGlassEffectView *sidebar;
@property (nonatomic, strong) NSGlassEffectView *tabs;
@property (nonatomic, strong) NSGlassEffectView *status;
@property (nonatomic, strong) NSGlassEffectView *editorCard;
@property (nonatomic, strong) NSView *editorContent;  // above editorCard, same frame
@property (nonatomic, strong) NSGlassEffectView *welcome;
@property (nonatomic) BOOL sidebarVisible;
/// The chat column on the right, full height.
@property (nonatomic, strong) NSGlassEffectView *chat;
@property (nonatomic) BOOL chatVisible;
@property (nonatomic) CGFloat chatWidth;
/// The terminal, between the editor and the status bar.
@property (nonatomic, strong) NSGlassEffectView *bottom;
@property (nonatomic) BOOL bottomVisible;
@property (nonatomic) CGFloat bottomHeight;
/// Thin strips you drag to resize the chat and the terminal.
@property (nonatomic, strong) NSView *chatHandle;
@property (nonatomic, strong) NSView *bottomHandle;
@end

@implementation GWRootView

- (BOOL)isFlipped { return YES; }

/// Where the zoom (green) button ends, in this view's coordinates.
- (CGFloat)rightEdgeOfWindowButtons {
    NSButton *zoom = [self.window standardWindowButton:NSWindowZoomButton];
    if (!zoom || !zoom.superview) {
        return 90;  // a sensible guess before the window is on screen
    }
    NSRect frame = [self convertRect:zoom.bounds fromView:zoom];
    return NSMaxX(frame);
}

- (void)layout {
    [super layout];
    NSRect bounds = self.bounds;
    CGFloat width = NSWidth(bounds), height = NSHeight(bounds);
    self.backdrop.frame = bounds;
    self.aurora.frame = bounds;

    self.sidebar.hidden = !self.sidebarVisible;
    self.sidebar.frame = NSMakeRect(kMargin, kMargin, kSidebarWidth, height - 2 * kMargin);
    // Without the sidebar, leave room for the window buttons.
    CGFloat left = NSMaxX(self.sidebar.frame) + kMargin;
    if (!self.sidebarVisible) {
        left = [self rightEdgeOfWindowButtons] + 14;
    }
    // The chat takes a full-height column on the right.
    CGFloat rightEdge = width - kMargin;
    self.chat.hidden = !self.chatVisible;
    self.chatHandle.hidden = !self.chatVisible;
    if (self.chatVisible) {
        CGFloat chatWidth = MAX(300, MIN(self.chatWidth, width - left - 380));
        self.chat.frame = NSMakeRect(width - kMargin - chatWidth, kMargin, chatWidth, height - 2 * kMargin);
        self.chatHandle.frame = NSMakeRect(NSMinX(self.chat.frame) - kMargin, kMargin + 40, kMargin, height - 2 * kMargin - 80);
        rightEdge = NSMinX(self.chat.frame) - kMargin;
    }
    CGFloat contentWidth = rightEdge - left;

    self.tabs.frame = NSMakeRect(left, kMargin, contentWidth, kTabBarHeight);
    self.status.frame = NSMakeRect(left, height - kMargin - kStatusHeight, contentWidth, kStatusHeight);
    CGFloat top = NSMaxY(self.tabs.frame) + kMargin;

    // The terminal sits between the editor and the status bar.
    CGFloat cardBottom = NSMinY(self.status.frame) - kMargin;
    self.bottom.hidden = !self.bottomVisible;
    self.bottomHandle.hidden = !self.bottomVisible;
    if (self.bottomVisible) {
        CGFloat available = cardBottom - top;
        CGFloat bottomHeight = MAX(120, MIN(self.bottomHeight, available - 160));
        self.bottom.frame = NSMakeRect(left, cardBottom - bottomHeight, contentWidth, bottomHeight);
        self.bottomHandle.frame = NSMakeRect(left + 40, NSMinY(self.bottom.frame) - kMargin, contentWidth - 80, kMargin);
        cardBottom = NSMinY(self.bottom.frame) - kMargin;
    }
    NSRect card = NSMakeRect(left, top, contentWidth, cardBottom - top);
    self.editorCard.frame = card;
    self.editorContent.frame = card;
    self.editorContent.hidden = self.editorCard.hidden;

    NSSize welcome = self.welcome.fittingSize;
    welcome.width = std::max(welcome.width, 460.0);
    self.welcome.frame = NSMakeRect(std::round(NSMidX(card) - welcome.width / 2), std::round(NSMidY(card) - welcome.height / 2 - 20),
                                    welcome.width, welcome.height);
}

@end

// MARK: - Window controller

@implementation GWMainWindowController {
    GWRootView *_root;
    GWEditorCard *_card;
    GWEditorView *_editorView;
    GWTabBar *_tabBar;
    GWFileTree *_fileTree;
    NSTextField *_sidebarTitle;
    NSButton *_openFolderButton;
    NSTextField *_breadcrumb;
    NSTextField *_statusLeft;
    NSTextField *_statusRight;
    NSStackView *_recentList;
    std::vector<std::unique_ptr<Tab>> _tabs;
    NSInteger _selected;

    // Every file in the open folder, relative to it, for quick open (⌘P) and search. A new
    // snapshot replaces the old one when the folder changes, so a running search keeps its own.
    std::shared_ptr<const FileIndex> _fileIndex;
    NSUInteger _indexGeneration;          // ignores results from an older folder's scan
    // Language servers: problems, hover, completion, rename, format.
    GWLanguageService *_language;
    GWSuggestionPopup *_suggestions;
    NSUInteger _hoverToken;
    NSUInteger _suggestionToken;
    gw::Position _suggestionWordStart;

    // Sidebar modes: files, source control, search.
    GWSidebarSwitcher *_switcher;
    NSView *_sidebarContainer;
    NSView *_filesPanel;
    NSInteger _sidebarMode;

    // Git
    GWGitRepository *_git;
    GWSourceControlPanel *_sourceControl;
    NSButton *_branchChip;
    GWFolderWatcher *_watcher;
    GWChatPanel *_chat;
    NSButton *_claudeChip;
    GWSearchPanel *_search;
    GWFindBar *_findBar;
    GWTerminalPanel *_terminal;
    BOOL _secondaryPanelsBuilt;
    uint64_t _nextTabIdentifier;
    NSUInteger _indexRebuildToken;
}

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1240, 800)
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                             NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable |
                                                             NSWindowStyleMaskFullSizeContentView
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    if ((self = [super initWithWindow:window])) {
        _selected = -1;
        window.titlebarAppearsTransparent = YES;
        window.titleVisibility = NSWindowTitleHidden;
        window.opaque = NO;
        window.backgroundColor = NSColor.clearColor;
        window.movableByWindowBackground = YES;  // drag from any empty glass
        window.minSize = NSMakeSize(720, 460);
        window.tabbingMode = NSWindowTabbingModeDisallowed;
        window.delegate = self;
        window.title = @"Glasswork";

        // An empty unified toolbar makes the title bar taller, which moves the close,
        // minimise and zoom buttons down and in so they sit inside the sidebar's rounded
        // glass corner instead of straddling its top edge. The toolbar itself draws nothing.
        NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:@"GlassworkToolbar"];
        window.toolbar = toolbar;
        window.toolbarStyle = NSWindowToolbarStyleUnified;
        window.titlebarSeparatorStyle = NSTitlebarSeparatorStyleNone;

        GWStartupMark(@"  window and toolbar created");
        [self buildInterface];
        [self setUpLanguageService];
        GWStartupMark(@"  interface built");
        [window center];
        [window setFrameAutosaveName:@"GlassworkMainWindow"];
        GWStartupMark(@"  window placed");

        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserver:self selector:@selector(themeChanged:) name:GWThemeDidChangeNotification object:nil];
        [center addObserver:self selector:@selector(themeChanged:) name:GWEditorSettingsDidChangeNotification object:nil];
        [center addObserver:self selector:@selector(extensionsChanged:) name:GWExtensionsDidChangeNotification object:nil];
        [center addObserver:self selector:@selector(gitStatusChanged:) name:GWGitStatusDidChangeNotification object:_git];
        [center addObserver:self selector:@selector(applicationBecameActive:) name:NSApplicationDidBecomeActiveNotification object:nil];
        [self applyTheme];
        GWStartupMark(@"  theme applied");
        [self refresh];
        GWStartupMark(@"  refreshed");

        // The panels that start hidden are built just after the window first appears.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self buildSecondaryPanels];
        });
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

// MARK: Interface

- (NSGlassEffectView *)glassWithCornerRadius:(CGFloat)radius content:(NSView *)content {
    NSGlassEffectView *glass = [NSGlassEffectView new];
    glass.cornerRadius = radius;
    glass.style = NSGlassEffectViewStyleRegular;
    glass.contentView = content;
    return glass;
}

- (NSTextField *)label:(NSString *)text size:(CGFloat)size weight:(NSFontWeight)weight secondary:(BOOL)secondary {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = [NSFont systemFontOfSize:size weight:weight];
    label.textColor = secondary ? NSColor.secondaryLabelColor : NSColor.labelColor;
    return label;
}

- (void)buildInterface {
    _root = [GWRootView new];
    _root.sidebarVisible = YES;
    __weak GWMainWindowController *weakSelf = self;

    // See-through frosted backdrop, then the aurora glow on top of it.
    NSVisualEffectView *backdrop = [NSVisualEffectView new];
    backdrop.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    backdrop.material = NSVisualEffectMaterialUnderWindowBackground;
    backdrop.state = NSVisualEffectStateActive;
    _root.backdrop = backdrop;
    [_root addSubview:backdrop];
    _root.aurora = [GWAuroraView new];
    [_root addSubview:_root.aurora];

    GWStartupMark(@"  built: backdrop and aurora");
    // Editor card: breadcrumbs, code and minimap on glass.
    _card = [GWEditorCard new];
    _card.wantsLayer = YES;
    _card.layer.cornerRadius = 20;
    _card.layer.cornerCurve = kCACornerCurveContinuous;
    _card.layer.masksToBounds = YES;

    NSView *breadcrumbBar = [NSView new];
    _breadcrumb = [self label:@"" size:12 weight:NSFontWeightMedium secondary:YES];
    _breadcrumb.lineBreakMode = NSLineBreakByTruncatingHead;
    _breadcrumb.translatesAutoresizingMaskIntoConstraints = NO;
    [breadcrumbBar addSubview:_breadcrumb];
    [NSLayoutConstraint activateConstraints:@[
        [_breadcrumb.leadingAnchor constraintEqualToAnchor:breadcrumbBar.leadingAnchor constant:16],
        [_breadcrumb.trailingAnchor constraintLessThanOrEqualToAnchor:breadcrumbBar.trailingAnchor constant:-16],
        [_breadcrumb.centerYAnchor constraintEqualToAnchor:breadcrumbBar.centerYAnchor constant:1],
    ]];
    _card.breadcrumbBar = breadcrumbBar;
    [_card addSubview:breadcrumbBar];

    NSScrollView *scroll = [NSScrollView new];
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = YES;
    scroll.hasHorizontalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.scrollerStyle = NSScrollerStyleOverlay;
    scroll.automaticallyAdjustsContentInsets = NO;
    scroll.contentView.drawsBackground = NO;
    scroll.borderType = NSNoBorder;
    _editorView = [[GWEditorView alloc] initWithFrame:NSMakeRect(0, 0, 400, 400)];
    scroll.documentView = _editorView;
    _card.scrollView = scroll;
    [_card addSubview:scroll];
    _card.minimap = _editorView.minimapView;
    [_card addSubview:_card.minimap];
    _card.editor = _editorView;
    [_card addSubview:_editorView.gutterView];
    _findBar = [[GWFindBar alloc] initWithFrame:NSMakeRect(0, 0, 400, 44)];
    _findBar.editor = _editorView;
    _findBar.onResize = ^{
        GWMainWindowController *strongSelf = weakSelf;
        strongSelf->_card.needsLayout = YES;
    };
    _card.findBar = _findBar;
    [_card addSubview:_findBar];
    _editorView.onEdit = ^{
        [weakSelf documentEdited];
    };
    _editorView.onSelectionChange = ^{
        [weakSelf caretMoved];
    };
    _editorView.onSectionsChange = ^{
        [weakSelf updateBreadcrumb];
    };
    _editorView.onInspectColors = ^{
        [weakSelf inspectColors:nil];
    };
    _editorView.onChangeMarkerClick = ^(size_t line, NSRect rect) {
        [weakSelf showChangeAtLine:line rect:rect];
    };
    NSClickGestureRecognizer *breadcrumbClick = [[NSClickGestureRecognizer alloc] initWithTarget:self
                                                                                        action:@selector(breadcrumbClicked:)];
    [breadcrumbBar addGestureRecognizer:breadcrumbClick];

    // The glass is only the card's backdrop: the editor sits on top of it rather than inside
    // it, because glass blends its own content, which dulled the syntax colours.
    _root.editorCard = [self glassWithCornerRadius:20 content:nil];
    [_root addSubview:_root.editorCard];
    _root.editorContent = _card;
    [_root addSubview:_card];

    GWStartupMark(@"  built: editor card");
    [self buildWelcome];

    GWStartupMark(@"  built: welcome card");
    // Sidebar: a switcher on top and one panel below it (files, source control or search).
    // The top clears the window buttons.
    NSView *sidebarContent = [NSView new];

    _switcher = [[GWSidebarSwitcher alloc] initWithSymbols:@[@"folder", @"arrow.triangle.branch", @"magnifyingglass"]
                                                  tooltips:@[@"Files  ⇧⌘E", @"Source Control  ⌃⇧G", @"Search  ⇧⌘F"]];
    _switcher.onSelect = ^(NSInteger index) {
        [weakSelf setSidebarMode:index];
    };
    _sidebarContainer = [NSView new];
    for (NSView *view in @[_switcher, _sidebarContainer]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [sidebarContent addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [_switcher.topAnchor constraintEqualToAnchor:sidebarContent.topAnchor constant:42],
        [_switcher.leadingAnchor constraintEqualToAnchor:sidebarContent.leadingAnchor constant:14],
        [_switcher.trailingAnchor constraintEqualToAnchor:sidebarContent.trailingAnchor constant:-14],
        [_switcher.heightAnchor constraintEqualToConstant:30],
        [_sidebarContainer.topAnchor constraintEqualToAnchor:_switcher.bottomAnchor constant:8],
        [_sidebarContainer.leadingAnchor constraintEqualToAnchor:sidebarContent.leadingAnchor],
        [_sidebarContainer.trailingAnchor constraintEqualToAnchor:sidebarContent.trailingAnchor],
        [_sidebarContainer.bottomAnchor constraintEqualToAnchor:sidebarContent.bottomAnchor constant:-4],
    ]];

    // Files: the folder name and its tree.
    _filesPanel = [NSView new];
    _sidebarTitle = [self label:@"No Folder Open" size:15 weight:NSFontWeightBold secondary:NO];
    _sidebarTitle.lineBreakMode = NSLineBreakByTruncatingTail;
    NSTextField *explorer = [self label:@"EXPLORER" size:10.5 weight:NSFontWeightSemibold secondary:YES];
    explorer.attributedStringValue = [[NSAttributedString alloc] initWithString:@"EXPLORER" attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:10.5 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: NSColor.tertiaryLabelColor,
        NSKernAttributeName: @1.2,
    }];
    _openFolderButton = [NSButton buttonWithTitle:@"Open Folder…" target:self action:@selector(openFolder:)];
    _openFolderButton.bezelStyle = NSBezelStyleGlass;
    _fileTree = [GWFileTree new];
    _fileTree.onOpenFile = ^(NSURL *url) { [weakSelf openURL:url]; };
    _fileTree.onItemMoved = ^(NSURL *from, NSURL *to) { [weakSelf fileItemMovedFrom:from to:to]; };
    _fileTree.onItemTrashed = ^(NSURL *url) { [weakSelf fileItemTrashed:url]; };
    _fileTree.onOpenInTerminal = ^(NSURL *folder) { [weakSelf openTerminalInFolder:folder]; };
    _fileTree.onFindInFolder = ^(NSURL *folder) { [weakSelf findInFolder:folder]; };
    _fileTree.onAskClaude = ^(NSURL *url) { [weakSelf askClaudeAboutItem:url]; };
    _fileTree.onError = ^(NSString *title, NSString *message) { [weakSelf showErrorTitle:title message:message]; };
    NSScrollView *tree = _fileTree.view;
    for (NSView *view in @[explorer, _sidebarTitle, tree, _openFolderButton]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [_filesPanel addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [explorer.topAnchor constraintEqualToAnchor:_filesPanel.topAnchor constant:4],
        [explorer.leadingAnchor constraintEqualToAnchor:_filesPanel.leadingAnchor constant:18],
        [_sidebarTitle.topAnchor constraintEqualToAnchor:explorer.bottomAnchor constant:3],
        [_sidebarTitle.leadingAnchor constraintEqualToAnchor:_filesPanel.leadingAnchor constant:18],
        [_sidebarTitle.trailingAnchor constraintLessThanOrEqualToAnchor:_filesPanel.trailingAnchor constant:-16],
        [tree.topAnchor constraintEqualToAnchor:_sidebarTitle.bottomAnchor constant:10],
        [tree.leadingAnchor constraintEqualToAnchor:_filesPanel.leadingAnchor constant:6],
        [tree.trailingAnchor constraintEqualToAnchor:_filesPanel.trailingAnchor constant:-6],
        [tree.bottomAnchor constraintEqualToAnchor:_filesPanel.bottomAnchor constant:-6],
        [_openFolderButton.centerXAnchor constraintEqualToAnchor:_filesPanel.centerXAnchor],
        [_openFolderButton.topAnchor constraintEqualToAnchor:_sidebarTitle.bottomAnchor constant:18],
    ]];

    GWStartupMark(@"  built: files sidebar");
    _git = [GWGitRepository new];

    [self addSidebarPanel:_filesPanel];
    [self setSidebarMode:0];

    _root.sidebar = [self glassWithCornerRadius:22 content:sidebarContent];
    [_root addSubview:_root.sidebar];

    GWStartupMark(@"  built: sidebar glass");
    // Tabs in a glass capsule.
    _tabBar = [GWTabBar new];
    _tabBar.onSelect = ^(NSInteger index) { [weakSelf selectTab:index]; };
    _tabBar.onClose = ^(NSInteger index) { [weakSelf closeTabAtIndex:index]; };
    _root.tabs = [self glassWithCornerRadius:kTabBarHeight / 2 content:_tabBar];
    [_root addSubview:_root.tabs];

    GWStartupMark(@"  built: tabs");
    // Status bar capsule.
    NSView *statusContent = [NSView new];
    _statusLeft = [self label:@"" size:11.5 weight:NSFontWeightMedium secondary:YES];
    _statusRight = [self label:@"" size:11.5 weight:NSFontWeightMedium secondary:YES];
    _branchChip = [NSButton buttonWithTitle:@"" target:self action:@selector(branchChipClicked:)];
    _branchChip.bordered = NO;
    _branchChip.hidden = YES;
    _branchChip.toolTip = @"Switch branch";
    NSStackView *statusLeftStack = [NSStackView stackViewWithViews:@[_branchChip, _statusLeft]];
    statusLeftStack.spacing = 14;

    _claudeChip = [NSButton buttonWithTitle:@"" target:self action:@selector(toggleChat:)];
    _claudeChip.bordered = NO;
    _claudeChip.toolTip = @"Chat with Claude  ⌘L";
    NSStackView *statusRightStack = [NSStackView stackViewWithViews:@[_statusRight, _claudeChip]];
    statusRightStack.spacing = 14;

    for (NSView *view in @[statusLeftStack, statusRightStack]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [statusContent addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [statusLeftStack.leadingAnchor constraintEqualToAnchor:statusContent.leadingAnchor constant:14],
        [statusLeftStack.centerYAnchor constraintEqualToAnchor:statusContent.centerYAnchor],
        [statusRightStack.trailingAnchor constraintEqualToAnchor:statusContent.trailingAnchor constant:-14],
        [statusRightStack.centerYAnchor constraintEqualToAnchor:statusContent.centerYAnchor],
        [statusRightStack.leadingAnchor constraintGreaterThanOrEqualToAnchor:statusLeftStack.trailingAnchor constant:12],
    ]];
    [self updateClaudeChip];
    _root.status = [self glassWithCornerRadius:kStatusHeight / 2 content:statusContent];
    [_root addSubview:_root.status];

    GWStartupMark(@"  built: status bar");
    // Resize handles for the chat and the terminal.
    GWSplitHandle *chatHandle = [GWSplitHandle new];
    chatHandle.horizontal = YES;
    chatHandle.onDrag = ^(CGFloat delta) {
        GWMainWindowController *strongSelf = weakSelf;
        strongSelf->_root.chatWidth = MAX(300, MIN(strongSelf->_root.chatWidth - delta, 900));
        strongSelf->_root.needsLayout = YES;
    };
    chatHandle.onFinish = ^{
        GWMainWindowController *strongSelf = weakSelf;
        [NSUserDefaults.standardUserDefaults setDouble:strongSelf->_root.chatWidth forKey:@"chatWidth"];
    };
    _root.chatHandle = chatHandle;
    [_root addSubview:chatHandle];

    GWSplitHandle *bottomHandle = [GWSplitHandle new];
    bottomHandle.horizontal = NO;
    bottomHandle.onDrag = ^(CGFloat delta) {
        GWMainWindowController *strongSelf = weakSelf;
        strongSelf->_root.bottomHeight = MAX(120, MIN(strongSelf->_root.bottomHeight - delta, 700));
        strongSelf->_root.needsLayout = YES;
    };
    bottomHandle.onFinish = ^{
        GWMainWindowController *strongSelf = weakSelf;
        [NSUserDefaults.standardUserDefaults setDouble:strongSelf->_root.bottomHeight forKey:@"bottomHeight"];
    };
    _root.bottomHandle = bottomHandle;
    [_root addSubview:bottomHandle];

    double savedChatWidth = [NSUserDefaults.standardUserDefaults doubleForKey:@"chatWidth"];
    double savedBottomHeight = [NSUserDefaults.standardUserDefaults doubleForKey:@"bottomHeight"];
    _root.chatWidth = savedChatWidth >= 300 ? savedChatWidth : 430;
    _root.bottomHeight = savedBottomHeight >= 120 ? savedBottomHeight : 260;
    _root.chatVisible = [NSUserDefaults.standardUserDefaults boolForKey:@"chatVisible"];
    _root.bottomVisible = NO;  // the terminal is restored after the window appears

    self.window.contentView = _root;
}

/// The welcome card shown when no file is open: title, quick actions and recent folders.
- (void)buildWelcome {
    NSImage *symbol = [NSImage imageWithSystemSymbolName:@"chevron.left.forwardslash.chevron.right" accessibilityDescription:nil];
    NSImageSymbolConfiguration *configuration = [[NSImageSymbolConfiguration configurationWithPointSize:34 weight:NSFontWeightSemibold]
        configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[NSColor.controlAccentColor]]];
    NSImageView *icon = [NSImageView imageViewWithImage:[symbol imageWithSymbolConfiguration:configuration]];

    NSTextField *title = [self label:@"Glasswork" size:32 weight:NSFontWeightBold secondary:NO];
    NSTextField *subtitle = [self label:@"A Liquid Glass code editor" size:13.5 weight:NSFontWeightRegular secondary:YES];

    NSButton *openFolder = [NSButton buttonWithTitle:@"Open Folder…" target:self action:@selector(openFolder:)];
    NSButton *openFile = [NSButton buttonWithTitle:@"Open File…" target:self action:@selector(openDocument:)];
    NSButton *newFile = [NSButton buttonWithTitle:@"New File" target:self action:@selector(newDocument:)];
    for (NSButton *button in @[openFolder, openFile, newFile]) {
        button.bezelStyle = NSBezelStyleGlass;
        button.controlSize = NSControlSizeLarge;
    }
    openFolder.keyEquivalent = @"\r";
    NSStackView *actions = [NSStackView stackViewWithViews:@[openFolder, openFile, newFile]];
    actions.spacing = 10;

    NSTextField *recentTitle = [self label:@"RECENT" size:10.5 weight:NSFontWeightSemibold secondary:YES];
    _recentList = [NSStackView new];
    _recentList.orientation = NSUserInterfaceLayoutOrientationVertical;
    _recentList.alignment = NSLayoutAttributeLeading;
    _recentList.spacing = 2;
    NSStackView *recent = [NSStackView stackViewWithViews:@[recentTitle, _recentList]];
    recent.orientation = NSUserInterfaceLayoutOrientationVertical;
    recent.alignment = NSLayoutAttributeLeading;
    recent.spacing = 6;

    NSStackView *stack = [NSStackView stackViewWithViews:@[icon, title, subtitle, actions, recent]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeCenterX;
    stack.spacing = 8;
    [stack setCustomSpacing:18 afterView:subtitle];
    [stack setCustomSpacing:26 afterView:actions];
    stack.edgeInsets = NSEdgeInsetsMake(34, 40, 30, 40);
    [recent.widthAnchor constraintGreaterThanOrEqualToConstant:360].active = YES;

    _root.welcome = [self glassWithCornerRadius:30 content:stack];
    [_root addSubview:_root.welcome];
    [self reloadRecents];
}

- (void)reloadRecents {
    for (NSView *view in _recentList.arrangedSubviews) [view removeFromSuperview];
    NSArray<NSURL *> *urls = NSDocumentController.sharedDocumentController.recentDocumentURLs;
    NSUInteger shown = 0;
    for (NSURL *url in urls) {
        if (shown == 5) break;
        NSNumber *directory = nil;
        [url getResourceValue:&directory forKey:NSURLIsDirectoryKey error:nil];
        NSString *symbol = directory.boolValue ? @"folder.fill" : GWSymbolForFile(url.lastPathComponent);
        NSColor *color = directory.boolValue ? NSColor.controlAccentColor : GWColorForFile(url.lastPathComponent);

        NSMutableAttributedString *text = [GWSymbolString(symbol, color, 12) mutableCopy];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:[@"  " stringByAppendingString:url.lastPathComponent] attributes:@{
            NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightMedium],
            NSForegroundColorAttributeName: NSColor.labelColor,
        }]];
        NSString *parent = [url.URLByDeletingLastPathComponent.path stringByAbbreviatingWithTildeInPath];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:[@"   " stringByAppendingString:parent] attributes:@{
            NSFontAttributeName: [NSFont systemFontOfSize:11.5],
            NSForegroundColorAttributeName: NSColor.tertiaryLabelColor,
        }]];
        NSButton *button = [NSButton buttonWithTitle:@"" target:self action:@selector(openRecent:)];
        button.attributedTitle = text;
        button.bordered = NO;
        button.alignment = NSTextAlignmentLeft;
        button.toolTip = url.path;
        button.identifier = url.path;
        [_recentList addArrangedSubview:button];
        ++shown;
    }
    if (shown == 0) [_recentList addArrangedSubview:[self label:@"Folders you open will appear here." size:12 weight:NSFontWeightRegular secondary:YES]];
    _root.needsLayout = YES;
}

- (void)openRecent:(NSButton *)sender {
    [self openURL:[NSURL fileURLWithPath:sender.identifier]];
}

// MARK: Theme

- (void)themeChanged:(NSNotification *)notification { [self applyTheme]; }

- (void)applyTheme {
    GWServices *services = GWServices.shared;
    _language.enabled = services.settings.languageServers;
    const gw::Theme &theme = services.theme;
    BOOL dark = theme.isDark();
    self.window.appearance = [NSAppearance appearanceNamed:dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];

    // Tint the glass slightly towards the theme so panels and code feel like one surface.
    NSColor *editor = [services color:@"editor.background" fallback:NSColor.clearColor];
    NSColor *sidebar = [services color:@"sideBar.background" fallback:editor];
    _root.sidebar.tintColor = [sidebar colorWithAlphaComponent:0.30];
    _root.tabs.tintColor = [editor colorWithAlphaComponent:0.22];
    _root.status.tintColor = [editor colorWithAlphaComponent:0.22];
    _root.chat.tintColor = [sidebar colorWithAlphaComponent:0.30];
    _root.bottom.tintColor = [editor colorWithAlphaComponent:0.30];
    _root.editorCard.tintColor = [editor colorWithAlphaComponent:0.18];
    _root.welcome.tintColor = [editor colorWithAlphaComponent:0.18];

    // Aurora colours from the theme's own accents, with vivid fallbacks.
    NSArray *aurora = @[
        [services color:@"terminal.ansiBlue" fallback:GWColor(0x3B82F6FF)],
        [services color:@"terminal.ansiMagenta" fallback:GWColor(0xA855F7FF)],
        [services color:@"terminal.ansiCyan" fallback:GWColor(0x22D3EEFF)],
    ];
    [_root.aurora setColors:aurora strength:dark ? 0.34 : 0.22];

    [_editorView reloadAppearance];
    _card.needsLayout = YES;  // the minimap may have been switched on or off
    [self updateStatus];
}

- (void)extensionsChanged:(NSNotification *)notification {
    // Grammars were reloaded, so every tab must pick up fresh grammar pointers now.
    for (auto &tab : _tabs) [self configureLanguageForTab:*tab];
    if (_selected >= 0) [self showTab:_selected];
    [self updateStatus];
}

// MARK: Tabs

- (void)configureLanguageForTab:(Tab &)tab {
    GWServices *services = GWServices.shared;
    auto &extensions = services.extensions;
    std::string language = "plaintext";
    if (!tab.forcedLanguage.empty()) {
        language = tab.forcedLanguage;
    } else if (tab.document->path()) {
        if (auto detected = extensions.languageForFile(*tab.document->path())) language = *detected;
    }
    tab.document->languageId = language;
    tab.highlighter->setGrammar(services.grammars.forLanguage(language));
    tab.configuration = extensions.configuration(language);
    [_language trackDocument:tab.document.get()];  // a new language may mean a different server
}

- (Tab *)currentTab {
    return _selected >= 0 && _selected < static_cast<NSInteger>(_tabs.size()) ? _tabs[static_cast<size_t>(_selected)].get() : nullptr;
}

- (void)addTab:(std::unique_ptr<gw::Document>)document {
    [self addTab:std::move(document) atIndex:-1 configure:nil];
}

/// Adds a tab at `index` (-1 for the end). `configure` can set up the tab before its
/// language is chosen and it is shown.
- (void)addTab:(std::unique_ptr<gw::Document>)document atIndex:(NSInteger)index configure:(void (^)(Tab &tab))configure {
    auto tab = std::make_unique<Tab>();
    tab->identifier = ++_nextTabIdentifier;
    tab->document = std::move(document);
    if (tab->document->path()) {
        NSString *resolved = [@(tab->document->path()->c_str()) stringByResolvingSymlinksInPath];
        tab->realPath = resolved.UTF8String;
    }
    if (configure) {
        configure(*tab);
    }
    tab->highlighter = std::make_unique<gw::Highlighter>();
    gw::Highlighter *highlighter = tab->highlighter.get();
    gw::Document *raw = tab->document.get();
    __weak GWEditorView *editor = _editorView;
    tab->document->onChange = [highlighter, editor, raw](const gw::Change &change) {
        highlighter->didChange(change);
        [editor document:raw changed:change];
    };
    [self configureLanguageForTab:*tab];
    gw::Document *newDocument = tab->document.get();
    NSInteger position = index < 0 || index > static_cast<NSInteger>(_tabs.size()) ? static_cast<NSInteger>(_tabs.size()) : index;
    _tabs.insert(_tabs.begin() + position, std::move(tab));
    [_language trackDocument:newDocument];
    [self showTab:position];
}

- (void)showTab:(NSInteger)index {
    if (Tab *current = [self currentTab]) current->scroll = _card.scrollView.contentView.bounds.origin;
    _selected = index;
    Tab *tab = [self currentTab];
    if (tab) {
        [_editorView setDocument:tab->document.get() highlighter:tab->highlighter.get() configuration:tab->configuration];
        [_editorView setLineChanges:tab->changes];
        [_editorView setLineTints:tab->lineTints];
        [_editorView setDiagnostics:[_language diagnosticsForDocument:tab->document.get()]];
        [self refreshChangesForTab:tab];
        [_findBar documentChanged];
        if (_root.chatVisible) {
            [_chat contextDidChange];
        }
        if (tab->document->isDirty() && tab->document->fileChangedOnDisk()) {
            [self askAboutDiskChangeForTab:tab];
        }
        [_card.scrollView.contentView scrollToPoint:tab->scroll];
        [_card.scrollView reflectScrolledClipView:_card.scrollView.contentView];
        [self.window makeFirstResponder:_editorView];
    } else {
        [_editorView setDocument:nullptr highlighter:nullptr configuration:{}];
    }
    [self refresh];
}

- (void)selectTab:(NSInteger)index {
    if (index == _selected || index < 0 || index >= static_cast<NSInteger>(_tabs.size())) return;
    [self showTab:index];
}

- (void)closeTabAtIndex:(NSInteger)index {
    if (index < 0 || index >= static_cast<NSInteger>(_tabs.size())) return;
    Tab &tab = *_tabs[static_cast<size_t>(index)];
    if (tab.document->isDirty() && ![self confirmCloseDocument:*tab.document]) return;
    if (index == _selected) [_editorView setDocument:nullptr highlighter:nullptr configuration:{}];
    [_language untrackDocument:tab.document.get()];
    _tabs.erase(_tabs.begin() + index);
    NSInteger next = _tabs.empty() ? -1 : std::min(index, static_cast<NSInteger>(_tabs.size()) - 1);
    _selected = -1;  // the closed tab's scroll position doesn't need saving
    [self showTab:next];
}

- (void)refresh {
    NSMutableArray<GWTabItem *> *items = [NSMutableArray array];
    for (const auto &tab : _tabs) {
        GWTabItem *item = [GWTabItem new];
        item.title = @(tab->document->displayName().c_str());
        item.dirty = tab->document->isDirty();
        [items addObject:item];
    }
    _tabBar.items = items;
    _tabBar.selectedIndex = _selected;
    Tab *tab = [self currentTab];
    _root.editorCard.hidden = tab == nullptr;
    _root.editorContent.hidden = tab == nullptr;
    _root.welcome.hidden = tab != nullptr;
    if (!tab) [self reloadRecents];
    self.window.documentEdited = tab && tab->document->isDirty();
    if (tab && tab->document->path()) self.window.representedURL = [NSURL fileURLWithPath:@(tab->document->path()->c_str())];
    [self updateBreadcrumb];
    [self updateStatus];
}

- (void)documentEdited {
    if (Tab *editedTab = [self currentTab]) {
        [_language documentDidChange:editedTab->document.get()];
    }
    [self refresh];
    [self scheduleChangeRefresh];
    [_findBar documentChanged];
    [self scheduleAutoSave];
}

// MARK: Auto save

/// With "files.autoSave" on, saves a second after the last edit.
- (void)scheduleAutoSave {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(autoSaveDirtyTabs) object:nil];
    if (GWServices.shared.settings.autoSave) {
        [self performSelector:@selector(autoSaveDirtyTabs) withObject:nil afterDelay:1.0];
    }
}

/// Saves every file-backed tab with unsaved edits. A file that changed on disk in the meantime
/// is left alone, so the "changed on disk" question can be asked instead of overwriting it.
- (void)autoSaveDirtyTabs {
    if (!GWServices.shared.settings.autoSave) {
        return;
    }
    BOOL savedAny = NO;
    for (auto &tab : _tabs) {
        if (tab->isVirtual || !tab->document->path() || !tab->document->isDirty()) {
            continue;
        }
        if (tab->document->fileChangedOnDisk()) {
            continue;
        }
        std::string error;
        if (tab->document->save(&error)) {
            savedAny = YES;
        }
    }
    if (savedAny) {
        [self refresh];
        [_git refresh];
    }
}

/// "Glasswork › src › core › Highlighter.cpp", relative to the open folder.
- (void)updateBreadcrumb {
    Tab *tab = [self currentTab];
    if (!tab) return;
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (tab->document->path()) {
        NSString *path = @(tab->document->path()->c_str());
        NSString *root = _fileTree.rootURL.path;
        if (root && [path hasPrefix:[root stringByAppendingString:@"/"]]) {
            [parts addObject:root.lastPathComponent];
            [parts addObjectsFromArray:[[path substringFromIndex:root.length + 1] pathComponents]];
        } else {
            [parts addObjectsFromArray:[[path stringByAbbreviatingWithTildeInPath] pathComponents]];
        }
    } else if (tab->isVirtual) {
        [parts addObject:@(tab->document->displayName().c_str())];
    } else {
        [parts addObject:@"Untitled"];
    }
    NSMutableAttributedString *text = [NSMutableAttributedString new];
    NSDictionary *folder = @{NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightMedium],
                             NSForegroundColorAttributeName: [NSColor.labelColor colorWithAlphaComponent:0.6]};
    NSDictionary *file = @{NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold],
                           NSForegroundColorAttributeName: NSColor.labelColor};
    for (NSUInteger index = 0; index < parts.count; ++index) {
        BOOL last = index + 1 == parts.count;
        if (index > 0) {
            [text appendAttributedString:[[NSAttributedString alloc] initWithString:@"  " attributes:folder]];
            [text appendAttributedString:GWSymbolString(@"chevron.right", [NSColor.labelColor colorWithAlphaComponent:0.4], 8)];
            [text appendAttributedString:[[NSAttributedString alloc] initWithString:@"  " attributes:folder]];
        }
        if (last) {
            [text appendAttributedString:GWSymbolString(GWSymbolForFile(parts[index]), GWColorForFile(parts[index]), 11)];
            [text appendAttributedString:[[NSAttributedString alloc] initWithString:@" " attributes:file]];
        }
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:parts[index] attributes:last ? file : folder]];
    }

    // Xcode-style: the MARK section the caret is in, like a jump bar.
    std::vector<gw::Section> sections = [_editorView sections];
    long current = gw::sectionContaining(sections, tab->document->selection.caret.line);
    if (current >= 0 && !sections[static_cast<size_t>(current)].title.empty()) {
        NSString *title = @(sections[static_cast<size_t>(current)].title.c_str());
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:@"  " attributes:folder]];
        [text appendAttributedString:GWSymbolString(@"chevron.right", [NSColor.labelColor colorWithAlphaComponent:0.4], 8)];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:@"  " attributes:folder]];
        [text appendAttributedString:GWSymbolString(@"number", NSColor.controlAccentColor, 10)];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:[@" " stringByAppendingString:title] attributes:folder]];
    }
    _breadcrumb.attributedStringValue = text;
}

- (void)caretMoved {
    [self dropSuggestionsIfCaretLeftWord];
    [self updateStatus];
    [self updateBreadcrumb];
    [GWColorInspector.shared refresh];
    if (_root.chatVisible) {
        [_chat contextDidChange];
    }
}

// MARK: Sections (Xcode-style jump bar)

- (NSImage *)symbol:(NSString *)name color:(NSColor *)color {
    NSImageSymbolConfiguration *configuration = [NSImageSymbolConfiguration configurationWithPaletteColors:@[color]];
    return [[NSImage imageWithSystemSymbolName:name accessibilityDescription:nil] imageWithSymbolConfiguration:configuration];
}

/// Clicking the breadcrumb lists every section, TODO and FIXME in the file.
- (void)breadcrumbClicked:(NSClickGestureRecognizer *)gesture {
    if (![self currentTab]) {
        return;
    }
    NSMenu *menu = [NSMenu new];
    std::vector<gw::Section> sections = [_editorView sections];
    if (sections.empty()) {
        NSMenuItem *hint = [[NSMenuItem alloc] initWithTitle:@"No sections yet. Add “// MARK: - Name” comments."
                                                      action:nil keyEquivalent:@""];
        hint.enabled = NO;
        [menu addItem:hint];
    }
    for (const gw::Section &section : sections) {
        if (section.divider && menu.numberOfItems > 0) {
            [menu addItem:NSMenuItem.separatorItem];
        }
        NSString *title = section.title.empty() ? @"(untitled section)" : @(section.title.c_str());
        NSImage *image = [self symbol:@"number" color:NSColor.controlAccentColor];
        if (section.kind == gw::Section::Kind::Todo) {
            title = [@"TODO: " stringByAppendingString:title];
            image = [self symbol:@"checklist" color:NSColor.systemOrangeColor];
        } else if (section.kind == gw::Section::Kind::Fixme) {
            title = [@"FIXME: " stringByAppendingString:title];
            image = [self symbol:@"exclamationmark.triangle.fill" color:NSColor.systemRedColor];
        }
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:@selector(jumpToSectionItem:) keyEquivalent:@""];
        item.target = self;
        item.image = image;
        item.tag = static_cast<NSInteger>(section.line);
        [menu addItem:item];
    }
    NSPoint location = [gesture locationInView:gesture.view];
    [menu popUpMenuPositioningItem:nil atLocation:location inView:gesture.view];
}

- (void)jumpToSectionItem:(NSMenuItem *)item {
    [_editorView jumpToLine:static_cast<size_t>(item.tag)];
}

/// ⌃6: the same list in the fuzzy palette.
- (IBAction)jumpToSection:(id)sender {
    if (![self currentTab]) {
        return;
    }
    std::vector<gw::Section> sections = [_editorView sections];
    __weak GWEditorView *editor = _editorView;
    [GWPalette.shared showOverWindow:self.window placeholder:@"Jump to a section, TODO or FIXME…"
                            provider:^NSArray<GWPaletteItem *> *(NSString *query) {
        NSMutableArray<GWPaletteItem *> *items = [NSMutableArray array];
        std::string wanted = query.UTF8String;
        for (const gw::Section &section : sections) {
            std::string title = section.title.empty() ? "(untitled section)" : section.title;
            std::optional<gw::FuzzyMatch> match = gw::fuzzyMatch(wanted, title);
            if (!match) {
                continue;
            }
            GWPaletteItem *item = [GWPaletteItem new];
            item.title = @(title.c_str());
            item.subtitle = [NSString stringWithFormat:@"line %zu", section.line + 1];
            item.symbol = @"number";
            item.symbolColor = NSColor.controlAccentColor;
            if (section.kind == gw::Section::Kind::Todo) {
                item.symbol = @"checklist";
                item.symbolColor = NSColor.systemOrangeColor;
            } else if (section.kind == gw::Section::Kind::Fixme) {
                item.symbol = @"exclamationmark.triangle.fill";
                item.symbolColor = NSColor.systemRedColor;
            }
            NSMutableIndexSet *indexes = [NSMutableIndexSet indexSet];
            for (uint32_t position : match->positions) {
                [indexes addIndex:position];
            }
            item.matchedIndexes = indexes;
            size_t line = section.line;
            item.run = ^{
                [editor jumpToLine:line];
            };
            [items addObject:item];
        }
        return items;
    }];
}

// MARK: Quick open and command palette (Zed-style)

/// Lists every file in the folder on a background thread, skipping build output and
/// dependency folders that nobody wants in quick open.
- (void)rebuildFileIndex:(NSURL *)root {
    NSUInteger generation = ++_indexGeneration;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        auto index = std::make_shared<FileIndex>();

        // In a Git project, git knows the answer exactly: what's tracked plus what's new,
        // minus everything in .gitignore (build folders, dependencies…). Fast, too.
        bool fromGit = false;
        std::vector<std::string> listed = gw::git::listFiles(root.path.UTF8String, &fromGit);
        if (fromGit) {
            index->paths = std::move(listed);
        } else {
            NSSet *skipped = [NSSet setWithArray:@[@"build", @".build", @"node_modules", @"DerivedData", @"Pods",
                                                   @"target", @"dist", @"__pycache__", @".git"]];
            NSDirectoryEnumerator *walker = [NSFileManager.defaultManager
                        enumeratorAtURL:root
             includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                                options:NSDirectoryEnumerationSkipsHiddenFiles | NSDirectoryEnumerationSkipsPackageDescendants
                           errorHandler:nil];
            NSUInteger rootLength = root.path.length + 1;
            for (NSURL *url in walker) {
                NSNumber *directory = nil;
                [url getResourceValue:&directory forKey:NSURLIsDirectoryKey error:nil];
                if (directory.boolValue) {
                    if ([skipped containsObject:url.lastPathComponent]) {
                        [walker skipDescendants];
                    }
                    continue;
                }
                if (url.path.length <= rootLength) {
                    continue;
                }
                index->paths.push_back([url.path substringFromIndex:rootLength].UTF8String);
                if (index->paths.size() >= 200000) {
                    break;
                }
            }
        }
        index->nameStarts.reserve(index->paths.size());
        for (const std::string &path : index->paths) {
            size_t slash = path.rfind('/');
            index->nameStarts.push_back(slash == std::string::npos ? 0 : slash + 1);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self->_indexGeneration) {
                return;  // a newer folder was opened meanwhile
            }
            self->_fileIndex = index;
        });
    });
}

- (IBAction)quickOpen:(id)sender {
    NSURL *root = _fileTree.rootURL;
    if (!root) {
        [self openDocument:sender];  // no folder yet: fall back to the open panel
        return;
    }
    __weak GWMainWindowController *weakSelf = self;
    [GWPalette.shared showOverWindow:self.window placeholder:@"Go to file…"
                            provider:^NSArray<GWPaletteItem *> *(NSString *query) {
        GWMainWindowController *strongSelf = weakSelf;
        if (!strongSelf) {
            return @[];
        }
        return [strongSelf fileItemsForQuery:query root:root];
    }];
}

- (NSArray<GWPaletteItem *> *)fileItemsForQuery:(NSString *)query root:(NSURL *)root {
    struct Candidate {
        int score;
        size_t index;
    };
    const std::string wanted = query.UTF8String;
    std::shared_ptr<const FileIndex> snapshot = _fileIndex;
    if (!snapshot) {
        return @[];
    }
    const std::vector<std::string> &paths = snapshot->paths;
    const std::vector<size_t> &nameStarts = snapshot->nameStarts;

    // Score every file across all cores. Each chunk collects its own matches, so no locking
    // is needed; the chunks are merged afterwards.
    const size_t chunkCount = 16;
    const size_t chunkSize = (paths.size() + chunkCount - 1) / chunkCount;
    std::vector<std::vector<Candidate>> chunkMatches(chunkCount);
    // Blocks capture C++ objects as const copies, so hand the block a pointer instead.
    std::vector<Candidate> *chunkResults = chunkMatches.data();
    dispatch_apply(chunkCount, DISPATCH_APPLY_AUTO, ^(size_t chunk) {
        const size_t first = chunk * chunkSize;
        const size_t last = std::min(paths.size(), first + chunkSize);
        std::vector<Candidate> &found = chunkResults[chunk];
        for (size_t index = first; index < last; ++index) {
            std::optional<int> score = gw::fuzzyScore(wanted, paths[index], nameStarts[index]);
            if (score) {
                found.push_back({*score, index});
            }
        }
    });
    std::vector<Candidate> matches;
    for (const std::vector<Candidate> &found : chunkMatches) {
        matches.insert(matches.end(), found.begin(), found.end());
    }

    // Best first; keep only what the list can show. Ties go to the shorter path.
    const size_t shown = std::min<size_t>(matches.size(), 60);
    auto better = [&paths](const Candidate &a, const Candidate &b) {
        if (a.score != b.score) {
            return a.score > b.score;
        }
        return paths[a.index].size() < paths[b.index].size();
    };
    std::partial_sort(matches.begin(), matches.begin() + static_cast<long>(shown), matches.end(), better);

    NSMutableArray<GWPaletteItem *> *items = [NSMutableArray array];
    for (size_t rank = 0; rank < shown; ++rank) {
        const Candidate &candidate = matches[rank];
        const std::string &path = paths[candidate.index];
        size_t nameStart = nameStarts[candidate.index];
        // Positions (for the bold highlight) only for the rows actually shown.
        std::optional<gw::FuzzyMatch> match = gw::fuzzyMatch(wanted, path, nameStart);
        std::vector<uint32_t> positions = match ? match->positions : std::vector<uint32_t>{};
        NSString *name = @(path.substr(nameStart).c_str());
        NSString *folder = nameStart > 0 ? @(path.substr(0, nameStart - 1).c_str()) : @"";

        GWPaletteItem *item = [GWPaletteItem new];
        item.title = name;
        item.subtitle = folder;
        item.symbol = GWSymbolForFile(name);
        item.symbolColor = GWColorForFile(name);
        NSMutableIndexSet *indexes = [NSMutableIndexSet indexSet];
        for (uint32_t position : positions) {
            if (position >= nameStart) {
                [indexes addIndex:position - nameStart];
            }
        }
        item.matchedIndexes = indexes;
        NSURL *url = [root URLByAppendingPathComponent:@(path.c_str())];
        __weak GWMainWindowController *weakSelf = self;
        item.run = ^{
            [weakSelf openURL:url];
        };
        [items addObject:item];
    }
    return items;
}

/// "⇧⌘P"-style text for a menu item's shortcut.
- (NSString *)shortcutFor:(NSMenuItem *)item {
    if (item.keyEquivalent.length == 0) {
        return nil;
    }
    NSMutableString *text = [NSMutableString string];
    NSEventModifierFlags flags = item.keyEquivalentModifierMask;
    if (flags & NSEventModifierFlagControl) [text appendString:@"⌃"];
    if (flags & NSEventModifierFlagOption) [text appendString:@"⌥"];
    if (flags & NSEventModifierFlagShift) [text appendString:@"⇧"];
    if (flags & NSEventModifierFlagCommand) [text appendString:@"⌘"];
    [text appendString:item.keyEquivalent.uppercaseString];
    return text;
}

- (void)collectCommandsFrom:(NSMenu *)menu path:(NSString *)path into:(NSMutableArray<NSMenuItem *> *)items
                     titles:(NSMutableArray<NSString *> *)titles {
    for (NSMenuItem *item in menu.itemArray) {
        if (item.separatorItem || item.hidden) {
            continue;
        }
        NSString *title = path.length ? [NSString stringWithFormat:@"%@ › %@", path, item.title] : item.title;
        if (item.submenu) {
            [self collectCommandsFrom:item.submenu path:title into:items titles:titles];
        } else if (item.action) {
            [items addObject:item];
            [titles addObject:title];
        }
    }
}

- (IBAction)showCommandPalette:(id)sender {
    NSMutableArray<NSMenuItem *> *commands = [NSMutableArray array];
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    for (NSMenuItem *top in NSApp.mainMenu.itemArray) {
        if (top.submenu && ![top.title isEqualToString:@"Glasswork"]) {
            [self collectCommandsFrom:top.submenu path:top.submenu.title into:commands titles:titles];
        }
    }
    NSArray<NSString *> *themes = GWServices.shared.themeLabels;

    [GWPalette.shared showOverWindow:self.window placeholder:@"Run a command…"
                            provider:^NSArray<GWPaletteItem *> *(NSString *query) {
        std::string wanted = query.UTF8String;
        std::vector<std::pair<int, GWPaletteItem *>> scored;

        for (NSUInteger index = 0; index < commands.count; ++index) {
            NSMenuItem *command = commands[index];
            std::optional<gw::FuzzyMatch> match = gw::fuzzyMatch(wanted, titles[index].UTF8String);
            if (!match) {
                continue;
            }
            GWPaletteItem *item = [GWPaletteItem new];
            item.title = titles[index];
            item.shortcut = [self shortcutFor:command];
            item.symbol = @"command";
            item.symbolColor = NSColor.controlAccentColor;
            NSMutableIndexSet *indexes = [NSMutableIndexSet indexSet];
            for (uint32_t position : match->positions) {
                [indexes addIndex:position];
            }
            item.matchedIndexes = indexes;
            item.run = ^{
                [NSApp sendAction:command.action to:command.target from:command];
            };
            scored.emplace_back(match->score, item);
        }
        for (NSString *theme in themes) {
            NSString *title = [@"Theme: " stringByAppendingString:theme];
            std::optional<gw::FuzzyMatch> match = gw::fuzzyMatch(wanted, title.UTF8String);
            if (!match) {
                continue;
            }
            GWPaletteItem *item = [GWPaletteItem new];
            item.title = title;
            item.symbol = @"paintpalette.fill";
            item.symbolColor = NSColor.systemPinkColor;
            item.run = ^{
                [GWServices.shared selectThemeNamed:theme];
            };
            scored.emplace_back(match->score, item);
        }

        std::stable_sort(scored.begin(), scored.end(), [](const auto &a, const auto &b) { return a.first > b.first; });
        NSMutableArray<GWPaletteItem *> *items = [NSMutableArray array];
        for (const auto &[score, item] : scored) {
            [items addObject:item];
        }
        return items;
    }];
}

- (IBAction)inspectColors:(id)sender {
    if ([self currentTab]) {
        [GWColorInspector.shared showForEditor:_editorView];
    }
}

- (IBAction)openSettings:(id)sender {
    [self openURL:GWServices.shared.settingsURL];
}

- (void)updateStatus {
    Tab *tab = [self currentTab];
    GWServices *services = GWServices.shared;
    NSDictionary *attributes = @{NSFontAttributeName: [NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium],
                                 NSForegroundColorAttributeName: NSColor.secondaryLabelColor};
    auto segment = ^NSAttributedString *(NSString *symbol, NSColor *color, NSString *text) {
        NSMutableAttributedString *piece = [GWSymbolString(symbol, color, 10.5) mutableCopy];
        [piece appendAttributedString:[[NSAttributedString alloc] initWithString:[@" " stringByAppendingString:text] attributes:attributes]];
        return piece;
    };
    auto join = ^NSAttributedString *(NSArray<NSAttributedString *> *pieces) {
        NSMutableAttributedString *joined = [NSMutableAttributedString new];
        for (NSUInteger index = 0; index < pieces.count; ++index) {
            if (index > 0) [joined appendAttributedString:[[NSAttributedString alloc] initWithString:@"     " attributes:attributes]];
            [joined appendAttributedString:pieces[index]];
        }
        return joined;
    };
    NSColor *muted = NSColor.secondaryLabelColor;
    NSAttributedString *theme = segment(@"paintpalette.fill", muted, services.themeLabel);

    if (!tab) {
        NSString *message = services.installingDefaults ? @"Installing language support from Open VSX…" : @"Ready";
        _statusLeft.attributedStringValue = segment(services.installingDefaults ? @"arrow.down.circle.fill" : @"checkmark.circle.fill",
                                                    NSColor.controlAccentColor, message);
        _statusRight.attributedStringValue = theme;
        return;
    }
    const gw::Document &document = *tab->document;
    gw::Position caret = document.selection.caret;
    // Columns count characters (not bytes), from 1, like other editors.
    const std::string &line = document.buffer().line(caret.line);
    NSString *prefix = [[NSString alloc] initWithBytes:line.data() length:std::min(caret.column, line.size()) encoding:NSUTF8StringEncoding];
    NSMutableArray<NSAttributedString *> *left = [NSMutableArray array];
    [left addObject:segment(@"text.cursor", NSColor.controlAccentColor,
                            [NSString stringWithFormat:@"Ln %zu, Col %lu", caret.line + 1, (unsigned long)prefix.length + 1])];
    if (!document.selection.empty()) {
        NSString *selected = @(document.buffer().text(document.selection.range()).c_str());
        [left addObject:segment(@"selection.pin.in.out", muted, [NSString stringWithFormat:@"%lu selected", (unsigned long)selected.length])];
    }
    if (services.installingDefaults) [left addObject:segment(@"arrow.down.circle.fill", muted, @"Installing language support…")];
    NSUInteger errorCount = [_language errorCount];
    NSUInteger warningCount = [_language warningCount];
    if (errorCount > 0) {
        [left addObject:segment(@"xmark.octagon.fill", NSColor.systemRedColor, [NSString stringWithFormat:@"%lu", (unsigned long)errorCount])];
    }
    if (warningCount > 0) {
        [left addObject:segment(@"exclamationmark.triangle.fill", NSColor.systemOrangeColor, [NSString stringWithFormat:@"%lu", (unsigned long)warningCount])];
    }
    NSString *serverStatus = [_language statusTextForLanguage:@(document.languageId.c_str())];
    if (serverStatus.length > 0) {
        [left addObject:segment(@"bolt.horizontal.circle", muted, serverStatus)];
    }
    _statusLeft.attributedStringValue = join(left);

    NSString *name = document.path() ? @(document.path()->filename().c_str()) : @"untitled";
    NSString *language = @(services.extensions.languageName(document.languageId).c_str());
    _statusRight.attributedStringValue = join(@[
        segment(GWSymbolForFile(name), GWColorForFile(name), language),
        segment(@"arrow.turn.down.left", muted, document.buffer().usesCRLF() ? @"CRLF" : @"LF"),
        segment(@"textformat", muted, @"UTF-8"),
        theme,
    ]);
}

// MARK: - Terminal

/// The terminal is built the first time it is wanted.
- (void)buildTerminalPanel {
    if (_terminal != nil) {
        return;
    }
    __weak GWMainWindowController *weakSelf = self;
    _terminal = [GWTerminalPanel new];
    _terminal.projectFolder = _fileTree.rootURL.path;
    _terminal.onOpenPath = ^(NSString *path, NSInteger line, NSInteger column) {
        [weakSelf openPath:path atLine:line];
    };
    _terminal.onHide = ^{
        GWMainWindowController *strongSelf = weakSelf;
        if (strongSelf->_root.bottomVisible) {
            [strongSelf toggleTerminal:nil];
        }
    };
    _root.bottom = [self glassWithCornerRadius:22 content:_terminal.view];
    [_root addSubview:_root.bottom positioned:NSWindowBelow relativeTo:_root.chatHandle];
    [self applyTheme];
}

- (void)setTerminalVisible:(BOOL)visible {
    [self buildTerminalPanel];
    if (visible == _root.bottomVisible) {
        return;
    }
    _root.bottomVisible = visible;
    [NSUserDefaults.standardUserDefaults setBool:visible forKey:@"terminalVisible"];
    if (visible && _terminal.terminalCount == 0) {
        [_terminal newTerminalRunning:nil];
    }
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.22;
        context.allowsImplicitAnimation = YES;
        [self->_root layoutSubtreeIfNeeded];
    }];
    _root.needsLayout = YES;
    if (visible) {
        [_terminal focusTerminal];
    } else {
        [self.window makeFirstResponder:_editorView];
    }
}

- (IBAction)toggleTerminal:(id)sender {
    [self setTerminalVisible:!_root.bottomVisible];
}

- (IBAction)newTerminal:(id)sender {
    [self buildTerminalPanel];
    [self setTerminalVisible:YES];
    [_terminal newTerminalRunning:nil];
}

- (IBAction)closeTerminal:(id)sender {
    if (_terminal != nil && _root.bottomVisible) {
        [_terminal closeCurrentTerminal];
    }
}

/// Opens the terminal and runs a command in it.
- (void)runInTerminal:(NSString *)command {
    [self buildTerminalPanel];
    [self setTerminalVisible:YES];
    [_terminal newTerminalRunning:command];
}

// MARK: - Claude

- (void)updateClaudeChip {
    NSDictionary *attributes = @{NSFontAttributeName: [NSFont systemFontOfSize:11.5 weight:NSFontWeightSemibold],
                                 NSForegroundColorAttributeName: _root.chatVisible ? NSColor.controlAccentColor : NSColor.secondaryLabelColor};
    NSMutableAttributedString *title = [GWSymbolString(@"sparkles", _root.chatVisible ? NSColor.controlAccentColor : NSColor.secondaryLabelColor, 11) mutableCopy];
    [title appendAttributedString:[[NSAttributedString alloc] initWithString:@" Claude" attributes:attributes]];
    _claudeChip.attributedTitle = title;
}

- (IBAction)toggleChat:(id)sender {
    [self buildSecondaryPanels];
    _root.chatVisible = !_root.chatVisible;
    [NSUserDefaults.standardUserDefaults setBool:_root.chatVisible forKey:@"chatVisible"];
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.25;
        context.allowsImplicitAnimation = YES;
        [self->_root layoutSubtreeIfNeeded];
    }];
    _root.needsLayout = YES;
    [self updateClaudeChip];
    if (_root.chatVisible) {
        [_chat focusComposer];
    } else {
        [self.window makeFirstResponder:_editorView];
    }
}

- (void)showChat {
    [self buildSecondaryPanels];
    if (!_root.chatVisible) {
        [self toggleChat:nil];
    } else {
        [_chat focusComposer];
    }
}

- (void)debugSendChatPrompt:(NSString *)prompt {
    [self showChat];
    [_chat sendPrompt:prompt includeSelection:NO];
}

- (IBAction)newClaudeChat:(id)sender {
    [self showChat];
    [_chat newChat];
    [_chat focusComposer];
}

/// ⇧⌘L: open the chat with the selected code attached, ready for a question.
- (IBAction)askClaudeAboutSelection:(id)sender {
    [self showChat];
    [_chat contextDidChange];
    [_chat focusComposer];
}

- (void)askClaude:(NSString *)prompt {
    [self showChat];
    [_chat sendPrompt:prompt includeSelection:YES];
}

- (IBAction)explainSelectionWithClaude:(id)sender {
    [self askClaude:@"Explain this code: what it does, and anything surprising about it."];
}

- (IBAction)findProblemsWithClaude:(id)sender {
    [self askClaude:@"Look for bugs, edge cases and risky spots in this code. Be specific and brief."];
}

- (IBAction)writeTestsWithClaude:(id)sender {
    [self askClaude:@"Write tests for this code. Follow how tests are done in this project, and put them where they belong."];
}

- (IBAction)improveWithClaude:(id)sender {
    [self askClaude:@"Suggest how to make this code simpler and clearer, then make the change."];
}

- (GWChatContext *)chatContext {
    GWChatContext *context = [GWChatContext new];
    Tab *tab = [self currentTab];
    if (tab == nullptr) {
        return context;
    }
    if (tab->document->path()) {
        context.filePath = @(tab->document->path()->c_str());
    }
    context.languageName = @(GWServices.shared.extensions.languageName(tab->document->languageId).c_str());
    const gw::Document &document = *tab->document;
    if (!document.selection.empty()) {
        gw::Range range = document.selection.range();
        context.selectedText = @(document.buffer().text(range).c_str());
        context.startLine = static_cast<NSInteger>(range.start.line) + 1;
        context.endLine = static_cast<NSInteger>(range.end.line) + 1;
        // A selection that ends at the very start of a line doesn't include that line.
        if (range.end.column == 0 && range.end.line > range.start.line) {
            context.endLine -= 1;
        }
    }
    return context;
}

- (void)openPath:(NSString *)path atLine:(NSInteger)line {
    NSString *absolute = path;
    if (![path hasPrefix:@"/"]) {
        absolute = [(_fileTree.rootURL.path ?: @"") stringByAppendingPathComponent:path];
    }
    [self openURL:[NSURL fileURLWithPath:absolute]];
    if (line > 0) {
        [_editorView jumpToLine:static_cast<size_t>(line - 1)];
    }
}

- (void)insertCodeAtCaret:(NSString *)code {
    Tab *tab = [self currentTab];
    if (tab == nullptr || tab->document->readOnly) {
        NSBeep();
        return;
    }
    gw::Range range = tab->document->selection.range();
    [_editorView replaceRange:range withText:std::string(code.UTF8String)];
    [self.window makeFirstResponder:_editorView];
}

/// Claude finished a reply: it may have changed files, so look again.
- (void)claudeFinishedTurn {
    [_git refresh];
    for (auto &tab : _tabs) {
        [self checkExternalChangeForTab:tab.get()];
    }
}

/// Best-matching files for an `@` mention in the chat.
- (NSArray<NSString *> *)suggestedFilesForQuery:(NSString *)query {
    std::shared_ptr<const FileIndex> snapshot = _fileIndex;
    if (!snapshot) {
        return @[];
    }
    std::string wanted = query.UTF8String;
    struct Match {
        int score;
        size_t index;
    };
    std::vector<Match> matches;
    for (size_t index = 0; index < snapshot->paths.size(); ++index) {
        std::optional<int> score = gw::fuzzyScore(wanted, snapshot->paths[index], snapshot->nameStarts[index]);
        if (score) {
            matches.push_back({*score, index});
        }
    }
    size_t shown = std::min<size_t>(matches.size(), 8);
    std::partial_sort(matches.begin(), matches.begin() + static_cast<long>(shown), matches.end(),
                      [](const Match &a, const Match &b) { return a.score > b.score; });
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (size_t rank = 0; rank < shown; ++rank) {
        [paths addObject:@(snapshot->paths[matches[rank].index].c_str())];
    }
    return paths;
}

// MARK: - Find and go to line

- (IBAction)showFind:(id)sender {
    if (![self currentTab]) {
        return;
    }
    NSString *selected = @(_editorView.selectedText.c_str());
    [_findBar showWithText:selected replace:NO];
}

- (IBAction)showFindAndReplace:(id)sender {
    if (![self currentTab]) {
        return;
    }
    [_findBar showWithText:@(_editorView.selectedText.c_str()) replace:YES];
}

- (IBAction)findNext:(id)sender { [_findBar findNext]; }
- (IBAction)findPrevious:(id)sender { [_findBar findPrevious]; }

- (IBAction)useSelectionForFind:(id)sender {
    NSString *selected = @(_editorView.selectedText.c_str());
    if (selected.length > 0) {
        [_findBar setSearchText:selected];
    }
}

/// ⌃G: jump to a line number.
- (IBAction)goToLine:(id)sender {
    Tab *tab = [self currentTab];
    if (tab == nullptr) {
        return;
    }
    size_t lineCount = tab->document->buffer().lineCount();
    __weak GWEditorView *editor = _editorView;
    [GWPalette.shared showOverWindow:self.window
                         placeholder:[NSString stringWithFormat:@"Go to line  (1 – %zu)", lineCount]
                            provider:^NSArray<GWPaletteItem *> *(NSString *query) {
        NSInteger number = query.integerValue;
        if (number < 1) {
            return @[];
        }
        number = MIN(number, static_cast<NSInteger>(lineCount));
        GWPaletteItem *item = [GWPaletteItem new];
        item.title = [NSString stringWithFormat:@"Go to line %ld", static_cast<long>(number)];
        item.symbol = @"arrow.down.to.line";
        item.symbolColor = NSColor.controlAccentColor;
        item.run = ^{
            [editor jumpToLine:static_cast<size_t>(number - 1)];
        };
        return @[item];
    }];
}

// MARK: - Search results

- (BOOL)isFileDirty:(NSString *)absolutePath {
    NSString *resolved = [absolutePath stringByResolvingSymlinksInPath];
    for (auto &tab : _tabs) {
        if (!tab->realPath.empty() && [@(tab->realPath.c_str()) isEqualToString:resolved] && tab->document->isDirty()) {
            return YES;
        }
    }
    return NO;
}

/// Files were rewritten on disk (Replace in Files): reload any that are open.
- (void)filesChangedOnDisk:(NSArray<NSString *> *)paths {
    NSMutableSet<NSString *> *resolved = [NSMutableSet set];
    for (NSString *path in paths) {
        [resolved addObject:[path stringByResolvingSymlinksInPath]];
    }
    for (auto &tab : _tabs) {
        if (!tab->realPath.empty() && [resolved containsObject:@(tab->realPath.c_str())]) {
            [self checkExternalChangeForTab:tab.get()];
        }
    }
    [_git refresh];
}

- (void)openSearchHitInFile:(NSString *)relative line:(NSUInteger)line column:(NSUInteger)column length:(NSUInteger)length {
    NSString *root = _fileTree.rootURL.path;
    if (root == nil) {
        return;
    }
    [self openURL:[NSURL fileURLWithPath:[root stringByAppendingPathComponent:relative]]];
    Tab *tab = [self currentTab];
    if (tab == nullptr || line >= tab->document->buffer().lineCount()) {
        return;
    }
    const std::string &text = tab->document->buffer().line(line);
    size_t start = std::min(column, text.size());
    size_t end = std::min(start + length, text.size());
    [_editorView selectRange:gw::Range{{line, start}, {line, end}}];
    [self.window makeFirstResponder:_editorView];
}

// MARK: - Panels built after the window appears

/// Puts a panel into the sidebar, filling it.
- (void)addSidebarPanel:(NSView *)panel {
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    [_sidebarContainer addSubview:panel];
    [NSLayoutConstraint activateConstraints:@[
        [panel.topAnchor constraintEqualToAnchor:_sidebarContainer.topAnchor],
        [panel.bottomAnchor constraintEqualToAnchor:_sidebarContainer.bottomAnchor],
        [panel.leadingAnchor constraintEqualToAnchor:_sidebarContainer.leadingAnchor],
        [panel.trailingAnchor constraintEqualToAnchor:_sidebarContainer.trailingAnchor],
    ]];
}

/// The source control, search and chat panels are not visible when the app starts, so they
/// are built a moment after the window is on screen. That keeps start-up fast: Auto Layout
/// would otherwise solve all of their constraints before the first frame.
- (void)buildSecondaryPanels {
    if (_secondaryPanelsBuilt) {
        return;
    }
    _secondaryPanelsBuilt = YES;
    __weak GWMainWindowController *weakSelf = self;

    // Source control.
    _sourceControl = [[GWSourceControlPanel alloc] initWithRepository:_git];
    _sourceControl.onOpenFile = ^(NSString *path) { [weakSelf openURL:[NSURL fileURLWithPath:path]]; };
    _sourceControl.onShowDiff = ^(NSString *path, BOOL staged) { [weakSelf showDiffForPath:path staged:staged]; };
    _sourceControl.onShowCommit = ^(NSString *hash, NSString *subject) { [weakSelf showCommit:hash subject:subject]; };
    _sourceControl.onSaveAll = ^{ [weakSelf saveAllDocuments]; };
    _sourceControl.onError = ^(NSString *title, NSString *message) { [weakSelf showErrorTitle:title message:message]; };
    _sourceControl.onRunInTerminal = ^(NSString *command) { [weakSelf runInTerminal:command]; };

    GWStartupMark(@"  built: source control panel");
    [self addSidebarPanel:_sourceControl.view];

    // Search.
    _search = [GWSearchPanel new];
    _search.filesProvider = ^std::shared_ptr<const std::vector<std::string>>() {
        GWMainWindowController *strongSelf = weakSelf;
        if (!strongSelf || !strongSelf->_fileIndex) {
            return nullptr;
        }
        // The vector lives inside the snapshot; an aliasing pointer keeps the snapshot alive.
        return std::shared_ptr<const std::vector<std::string>>(strongSelf->_fileIndex, &strongSelf->_fileIndex->paths);
    };
    _search.onOpenHit = ^(NSString *path, NSUInteger line, NSUInteger column, NSUInteger length) {
        [weakSelf openSearchHitInFile:path line:line column:column length:length];
    };
    _search.isFileDirty = ^BOOL(NSString *absolutePath) { return [weakSelf isFileDirty:absolutePath]; };
    _search.onFilesChanged = ^(NSArray<NSString *> *paths) { [weakSelf filesChangedOnDisk:paths]; };
    _search.onError = ^(NSString *title, NSString *message) { [weakSelf showErrorTitle:title message:message]; };

    GWStartupMark(@"  built: search panel");
    [self addSidebarPanel:_search.view];

    // Now that they exist, they can be shown, and told about the open folder.
    _sourceControl.view.hidden = _sidebarMode != 1;
    _search.view.hidden = _sidebarMode != 2;
    _search.rootFolder = _fileTree.rootURL.path;

    // The chat with Claude, on the right.
    _chat = [GWChatPanel new];
    _chat.contextProvider = ^GWChatContext *{ return [weakSelf chatContext]; };
    _chat.onOpenPath = ^(NSString *path, NSInteger line) { [weakSelf openPath:path atLine:line]; };
    _chat.onInsertCode = ^(NSString *code) { [weakSelf insertCodeAtCaret:code]; };
    _chat.onSaveAll = ^{ [weakSelf saveAllDocuments]; };
    _chat.onTurnFinished = ^{ [weakSelf claudeFinishedTurn]; };
    _chat.onClose = ^{ [weakSelf toggleChat:nil]; };
    _chat.fileSuggestions = ^NSArray<NSString *> *(NSString *query) { return [weakSelf suggestedFilesForQuery:query]; };
    _root.chat = [self glassWithCornerRadius:22 content:_chat.view];
    [_root addSubview:_root.chat positioned:NSWindowBelow relativeTo:_root.chatHandle];

    GWStartupMark(@"  built: chat panel");
    _chat.projectFolder = _fileTree.rootURL.path;
    [self applyTheme];
    _root.needsLayout = YES;
    GWStartupMark(@"secondary panels built");
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"terminalVisible"]) {
        [self setTerminalVisible:YES];
    }
}

// MARK: - Sidebar modes

- (void)setSidebarMode:(NSInteger)mode {
    if (mode != 0) {
        [self buildSecondaryPanels];
    }
    _sidebarMode = mode;
    _switcher.selectedIndex = mode;
    _filesPanel.hidden = mode != 0;
    _sourceControl.view.hidden = mode != 1;
    _search.view.hidden = mode != 2;
    if (mode == 1) {
        [_git refresh];
    }
}

- (void)revealSidebarMode:(NSInteger)mode {
    if (!_root.sidebarVisible) {
        [self toggleSidebar:nil];
    }
    [self setSidebarMode:mode];
}

- (IBAction)showExplorer:(id)sender { [self revealSidebarMode:0]; }
- (IBAction)showSourceControl:(id)sender { [self revealSidebarMode:1]; }

/// ⇧⌘F: search the whole project, starting from the selected word.
- (IBAction)findInFiles:(id)sender {
    [self revealSidebarMode:2];
    NSString *selected = nil;
    if (Tab *tab = [self currentTab]) {
        (void)tab;
        selected = @(_editorView.selectedText.c_str());
    }
    [_search focusWithText:selected];
}

// MARK: - File tree operations

/// The path relative to the project folder, or the full path if it is outside it.
- (NSString *)projectRelativePath:(NSString *)absolutePath {
    NSString *root = _fileTree.rootURL.path;
    if (root.length == 0) {
        return absolutePath;
    }
    NSString *prefix = [root stringByAppendingString:@"/"];
    if ([absolutePath hasPrefix:prefix]) {
        return [absolutePath substringFromIndex:prefix.length];
    }
    if ([absolutePath isEqualToString:root]) {
        return @"";
    }
    return absolutePath;
}

/// A file or folder was renamed or moved: tabs that show it (or files inside it) follow it.
- (void)fileItemMovedFrom:(NSURL *)from to:(NSURL *)to {
    NSString *oldBase = from.URLByStandardizingPath.path;
    NSString *newBase = to.URLByStandardizingPath.path;
    NSString *oldFolderPrefix = [oldBase stringByAppendingString:@"/"];
    for (auto &tab : _tabs) {
        if (tab->isVirtual || !tab->document->path()) {
            continue;
        }
        NSString *tabPath = @(tab->document->path()->c_str());
        NSString *newPath = nil;
        if ([tabPath isEqualToString:oldBase]) {
            newPath = newBase;
        } else if ([tabPath hasPrefix:oldFolderPrefix]) {
            newPath = [newBase stringByAppendingString:[tabPath substringFromIndex:oldBase.length]];
        }
        if (newPath == nil) {
            continue;
        }
        tab->document->movedTo(std::filesystem::path(newPath.UTF8String));
        tab->realPath = [newPath stringByResolvingSymlinksInPath].UTF8String;
        tab->headLoaded = false;
        [_language documentDidMove:tab->document.get() fromPath:tabPath];
        [self configureLanguageForTab:*tab];
    }
    Tab *current = [self currentTab];
    if (current != nullptr) {
        [_editorView setDocument:current->document.get() highlighter:current->highlighter.get() configuration:current->configuration];
    }
    [self refresh];
    [_git refresh];
}

/// A file or folder went to the Trash: close its tabs. Unsaved edits are never thrown away
/// silently, so a tab with edits stays open (as an untitled-looking copy the user can save).
- (void)fileItemTrashed:(NSURL *)url {
    NSString *base = url.URLByStandardizingPath.path;
    NSString *folderPrefix = [base stringByAppendingString:@"/"];
    for (NSInteger index = static_cast<NSInteger>(_tabs.size()) - 1; index >= 0; --index) {
        Tab &tab = *_tabs[static_cast<size_t>(index)];
        if (tab.isVirtual || !tab.document->path()) {
            continue;
        }
        NSString *tabPath = @(tab.document->path()->c_str());
        BOOL isTheItem = [tabPath isEqualToString:base];
        BOOL isInsideIt = [tabPath hasPrefix:folderPrefix];
        if (!isTheItem && !isInsideIt) {
            continue;
        }
        if (tab.document->isDirty()) {
            continue;
        }
        [self closeTabAtIndex:index];
    }
    [_git refresh];
}

- (NSString *)shellQuoted:(NSString *)text {
    NSString *escaped = [text stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
    return [NSString stringWithFormat:@"'%@'", escaped];
}

- (void)openTerminalInFolder:(NSURL *)folder {
    NSString *command = [NSString stringWithFormat:@"cd %@ && clear", [self shellQuoted:folder.path]];
    [self runInTerminal:command];
}

- (void)findInFolder:(NSURL *)folder {
    [self revealSidebarMode:2];
    [_search restrictToFolder:[self projectRelativePath:folder.path]];
}

- (void)askClaudeAboutItem:(NSURL *)url {
    NSString *relative = [self projectRelativePath:url.path];
    BOOL isDirectory = NO;
    [NSFileManager.defaultManager fileExistsAtPath:url.path isDirectory:&isDirectory];
    NSString *kind = isDirectory ? @"folder" : @"file";
    NSString *text = [NSString stringWithFormat:@"About the %@ @%@: ", kind, relative];
    [self showChat];
    [_chat prefillComposer:text];
}

// MARK: - Source control

- (void)showErrorTitle:(NSString *)title message:(NSString *)message {
    NSAlert *alert = [NSAlert new];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = title;
    alert.informativeText = message;
    [alert addButtonWithTitle:@"OK"];
    [alert beginSheetModalForWindow:self.window completionHandler:nil];
}

/// Saves every file that has unsaved changes (before a commit, or before asking Claude).
- (void)saveAllDocuments {
    for (auto &tab : _tabs) {
        if (tab->isVirtual || !tab->document->isDirty() || !tab->document->path()) {
            continue;
        }
        std::string error;
        tab->document->save(&error);
    }
    [self refresh];
}

- (void)gitStatusChanged:(NSNotification *)notification {
    [self updateBranchChip];
    [_switcher setBadge:static_cast<NSInteger>(_git.status.changes.size()) forIndex:1];
    if (Tab *tab = [self currentTab]) {
        [self refreshChangesForTab:tab];
    }
}

- (void)updateBranchChip {
    const gw::git::Status &status = _git.status;
    _branchChip.hidden = !status.isRepository;
    if (!status.isRepository) {
        return;
    }
    NSString *name = status.branch.empty() ? [NSString stringWithFormat:@"%@", @(status.headCommit.substr(0, 7).c_str())]
                                           : @(status.branch.c_str());
    if (status.headCommit.empty() && status.branch.empty()) {
        name = @"no commits";
    }
    NSDictionary *attributes = @{NSFontAttributeName: [NSFont systemFontOfSize:11.5 weight:NSFontWeightSemibold],
                                 NSForegroundColorAttributeName: NSColor.labelColor};
    NSMutableAttributedString *title = [GWSymbolString(@"arrow.triangle.branch", NSColor.controlAccentColor, 11) mutableCopy];
    [title appendAttributedString:[[NSAttributedString alloc] initWithString:[@" " stringByAppendingString:name] attributes:attributes]];
    NSDictionary *quiet = @{NSFontAttributeName: [NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium],
                            NSForegroundColorAttributeName: NSColor.secondaryLabelColor};
    if (status.ahead > 0 || status.behind > 0) {
        NSString *counts = [NSString stringWithFormat:@"  ↑%d ↓%d", status.ahead, status.behind];
        [title appendAttributedString:[[NSAttributedString alloc] initWithString:counts attributes:quiet]];
    }
    if (_git.isBusy) {
        [title appendAttributedString:[[NSAttributedString alloc] initWithString:[@"  " stringByAppendingString:_git.busyTitle ?: @""]
                                                                     attributes:quiet]];
    }
    _branchChip.attributedTitle = title;
}

- (void)branchChipClicked:(id)sender {
    [self buildSecondaryPanels];
    [_sourceControl showBranchMenuRelativeToView:_branchChip];
}

// ---- Diff and commit tabs

/// Shows text that isn't a file in a read-only tab. A tab with the same `key` is replaced,
/// so clicking the same change twice doesn't pile up tabs.
- (void)showVirtualText:(NSString *)text title:(NSString *)title language:(std::string)language key:(std::string)key diff:(BOOL)diff {
    NSInteger existing = -1;
    for (size_t index = 0; index < _tabs.size(); ++index) {
        if (_tabs[index]->isVirtual && _tabs[index]->key == key) {
            existing = static_cast<NSInteger>(index);
            break;
        }
    }
    if (existing >= 0) {
        if (existing == _selected) {
            [_editorView setDocument:nullptr highlighter:nullptr configuration:{}];
        }
        _tabs.erase(_tabs.begin() + existing);
        _selected = -1;
    }
    std::string body = text.UTF8String ?: "";
    if (body.empty()) {
        body = "No changes.\n";
    }
    auto document = std::make_unique<gw::Document>(gw::Document::readOnlyText(body, title.UTF8String));
    [self addTab:std::move(document) atIndex:existing configure:^(Tab &tab) {
        tab.isVirtual = true;
        tab.key = key;
        tab.forcedLanguage = language;
        if (diff) {
            tab.lineTints = tintsForDiff(tab.document->buffer().text());
        }
    }];
}

- (void)showDiffForPath:(NSString *)path staged:(BOOL)staged {
    std::string relative = path.UTF8String;
    [_git read:^id(NSString *root) {
        return @(gw::git::readDiff(root.UTF8String, relative, staged).c_str());
    } completion:^(id text) {
        NSString *title = [NSString stringWithFormat:@"%@ (%@)", path.lastPathComponent, staged ? @"Staged" : @"Changes"];
        std::string key = std::string(staged ? "staged:" : "changes:") + relative;
        [self showVirtualText:text title:title language:"diff" key:key diff:YES];
    }];
}

// MARK: - Interaction benchmark

static void reportTimes(const char *name, std::vector<double> &milliseconds) {
    if (milliseconds.empty()) {
        return;
    }
    std::sort(milliseconds.begin(), milliseconds.end());
    double total = 0;
    for (double value : milliseconds) {
        total += value;
    }
    auto percentile = [&](double fraction) {
        return milliseconds[std::min(milliseconds.size() - 1, static_cast<size_t>(fraction * milliseconds.size()))];
    };
    fprintf(stderr, "  %-34s avg %6.2f ms   median %6.2f   p95 %6.2f   worst %7.2f   (%zu samples)\n", name,
            total / milliseconds.size(), percentile(0.5), percentile(0.95), milliseconds.back(), milliseconds.size());
}

/// Runs the work and returns how many milliseconds of main-thread time it took, including
/// drawing the result.
static double timed(void (^work)(void)) {
    CFTimeInterval start = CACurrentMediaTime();
    work();
    return (CACurrentMediaTime() - start) * 1000;
}

- (void)runInteractionBenchmark {
    Tab *tab = [self currentTab];
    if (tab == nullptr) {
        fprintf(stderr, "benchmark: open a file first\n");
        [NSApp terminate:nil];
        return;
    }
    [self.window makeFirstResponder:_editorView];
    NSScrollView *scroll = _card.scrollView;
    size_t lines = tab->document->buffer().lineCount();
    fprintf(stderr, "\nInteraction benchmark: %s (%zu lines)\n", tab->document->displayName().c_str(), lines);

    // Jumping straight into the middle of a huge file.
    std::vector<double> jumps;
    for (double fraction : {0.25, 0.5, 0.75, 0.9}) {
        size_t target = static_cast<size_t>(fraction * static_cast<double>(lines));
        jumps.push_back(timed(^{
            [self->_editorView jumpToLine:target];
            [self->_root displayIfNeeded];
            [self->_editorView displayIfNeeded];
        }));
    }
    reportTimes("jump to a line far into the file", jumps);

    // Typing: insert a character and draw the result, the way a keystroke does.
    [_editorView jumpToLine:lines / 3];
    [_root displayIfNeeded];
    std::vector<double> typing;
    for (int index = 0; index < 300; ++index) {
        typing.push_back(timed(^{
            [self->_editorView insertText:@"a" replacementRange:NSMakeRange(NSNotFound, 0)];
            [self->_root displayIfNeeded];
            [self->_editorView displayIfNeeded];
        }));
    }
    reportTimes("type a character and redraw", typing);

    // Pressing Return in the middle of the file.
    std::vector<double> returns;
    for (int index = 0; index < 60; ++index) {
        returns.push_back(timed(^{
            [self->_editorView insertNewline:nil];
            [self->_root displayIfNeeded];
            [self->_editorView displayIfNeeded];
        }));
    }
    reportTimes("press Return and redraw", returns);

    // Scrolling a screenful at a time, and by small wheel steps.
    [_editorView jumpToLine:0];
    [_root displayIfNeeded];
    NSClipView *clip = scroll.contentView;
    CGFloat page = NSHeight(clip.bounds);
    std::vector<double> pages;
    for (int index = 1; index <= 120; ++index) {
        pages.push_back(timed(^{
            [clip scrollToPoint:NSMakePoint(0, index * page * 0.95)];
            [scroll reflectScrolledClipView:clip];
            [self->_root displayIfNeeded];
            [self->_editorView displayIfNeeded];
        }));
    }
    reportTimes("scroll one screenful and redraw", pages);

    std::vector<double> steps;
    CGFloat origin = NSMinY(clip.bounds);
    for (int index = 1; index <= 400; ++index) {
        steps.push_back(timed(^{
            [clip scrollToPoint:NSMakePoint(0, origin + index * 12)];
            [scroll reflectScrolledClipView:clip];
            [self->_root displayIfNeeded];
            [self->_editorView displayIfNeeded];
        }));
    }
    reportTimes("scroll a few lines and redraw", steps);

    // Undoing the typing.
    std::vector<double> undos;
    for (int index = 0; index < 60; ++index) {
        undos.push_back(timed(^{
            [NSApp sendAction:@selector(undo:) to:self->_editorView from:nil];
            [self->_root displayIfNeeded];
            [self->_editorView displayIfNeeded];
        }));
    }
    reportTimes("undo and redraw", undos);
    fprintf(stderr, "\nbenchmark done\n");
    [NSApp terminate:nil];
}

/// For development: run something colourful in a new terminal (see GLASSWORK_ACTIONS).
/// Developer check: open README.md, rename it on disk the way the file tree does, and confirm
/// the tab follows.
- (IBAction)debugOpenReadme:(id)sender {
    NSURL *readme = [_fileTree.rootURL URLByAppendingPathComponent:@"README.md"];
    [self openURL:readme];
}

- (IBAction)debugRenameReadme:(id)sender {
    NSURL *from = [_fileTree.rootURL URLByAppendingPathComponent:@"README.md"];
    NSURL *to = [_fileTree.rootURL URLByAppendingPathComponent:@"GUIDE.txt"];
    [NSFileManager.defaultManager moveItemAtURL:from toURL:to error:nil];
    [self fileItemMovedFrom:from to:to];
    [_fileTree reloadDirectory:_fileTree.rootURL];
}

- (IBAction)debugTrashGuide:(id)sender {
    NSURL *guide = [_fileTree.rootURL URLByAppendingPathComponent:@"GUIDE.txt"];
    [self fileItemTrashed:guide];
}

/// Developer hook: sends an editor action (such as moveLinesDown:) straight to the editor.
- (BOOL)debugPerformEditorAction:(SEL)action {
    if (![_editorView respondsToSelector:action]) {
        return NO;
    }
    [self.window makeFirstResponder:_editorView];
    [_editorView tryToPerform:action with:nil];
    return YES;
}

/// Developer check: shows the file tree's right-click menu for the second row.
- (IBAction)debugShowTreeMenu:(id)sender {
    NSView *tree = _fileTree.view.documentView;
    NSMenu *menu = [_fileTree contextMenuForRow:1];
    NSPoint where = NSMakePoint(60, 40);
    NSEvent *event = [NSEvent mouseEventWithType:NSEventTypeRightMouseDown
                                        location:[tree convertPoint:where toView:nil]
                                   modifierFlags:0
                                       timestamp:0
                                    windowNumber:self.window.windowNumber
                                         context:nil
                                     eventNumber:0
                                      clickCount:1
                                        pressure:1];
    [NSMenu popUpContextMenu:menu withEvent:event forView:tree];
}

- (IBAction)debugNewFileSheet:(id)sender {
    [_fileTree createFileInFolder:_fileTree.rootURL];
}

/// Developer check: acts as if the pointer had rested on the word at the caret.
- (IBAction)debugHoverAtCaret:(id)sender {
    Tab *tab = [self currentTab];
    if (tab == nullptr) {
        return;
    }
    gw::Position caret = tab->document->selection.caret;
    gw::Range word = tab->document->buffer().wordAt(caret);
    [self hoverAtPosition:word.start word:word];
}

/// Developer check: types "sq" at the caret, one letter at a time, as a person would.
- (IBAction)debugTypeSq:(id)sender {
    [self.window makeFirstResponder:_editorView];
    [_editorView insertText:@"s" replacementRange:NSMakeRange(NSNotFound, 0)];
    [_editorView insertText:@"q" replacementRange:NSMakeRange(NSNotFound, 0)];
}

/// Developer check: presses Tab in the editor (accepts the highlighted suggestion).
- (IBAction)debugPressTab:(id)sender {
    [_editorView doCommandBySelector:@selector(insertTab:)];
}

/// Developer check: renames the symbol at the caret to "squared" without asking.
- (IBAction)debugRenameToSquared:(id)sender {
    Tab *tab = [self currentTab];
    if (tab == nullptr) {
        return;
    }
    gw::Document *document = tab->document.get();
    gw::lsp::Json params = [_language positionParamsForDocument:document position:document->selection.caret];
    params["newName"] = "squared";
    __weak GWMainWindowController *weakSelf = self;
    [_language request:@"textDocument/rename" params:params document:document requireSameVersion:NO
            completion:^(const gw::lsp::Json &result, NSString *error) {
        if (error != nil) {
            fprintf(stderr, "rename failed: %s\n", error.UTF8String);
            return;
        }
        [weakSelf applyWorkspaceEdit:result];
    }];
}

/// Developer check: types "square(" at the caret (shows the signature help).
- (IBAction)debugTypeCall:(id)sender {
    [self.window makeFirstResponder:_editorView];
    for (NSString *character in @[@"s", @"q", @"u", @"a", @"r", @"e", @"("]) {
        [_editorView insertText:character replacementRange:NSMakeRange(NSNotFound, 0)];
    }
}

- (IBAction)debugTerminalDemo:(id)sender {
    [self runInTerminal:@"clear; printf '\\e[1;31mbold red\\e[0m \\e[4munderline\\e[0m \\e[3mitalic\\e[0m \\e[38;2;255;160;0mtruecolor\\e[0m \\e[7minverse\\e[0m\\n'; ls -la /System | head -8; echo '日本語 ✓ ─│┌┐└┘╭╮'; git -C ~/Code/Glasswork status -sb | head -3"];
}

- (IBAction)debugTerminalTop:(id)sender {
    [self runInTerminal:@"top -l 2 -n 6 -s 1"];
}

/// For development: run a project search and open find with replace (see GLASSWORK_ACTIONS).
- (IBAction)debugSearchTotal:(id)sender {
    [self revealSidebarMode:2];
    [_search focusWithText:@"total"];
}

- (IBAction)debugFindTotal:(id)sender {
    [_findBar showWithText:@"total" replace:YES];
}

/// For development: shows the details popover for the first change in the open file.
- (IBAction)debugShowFirstChange:(id)sender {
    if (Tab *tab = [self currentTab]) {
        [self jumpToHunkAtIndex:0 tabIdentifier:tab->identifier showDetails:YES];
    }
}

/// For development: opens the diff of the first changed file (see GLASSWORK_ACTIONS).
- (IBAction)debugShowFirstDiff:(id)sender {
    for (const gw::git::FileChange &change : _git.status.changes) {
        [self showDiffForPath:@(change.path.c_str()) staged:change.hasStagedChange() && !change.hasUnstagedChange()];
        return;
    }
}

- (void)showCommit:(NSString *)hash subject:(NSString *)subject {
    std::string commit = hash.UTF8String;
    [_git read:^id(NSString *root) {
        return @(gw::git::readCommitDiff(root.UTF8String, commit).c_str());
    } completion:^(id text) {
        NSString *title = [NSString stringWithFormat:@"%@ %@", [hash substringToIndex:MIN(hash.length, 7UL)], subject];
        [self showVirtualText:text title:title language:"diff" key:"commit:" + commit diff:YES];
    }];
}

// ---- Change bars in the gutter

- (Tab *)tabWithIdentifier:(uint64_t)identifier {
    for (auto &tab : _tabs) {
        if (tab->identifier == identifier) {
            return tab.get();
        }
    }
    return nullptr;
}

/// Recompute the bars a moment after typing stops.
- (void)scheduleChangeRefresh {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(refreshChangesForCurrentTab) object:nil];
    [self performSelector:@selector(refreshChangesForCurrentTab) withObject:nil afterDelay:0.15];
}

- (void)refreshChangesForCurrentTab {
    if (Tab *tab = [self currentTab]) {
        [self refreshChangesForTab:tab];
    }
}

- (void)clearChangesForTab:(Tab *)tab {
    tab->changes.clear();
    tab->hunks.clear();
    if (tab == [self currentTab]) {
        [_editorView setLineChanges:{}];
    }
}

/// True if git lists this file as new (untracked, or added but not yet committed).
- (BOOL)isNewFileInRepository:(NSString *)relative {
    std::string wanted = relative.UTF8String;
    for (const gw::git::FileChange &change : _git.status.changes) {
        if (change.path == wanted) {
            return change.isUntracked() || change.staged == gw::git::ChangeKind::Added;
        }
    }
    return NO;
}

- (void)refreshChangesForTab:(Tab *)tab {
    if (tab == nullptr || tab->isVirtual || !tab->document->path() || !_git.isRepository) {
        if (tab != nullptr) {
            [self clearChangesForTab:tab];
        }
        return;
    }
    NSString *path = @(tab->document->path()->c_str());
    NSString *relative = [_git relativePathForAbsolute:path];
    if (relative == nil) {
        [self clearChangesForTab:tab];
        return;
    }

    // The committed text is fetched once per commit and file, then kept.
    if (!tab->headLoaded || tab->headCommit != _git.status.headCommit) {
        uint64_t identifier = tab->identifier;
        [_git headTextForPath:path completion:^(std::shared_ptr<const std::string> text) {
            Tab *found = [self tabWithIdentifier:identifier];
            if (found == nullptr) {
                return;
            }
            found->headText = text;
            found->headLoaded = true;
            found->headCommit = self->_git.status.headCommit;
            [self recomputeChangesForTab:found relative:relative];
        }];
        return;
    }
    [self recomputeChangesForTab:tab relative:relative];
}

- (void)recomputeChangesForTab:(Tab *)tab relative:(NSString *)relative {
    if (!tab->headText) {
        // Not in the last commit. If git knows it as a new file, every line is an addition.
        if ([self isNewFileInRepository:relative]) {
            size_t lines = tab->document->buffer().lineCount();
            tab->hunks = {gw::DiffHunk{0, 0, 0, lines}};
            tab->changes = gw::gutterChanges(tab->hunks);
            if (tab == [self currentTab]) {
                [_editorView setLineChanges:tab->changes];
            }
        } else {
            [self clearChangesForTab:tab];
        }
        return;
    }

    uint64_t identifier = tab->identifier;
    uint64_t version = tab->document->version();
    std::shared_ptr<const std::string> head = tab->headText;
    std::string text = tab->document->buffer().text();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        std::vector<std::string_view> oldLines = gw::splitLines(*head);
        std::vector<std::string_view> newLines = gw::splitLines(text);
        std::vector<gw::DiffHunk> hunks = gw::diffLines(oldLines, newLines);
        std::vector<gw::LineChange> changes = gw::gutterChanges(hunks);
        dispatch_async(dispatch_get_main_queue(), ^{
            Tab *found = [self tabWithIdentifier:identifier];
            if (found == nullptr || found->document->version() != version) {
                return;  // edited again meanwhile; a newer run follows
            }
            found->hunks = hunks;
            found->changes = changes;
            if (found == [self currentTab]) {
                [self->_editorView setLineChanges:changes];
            }
        });
    });
}

// ---- Looking at one change

/// The index of the hunk that covers a line of the new text, or -1.
- (NSInteger)hunkIndexForLine:(size_t)line inTab:(Tab *)tab {
    for (size_t index = 0; index < tab->hunks.size(); ++index) {
        const gw::DiffHunk &hunk = tab->hunks[index];
        bool covers = hunk.newCount > 0 && line >= hunk.newStart && line < hunk.newStart + hunk.newCount;
        bool removalHere = hunk.newCount == 0 && (line == hunk.newStart || line + 1 == hunk.newStart);
        if (covers || removalHere) {
            return static_cast<NSInteger>(index);
        }
    }
    return -1;
}

- (NSArray<NSString *> *)stringsFromLines:(const std::vector<std::string_view> &)lines start:(size_t)start count:(size_t)count {
    NSMutableArray<NSString *> *strings = [NSMutableArray array];
    for (size_t index = start; index < start + count && index < lines.size(); ++index) {
        NSString *text = [[NSString alloc] initWithBytes:lines[index].data() length:lines[index].size() encoding:NSUTF8StringEncoding];
        [strings addObject:text ?: @""];
    }
    return strings;
}

- (void)showChangeAtLine:(size_t)line rect:(NSRect)rect {
    Tab *tab = [self currentTab];
    if (tab == nullptr || !tab->headText) {
        return;
    }
    NSInteger index = [self hunkIndexForLine:line inTab:tab];
    if (index < 0) {
        return;
    }
    [self showHunkAtIndex:static_cast<size_t>(index) rect:rect];
}

- (void)showHunkAtIndex:(size_t)index rect:(NSRect)rect {
    Tab *tab = [self currentTab];
    if (tab == nullptr || !tab->headText || index >= tab->hunks.size()) {
        return;
    }
    gw::DiffHunk hunk = tab->hunks[index];
    std::string current = tab->document->buffer().text();
    std::vector<std::string_view> oldLines = gw::splitLines(*tab->headText);
    std::vector<std::string_view> newLines = gw::splitLines(current);
    NSArray<NSString *> *oldStrings = [self stringsFromLines:oldLines start:hunk.oldStart count:hunk.oldCount];
    NSArray<NSString *> *newStrings = [self stringsFromLines:newLines start:hunk.newStart count:hunk.newCount];

    NSString *title = hunk.newCount > 0
        ? (hunk.newCount == 1 ? [NSString stringWithFormat:@"Line %zu", hunk.newStart + 1]
                              : [NSString stringWithFormat:@"Lines %zu–%zu", hunk.newStart + 1, hunk.newStart + hunk.newCount])
        : [NSString stringWithFormat:@"Deleted at line %zu", hunk.newStart + 1];
    NSString *summary = [NSString stringWithFormat:@"+%zu  −%zu", hunk.newCount, hunk.oldCount];

    // Rectangles from the gutter are in the gutter's coordinates.
    NSView *gutter = _editorView.gutterView;
    __weak GWMainWindowController *weakSelf = self;
    uint64_t identifier = tab->identifier;
    NSString *relative = tab->document->path() ? [_git relativePathForAbsolute:@(tab->document->path()->c_str())] : nil;

    // Buttons that don't apply (nothing before the first change, no repository path…) are
    // left out by passing nil.
    void (^stage)(void) = nil;
    if (relative != nil) {
        stage = ^{
            [weakSelf stageHunkAtIndex:index tabIdentifier:identifier relative:relative];
        };
    }
    void (^revert)(void) = ^{
        [weakSelf revertHunkAtIndex:index tabIdentifier:identifier];
    };
    void (^previous)(void) = nil;
    if (index > 0) {
        previous = ^{
            [weakSelf jumpToHunkAtIndex:index - 1 tabIdentifier:identifier showDetails:YES];
        };
    }
    void (^next)(void) = nil;
    if (index + 1 < tab->hunks.size()) {
        next = ^{
            [weakSelf jumpToHunkAtIndex:index + 1 tabIdentifier:identifier showDetails:YES];
        };
    }
    [GWChangePopover showRelativeToRect:rect ofView:gutter title:title oldLines:oldStrings newLines:newStrings count:summary
                                onStage:stage onRevert:revert onPrevious:previous onNext:next];
}

- (void)jumpToHunkAtIndex:(size_t)index tabIdentifier:(uint64_t)identifier showDetails:(BOOL)showDetails {
    Tab *tab = [self tabWithIdentifier:identifier];
    if (tab == nullptr || tab != [self currentTab] || index >= tab->hunks.size()) {
        return;
    }
    const gw::DiffHunk &hunk = tab->hunks[index];
    [_editorView jumpToLine:hunk.newStart];
    if (!showDetails) {
        return;
    }
    // Wait a moment for the scroll, then point at the bar.
    dispatch_async(dispatch_get_main_queue(), ^{
        NSView *gutter = self->_editorView.gutterView;
        CGFloat lineHeight = NSHeight(gutter.bounds) > 0 ? ceil(GWServices.shared.fontSize * 1.65) : 20;
        CGFloat top = hunk.newStart * lineHeight - NSMinY(self->_editorView.visibleRect);
        NSRect bar = NSMakeRect(NSWidth(gutter.bounds) - 6, top, 6, MAX(hunk.newCount, 1UL) * lineHeight);
        [self showHunkAtIndex:index rect:bar];
    });
}

- (void)revertHunkAtIndex:(size_t)index tabIdentifier:(uint64_t)identifier {
    Tab *tab = [self tabWithIdentifier:identifier];
    if (tab == nullptr || !tab->headText || index >= tab->hunks.size()) {
        return;
    }
    gw::DiffHunk hunk = tab->hunks[index];
    std::vector<std::string_view> oldLines = gw::splitLines(*tab->headText);
    std::string oldText;
    for (size_t line = hunk.oldStart; line < hunk.oldStart + hunk.oldCount && line < oldLines.size(); ++line) {
        if (line > hunk.oldStart) {
            oldText += "\n";
        }
        oldText += oldLines[line];
    }

    const gw::TextBuffer &buffer = tab->document->buffer();
    size_t lineCount = buffer.lineCount();
    gw::Range range;
    std::string replacement;
    if (hunk.newStart + hunk.newCount < lineCount) {
        // Lines follow the change: swap whole lines, line breaks included.
        range = {{hunk.newStart, 0}, {hunk.newStart + hunk.newCount, 0}};
        replacement = hunk.oldCount > 0 ? oldText + "\n" : std::string();
    } else if (hunk.newStart > 0) {
        // The change runs to the end of the file: start from the end of the line before it.
        range = {{hunk.newStart - 1, buffer.line(hunk.newStart - 1).size()}, buffer.end()};
        replacement = hunk.oldCount > 0 ? "\n" + oldText : std::string();
    } else {
        range = {{0, 0}, buffer.end()};
        replacement = oldText;
    }
    [_editorView replaceRange:range withText:replacement];
    [_editorView flashLines:hunk.newStart count:hunk.oldCount];
}

- (void)stageHunkAtIndex:(size_t)index tabIdentifier:(uint64_t)identifier relative:(NSString *)relative {
    Tab *tab = [self tabWithIdentifier:identifier];
    if (tab == nullptr || !tab->headText || index >= tab->hunks.size()) {
        return;
    }
    gw::DiffHunk hunk = tab->hunks[index];
    std::string current = tab->document->buffer().text();
    std::vector<std::string_view> oldLines = gw::splitLines(*tab->headText);
    std::vector<std::string_view> newLines = gw::splitLines(current);
    std::string patch = gw::patchForHunk(relative.UTF8String, oldLines, newLines, hunk);
    [_git perform:@"Staging…" operation:^gw::git::CommandResult(NSString *root) {
        return gw::git::applyPatch(root.UTF8String, patch, true, false);
    } completion:^(gw::git::CommandResult result) {
        if (!result.ok) {
            [self showErrorTitle:@"Couldn't stage this change"
                         message:@(result.error.c_str())];
        }
    }];
}

/// Go to the next or previous change in the file (from the caret).
- (void)stepToChange:(int)direction {
    Tab *tab = [self currentTab];
    if (tab == nullptr || tab->hunks.empty()) {
        NSBeep();
        return;
    }
    size_t caretLine = tab->document->selection.caret.line;
    long target = -1;
    if (direction > 0) {
        for (size_t index = 0; index < tab->hunks.size(); ++index) {
            if (tab->hunks[index].newStart > caretLine) {
                target = static_cast<long>(index);
                break;
            }
        }
        if (target < 0) {
            target = 0;  // wrap around
        }
    } else {
        for (size_t index = tab->hunks.size(); index-- > 0;) {
            if (tab->hunks[index].newStart < caretLine) {
                target = static_cast<long>(index);
                break;
            }
        }
        if (target < 0) {
            target = static_cast<long>(tab->hunks.size()) - 1;
        }
    }
    [self jumpToHunkAtIndex:static_cast<size_t>(target) tabIdentifier:tab->identifier showDetails:NO];
}

- (IBAction)nextChange:(id)sender { [self stepToChange:1]; }
- (IBAction)previousChange:(id)sender { [self stepToChange:-1]; }

// ---- Watching the folder for outside changes

- (void)startWatchingFolder:(NSString *)folder {
    [_watcher stop];
    __weak GWMainWindowController *weakSelf = self;
    _watcher = [[GWFolderWatcher alloc] initWithFolder:folder handler:^(NSArray<NSString *> *paths) {
        [weakSelf folderChanged:paths];
    }];
}

- (void)folderChanged:(NSArray<NSString *> *)paths {
    NSSet<NSString *> *changed = [NSSet setWithArray:paths];
    NSMutableSet<NSString *> *changedFolders = [NSMutableSet set];
    for (NSString *path in paths) {
        [changedFolders addObject:path.stringByDeletingLastPathComponent];
    }
    for (NSString *folderPath in changedFolders) {
        [_fileTree reloadDirectory:[NSURL fileURLWithPath:folderPath isDirectory:YES]];
    }
    for (auto &tab : _tabs) {
        if (!tab->realPath.empty() && [changed containsObject:@(tab->realPath.c_str())]) {
            [self checkExternalChangeForTab:tab.get()];
        }
    }
    [_git refresh];
}

/// A file was changed by something other than us (Claude, a build, git…).
- (void)checkExternalChangeForTab:(Tab *)tab {
    gw::Document &document = *tab->document;
    if (tab->isVirtual || !document.fileChangedOnDisk()) {
        return;
    }
    if (!document.isDirty()) {
        std::string error;
        gw::Document::ReloadResult result = document.reloadFromDisk(&error);
        if (result == gw::Document::ReloadResult::Reloaded) {
            [_language documentDidChange:&document];
        }
        if (result == gw::Document::ReloadResult::Reloaded && tab == [self currentTab]) {
            [_editorView invalidateLayout];
            [_editorView flashLines:document.reloadedFirstLine count:document.reloadedLineCount];
            [self refresh];
            [self scheduleChangeRefresh];
        } else if (result == gw::Document::ReloadResult::Reloaded) {
            [self refresh];
        }
        return;
    }

    // Unsaved edits and a different file on disk: ask, once per change.
    if (tab != [self currentTab]) {
        return;  // asked when the tab is shown
    }
    [self askAboutDiskChangeForTab:tab];
}

- (void)askAboutDiskChangeForTab:(Tab *)tab {
    NSAlert *alert = [NSAlert new];
    alert.messageText = [NSString stringWithFormat:@"“%s” changed on disk", tab->document->displayName().c_str()];
    alert.informativeText = @"You have unsaved edits in Glasswork, and the file was changed somewhere else.";
    [alert addButtonWithTitle:@"Keep My Version"];
    [alert addButtonWithTitle:@"Load From Disk"];
    uint64_t identifier = tab->identifier;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        Tab *found = [self tabWithIdentifier:identifier];
        if (found == nullptr) {
            return;
        }
        if (response == NSAlertSecondButtonReturn) {
            found->document->reloadFromDisk();
            [self->_editorView invalidateLayout];
            [self refresh];
            [self scheduleChangeRefresh];
        } else {
            // Remember that we asked, so we don't ask again until the file changes once more.
            found->document->acknowledgeDiskChange();
        }
    }];
}

- (void)windowDidResignKey:(NSNotification *)notification {
    [self autoSaveDirtyTabs];
}

- (void)applicationBecameActive:(NSNotification *)notification {
    for (auto &tab : _tabs) {
        [self checkExternalChangeForTab:tab.get()];
    }
    [_git refresh];
}

// MARK: - Code intelligence

/// Creates the language service and connects it to the editor: problems, hover and completion.
- (void)setUpLanguageService {
    __weak GWMainWindowController *weakSelf = self;
    _language = [GWLanguageService new];
    _language.enabled = GWServices.shared.settings.languageServers;
    _language.onDiagnosticsChanged = ^(gw::Document *document) {
        [weakSelf diagnosticsChangedForDocument:document];
    };
    _language.onStatusChanged = ^{
        [weakSelf updateStatus];
    };

    _suggestions = [GWSuggestionPopup new];
    _suggestions.onAccept = ^(GWSuggestion *suggestion) {
        [weakSelf acceptSuggestion:suggestion];
    };

    _editorView.onHoverRequest = ^(gw::Position position, gw::Range word) {
        [weakSelf hoverAtPosition:position word:word];
    };
    _editorView.onHoverEnd = ^{
        GWMainWindowController *strongSelf = weakSelf;
        if (strongSelf != nil) {
            ++strongSelf->_hoverToken;
        }
        [GWHoverPopover hide];
    };
    _editorView.onCompletionKey = ^BOOL(SEL selector) {
        GWMainWindowController *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return NO;
        }
        return [strongSelf->_suggestions handleSelector:selector];
    };
    _editorView.onTypedText = ^(NSString *typed) {
        [weakSelf editorTypedText:typed];
    };
}

- (void)diagnosticsChangedForDocument:(gw::Document *)document {
    Tab *tab = [self currentTab];
    if (tab != nullptr && tab->document.get() == document) {
        [_editorView setDiagnostics:[_language diagnosticsForDocument:document]];
    }
    [self updateStatus];
}

// ---- Hover

/// The plain text of a hover answer, which a server may give as a string, a marked string, a
/// list of them, or a MarkupContent.
static NSString *markdownFromHover(const gw::lsp::Json &contents) {
    using Json = gw::lsp::Json;
    auto fromOne = [](const Json &piece) -> std::string {
        if (piece.is_string()) {
            return piece.get<std::string>();
        }
        if (piece.is_object() && piece.contains("value")) {
            std::string value = piece["value"].get<std::string>();
            if (piece.contains("language") && piece["language"].is_string()) {
                return "```" + piece["language"].get<std::string>() + "\n" + value + "\n```";
            }
            return value;
        }
        return std::string();
    };
    std::string result;
    if (contents.is_array()) {
        for (const Json &piece : contents) {
            std::string text = fromOne(piece);
            if (!text.empty()) {
                if (!result.empty()) {
                    result += "\n\n";
                }
                result += text;
            }
        }
    } else {
        result = fromOne(contents);
    }
    return @(result.c_str());
}

- (void)hoverAtPosition:(gw::Position)position word:(gw::Range)word {
    Tab *tab = [self currentTab];
    if (tab == nullptr || !tab->document->path()) {
        return;
    }
    gw::Document *document = tab->document.get();
    NSUInteger token = ++_hoverToken;

    // Problems that touch this word.
    NSMutableArray<NSString *> *problems = [NSMutableArray array];
    for (const GWDiagnostic &diagnostic : [_language diagnosticsForDocument:document]) {
        bool sameLine = diagnostic.range.start.line == position.line;
        bool overlaps = diagnostic.range.start.column <= word.end.column && diagnostic.range.end.column >= word.start.column;
        if (sameLine && overlaps) {
            NSString *marker = diagnostic.severity == 1 ? @"⛔️ " : @"⚠️ ";
            [problems addObject:[marker stringByAppendingString:@(diagnostic.message.c_str())]];
        }
    }
    __weak GWMainWindowController *weakSelf = self;
    void (^show)(NSString *) = ^(NSString *markdown) {
        GWMainWindowController *strongSelf = weakSelf;
        if (strongSelf == nil || token != strongSelf->_hoverToken) {
            return;
        }
        NSRect rect = [strongSelf->_editorView viewRectForRange:word];
        [GWHoverPopover showMarkdown:markdown problems:problems relativeToRect:rect ofView:strongSelf->_editorView];
    };
    if (![_language serverSupports:@"hoverProvider" forDocument:document]) {
        if (problems.count > 0) {
            show(nil);
        }
        return;
    }
    [_language request:@"textDocument/hover"
                params:[_language positionParamsForDocument:document position:position]
              document:document
    requireSameVersion:YES
            completion:^(const gw::lsp::Json &result, NSString *error) {
        NSString *markdown = nil;
        if (error == nil && result.is_object() && result.contains("contents")) {
            markdown = markdownFromHover(result["contents"]);
        }
        if (markdown.length > 0 || problems.count > 0) {
            show(markdown);
        }
    }];
}

// ---- Completion

/// Where the word being typed starts (the caret if it isn't in a word).
- (gw::Position)wordStartBeforeCaret {
    Tab *tab = [self currentTab];
    gw::Position caret = tab->document->selection.caret;
    const std::string &line = tab->document->buffer().line(caret.line);
    size_t column = std::min(caret.column, line.size());
    while (column > 0 && gw::isWordByte(static_cast<unsigned char>(line[column - 1]))) {
        --column;
    }
    return {caret.line, column};
}

/// The letters typed so far in the current word.
- (NSString *)typedPrefix {
    Tab *tab = [self currentTab];
    gw::Position caret = tab->document->selection.caret;
    gw::Position start = [self wordStartBeforeCaret];
    if (start.line != caret.line || start.column >= caret.column) {
        return @"";
    }
    std::string text = tab->document->buffer().text({start, caret});
    return @(text.c_str());
}

- (void)editorTypedText:(NSString *)typed {
    Tab *tab = [self currentTab];
    if (tab == nullptr || !tab->document->path() || !_language.enabled) {
        return;
    }
    if (typed == nil) {
        // A deletion or other change: keep the list in step, or drop it.
        if (_suggestions.visible) {
            [_suggestions filterWithPrefix:[self typedPrefix]];
        }
        return;
    }
    unichar last = typed.length > 0 ? [typed characterAtIndex:typed.length - 1] : 0;
    if (last == '(' || last == ',') {
        [self requestSignatureHelp];
    } else if (last == ')' || last == ';') {
        ++_hoverToken;
        [GWHoverPopover hide];
    }
    BOOL wordCharacter = (last >= 'a' && last <= 'z') || (last >= 'A' && last <= 'Z') || (last >= '0' && last <= '9') || last == '_';
    NSString *triggers = [_language completionTriggerCharactersForDocument:tab->document.get()];
    BOOL triggerCharacter = typed.length == 1 && [triggers containsString:typed];

    if (_suggestions.visible && wordCharacter) {
        [_suggestions filterWithPrefix:[self typedPrefix]];
        return;
    }
    [_suggestions hide];
    ++_suggestionToken;  // answers to earlier requests are stale now
    if (triggerCharacter || (wordCharacter && [self typedPrefix].length >= 1)) {
        NSUInteger token = ++_suggestionToken;
        __weak GWMainWindowController *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(0.09 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            GWMainWindowController *strongSelf = weakSelf;
            if (strongSelf != nil && token == strongSelf->_suggestionToken) {
                [strongSelf requestSuggestionsExplicitly:NO];
            }
        });
    }
}

/// The caret moved: a list for a word we've left is stale.
- (void)dropSuggestionsIfCaretLeftWord {
    if (!_suggestions.visible) {
        return;
    }
    Tab *tab = [self currentTab];
    if (tab == nullptr) {
        [_suggestions hide];
        return;
    }
    gw::Position caret = tab->document->selection.caret;
    gw::Position start = [self wordStartBeforeCaret];
    bool movedOffLine = caret.line != _suggestionWordStart.line;
    bool movedBeforeWord = start.line == _suggestionWordStart.line && caret.column < _suggestionWordStart.column;
    if (movedOffLine || movedBeforeWord || !tab->document->selection.empty()) {
        [_suggestions hide];
        ++_suggestionToken;
    }
}

- (IBAction)completeCode:(id)sender {
    [self requestSuggestionsExplicitly:YES];
}

- (void)requestSuggestionsExplicitly:(BOOL)explicitly {
    Tab *tab = [self currentTab];
    if (tab == nullptr || !tab->document->path()) {
        if (explicitly) {
            [self languageMessage:@"Save this file first so the language server can understand it."];
        }
        return;
    }
    gw::Document *document = tab->document.get();
    if (![_language serverSupports:@"completionProvider" forDocument:document]) {
        if (explicitly) {
            NSString *status = [_language statusTextForLanguage:@(document->languageId.c_str())];
            NSString *hint = [_language installHintForLanguage:@(document->languageId.c_str())];
            if (status.length == 0) {
                [self languageMessage:@"There is no language server for this kind of file yet."];
            } else if (hint.length > 0) {
                [self languageMessage:hint];
            } else {
                _statusLeft.stringValue = [status stringByAppendingString:@" · not ready yet"];
            }
        }
        return;
    }
    gw::Position caret = document->selection.caret;
    gw::Position wordStart = [self wordStartBeforeCaret];
    NSUInteger token = _suggestionToken;
    __weak GWMainWindowController *weakSelf = self;
    [_language request:@"textDocument/completion"
                params:[_language positionParamsForDocument:document position:caret]
              document:document
    requireSameVersion:YES
            completion:^(const gw::lsp::Json &result, NSString *error) {
        GWMainWindowController *strongSelf = weakSelf;
        if (strongSelf == nil || error != nil || (!explicitly && token != strongSelf->_suggestionToken)) {
            return;
        }
        [strongSelf showSuggestionsFromResult:result wordStart:wordStart];
    }];
}

- (void)showSuggestionsFromResult:(const gw::lsp::Json &)result wordStart:(gw::Position)wordStart {
    using Json = gw::lsp::Json;
    Json rows = result;
    if (result.is_object()) {
        rows = result.value("items", Json::array());
    }
    if (!rows.is_array() || rows.empty()) {
        return;
    }
    NSMutableArray<GWSuggestion *> *items = [NSMutableArray array];
    for (const Json &row : rows) {
        if (!row.is_object()) {
            continue;
        }
        GWSuggestion *item = [GWSuggestion new];
        std::string label = row.value("label", "");
        if (label.empty()) {
            continue;
        }
        item.label = @(label.c_str());
        item.detail = @(row.value("detail", "").c_str());
        item.filterText = @(row.value("filterText", label).c_str());
        item.sortText = @(row.value("sortText", label).c_str());
        item.kind = row.value("kind", 0);
        item.raw = std::make_shared<Json>(row);
        [items addObject:item];
        if (items.count >= 400) {
            break;
        }
    }
    if (items.count == 0) {
        return;
    }
    Tab *tab = [self currentTab];
    if (tab == nullptr) {
        return;
    }
    _suggestionWordStart = wordStart;
    [_suggestions setItems:items];
    NSRect caretRect = [_editorView screenRectForPosition:tab->document->selection.caret];
    [_suggestions showBelowScreenRect:caretRect parentWindow:self.window];
    [_suggestions filterWithPrefix:[self typedPrefix]];
}

/// A snippet body with its tab stops removed: "foo(${1:a}, ${2:b})$0" → "foo(a, b)".
static std::string plainTextFromSnippet(const std::string &snippet) {
    std::string result;
    for (size_t index = 0; index < snippet.size(); ++index) {
        char c = snippet[index];
        if (c == '\\' && index + 1 < snippet.size()) {
            result += snippet[++index];
            continue;
        }
        if (c != '$') {
            result += c;
            continue;
        }
        if (index + 1 < snippet.size() && std::isdigit(static_cast<unsigned char>(snippet[index + 1]))) {
            while (index + 1 < snippet.size() && std::isdigit(static_cast<unsigned char>(snippet[index + 1]))) {
                ++index;
            }
            continue;
        }
        if (index + 1 < snippet.size() && snippet[index + 1] == '{') {
            size_t close = snippet.find('}', index);
            std::string inside = snippet.substr(index + 2, close == std::string::npos ? std::string::npos : close - index - 2);
            size_t colon = inside.find(':');
            if (colon != std::string::npos) {
                result += inside.substr(colon + 1);
            }
            if (close == std::string::npos) {
                break;
            }
            index = close;
            continue;
        }
        result += c;
    }
    return result;
}

- (void)acceptSuggestion:(GWSuggestion *)suggestion {
    Tab *tab = [self currentTab];
    if (tab == nullptr || suggestion.raw == nullptr) {
        return;
    }
    using Json = gw::lsp::Json;
    const Json &item = *suggestion.raw;
    gw::Document *document = tab->document.get();
    const gw::TextBuffer &buffer = document->buffer();
    gw::Position caret = document->selection.caret;

    gw::Range range{[self wordStartBeforeCaret], caret};
    std::string text = item.value("insertText", item.value("label", ""));
    try {
        if (item.contains("textEdit") && item["textEdit"].is_object()) {
            const Json &edit = item["textEdit"];
            const Json &editRange = edit.contains("range") ? edit["range"] : edit.at("replace");
            range = {gw::lsp::position(buffer, editRange.at("start")), gw::lsp::position(buffer, editRange.at("end"))};
            text = edit.at("newText").get<std::string>();
        }
    } catch (const std::exception &) {
        // Keep the plain replacement of the typed word.
    }
    if (item.value("insertTextFormat", 1) == 2) {
        text = plainTextFromSnippet(text);
    }
    // The range from the server can end before what was typed since; cover up to the caret.
    if (range.end < caret && range.end.line == caret.line) {
        range.end = caret;
    }
    // Extra edits (such as an added #include) apply together with the main one, as one undo step.
    std::vector<std::pair<gw::Range, std::string>> edits;
    edits.push_back({range, text});
    if (item.contains("additionalTextEdits") && item["additionalTextEdits"].is_array()) {
        for (const Json &extra : item["additionalTextEdits"]) {
            try {
                gw::Range extraRange{gw::lsp::position(buffer, extra.at("range").at("start")),
                                     gw::lsp::position(buffer, extra.at("range").at("end"))};
                edits.push_back({extraRange, extra.value("newText", "")});
            } catch (const std::exception &) {
            }
        }
    }
    [self applyEdits:edits toCurrentDocumentPlacingCaretAfterFirst:YES];
}

/// Applies edits (positions in the document as it is now) as one undoable step. They are
/// applied last-to-first so earlier positions stay valid.
- (void)applyEdits:(std::vector<std::pair<gw::Range, std::string>>)edits toCurrentDocumentPlacingCaretAfterFirst:(BOOL)placeCaret {
    Tab *tab = [self currentTab];
    if (tab == nullptr || tab->document->readOnly) {
        return;
    }
    gw::Range firstRange = edits.front().first;
    std::string firstText = edits.front().second;
    std::stable_sort(edits.begin(), edits.end(), [](const auto &a, const auto &b) {
        return b.first.start < a.first.start;  // descending
    });
    __block gw::Position caretAfter = firstRange.start;
    [_editorView editDocument:^(gw::Document &document) {
        for (const auto &[range, replacement] : edits) {
            document.replace(range, replacement);
        }
    }];
    if (placeCaret) {
        // Put the caret after the text that replaced the first edit's range.
        gw::Position end = gw::endOfInsertion(firstRange.start, firstText);
        for (const auto &[range, replacement] : edits) {
            bool isAbove = range.start < firstRange.start;
            if (isAbove) {
                size_t removedLines = range.end.line - range.start.line;
                size_t addedLines = static_cast<size_t>(std::count(replacement.begin(), replacement.end(), '\n'));
                if (addedLines >= removedLines) {
                    end.line += addedLines - removedLines;
                } else {
                    end.line -= removedLines - addedLines;
                }
            }
        }
        caretAfter = tab->document->buffer().clamp(end);
        tab->document->selection = {caretAfter, caretAfter};
        [_editorView jumpToPosition:caretAfter];
    }
}

// ---- Go to definition / references / problems

- (IBAction)goToDefinition:(id)sender {
    [self requestLocationsForMethod:@"textDocument/definition" title:@"Definitions…" openSingleResult:YES];
}

- (IBAction)findReferences:(id)sender {
    [self requestLocationsForMethod:@"textDocument/references" title:@"References…" openSingleResult:NO];
}

- (void)languageMessage:(NSString *)message {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Code Intelligence";
    alert.informativeText = message;
    [alert beginSheetModalForWindow:self.window completionHandler:nil];
}

/// A document the language server can work with, or nil (with a message) if there is none.
- (gw::Document *)documentForLanguageCommand {
    Tab *tab = [self currentTab];
    if (tab == nullptr || !tab->document->path()) {
        [self languageMessage:@"Save this file first so the language server can resolve its project."];
        return nullptr;
    }
    gw::Document *document = tab->document.get();
    NSString *languageId = @(document->languageId.c_str());
    if (![_language hasServerForLanguage:languageId]) {
        [self languageMessage:@"There is no language server for this kind of file yet."];
        return nullptr;
    }
    NSString *hint = [_language installHintForLanguage:languageId];
    if (hint.length > 0) {
        [self languageMessage:hint];
        return nullptr;
    }
    return document;
}

- (void)requestLocationsForMethod:(NSString *)method title:(NSString *)title openSingleResult:(BOOL)openSingle {
    gw::Document *document = [self documentForLanguageCommand];
    if (document == nullptr) {
        return;
    }
    gw::lsp::Json params = [_language positionParamsForDocument:document position:document->selection.caret];
    if ([method isEqualToString:@"textDocument/references"]) {
        params["context"] = {{"includeDeclaration", true}};
    }
    _statusLeft.stringValue = @"Asking the language server…";
    __weak GWMainWindowController *weakSelf = self;
    [_language request:method params:params document:document requireSameVersion:NO
            completion:^(const gw::lsp::Json &result, NSString *error) {
        GWMainWindowController *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        [strongSelf updateStatus];
        if (error != nil) {
            [strongSelf languageMessage:error];
            return;
        }
        [strongSelf showLocations:result title:title openSingleResult:openSingle];
    }];
}

- (void)showLocations:(const gw::lsp::Json &)result title:(NSString *)title openSingleResult:(BOOL)openSingle {
    using Json = gw::lsp::Json;
    Json rows = result;
    if (result.is_object()) {
        rows = Json::array({result});
    }
    NSMutableArray<GWPaletteItem *> *items = [NSMutableArray array];
    __weak GWMainWindowController *weakSelf = self;
    if (rows.is_array()) {
        for (const Json &row : rows) {
            if (!row.is_object()) {
                continue;
            }
            std::string uri = row.value("uri", row.value("targetUri", ""));
            const Json *range = nullptr;
            if (row.contains("targetSelectionRange")) {
                range = &row["targetSelectionRange"];
            } else if (row.contains("range")) {
                range = &row["range"];
            }
            if (range == nullptr || uri.empty()) {
                continue;
            }
            std::string path = gw::lsp::pathFromURI(uri);
            size_t line = (*range)["start"].value("line", 0) + 1;
            GWPaletteItem *item = [GWPaletteItem new];
            NSString *relative = [self projectRelativePath:@(path.c_str())];
            item.title = @(std::filesystem::path(path).filename().c_str());
            item.subtitle = [NSString stringWithFormat:@"%@ · line %zu", relative, line];
            item.symbol = @"arrow.turn.down.right";
            item.symbolColor = NSColor.controlAccentColor;
            Json location = row;
            item.run = ^{
                [weakSelf openLanguageLocation:location];
            };
            [items addObject:item];
        }
    }
    if (items.count == 0) {
        [self languageMessage:@"No results at this position."];
        return;
    }
    if (openSingle && items.count == 1) {
        items.firstObject.run();
        return;
    }
    [self showPaletteWithItems:items placeholder:title];
}

- (void)showPaletteWithItems:(NSArray<GWPaletteItem *> *)items placeholder:(NSString *)placeholder {
    [GWPalette.shared showOverWindow:self.window placeholder:placeholder provider:^NSArray<GWPaletteItem *> *(NSString *query) {
        NSMutableArray *filtered = [NSMutableArray array];
        for (GWPaletteItem *item in items) {
            if (query.length == 0 || [item.title localizedCaseInsensitiveContainsString:query] ||
                [item.subtitle localizedCaseInsensitiveContainsString:query]) {
                [filtered addObject:item];
            }
            if (filtered.count == 100) break;
        }
        return filtered;
    }];
}

- (void)openLanguageLocation:(const gw::lsp::Json &)location {
    try {
        std::string uri = location.value("uri", location.value("targetUri", ""));
        std::string path = gw::lsp::pathFromURI(uri);
        if (path.empty()) {
            return;
        }
        NSURL *url = [NSURL fileURLWithPath:@(path.c_str())];
        [self openURL:url];
        Tab *tab = [self currentTab];
        if (!tab || !tab->document->path() || tab->document->path()->string() != path) {
            return;
        }
        const auto &range = location.contains("targetSelectionRange") ? location.at("targetSelectionRange") : location.at("range");
        [_editorView jumpToPosition:gw::lsp::position(tab->document->buffer(), range.at("start"))];
    } catch (const std::exception &) {
        [self languageMessage:@"The language server returned an invalid source location."];
    }
}

/// ⇧⌘M: the problems in the current file, as a list to jump through.
- (IBAction)checkProblems:(id)sender {
    Tab *tab = [self currentTab];
    if (tab == nullptr) {
        return;
    }
    gw::Document *document = tab->document.get();
    const std::vector<GWDiagnostic> &diagnostics = [_language diagnosticsForDocument:document];
    if (diagnostics.empty()) {
        NSString *status = [_language statusTextForLanguage:@(document->languageId.c_str())];
        NSString *hint = [_language installHintForLanguage:@(document->languageId.c_str())];
        if (hint.length > 0) {
            [self languageMessage:hint];
        } else if (status.length == 0) {
            [self languageMessage:@"There is no language server for this kind of file yet."];
        } else {
            [self languageMessage:@"No problems found in this file."];
        }
        return;
    }
    NSMutableArray<GWPaletteItem *> *items = [NSMutableArray array];
    __weak GWMainWindowController *weakSelf = self;
    for (const GWDiagnostic &diagnostic : diagnostics) {
        GWPaletteItem *item = [GWPaletteItem new];
        item.title = @(diagnostic.message.c_str());
        BOOL isError = diagnostic.severity == 1;
        item.symbol = isError ? @"xmark.octagon.fill" : @"exclamationmark.triangle.fill";
        item.symbolColor = isError ? NSColor.systemRedColor : NSColor.systemOrangeColor;
        item.subtitle = [NSString stringWithFormat:@"line %zu", diagnostic.range.start.line + 1];
        gw::Position where = diagnostic.range.start;
        item.run = ^{
            GWMainWindowController *strongSelf = weakSelf;
            if (strongSelf != nil) {
                [strongSelf->_editorView jumpToPosition:where];
            }
        };
        [items addObject:item];
    }
    [self showPaletteWithItems:items placeholder:@"Problems in this file…"];
}

// ---- Quick fixes and signature help

/// ⌘.: fixes the language server offers for the problems at the caret.
- (IBAction)showQuickFixes:(id)sender {
    gw::Document *document = [self documentForLanguageCommand];
    if (document == nullptr) {
        return;
    }
    if (![_language serverSupports:@"codeActionProvider" forDocument:document]) {
        [self languageMessage:@"The language server for this file doesn't offer quick fixes."];
        return;
    }
    using Json = gw::lsp::Json;
    gw::Selection selection = document->selection;
    gw::Range range = selection.range();
    const gw::TextBuffer &buffer = document->buffer();

    // The problems on the caret's line (or inside the selection) go along with the request.
    Json diagnostics = Json::array();
    for (const GWDiagnostic &diagnostic : [_language diagnosticsForDocument:document]) {
        bool touches = diagnostic.range.start.line <= range.end.line && diagnostic.range.end.line >= range.start.line;
        if (touches && diagnostic.raw != nullptr) {
            diagnostics.push_back(*diagnostic.raw);
        }
    }
    Json params = {
        {"textDocument", {{"uri", gw::lsp::fileURI(document->path()->string())}}},
        {"range", {{"start", gw::lsp::position(buffer, range.start)}, {"end", gw::lsp::position(buffer, range.end)}}},
        {"context", {{"diagnostics", diagnostics}}},
    };
    __weak GWMainWindowController *weakSelf = self;
    [_language request:@"textDocument/codeAction" params:params document:document requireSameVersion:YES
            completion:^(const gw::lsp::Json &result, NSString *error) {
        GWMainWindowController *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        if (error != nil) {
            [strongSelf languageMessage:error];
            return;
        }
        NSMutableArray<GWPaletteItem *> *items = [NSMutableArray array];
        if (result.is_array()) {
            for (const gw::lsp::Json &action : result) {
                if (!action.is_object()) {
                    continue;
                }
                // The edit is either in the action itself, or (clangd's way) the first argument of
                // the command it wants run. Other commands need the server to run them: not supported.
                Json edit;
                if (action.contains("edit") && action["edit"].is_object()) {
                    edit = action["edit"];
                } else {
                    const Json *arguments = nullptr;
                    if (action.contains("arguments")) {
                        arguments = &action["arguments"];
                    } else if (action.contains("command") && action["command"].is_object() && action["command"].contains("arguments")) {
                        arguments = &action["command"]["arguments"];
                    }
                    if (arguments != nullptr && arguments->is_array() && !arguments->empty() && (*arguments)[0].is_object() &&
                        ((*arguments)[0].contains("documentChanges") || (*arguments)[0].contains("changes"))) {
                        edit = (*arguments)[0];
                    }
                }
                if (edit.is_null()) {
                    continue;
                }
                GWPaletteItem *item = [GWPaletteItem new];
                item.title = @(action.value("title", "Fix").c_str());
                item.symbol = action.value("isPreferred", false) ? @"lightbulb.fill" : @"lightbulb";
                item.symbolColor = NSColor.systemYellowColor;
                item.run = ^{
                    [weakSelf applyWorkspaceEdit:edit];
                };
                [items addObject:item];
            }
        }
        if (items.count == 0) {
            [strongSelf languageMessage:@"There are no quick fixes here."];
            return;
        }
        if (items.count == 1) {
            items.firstObject.run();
            return;
        }
        [strongSelf showPaletteWithItems:items placeholder:@"Quick fixes…"];
    }];
}

/// While typing a call: shows the function's signature with the current argument in bold.
- (void)requestSignatureHelp {
    Tab *tab = [self currentTab];
    if (tab == nullptr || !tab->document->path()) {
        return;
    }
    gw::Document *document = tab->document.get();
    if (![_language serverSupports:@"signatureHelpProvider" forDocument:document]) {
        return;
    }
    gw::Position caret = document->selection.caret;
    NSUInteger token = ++_hoverToken;
    __weak GWMainWindowController *weakSelf = self;
    [_language request:@"textDocument/signatureHelp"
                params:[_language positionParamsForDocument:document position:caret]
              document:document
    requireSameVersion:YES
            completion:^(const gw::lsp::Json &result, NSString *error) {
        GWMainWindowController *strongSelf = weakSelf;
        if (strongSelf == nil || error != nil || token != strongSelf->_hoverToken) {
            return;
        }
        if (!result.is_object() || !result.contains("signatures") || result["signatures"].empty()) {
            return;
        }
        using Json = gw::lsp::Json;
        size_t active = result.value("activeSignature", 0);
        const Json &signatures = result["signatures"];
        const Json &signature = signatures[std::min(active, signatures.size() - 1)];
        std::string label = signature.value("label", "");
        int parameterIndex = signature.contains("activeParameter") && signature["activeParameter"].is_number()
                                 ? signature["activeParameter"].get<int>()
                                 : result.value("activeParameter", 0);

        std::string markdown = "```\n" + label + "\n```";
        if (signature.contains("parameters") && signature["parameters"].is_array() && parameterIndex >= 0 &&
            static_cast<size_t>(parameterIndex) < signature["parameters"].size()) {
            const Json &parameter = signature["parameters"][static_cast<size_t>(parameterIndex)];
            std::string name;
            if (parameter.contains("label") && parameter["label"].is_string()) {
                name = parameter["label"].get<std::string>();
            } else if (parameter.contains("label") && parameter["label"].is_array() && parameter["label"].size() == 2) {
                size_t start = parameter["label"][0].get<size_t>();
                size_t end = parameter["label"][1].get<size_t>();
                if (start <= end && end <= label.size()) {
                    name = label.substr(start, end - start);
                }
            }
            if (!name.empty()) {
                markdown += "\n\n**" + name + "**";
                if (parameter.contains("documentation")) {
                    const Json &documentation = parameter["documentation"];
                    std::string text = documentation.is_string() ? documentation.get<std::string>() : documentation.value("value", "");
                    if (!text.empty()) {
                        markdown += " — " + text;
                    }
                }
            }
        }
        NSRect rect = [strongSelf->_editorView viewRectForRange:gw::Range{caret, caret}];
        [GWHoverPopover showMarkdown:@(markdown.c_str()) problems:@[] relativeToRect:rect ofView:strongSelf->_editorView];
    }];
}

// ---- Rename and format

/// Applies TextEdits (from a server) to a document, as one undo step. Ranges are read from the
/// document first, so the edits don't disturb each other.
static std::vector<std::pair<gw::Range, std::string>> editsFromLsp(const gw::lsp::Json &edits, const gw::TextBuffer &buffer) {
    std::vector<std::pair<gw::Range, std::string>> result;
    for (const gw::lsp::Json &edit : edits) {
        try {
            gw::Range range{gw::lsp::position(buffer, edit.at("range").at("start")), gw::lsp::position(buffer, edit.at("range").at("end"))};
            result.push_back({range, edit.value("newText", "")});
        } catch (const std::exception &) {
        }
    }
    return result;
}

- (IBAction)renameSymbol:(id)sender {
    gw::Document *document = [self documentForLanguageCommand];
    if (document == nullptr) {
        return;
    }
    if (![_language serverSupports:@"renameProvider" forDocument:document]) {
        [self languageMessage:@"The language server for this file doesn't support renaming."];
        return;
    }
    std::string current = [_editorView wordAtCaret];
    if (current.empty()) {
        [self languageMessage:@"Put the caret on a name to rename it."];
        return;
    }
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Rename Symbol";
    alert.informativeText = [NSString stringWithFormat:@"Rename “%s” everywhere it is used.", current.c_str()];
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 300, 24)];
    field.stringValue = @(current.c_str());
    alert.accessoryView = field;
    [alert addButtonWithTitle:@"Rename"];
    [alert addButtonWithTitle:@"Cancel"];
    alert.window.initialFirstResponder = field;
    gw::Position caret = document->selection.caret;
    __weak GWMainWindowController *weakSelf = self;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        GWMainWindowController *strongSelf = weakSelf;
        NSString *newName = [field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (strongSelf == nil || response != NSAlertFirstButtonReturn || newName.length == 0 ||
            newName.UTF8String == current) {
            return;
        }
        gw::lsp::Json params = [strongSelf->_language positionParamsForDocument:document position:caret];
        params["newName"] = newName.UTF8String;
        strongSelf->_statusLeft.stringValue = @"Renaming…";
        [strongSelf->_language request:@"textDocument/rename" params:params document:document requireSameVersion:NO
                            completion:^(const gw::lsp::Json &result, NSString *error) {
            [weakSelf updateStatus];
            if (error != nil) {
                [weakSelf languageMessage:error];
                return;
            }
            [weakSelf applyWorkspaceEdit:result];
        }];
    }];
}

/// Applies a WorkspaceEdit from a server: open files are edited in the editor (undoable),
/// other files are changed on disk.
- (void)applyWorkspaceEdit:(const gw::lsp::Json &)edit {
    using Json = gw::lsp::Json;
    std::vector<std::pair<std::string, Json>> fileEdits;  // uri and its TextEdits
    if (edit.is_object() && edit.contains("documentChanges") && edit["documentChanges"].is_array()) {
        for (const Json &change : edit["documentChanges"]) {
            if (change.contains("textDocument") && change.contains("edits")) {
                fileEdits.push_back({change["textDocument"].value("uri", ""), change["edits"]});
            }
        }
    } else if (edit.is_object() && edit.contains("changes") && edit["changes"].is_object()) {
        for (const auto &[uri, edits] : edit["changes"].items()) {
            fileEdits.push_back({uri, edits});
        }
    }
    if (fileEdits.empty()) {
        [self languageMessage:@"The language server found nothing to change."];
        return;
    }
    size_t changedFiles = 0;
    size_t totalEdits = 0;
    NSMutableArray<NSString *> *failures = [NSMutableArray array];
    for (const auto &[uri, edits] : fileEdits) {
        std::string path = gw::lsp::pathFromURI(uri);
        if (path.empty()) {
            continue;
        }
        totalEdits += edits.size();
        Tab *openTab = nullptr;
        for (auto &tab : _tabs) {
            if (tab->document->path() && tab->document->path()->string() == path) {
                openTab = tab.get();
                break;
            }
        }
        if (openTab != nullptr) {
            std::vector<std::pair<gw::Range, std::string>> parsed = editsFromLsp(edits, openTab->document->buffer());
            std::stable_sort(parsed.begin(), parsed.end(), [](const auto &a, const auto &b) { return b.first.start < a.first.start; });
            gw::Document *document = openTab->document.get();
            if (openTab == [self currentTab]) {
                [_editorView editDocument:^(gw::Document &doc) {
                    for (const auto &[range, text] : parsed) {
                        doc.replace(range, text);
                    }
                }];
            } else {
                document->beginUndoGroup();
                for (const auto &[range, text] : parsed) {
                    document->replace(range, text);
                }
                document->endUndoGroup();
            }
            ++changedFiles;
            continue;
        }
        std::string error;
        auto document = gw::Document::open(path, &error);
        if (!document) {
            [failures addObject:@(path.c_str())];
            continue;
        }
        std::vector<std::pair<gw::Range, std::string>> parsed = editsFromLsp(edits, document->buffer());
        std::stable_sort(parsed.begin(), parsed.end(), [](const auto &a, const auto &b) { return b.first.start < a.first.start; });
        for (const auto &[range, text] : parsed) {
            document->replace(range, text);
        }
        if (document->save(&error)) {
            ++changedFiles;
        } else {
            [failures addObject:@(path.c_str())];
        }
    }
    [self refresh];
    [_git refresh];
    if (failures.count > 0) {
        [self showErrorTitle:@"Some files couldn't be changed" message:[failures componentsJoinedByString:@"\n"]];
    } else {
        _statusLeft.stringValue = [NSString stringWithFormat:@"Changed %zu place%s in %zu file%s", totalEdits, totalEdits == 1 ? "" : "s",
                                   changedFiles, changedFiles == 1 ? "" : "s"];
    }
}

/// ⇧⌥F: lets the language server tidy the whole file.
- (IBAction)formatDocument:(id)sender {
    gw::Document *document = [self documentForLanguageCommand];
    if (document == nullptr) {
        return;
    }
    if (![_language serverSupports:@"documentFormattingProvider" forDocument:document]) {
        [self languageMessage:@"The language server for this file can't format it."];
        return;
    }
    gw::lsp::Json params = {
        {"textDocument", {{"uri", gw::lsp::fileURI(document->path()->string())}}},
        {"options", {{"tabSize", GWServices.shared.settings.tabSize}, {"insertSpaces", true}}},
    };
    __weak GWMainWindowController *weakSelf = self;
    _statusLeft.stringValue = @"Formatting…";
    [_language request:@"textDocument/formatting" params:params document:document requireSameVersion:YES
            completion:^(const gw::lsp::Json &result, NSString *error) {
        GWMainWindowController *strongSelf = weakSelf;
        [strongSelf updateStatus];
        if (strongSelf == nil) {
            return;
        }
        if (error != nil) {
            [strongSelf languageMessage:error];
            return;
        }
        Tab *tab = [strongSelf currentTab];
        if (tab == nullptr || tab->document.get() != document || !result.is_array() || result.empty()) {
            return;
        }
        auto edits = editsFromLsp(result, document->buffer());
        if (edits.empty()) {
            return;
        }
        gw::Position caret = document->selection.caret;
        [strongSelf applyEdits:edits toCurrentDocumentPlacingCaretAfterFirst:NO];
        [strongSelf->_editorView jumpToPosition:caret];
    }];
}

// MARK: Opening and saving

- (void)openURL:(NSURL *)url {
    NSNumber *directory = nil;
    [url getResourceValue:&directory forKey:NSURLIsDirectoryKey error:nil];
    if (directory.boolValue) {
        _fileTree.rootURL = url;
        [self rebuildFileIndex:url];
        [_git openFolder:url.path];
        [self startWatchingFolder:url.path];
        _chat.projectFolder = url.path;
        _search.rootFolder = url.path;
        _language.rootFolder = url.path;
        _terminal.projectFolder = url.path;
        _sidebarTitle.stringValue = url.lastPathComponent;
        _openFolderButton.hidden = YES;
        self.window.title = url.lastPathComponent;
        [NSUserDefaults.standardUserDefaults setObject:url.path forKey:@"lastFolder"];
        [NSDocumentController.sharedDocumentController noteNewRecentDocumentURL:url];
        [self refresh];
        [self restoreSessionForFolder:url.path];
        return;
    }
    // Already open: just switch to it.
    for (size_t index = 0; index < _tabs.size(); ++index) {
        const auto &path = _tabs[index]->document->path();
        if (path && [@(path->c_str()) isEqualToString:url.path]) {
            [self selectTab:static_cast<NSInteger>(index)];
            return;
        }
    }
    if (looksBinary(url.fileSystemRepresentation)) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = [NSString stringWithFormat:@"“%@” is a binary file", url.lastPathComponent];
        alert.informativeText = @"Glasswork edits text files. Open it in another app?";
        [alert addButtonWithTitle:@"Open in Default App"];
        [alert addButtonWithTitle:@"Cancel"];
        if ([alert runModal] == NSAlertFirstButtonReturn) [NSWorkspace.sharedWorkspace openURL:url];
        return;
    }
    std::string error;
    auto document = gw::Document::open(url.fileSystemRepresentation, &error);
    if (!document) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Couldn't open the file";
        alert.informativeText = @(error.c_str());
        [alert runModal];
        return;
    }
    [NSDocumentController.sharedDocumentController noteNewRecentDocumentURL:url];
    [self addTab:std::make_unique<gw::Document>(std::move(*document))];
    GWStartupMark([NSString stringWithFormat:@"opened %@", url.lastPathComponent]);
}

- (IBAction)newDocument:(id)sender {
    [self addTab:std::make_unique<gw::Document>()];
}

- (IBAction)openDocument:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = YES;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK) return;
        for (NSURL *url in panel.URLs) [self openURL:url];
    }];
}

- (IBAction)openFolder:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.prompt = @"Open Folder";
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response == NSModalResponseOK) [self openURL:panel.URL];
    }];
}

- (BOOL)saveTab:(Tab &)tab {
    if (tab.isVirtual) return YES;
    if (!tab.document->path()) return [self saveTabAs:tab];
    std::string error;
    if (!tab.document->save(&error)) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Couldn't save";
        alert.informativeText = @(error.c_str());
        [alert runModal];
        return NO;
    }
    [_language documentDidSave:tab.document.get()];
    [self refresh];
    [_git refresh];
    return YES;
}

- (BOOL)saveTabAs:(Tab &)tab {
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.nameFieldStringValue = @(tab.document->displayName().c_str());
    if (_fileTree.rootURL) panel.directoryURL = _fileTree.rootURL;
    if ([panel runModal] != NSModalResponseOK) return NO;
    std::string error;
    if (!tab.document->saveAs(panel.URL.fileSystemRepresentation, &error)) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Couldn't save";
        alert.informativeText = @(error.c_str());
        [alert runModal];
        return NO;
    }
    [self configureLanguageForTab:tab];  // the new name may mean a new language
    if (&tab == [self currentTab]) {
        [_editorView setDocument:tab.document.get() highlighter:tab.highlighter.get() configuration:tab.configuration];
    }
    _fileTree.rootURL = _fileTree.rootURL;  // show the new file
    [self refresh];
    return YES;
}

- (IBAction)saveDocument:(id)sender {
    if (Tab *tab = [self currentTab]) [self saveTab:*tab];
}

- (IBAction)saveDocumentAs:(id)sender {
    if (Tab *tab = [self currentTab]) [self saveTabAs:*tab];
}

- (IBAction)closeTab:(id)sender {
    if (_selected >= 0) {
        [self closeTabAtIndex:_selected];
    } else {
        [self.window performClose:sender];
    }
}

- (IBAction)selectNextTab:(id)sender {
    if (_tabs.size() > 1) [self selectTab:(_selected + 1) % static_cast<NSInteger>(_tabs.size())];
}

- (IBAction)selectPreviousTab:(id)sender {
    if (_tabs.size() > 1) [self selectTab:(_selected + static_cast<NSInteger>(_tabs.size()) - 1) % static_cast<NSInteger>(_tabs.size())];
}

- (IBAction)toggleSidebar:(id)sender {
    _root.sidebarVisible = !_root.sidebarVisible;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.25;
        context.allowsImplicitAnimation = YES;
        [self->_root layoutSubtreeIfNeeded];
    }];
    _root.needsLayout = YES;
}

- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item {
    SEL action = item.action;
    if (action == @selector(saveDocument:) || action == @selector(saveDocumentAs:)) {
        Tab *tab = [self currentTab];
        return tab != nullptr && !tab->isVirtual;
    }
    if (action == @selector(selectNextTab:) || action == @selector(selectPreviousTab:)) return _tabs.size() > 1;
    return YES;
}

// MARK: Unsaved changes

/// Save / Don't Save / Cancel for one document. Returns NO on Cancel or a failed save.
- (BOOL)confirmCloseDocument:(gw::Document &)document {
    NSAlert *alert = [NSAlert new];
    alert.messageText = [NSString stringWithFormat:@"Save changes to “%s”?", document.displayName().c_str()];
    alert.informativeText = @"Your changes will be lost if you don't save them.";
    [alert addButtonWithTitle:@"Save"];
    [alert addButtonWithTitle:@"Cancel"];
    [alert addButtonWithTitle:@"Don't Save"];
    NSModalResponse response = [alert runModal];
    if (response == NSAlertSecondButtonReturn) return NO;
    if (response == NSAlertThirdButtonReturn) return YES;
    for (auto &tab : _tabs) {
        if (tab->document.get() == &document) return [self saveTab:*tab];
    }
    return NO;
}

- (BOOL)confirmCloseAll {
    for (auto &tab : _tabs) {
        if (tab->document->isDirty() && ![self confirmCloseDocument:*tab->document]) return NO;
    }
    [self saveSession];
    [_language shutdown];
    return YES;
}

// MARK: Session (which files were open in a folder)

- (NSString *)sessionKeyForFolder:(NSString *)folder {
    return [@"session:" stringByAppendingString:folder];
}

/// Remembers the open files, where the caret and scroll position were in each, and which tab
/// was in front, so opening the folder again puts everything back.
- (void)saveSession {
    NSString *folder = _fileTree.rootURL.path;
    if (folder.length == 0) {
        return;
    }
    if (Tab *current = [self currentTab]) {
        current->scroll = _card.scrollView.contentView.bounds.origin;
    }
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    NSInteger selectedEntry = 0;
    for (size_t index = 0; index < _tabs.size(); ++index) {
        const Tab &tab = *_tabs[index];
        if (tab.isVirtual || !tab.document->path()) {
            continue;
        }
        if (static_cast<NSInteger>(index) == _selected) {
            selectedEntry = static_cast<NSInteger>(entries.count);
        }
        gw::Position caret = tab.document->selection.caret;
        NSDictionary *entry = @{
            @"path": @(tab.document->path()->c_str()),
            @"line": @(caret.line),
            @"column": @(caret.column),
            @"scrollY": @(tab.scroll.y),
        };
        [entries addObject:entry];
    }
    NSDictionary *session = @{@"tabs": entries, @"selected": @(selectedEntry)};
    [NSUserDefaults.standardUserDefaults setObject:session forKey:[self sessionKeyForFolder:folder]];
}

/// Opens the files that were open the last time this folder was closed.
- (void)restoreSessionForFolder:(NSString *)folder {
    if (!_tabs.empty()) {
        return;
    }
    NSDictionary *session = [NSUserDefaults.standardUserDefaults dictionaryForKey:[self sessionKeyForFolder:folder]];
    NSArray<NSDictionary *> *entries = session[@"tabs"];
    if (entries.count == 0) {
        return;
    }
    NSInteger wantedEntry = [session[@"selected"] integerValue];
    NSInteger selectedTabIndex = -1;
    for (NSUInteger entryIndex = 0; entryIndex < entries.count; ++entryIndex) {
        NSDictionary *entry = entries[entryIndex];
        NSString *path = entry[@"path"];
        if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
            continue;
        }
        [self openURL:[NSURL fileURLWithPath:path]];
        Tab *tab = [self currentTab];
        if (tab == nullptr) {
            continue;
        }
        gw::Position caret = {static_cast<size_t>([entry[@"line"] unsignedIntegerValue]),
                              static_cast<size_t>([entry[@"column"] unsignedIntegerValue])};
        caret = tab->document->buffer().clamp(caret);
        tab->document->selection = {caret, caret};
        tab->scroll = NSMakePoint(0, [entry[@"scrollY"] doubleValue]);
        if (static_cast<NSInteger>(entryIndex) == wantedEntry) {
            selectedTabIndex = _selected;
        }
    }
    if (selectedTabIndex < 0) {
        return;
    }
    // Show the remembered tab again. Forgetting the current one first keeps showTab from
    // overwriting the scroll position that was just restored.
    _selected = -1;
    [self showTab:selectedTabIndex];
}

- (void)writeEditorSnapshotTo:(NSString *)path {
    NSRect rect = _editorView.visibleRect;
    NSBitmapImageRep *rep = [_editorView bitmapImageRepForCachingDisplayInRect:rect];
    [_editorView cacheDisplayInRect:rect toBitmapImageRep:rep];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];

}

- (BOOL)windowShouldClose:(NSWindow *)sender {
    return [self confirmCloseAll];
}

@end
