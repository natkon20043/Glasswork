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
#import "RemoteSupport.h"
#import "SearchPanel.h"
#import "Services.h"
#import "LanguageService.h"
#import "ExtensionHostService.h"
#import "KeybindingService.h"

#include "CssColor.hpp"
#include "RemoteHost.hpp"
#import "MarkdownView.h"
#import "CompletionPopup.h"
#import "DebugPanel.h"
#import "Debugger.h"
#import "SidebarSwitcher.h"
#import <WebKit/WebKit.h>
#import "ExtensionViews.h"
#import "SourceControlPanel.h"
#import "StartupTiming.h"
#import "TabBar.h"
#import "TerminalPanel.h"

#import <QuartzCore/QuartzCore.h>

#include "Document.hpp"
#include "EditorConfig.hpp"
#include <map>
#include <set>

#include "Fuzzy.hpp"
#include "NavigationHistory.hpp"
#include "Tasks.hpp"
#include "Highlighter.hpp"
#include "LanguageServer.hpp"
#include "LineDiff.hpp"
#include "Sections.hpp"
#include "WordSuggestions.hpp"
#include "JsonText.hpp"

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
    /// For a file from another machine: its ssh:// URL. The document is a copy on this Mac that
    /// is sent back to the machine every time it is saved. Empty for ordinary files.
    std::string remoteURL;
    std::string key;
    std::string forcedLanguage;
    std::vector<gw::Color> lineTints;

    // How this file differs from the last commit, for the change bars in the gutter.
    std::shared_ptr<const std::string> headText;
    bool headLoaded = false;
    std::string headCommit;
    std::vector<gw::DiffHunk> hunks;
    std::vector<gw::LineChange> changes;

    /// What the project's .editorconfig files say about this file.
    gw::EditorConfigResult editorConfig;

    /// Most tabs show text. A preview tab shows a Markdown file rendered; an image tab shows a picture.
    enum class Kind { Text, MarkdownPreview, Image, Webview };
    Kind kind = Kind::Text;
    uint64_t sourceIdentifier = 0;  // the Markdown tab a preview follows
    std::string imagePath;
    std::string webviewHandle;  // the extension webview a Webview tab shows

    /// Looks extensions gave to stretches of this file (`setDecorations`), by decoration type.
    std::map<std::string, std::vector<GWDecoration>> decorations;
};

/// Colors for the lines of a unified diff: green for added, red for removed.
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

/// Soft washes of the theme's accent colors behind all the glass, so color and light
/// come through the panels. Static layers: they cost nothing once drawn.
@interface GWAuroraView : NSView
- (void)setColors:(NSArray<NSColor *> *)colors strength:(CGFloat)strength;
@end

@implementation GWAuroraView {
    NSArray<CALayer *> *_blobs;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        NSMutableArray *blobs = [NSMutableArray array];
        for (int index = 0; index < 3; ++index) {
            // Plain bitmap layers. (Gradient layers computed on the fly made the glass over them
            // draw black, rainbow-edged splotches; a finished image is sampled cleanly.)
            CALayer *blob = [CALayer layer];
            blob.contentsGravity = kCAGravityResize;
            blob.magnificationFilter = kCAFilterLinear;
            [self.layer addSublayer:blob];
            [blobs addObject:blob];
        }
        _blobs = blobs;
    }
    return self;
}

- (BOOL)isFlipped { return YES; }

/// A square image of one soft glow: `color` at `strength` in the middle, fading smoothly to nothing
/// at the edge of the circle (and staying nothing beyond), so no edge of the image is ever visible.
- (CGImageRef)newGlowImageWithColor:(NSColor *)color strength:(CGFloat)strength {
    const size_t side = 256;
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(NULL, side, side, 8, 0, colorSpace,
                                                 (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    NSColor *srgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];

    // Many stops that ease out (smoothstep) so there is no visible ring or hard edge.
    const int stopCount = 24;
    CGFloat components[stopCount * 4];
    CGFloat locations[stopCount];
    for (int stop = 0; stop < stopCount; ++stop) {
        CGFloat position = static_cast<CGFloat>(stop) / (stopCount - 1);  // 0 in the middle, 1 at the rim
        CGFloat remaining = 1 - position;
        CGFloat eased = remaining * remaining * (3 - 2 * remaining);
        CGFloat alpha = strength * eased;
        components[stop * 4 + 0] = srgb.redComponent * alpha;    // premultiplied
        components[stop * 4 + 1] = srgb.greenComponent * alpha;
        components[stop * 4 + 2] = srgb.blueComponent * alpha;
        components[stop * 4 + 3] = alpha;
        locations[stop] = position;
    }
    CGGradientRef gradient = CGGradientCreateWithColorComponents(colorSpace, components, locations, stopCount);
    CGPoint center = CGPointMake(side / 2.0, side / 2.0);
    CGContextDrawRadialGradient(context, gradient, center, 0, center, side / 2.0, 0);
    CGImageRef image = CGBitmapContextCreateImage(context);

    CGGradientRelease(gradient);
    CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);
    return image;
}

- (void)setColors:(NSArray<NSColor *> *)colors strength:(CGFloat)strength {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (NSUInteger index = 0; index < _blobs.count; ++index) {
        NSColor *color = colors[index % colors.count];
        CGImageRef image = [self newGlowImageWithColor:color strength:strength];
        _blobs[index].contents = (__bridge id)image;
        CGImageRelease(image);
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

/// The page a rendered Markdown file sits on: top-left origin, so the text starts at the top.
@interface GWPreviewPage : NSView
@end

@implementation GWPreviewPage
- (BOOL)isFlipped { return YES; }
@end

/// The rounded card holding the breadcrumb bar, the code and the minimap.
@interface GWEditorCard : NSView
@property (nonatomic, weak) GWEditorView *editor;
@property (nonatomic, strong) NSView *breadcrumbBar;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) NSView *minimap;
@property (nonatomic, strong) GWFindBar *findBar;
/// Shows a rendered Markdown file or an image instead of the code.
@property (nonatomic, strong) NSScrollView *previewScroll;
@property (nonatomic) BOOL previewMode;
/// Holds an extension's webview; shown (instead of the scroll view above) for a webview tab.
@property (nonatomic, strong) NSView *webviewHolder;
@property (nonatomic) BOOL webviewMode;
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
    // The window animates the card itself when the chat, sidebar or terminal opens. The parts
    // inside must not animate as well: their animations can finish after a later layout and
    // put the code area back at a stale size, leaving it a small corner of the card.
    [NSAnimationContext beginGrouping];
    NSAnimationContext.currentContext.allowsImplicitAnimation = NO;
    [self layoutParts];
    [NSAnimationContext endGrouping];
}

- (void)layoutParts {
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
    self.previewScroll.frame = NSMakeRect(0, top, width, height - top);
    self.webviewHolder.frame = self.previewScroll.frame;
    // The text area is sized from the visible area, which has just changed.
    [self.editor updateFrameSize];
    CGFloat stickyHeight = self.editor.stickyHeight;
    self.editor.stickyView.frame = NSMakeRect(0, top, width - minimapWidth, stickyHeight);
    self.editor.stickyView.hidden = stickyHeight <= 0 || self.previewMode;
    BOOL preview = self.previewMode;
    self.previewScroll.hidden = !preview || self.webviewMode;
    self.webviewHolder.hidden = !preview || !self.webviewMode;
    self.scrollView.hidden = preview;
    self.editor.gutterView.hidden = preview;
    if (preview) {
        self.minimap.hidden = YES;
    }

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

@interface GWMainWindowController () <GWExtensionHostDelegate>
@end

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
    std::vector<gw::NavigationLocation> _recentlyClosed;  // for Reopen Closed Tab, newest last
    gw::NavigationHistory _navigation;   // Go Back / Go Forward
    BOOL _navigating;                    // true while going back or forward, so that is not recorded

    // Every file in the open folder, relative to it, for quick open (⌘P) and search. A new
    // snapshot replaces the old one when the folder changes, so a running search keeps its own.
    std::shared_ptr<const FileIndex> _fileIndex;
    NSUInteger _indexGeneration;          // ignores results from an older folder's scan
    // Language servers: problems, hover, completion, rename, format.
    // Debugging
    GWDebugger *_debugger;
    GWDebugPanel *_debugPanel;
    std::map<std::string, std::set<size_t>> _breakpointStore;  // every file's breakpoint lines, by path
    NSString *_executionPath;
    NSInteger _executionLine;

    GWMarkdownView *_previewMarkdown;
    NSImageView *_previewImage;
    GWLanguageService *_language;
    GWExtensionHostService *_extensionHost;
    GWExtensionViews *_extensionViews;
    NSMutableDictionary<NSString *, WKWebView *> *_webviewTabViews;  // webview panels extensions opened, by handle
    NSString *_extensionStatusMessage;  // a line an extension (or the host) put in the status bar
    NSMutableDictionary<NSString *, NSString *> *_serverProgress;  // what language servers are busy with
    BOOL _editorStateScheduled;
    GWKeybindingService *_keybindings;
    id _keyMonitor;
    NSMutableDictionary<NSString *, NSString *> *_extensionContextKeys;  // set by extensions with setContext
    GWSuggestionPopup *_suggestions;
    NSUInteger _hoverToken;
    NSUInteger _highlightToken;
    NSUInteger _suggestionToken;
    BOOL _suggestionsIncomplete;      // the server's list is partial: ask again as more is typed
    NSUInteger _suggestionResolveToken;  // answers to older resolve requests are ignored
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
    NSButton *_themeChip;  // the theme name in the status bar; click it to pick another
    NSButton *_fontChip;   // the editor font in the status bar; click it to change the font or its size
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
        // The window is see-through, so the system builds its shadow from the glass panes' edges and
        // draws it as a hard dark line along the top plus a small glitch at the middle. Each glass
        // pane already has its own soft shadow, so the window's shadow is switched off.
        window.hasShadow = NO;
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
        // The first window remembers where it was; later ones are placed by the app.
        static BOOL sFirstWindow = YES;
        if (sFirstWindow) {
            sFirstWindow = NO;
            [window setFrameAutosaveName:@"GlassworkMainWindow"];
        }
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
    [self buildEditorCard];
    GWStartupMark(@"  built: editor card");
    [self buildWelcome];

    GWStartupMark(@"  built: welcome card");
    [self buildSidebar];
    GWStartupMark(@"  built: sidebar glass");
    [self buildTabBar];
    GWStartupMark(@"  built: tabs");
    [self buildStatusBar];
    GWStartupMark(@"  built: status bar");
    [self buildResizeHandles];

    self.window.contentView = _root;
}

/// The editor card: breadcrumb bar, the code in its scroll view, the previews, the minimap and the find bar, on a glass backdrop.
- (void)buildEditorCard {
    __weak GWMainWindowController *weakSelf = self;
    // Editor card: breadcrumbs, code and minimap on glass.
    _card = [GWEditorCard new];
    _card.wantsLayer = YES;
    _card.layer.cornerRadius = 20;
    _card.layer.cornerCurve = kCACornerCurveContinuous;
    _card.layer.masksToBounds = YES;

    NSView *breadcrumbBar = [NSView new];
    _breadcrumb = [self label:@"" size:12 weight:NSFontWeightMedium secondary:YES];
    _breadcrumb.lineBreakMode = NSLineBreakByTruncatingHead;
    _breadcrumb.maximumNumberOfLines = 1;  // a long path is cut at the front, never wrapped onto a second line
    _breadcrumb.cell.usesSingleLineMode = YES;
    [_breadcrumb setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
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
    NSScrollView *previewScroll = [NSScrollView new];
    previewScroll.drawsBackground = NO;
    previewScroll.hasVerticalScroller = YES;
    previewScroll.autohidesScrollers = YES;
    previewScroll.scrollerStyle = NSScrollerStyleOverlay;
    previewScroll.hidden = YES;
    _card.previewScroll = previewScroll;
    [_card addSubview:previewScroll];
    _card.webviewHolder = [NSView new];
    _card.webviewHolder.hidden = YES;
    [_card addSubview:_card.webviewHolder];
    _card.minimap = _editorView.minimapView;
    [_card addSubview:_card.minimap];
    _card.editor = _editorView;
    [_card addSubview:_editorView.gutterView];
    [_card addSubview:_editorView.stickyView];
    _editorView.onStickyChange = ^{
        GWMainWindowController *strongSelf = weakSelf;
        strongSelf->_card.needsLayout = YES;
    };
    _findBar = [[GWFindBar alloc] initWithFrame:NSMakeRect(0, 0, 400, 44)];
    _findBar.editor = _editorView;
    _findBar.onResize = ^{
        GWMainWindowController *strongSelf = weakSelf;
        strongSelf->_card.needsLayout = YES;
    };
    _card.findBar = _findBar;
    [_card addSubview:_findBar];
    [self connectEditorCallbacks];
    NSClickGestureRecognizer *breadcrumbClick = [[NSClickGestureRecognizer alloc] initWithTarget:self
                                                                                        action:@selector(breadcrumbClicked:)];
    [breadcrumbBar addGestureRecognizer:breadcrumbClick];

    // The glass is only the card's backdrop: the editor sits on top of it rather than inside
    // it, because glass blends its own content, which dulled the syntax colors.
    _root.editorCard = [self glassWithCornerRadius:20 content:nil];
    [_root addSubview:_root.editorCard];
    _root.editorContent = _card;
    [_root addSubview:_card];
}

/// What the editor tells the window: edits, caret moves, section changes and clicks in the margins.
- (void)connectEditorCallbacks {
    __weak GWMainWindowController *weakSelf = self;
    _editorView.onEdit = ^{
        [weakSelf documentEdited];
    };
    _editorView.onSelectionChange = ^{
        [weakSelf caretMoved];
    };
    _editorView.onSectionsChange = ^{
        [weakSelf updateBreadcrumb];
    };
    _editorView.onVimStatusChange = ^{
        [weakSelf vimStatusChanged];
    };
    _editorView.onVimCommand = ^NSString *(NSString *command) {
        return [weakSelf runVimCommand:command];
    };
    _editorView.onVimAction = ^(gw::VimAction action) {
        [weakSelf vimAction:action];
    };
    _editorView.onInspectColors = ^{
        [weakSelf inspectColors:nil];
    };
    _editorView.onChangeMarkerClick = ^(size_t line, NSRect rect) {
        [weakSelf showChangeAtLine:line rect:rect];
    };
}

/// The sidebar: the switcher on top, and below it the panel of the chosen mode (files first).
- (void)buildSidebar {
    __weak GWMainWindowController *weakSelf = self;
    // Sidebar: a switcher on top and one panel below it (files, source control or search).
    // The top clears the window buttons.
    NSView *sidebarContent = [NSView new];

    _switcher = [[GWSidebarSwitcher alloc] initWithSymbols:@[@"folder", @"arrow.triangle.branch", @"magnifyingglass", @"ladybug", @"puzzlepiece.extension"]
                                                  tooltips:@[@"Files  ⇧⌘E", @"Source Control  ⌃⇧G", @"Search  ⇧⌘F", @"Run and Debug  ⇧⌘D", @"Extension Views"]];
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
}

/// The tabs in a glass capsule.
- (void)buildTabBar {
    __weak GWMainWindowController *weakSelf = self;
    // Tabs in a glass capsule.
    _tabBar = [GWTabBar new];
    _tabBar.onSelect = ^(NSInteger index) { [weakSelf selectTab:index]; };
    _tabBar.onClose = ^(NSInteger index) { [weakSelf closeTabAtIndex:index]; };
    _root.tabs = [self glassWithCornerRadius:kTabBarHeight / 2 content:_tabBar];
    [_root addSubview:_root.tabs];
}

/// The status bar capsule: branch, problems and position on the left, language and Claude on the right.
- (void)buildStatusBar {
    // Status bar capsule.
    NSView *statusContent = [NSView new];
    _statusLeft = [self label:@"" size:11.5 weight:NSFontWeightMedium secondary:NO];
    _statusRight = [self label:@"" size:11.5 weight:NSFontWeightMedium secondary:NO];
    _statusLeft.textColor = GWStatusTextColor();
    _statusRight.textColor = GWStatusTextColor();
    _branchChip = [NSButton buttonWithTitle:@"" target:self action:@selector(branchChipClicked:)];
    _branchChip.bordered = NO;
    _branchChip.hidden = YES;
    _branchChip.toolTip = @"Switch branch";
    NSStackView *statusLeftStack = [NSStackView stackViewWithViews:@[_branchChip, _statusLeft]];
    statusLeftStack.spacing = 14;

    _claudeChip = [NSButton buttonWithTitle:@"" target:self action:@selector(toggleChat:)];
    _claudeChip.bordered = NO;
    _claudeChip.toolTip = @"Chat with Claude  ⌘L";
    _themeChip = [NSButton buttonWithTitle:@"" target:self action:@selector(themeChipClicked:)];
    _themeChip.bordered = NO;
    _themeChip.toolTip = @"Change the color theme";
    _fontChip = [NSButton buttonWithTitle:@"" target:self action:@selector(fontChipClicked:)];
    _fontChip.bordered = NO;
    _fontChip.toolTip = @"Change the editor font and size";
    NSStackView *statusRightStack = [NSStackView stackViewWithViews:@[_statusRight, _fontChip, _themeChip, _claudeChip]];
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
}

/// The drag handles for resizing the chat (on the right) and the terminal (underneath), and the sizes saved last time.
- (void)buildResizeHandles {
    __weak GWMainWindowController *weakSelf = self;
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
    [recent.widthAnchor constraintGreaterThanOrEqualToConstant:360].active = YES;

    // The glass sizes itself to its content but ignores a stack's own insets, so the padding is
    // made of constraints around the stack; otherwise a long recent path touches the border.
    NSView *content = [NSView new];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:44],
        [stack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-44],
        [stack.topAnchor constraintEqualToAnchor:content.topAnchor constant:34],
        [stack.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-32],
    ]];

    _root.welcome = [self glassWithCornerRadius:30 content:content];
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
        NSMutableParagraphStyle *truncating = [NSMutableParagraphStyle new];
        truncating.lineBreakMode = NSLineBreakByTruncatingMiddle;  // a long path shortens in the middle
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:[@"   " stringByAppendingString:parent] attributes:@{
            NSFontAttributeName: [NSFont systemFontOfSize:11.5],
            NSForegroundColorAttributeName: NSColor.tertiaryLabelColor,
        }]];
        NSButton *button = [NSButton buttonWithTitle:@"" target:self action:@selector(openRecent:)];
        [text addAttribute:NSParagraphStyleAttributeName value:truncating range:NSMakeRange(0, text.length)];
        button.attributedTitle = text;
        button.bordered = NO;
        button.alignment = NSTextAlignmentLeft;
        [button.widthAnchor constraintLessThanOrEqualToConstant:520].active = YES;
        [button setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
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

- (void)themeChanged:(NSNotification *)notification {
    [_fileTree refreshIcons];  // the file icon theme may have changed
    _tabBar.needsDisplay = YES;
    [self applyTheme];
    [_extensionHost settingsDidChange];
    [_language settingsDidChange:[_extensionHost allSettings]];
}

- (void)applyTheme {
    GWServices *services = GWServices.shared;
    _language.enabled = services.settings.languageServers;
    const gw::Theme &theme = services.theme;
    BOOL dark = theme.isDark();
    self.window.appearance = [NSAppearance appearanceNamed:dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];

    // Tint the glass slightly towards the theme so panels and code feel like one surface.
    NSColor *editor = [services color:@"editor.background" fallback:NSColor.clearColor];
    NSColor *sidebar = [services color:@"sideBar.background" fallback:editor];
    // The tint of each panel is its strongest value scaled by the glassTint setting.
    const CGFloat tint = services.settings.glassTint;
    // Panels with lots of text (chat, terminal, editor) get more tint than the bars, so their
    // text stays readable over a bright picture behind the window.
    _root.sidebar.tintColor = [sidebar colorWithAlphaComponent:std::min(1.0, 0.80 * tint)];
    _root.tabs.tintColor = [editor colorWithAlphaComponent:std::min(1.0, 0.80 * tint)];
    _root.status.tintColor = [editor colorWithAlphaComponent:std::min(1.0, 1.60 * tint)];
    _root.chat.tintColor = [sidebar colorWithAlphaComponent:std::min(1.0, 1.30 * tint)];
    _root.bottom.tintColor = [editor colorWithAlphaComponent:std::min(1.0, 2.00 * tint)];
    _root.editorCard.tintColor = [editor colorWithAlphaComponent:std::min(1.0, 0.90 * tint)];
    _root.welcome.tintColor = [editor colorWithAlphaComponent:std::min(1.0, 0.60 * tint)];

    // Clear glass for the bars and sidebar, if asked for; the text-heavy panels stay regular.
    NSGlassEffectViewStyle chromeStyle =
        services.settings.glassStyle == "clear" ? NSGlassEffectViewStyleClear : NSGlassEffectViewStyleRegular;
    _root.sidebar.style = chromeStyle;
    _root.tabs.style = chromeStyle;
    _root.status.style = chromeStyle;

    // The blurred layer behind the window hides the desktop; without it the glass has something
    // sharp to bend.
    [self updateBackdrop];

    // Aurora colors from the theme's own accents, with vivid fallbacks.
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
    // Extensions came or went: the host starts again, with the new set, the next time it is needed.
    [_extensionHost extensionsDidChange];
    [_extensionHost shutdown];
    [_extensionViews hostViewsDidReset];  // the old host's panels and views are gone
    [_extensionViews reload];
    [_extensionHost startIfExtensionsWantToRun];
    [_keybindings reload];  // they may have brought, or taken, keybindings
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
    Tab *tabPointer = tab.get();  // the tab lives exactly as long as its document, which owns this callback
    __weak GWEditorView *editor = _editorView;
    __weak GWMainWindowController *weakSelf = self;
    tab->document->onChange = [highlighter, editor, raw, tabPointer, weakSelf](const gw::Change &change) {
        highlighter->didChange(change);
        [editor document:raw changed:change];
        // Extension decorations move with the lines they are on, until the extension sends fresh ones.
        if (change.lineDelta != 0 && !tabPointer->decorations.empty()) {
            auto shiftLine = [&](size_t line) {
                if (line <= change.firstLine) return line;
                long moved = static_cast<long>(line) + change.lineDelta;
                return static_cast<size_t>(std::max(moved, static_cast<long>(change.firstLine)));
            };
            for (auto &[key, decorations] : tabPointer->decorations) {
                for (GWDecoration &decoration : decorations) {
                    decoration.range.start.line = shiftLine(decoration.range.start.line);
                    decoration.range.end.line = shiftLine(decoration.range.end.line);
                }
            }
            GWMainWindowController *strongSelf = weakSelf;
            if (strongSelf != nil && [strongSelf currentTab] == tabPointer) {
                [editor setDecorationGroups:tabPointer->decorations];
            }
        }
    };
    [self configureLanguageForTab:*tab];
    [self loadEditorConfigForTab:*tab];
    if (tab->document->path()) {
        auto stored = _breakpointStore.find(tab->document->path()->string());
        if (stored != _breakpointStore.end()) {
            tab->document->breakpointLines = stored->second;
        }
    }
    gw::Document *newDocument = tab->document.get();
    NSInteger position = index < 0 || index > static_cast<NSInteger>(_tabs.size()) ? static_cast<NSInteger>(_tabs.size()) : index;
    _tabs.insert(_tabs.begin() + position, std::move(tab));
    [_language trackDocument:newDocument];
    [self showTab:position];
}

- (void)showTab:(NSInteger)index {
    if (Tab *current = [self currentTab]) current->scroll = _card.scrollView.contentView.bounds.origin;
    _selected = index;
    [self scheduleEditorStateForExtensions];
    Tab *tab = [self currentTab];
    if (tab) {
        [_editorView setDocument:tab->document.get() highlighter:tab->highlighter.get() configuration:tab->configuration];
        [_editorView setDecorationGroups:tab->decorations];
        [_editorView setInlayHints:[_language inlayHintsForDocument:tab->document.get()]];
        [self applyEditorConfigOfTab:*tab];
        [_editorView setLineChanges:tab->changes];
        [_editorView setLineTints:tab->lineTints];
        [_editorView setDiagnostics:[_language diagnosticsForDocument:tab->document.get()]];
        [_editorView setSemanticTokens:[_language semanticTokensForDocument:tab->document.get()]];
        [self updateExecutionMarker];
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
        BOOL isPreview = tab->kind != Tab::Kind::Text;
        _card.webviewMode = tab->kind == Tab::Kind::Webview;
        _card.previewMode = isPreview;
        _card.needsLayout = YES;
        if (isPreview) {
            [self showPreviewContentForTab:*tab];
        } else {
            [self.window makeFirstResponder:_editorView];
        }
    } else {
        _card.previewMode = NO;
        _card.webviewMode = NO;
        [_editorView setDocument:nullptr highlighter:nullptr configuration:{}];
    }
    [self tellExtensionsWhichWebviewIsInFront];
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
    [self removeTabAtIndex:index];
}

/// Closes a tab without asking about unsaved changes (the caller has already dealt with them).
- (void)removeTabAtIndex:(NSInteger)index {
    Tab &tab = *_tabs[static_cast<size_t>(index)];
    if (tab.document->path() && !tab.isVirtual) {
        _breakpointStore[tab.document->path()->string()] = tab.document->breakpointLines;
        _recentlyClosed.push_back({tab.document->path()->string(), tab.document->selection.caret});
        if (_recentlyClosed.size() > 20) {
            _recentlyClosed.erase(_recentlyClosed.begin());
        }
    }
    if (index == _selected) [_editorView setDocument:nullptr highlighter:nullptr configuration:{}];
    [_language untrackDocument:tab.document.get()];
    if (tab.kind == Tab::Kind::Webview) {
        NSString *handle = @(tab.webviewHandle.c_str());
        [_webviewTabViews removeObjectForKey:handle];
        [_extensionViews panelTabClosed:handle];
    }
    _tabs.erase(_tabs.begin() + index);
    NSInteger next = _tabs.empty() ? -1 : std::min(index, static_cast<NSInteger>(_tabs.size()) - 1);
    _selected = -1;  // the closed tab's scroll position doesn't need saving
    [self showTab:next];
}

/// The window shows the desktop through it sharply while a file is open. With nothing open the
/// welcome card sits on a blurred backdrop instead, so whatever is behind the window doesn't
/// show through (and get bent by the glass) behind the text. "window.frostedBackdrop" blurs always.
- (void)updateBackdrop {
    BOOL noFileOpen = [self currentTab] == nullptr;
    BOOL blur = GWServices.shared.settings.frostedBackdrop || noFileOpen;
    _root.backdrop.hidden = !blur;
}

- (void)refresh {
    [self updateBackdrop];
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
    [self scheduleMarkdownPreviewRefresh];
}

// MARK: Previews (Markdown and images)

static bool isImageExtension(NSString *extension) {
    static NSSet<NSString *> *extensions = [NSSet setWithArray:@[
        @"png", @"jpg", @"jpeg", @"gif", @"bmp", @"tif", @"tiff", @"heic", @"webp", @"ico", @"icns", @"svg", @"pdf",
    ]];
    return [extensions containsObject:extension.lowercaseString];
}

/// ⇧⌘V: a rendered view of the Markdown file being edited, next to its tab; it follows the text as you type.
- (IBAction)openMarkdownPreview:(id)sender {
    Tab *source = [self currentTab];
    if (source == nullptr) {
        return;
    }
    if (source->kind == Tab::Kind::MarkdownPreview) {
        return;
    }
    if (source->document->languageId != "markdown") {
        NSBeep();
        return;
    }
    // One preview per file: show the existing one.
    for (size_t index = 0; index < _tabs.size(); ++index) {
        if (_tabs[index]->kind == Tab::Kind::MarkdownPreview && _tabs[index]->sourceIdentifier == source->identifier) {
            [self selectTab:static_cast<NSInteger>(index)];
            return;
        }
    }
    uint64_t sourceIdentifier = source->identifier;
    NSInteger sourceIndex = _selected;
    std::string title = "Preview " + source->document->displayName();
    auto document = std::make_unique<gw::Document>(gw::Document::readOnlyText("", title));
    [self addTab:std::move(document) atIndex:sourceIndex + 1 configure:^(Tab &tab) {
        tab.isVirtual = true;
        tab.kind = Tab::Kind::MarkdownPreview;
        tab.sourceIdentifier = sourceIdentifier;
        tab.key = "preview:" + std::to_string(sourceIdentifier);
        tab.forcedLanguage = "plaintext";
    }];
}

- (void)openImageAtURL:(NSURL *)url {
    std::string path = url.fileSystemRepresentation;
    for (size_t index = 0; index < _tabs.size(); ++index) {
        if (_tabs[index]->kind == Tab::Kind::Image && _tabs[index]->imagePath == path) {
            [self selectTab:static_cast<NSInteger>(index)];
            return;
        }
    }
    NSImage *probe = [[NSImage alloc] initWithContentsOfURL:url];
    if (probe == nil) {
        [self showErrorTitle:@"Couldn't open the image" message:url.lastPathComponent];
        return;
    }
    auto document = std::make_unique<gw::Document>(gw::Document::readOnlyText("", url.lastPathComponent.UTF8String));
    [self addTab:std::move(document) atIndex:-1 configure:^(Tab &tab) {
        tab.isVirtual = true;
        tab.kind = Tab::Kind::Image;
        tab.imagePath = path;
        tab.key = "image:" + path;
        tab.forcedLanguage = "plaintext";
    }];
}

/// Fills the preview area for the selected preview or image tab.
- (void)showPreviewContentForTab:(Tab &)tab {
    NSScrollView *scroll = _card.previewScroll;
    if (tab.kind == Tab::Kind::Webview) {
        WKWebView *webView = _webviewTabViews[@(tab.webviewHandle.c_str())];
        for (NSView *old in [_card.webviewHolder.subviews copy]) {
            [old removeFromSuperview];
        }
        if (webView != nil) {
            webView.frame = _card.webviewHolder.bounds;
            webView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            [_card.webviewHolder addSubview:webView];
            [self.window makeFirstResponder:webView];
        }
        return;
    }
    if (tab.kind == Tab::Kind::Image) {
        NSImage *image = [[NSImage alloc] initWithContentsOfFile:@(tab.imagePath.c_str())];
        if (_previewImage == nil) {
            _previewImage = [NSImageView new];
            _previewImage.imageScaling = NSImageScaleProportionallyDown;
            _previewImage.imageAlignment = NSImageAlignCenter;
            _previewImage.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        }
        _previewImage.image = image;
        _previewImage.frame = NSMakeRect(0, 0, NSWidth(scroll.contentView.bounds), NSHeight(scroll.contentView.bounds));
        scroll.documentView = _previewImage;
        return;
    }
    [self refreshMarkdownPreviewForTab:tab keepScroll:NO];
}

/// Renders the Markdown text of the file the preview follows.
- (void)refreshMarkdownPreviewForTab:(Tab &)preview keepScroll:(BOOL)keepScroll {
    Tab *source = [self tabWithIdentifier:preview.sourceIdentifier];
    NSScrollView *scroll = _card.previewScroll;
    NSString *markdown = source ? @(source->document->buffer().text().c_str()) : @"The file this preview followed was closed.";
    if (_previewMarkdown == nil) {
        _previewMarkdown = [GWMarkdownView new];
        _previewMarkdown.fontSize = 15;
        __weak GWMainWindowController *weakSelf = self;
        _previewMarkdown.onOpenPath = ^(NSString *path, NSInteger line) {
            [weakSelf openPath:path atLine:line];
        };
    }
    _previewMarkdown.projectRoot = _fileTree.rootURL.path;
    NSPoint offset = scroll.contentView.bounds.origin;

    // A flipped page that keeps the text in a comfortable column, centered.
    NSView *page = scroll.documentView;
    if (![page isKindOfClass:GWPreviewPage.class]) {
        page = [GWPreviewPage new];
        page.translatesAutoresizingMaskIntoConstraints = NO;
        scroll.documentView = page;
        NSClipView *clip = scroll.contentView;
        [NSLayoutConstraint activateConstraints:@[
            [page.topAnchor constraintEqualToAnchor:clip.topAnchor],
            [page.leadingAnchor constraintEqualToAnchor:clip.leadingAnchor],
            [page.trailingAnchor constraintEqualToAnchor:clip.trailingAnchor],
        ]];
    }
    if (_previewMarkdown.superview != page) {
        _previewMarkdown.translatesAutoresizingMaskIntoConstraints = NO;
        [page addSubview:_previewMarkdown];
        NSLayoutConstraint *preferredWidth = [_previewMarkdown.widthAnchor constraintEqualToConstant:820];
        preferredWidth.priority = NSLayoutPriorityDefaultHigh;
        [NSLayoutConstraint activateConstraints:@[
            preferredWidth,
            [_previewMarkdown.widthAnchor constraintLessThanOrEqualToAnchor:page.widthAnchor constant:-64],
            [_previewMarkdown.centerXAnchor constraintEqualToAnchor:page.centerXAnchor],
            [_previewMarkdown.topAnchor constraintEqualToAnchor:page.topAnchor constant:28],
            [_previewMarkdown.bottomAnchor constraintEqualToAnchor:page.bottomAnchor constant:-40],
        ]];
    }
    [_previewMarkdown setMarkdown:markdown];
    if (keepScroll) {
        [scroll layoutSubtreeIfNeeded];
        [scroll.contentView scrollToPoint:offset];
        [scroll reflectScrolledClipView:scroll.contentView];
    }
}

- (void)scheduleMarkdownPreviewRefresh {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(refreshMarkdownPreviewNow) object:nil];
    [self performSelector:@selector(refreshMarkdownPreviewNow) withObject:nil afterDelay:0.3];
}

/// Re-renders the visible preview, if it follows a file that was just edited.
- (void)refreshMarkdownPreviewNow {
    Tab *tab = [self currentTab];
    if (tab != nullptr && tab->kind == Tab::Kind::MarkdownPreview) {
        [self refreshMarkdownPreviewForTab:*tab keepScroll:YES];
    }
}

// MARK: .editorconfig and saving

- (void)loadEditorConfigForTab:(Tab &)tab {
    tab.editorConfig = gw::EditorConfigResult();
    if (tab.document->path() && !tab.isVirtual) {
        tab.editorConfig = gw::editorConfigFor(*tab.document->path());
    }
    if (&tab == [self currentTab]) {
        [self applyEditorConfigOfTab:tab];
    }
}

/// Gives the editor this file's indentation rules from its .editorconfig.
- (void)applyEditorConfigOfTab:(Tab &)tab {
    int usesTabs = -1;
    if (tab.editorConfig.useTabs) {
        usesTabs = *tab.editorConfig.useTabs ? 1 : 0;
    }
    size_t tabSize = 0;
    if (std::optional<int> columns = tab.editorConfig.columnsPerIndent()) {
        tabSize = static_cast<size_t>(*columns);
    }
    [_editorView setIndentationOverrideUsesTabs:usesTabs tabSize:tabSize];
}

/// Before saving: strips trailing spaces and adds the final newline where the settings or the
/// file's .editorconfig ask for it. Done as one undoable edit.
- (void)prepareTabForSaving:(Tab &)tab {
    const gw::EditorSettings &settings = GWServices.shared.settings;
    bool trim = tab.editorConfig.trimTrailingWhitespace.value_or(settings.trimTrailingWhitespace);
    bool finalNewline = tab.editorConfig.insertFinalNewline.value_or(settings.insertFinalNewline);
    if ((!trim && !finalNewline) || tab.document->readOnly) {
        return;
    }
    gw::Document &document = *tab.document;
    const gw::TextBuffer &buffer = document.buffer();
    std::vector<std::pair<gw::Range, std::string>> edits;
    if (trim) {
        for (size_t line = 0; line < buffer.lineCount(); ++line) {
            std::string_view text = buffer.line(line);
            size_t end = text.size();
            while (end > 0 && (text[end - 1] == ' ' || text[end - 1] == '\t')) {
                --end;
            }
            if (end < text.size()) {
                edits.push_back({gw::Range{{line, end}, {line, text.size()}}, std::string()});
            }
        }
    }
    if (finalNewline) {
        size_t lastLine = buffer.lineCount() - 1;
        if (!buffer.line(lastLine).empty()) {
            gw::Position end{lastLine, buffer.line(lastLine).size()};
            edits.push_back({gw::Range{end, end}, std::string("\n")});
        }
    }
    if (edits.empty()) {
        return;
    }
    // Last edit first, so the earlier positions stay valid.
    std::stable_sort(edits.begin(), edits.end(), [](const auto &a, const auto &b) { return b.first.start < a.first.start; });
    gw::Selection savedSelection = document.selection;
    if (&tab == [self currentTab]) {
        [_editorView editDocument:^(gw::Document &target) {
            for (const auto &[range, text] : edits) {
                target.replace(range, text);
            }
        }];
    } else {
        document.beginUndoGroup();
        for (const auto &[range, text] : edits) {
            document.replace(range, text);
        }
        document.endUndoGroup();
    }
    document.selection = {document.buffer().clamp(savedSelection.anchor), document.buffer().clamp(savedSelection.caret)};
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
        [self prepareTabForSaving:*tab];
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
    NSURL *remote = tab->remoteURL.empty() ? nil : [NSURL URLWithString:@(tab->remoteURL.c_str())];
    if (remote != nil) {
        [parts addObject:GWRemoteDestination(remote)];
        [parts addObjectsFromArray:[remote.path pathComponents]];
        [parts removeObject:@"/"];
    } else if (tab->document->path()) {
        NSString *path = @(tab->document->path()->c_str());
        NSString *root = _fileTree.rootURL.path;
        if (root && [path hasPrefix:[root stringByAppendingString:@"/"]]) {
            [parts addObject:root.lastPathComponent];
            [parts addObjectsFromArray:[[path substringFromIndex:root.length + 1] pathComponents]];
        } else {
            NSArray<NSString *> *all = [[path stringByAbbreviatingWithTildeInPath] pathComponents];
            // A file outside the project: the last few folders are enough.
            const NSUInteger keep = 4;
            if (all.count > keep + 1) {
                [parts addObject:@"…"];
                [parts addObjectsFromArray:[all subarrayWithRange:NSMakeRange(all.count - keep, keep)]];
            } else {
                [parts addObjectsFromArray:all];
            }
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
    [self scheduleEditorStateForExtensions];
    [self updateStatus];
    [self updateBreadcrumb];
    [self scheduleDocumentHighlight];
    [GWColorInspector.shared refresh];
    if (_root.chatVisible) {
        [_chat contextDidChange];
    }
}

// MARK: Document highlight (other uses of the symbol under the caret)

static NSString *const kHighlightGroup = @"gw.documentHighlight";

/// Drops the marks (if any are showing) so stale ones never sit on the wrong symbol.
- (void)clearDocumentHighlightInTab:(Tab *)tab {
    if (tab->decorations.erase(kHighlightGroup.UTF8String) > 0 && tab == [self currentTab]) {
        [_editorView setDecorationGroups:tab->decorations];
    }
}

/// After the caret rests for a moment, asks the server where else the symbol at the caret is
/// used and marks those places softly (writes a little stronger than reads).
- (void)scheduleDocumentHighlight {
    ++_highlightToken;
    Tab *tab = [self currentTab];
    if (tab == nullptr) {
        return;
    }
    [self clearDocumentHighlightInTab:tab];
    gw::Document *document = tab->document.get();
    if (!document->path() || !document->selection.empty()
        || ![_language serverSupports:@"documentHighlightProvider" forDocument:document]) {
        return;
    }
    gw::Position caret = document->selection.caret;
    std::string_view line = document->buffer().line(caret.line);
    bool onWord = caret.column < line.size() && gw::isWordByte(static_cast<unsigned char>(line[caret.column]));
    bool afterWord = caret.column > 0 && caret.column <= line.size() && gw::isWordByte(static_cast<unsigned char>(line[caret.column - 1]));
    if (!onWord && !afterWord) {
        return;
    }
    NSUInteger token = _highlightToken;
    __weak GWMainWindowController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        GWMainWindowController *strongSelf = weakSelf;
        if (strongSelf == nil || token != strongSelf->_highlightToken) {
            return;
        }
        [strongSelf requestDocumentHighlightAt:caret token:token];
    });
}

- (void)requestDocumentHighlightAt:(gw::Position)caret token:(NSUInteger)token {
    Tab *tab = [self currentTab];
    if (tab == nullptr) {
        return;
    }
    gw::Document *document = tab->document.get();
    Tab *tabPointer = tab;
    __weak GWMainWindowController *weakSelf = self;
    [_language request:@"textDocument/documentHighlight"
                params:[_language positionParamsForDocument:document position:caret]
              document:document
    requireSameVersion:YES
            completion:^(const gw::lsp::Json &result, NSString *error) {
        GWMainWindowController *strongSelf = weakSelf;
        if (strongSelf == nil || token != strongSelf->_highlightToken || tabPointer != [strongSelf currentTab]
            || error != nil || !result.is_array()) {
            return;
        }
        const gw::TextBuffer &buffer = document->buffer();
        std::vector<GWDecoration> marks;
        for (const gw::lsp::Json &item : result) {
            if (!item.is_object() || !item.contains("range")) {
                continue;
            }
            GWDecoration mark;
            try {
                mark.range = {gw::lsp::position(buffer, item["range"].at("start")), gw::lsp::position(buffer, item["range"].at("end"))};
            } catch (const std::exception &) {
                continue;
            }
            bool isWrite = item.value("kind", 1) == 3;
            mark.background = gw::parseCssColor(isWrite ? "rgba(255, 190, 90, 0.30)" : "rgba(140, 170, 255, 0.24)");
            marks.push_back(std::move(mark));
        }
        // A single mark is just the word under the caret: nothing worth showing.
        if (marks.size() < 2) {
            return;
        }
        tabPointer->decorations[kHighlightGroup.UTF8String] = std::move(marks);
        [strongSelf->_editorView setDecorationGroups:tabPointer->decorations];
    }];
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
    [self rememberLocationBeforeJump];
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
            [weakSelf rememberLocationBeforeJump];
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

- (void)collectCommandsFrom:(NSMenu *)menu
                       path:(NSString *)path
                       into:(NSMutableArray<NSMenuItem *> *)items
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

        for (GWPaletteItem *item in [self->_extensionHost commandItemsForQuery:query]) {
            scored.emplace_back(0, item);  // extension commands follow the editor's own
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
                                 NSForegroundColorAttributeName: GWStatusTextColor()};
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
    NSColor *muted = GWStatusTextColor();
    _themeChip.attributedTitle = segment(@"paintpalette.fill", muted, services.themeLabel);
    NSString *fontName = services.settings.fontFamily.empty() ? @"SF Mono" : @(services.settings.fontFamily.c_str());
    NSString *fontLabel = [NSString stringWithFormat:@"%@ %g", fontName, services.settings.fontSize];
    _fontChip.attributedTitle = segment(@"textformat", muted, fontLabel);

    if (!tab) {
        NSString *message = services.installingDefaults ? @"Installing language support from Open VSX…" : @"Ready";
        _statusLeft.attributedStringValue = segment(services.installingDefaults ? @"arrow.down.circle.fill" : @"checkmark.circle.fill",
                                                    NSColor.controlAccentColor, message);
        _statusRight.hidden = YES;  // nothing to show beside the theme name without a file
        return;
    }
    const gw::Document &document = *tab->document;
    gw::Position caret = document.selection.caret;
    // Columns count characters (not bytes), from 1, like other editors.
    std::string_view line = document.buffer().line(caret.line);
    NSString *prefix = [[NSString alloc] initWithBytes:line.data()
                                                length:std::min(caret.column, line.size())
                                              encoding:NSUTF8StringEncoding];
    NSMutableArray<NSAttributedString *> *left = [NSMutableArray array];
    [left addObject:segment(@"text.cursor", NSColor.controlAccentColor,
                            [NSString stringWithFormat:@"Ln %zu, Col %lu", caret.line + 1, (unsigned long)prefix.length + 1])];
    NSString *vimStatus = _editorView.vimStatus;
    if (vimStatus != nil) {
        [left insertObject:segment(@"keyboard", NSColor.controlAccentColor, vimStatus) atIndex:0];
    }
    if (_editorView.cursorCount > 1) {
        [left addObject:segment(@"cursorarrow.rays", muted, [NSString stringWithFormat:@"%lu cursors", (unsigned long)_editorView.cursorCount])];
    } else if (!document.selection.empty()) {
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
    for (GWExtensionStatusItem *item in _extensionHost.statusItems) {
        if (item.alignment != 2 && item.text.length > 0) {
            [left addObject:segment(@"puzzlepiece.extension", muted, item.text)];
        }
    }
    if (_extensionStatusMessage.length > 0) {
        [left addObject:segment(@"puzzlepiece.extension", NSColor.controlAccentColor, _extensionStatusMessage)];
    }
    for (NSString *token in [_serverProgress.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        [left addObject:segment(@"hourglass", NSColor.controlAccentColor, _serverProgress[token])];
    }
    _statusLeft.attributedStringValue = join(left);

    NSString *name = document.path() ? @(document.path()->filename().c_str()) : @"untitled";
    NSString *language = @(services.extensions.languageName(document.languageId).c_str());
    NSMutableArray<NSAttributedString *> *extensionItems = [NSMutableArray array];
    for (GWExtensionStatusItem *item in _extensionHost.statusItems) {
        if (item.alignment == 2 && item.text.length > 0) {
            [extensionItems addObject:segment(@"puzzlepiece.extension", muted, item.text)];
        }
    }
    NSMutableArray<NSAttributedString *> *right = [NSMutableArray array];
    if (extensionItems.count > 0) {
        [right addObject:join(extensionItems)];  // only when there is something: an empty piece still gets a separator
    }
    [right addObject:segment(GWSymbolForFile(name), GWColorForFile(name), language)];
    [right addObject:segment(@"arrow.turn.down.left", muted, document.buffer().usesCRLF() ? @"CRLF" : @"LF")];
    [right addObject:segment(@"textformat", muted, @"UTF-8")];
    _statusRight.hidden = NO;
    _statusRight.attributedStringValue = join(right);
}

// MARK: - Keybindings

/// Shortcuts from extensions and keybindings.json, handled before the menu sees the key.
- (void)setUpKeybindings {
    __weak GWMainWindowController *weakSelf = self;
    _keybindings = [GWKeybindingService new];
    _keybindings.contextProvider = ^NSDictionary<NSString *, NSString *> *{
        return [weakSelf keybindingContext];
    };
    _keybindings.runCommand = ^(NSString *command, id arguments) {
        [weakSelf runCommandById:command arguments:arguments];
    };
    _keybindings.showStatus = ^(NSString *text) {
        [weakSelf hostShowStatusMessage:text seconds:text.length > 0 ? 3 : 0];
    };
    [_keybindings reload];
    _keyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
        GWMainWindowController *strongSelf = weakSelf;
        if (strongSelf == nil || event.window != strongSelf.window) {
            return event;
        }
        return [strongSelf->_keybindings handleKeyDown:event] ? nil : event;
    }];
}

/// What `when` clauses can ask about: where the focus is, and the file in front.
- (NSDictionary<NSString *, NSString *> *)keybindingContext {
    NSMutableDictionary<NSString *, NSString *> *context = [NSMutableDictionary dictionary];
    NSResponder *responder = self.window.firstResponder;
    BOOL inEditor = responder == _editorView;
    BOOL inTerminal = [responder isKindOfClass:NSClassFromString(@"GWTerminalView")];
    BOOL inTextInput = [responder isKindOfClass:NSTextView.class] && !inEditor;
    context[@"isMac"] = @"true";
    context[@"editorTextFocus"] = inEditor ? @"true" : @"false";
    context[@"editorFocus"] = inEditor ? @"true" : @"false";
    context[@"terminalFocus"] = inTerminal ? @"true" : @"false";
    context[@"inputFocus"] = inTextInput ? @"true" : @"false";
    context[@"textInputFocus"] = (inEditor || inTextInput) ? @"true" : @"false";
    if (Tab *tab = [self currentTab]) {
        context[@"editorLangId"] = @(tab->document->languageId.c_str());
        context[@"editorReadonly"] = tab->document->readOnly ? @"true" : @"false";
        context[@"editorHasSelection"] = tab->document->selection.empty() ? @"false" : @"true";
        context[@"editorHasMultipleSelections"] = tab->document->extraSelections.empty() ? @"false" : @"true";
        if (tab->document->path()) {
            context[@"resourceExtname"] = @(tab->document->path()->extension().c_str());
            context[@"resourceFilename"] = @(tab->document->path()->filename().c_str());
        }
    }
    // Context keys that extensions set with the `setContext` command.
    for (NSString *key in _extensionContextKeys) {
        context[key] = _extensionContextKeys[key];
    }
    return context;
}

/// Runs a command by id: an editor action we have an equivalent for, else an extension's command.
- (void)runCommandById:(NSString *)command arguments:(id)arguments {
    NSString *actionName = [GWKeybindingService actionNameForCommand:command];
    if (actionName != nil) {
        [NSApp sendAction:NSSelectorFromString(actionName) to:nil from:self];
        return;
    }
    NSArray *argumentList = arguments == nil ? nil : (arguments == NSNull.null ? nil : @[arguments]);
    [_extensionHost executeCommand:command arguments:argumentList];
}

- (IBAction)openKeybindings:(id)sender {
    [_keybindings createUserFileIfNeeded];
    [self openURL:_keybindings.userFileURL];
}

// MARK: - Telling extensions about the editor

/// Several things change at once (switching tabs moves the document, the caret and the status), so
/// the report is made once, after they have settled.
- (void)scheduleEditorStateForExtensions {
    if (_editorStateScheduled) {
        return;
    }
    _editorStateScheduled = YES;
    __weak GWMainWindowController *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        GWMainWindowController *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        strongSelf->_editorStateScheduled = NO;
        [strongSelf sendEditorStateToExtensions];
    });
}

/// The front text file and its cursors, in the units extensions use (UTF-16 columns).
- (void)sendEditorStateToExtensions {
    using Json = gw::lsp::Json;
    Tab *tab = [self currentTab];
    bool isTextFile = tab != nullptr && tab->kind == Tab::Kind::Text && !tab->isVirtual && tab->document->path().has_value();
    if (!isTextFile) {
        [_extensionHost setEditorState:Json()];
        return;
    }
    const gw::Document &document = *tab->document;
    const gw::TextBuffer &buffer = document.buffer();
    auto selectionJson = [&](const gw::Selection &selection) {
        return Json{{"anchor", gw::lsp::position(buffer, selection.anchor)}, {"active", gw::lsp::position(buffer, selection.caret)}};
    };
    Json selections = Json::array();
    selections.push_back(selectionJson(document.selection));
    for (const gw::Selection &extra : document.extraSelections) {
        selections.push_back(selectionJson(extra));
    }
    Json state = {
        {"uri", gw::lsp::fileURI(document.path()->string())},
        {"selections", selections},
        {"tabSize", GWServices.shared.settings.tabSize},
        {"insertSpaces", true},
    };
    [_extensionHost setEditorState:state];
}

- (Tab *)tabForPath:(NSString *)path {
    for (auto &tab : _tabs) {
        if (tab->document->path() && tab->document->path()->string() == path.UTF8String) {
            return tab.get();
        }
    }
    return nullptr;
}

- (void)hostSetContextKey:(NSString *)key value:(NSString *)value {
    if (_extensionContextKeys == nil) {
        _extensionContextKeys = [NSMutableDictionary dictionary];
    }
    _extensionContextKeys[key] = value;
}

- (void)hostSetSelections:(const gw::lsp::Json &)selections forPath:(NSString *)path {
    Tab *tab = [self tabForPath:path];
    if (tab == nullptr || tab != [self currentTab] || !selections.is_array() || selections.empty()) {
        return;
    }
    const gw::TextBuffer &buffer = tab->document->buffer();
    std::vector<gw::Selection> parsed;
    for (const gw::lsp::Json &item : selections) {
        try {
            parsed.push_back(gw::Selection{gw::lsp::position(buffer, item.at("anchor")), gw::lsp::position(buffer, item.at("active"))});
        } catch (const std::exception &) {
        }
    }
    if (parsed.empty()) {
        return;
    }
    tab->document->selection = parsed.front();
    tab->document->extraSelections.assign(parsed.begin() + 1, parsed.end());
    [_editorView selectionDidChange];
    [_editorView jumpToPosition:parsed.front().caret];
}

/// A color from decoration options: CSS text, or a ThemeColor ({id}) looked up in the theme.
- (std::optional<gw::Color>)decorationColorFrom:(const gw::lsp::Json &)value {
    if (value.is_string()) {
        return gw::parseCssColor(value.get<std::string>());
    }
    if (value.is_object() && value.contains("id") && value["id"].is_string()) {
        NSString *key = @(value["id"].get<std::string>().c_str());
        if (key != nil && GWServices.shared.theme.hasColor(key.UTF8String)) {  // (nil: the name was not valid text)
            return GWColorFromNSColor([GWServices.shared color:key]);
        }
    }
    return std::nullopt;
}

/// `options` with the dark or light variant (and a range's own render options) laid over it.
static gw::lsp::Json MergedDecorationOptions(const gw::lsp::Json &base, const gw::lsp::Json &override, bool dark) {
    using Json = gw::lsp::Json;
    Json merged = base.is_object() ? base : Json::object();
    auto layer = [&](const Json &top) {
        if (!top.is_object()) return;
        for (const auto &[key, value] : top.items()) {
            if (key == "light" || key == "dark") continue;
            if (key == "after" && value.is_object() && merged.contains("after") && merged["after"].is_object()) {
                for (const auto &[innerKey, innerValue] : value.items()) merged["after"][innerKey] = innerValue;
            } else {
                merged[key] = value;
            }
        }
        const char *variant = dark ? "dark" : "light";
        if (top.contains(variant) && top[variant].is_object()) {
            for (const auto &[key, value] : top[variant].items()) merged[key] = value;
        }
    };
    layer(base);
    layer(override);
    return merged;
}

- (void)hostSetDecorationsForPath:(NSString *)path
                              key:(NSString *)key
                          options:(const gw::lsp::Json &)options
                           ranges:(const gw::lsp::Json &)ranges {
    using Json = gw::lsp::Json;
    Tab *tab = [self tabForPath:path];
    if (tab == nullptr) {
        return;
    }
    std::vector<GWDecoration> parsed;
    bool dark = GWServices.shared.theme.isDark();
    const gw::TextBuffer &buffer = tab->document->buffer();
    for (const Json &item : ranges) {
        if (!item.is_object() || !item.contains("range")) continue;
        Json look = MergedDecorationOptions(options, item.value("renderOptions", Json::object()), dark);
        GWDecoration decoration;
        try {
            decoration.range = {gw::lsp::position(buffer, item["range"].at("start")), gw::lsp::position(buffer, item["range"].at("end"))};
        } catch (const std::exception &) {
            continue;
        }
        if (look.contains("backgroundColor")) decoration.background = [self decorationColorFrom:look["backgroundColor"]];
        if (look.contains("color")) decoration.foreground = [self decorationColorFrom:look["color"]];
        decoration.wholeLine = look.value("isWholeLine", false);
        // A border or outline: its color is in "borderColor"/"outlineColor", or the last color in "1px solid red".
        for (const char *name : {"borderColor", "outlineColor"}) {
            if (look.contains(name)) decoration.border = [self decorationColorFrom:look[name]];
        }
        for (const char *name : {"border", "outline"}) {
            if (!decoration.border && look.contains(name) && look[name].is_string()) {
                std::string text = look[name].get<std::string>();
                size_t space = text.rfind(' ');
                decoration.border = gw::parseCssColor(space == std::string::npos ? text : text.substr(space + 1));
            }
        }
        std::string weight = gw::stringOr(look, "fontWeight");
        decoration.bold = weight == "bold" || weight == "bolder" || (weight.size() == 3 && weight[0] >= '6' && weight[0] <= '9');
        decoration.italic = look.value("fontStyle", "") == "italic";
        std::string textDecoration = look.value("textDecoration", "");
        decoration.underline = textDecoration.find("underline") != std::string::npos;
        decoration.strikethrough = textDecoration.find("line-through") != std::string::npos;
        if (look.contains("after") && look["after"].is_object()) {
            const Json &after = look["after"];
            decoration.afterText = after.value("contentText", "");
            if (after.contains("color")) decoration.afterColor = [self decorationColorFrom:after["color"]];
        }
        parsed.push_back(std::move(decoration));
    }
    std::string name = key.UTF8String;
    if (parsed.empty()) {
        tab->decorations.erase(name);
    } else {
        tab->decorations[name] = std::move(parsed);
    }
    if (tab == [self currentTab]) {
        [_editorView setDecorationGroups:tab->decorations];
    }
}

- (void)hostRevealRange:(const gw::lsp::Json &)range forPath:(NSString *)path {
    Tab *tab = [self tabForPath:path];
    if (tab == nullptr || tab != [self currentTab] || !range.is_object() || !range.contains("start")) {
        return;
    }
    try {
        [_editorView jumpToPosition:gw::lsp::position(tab->document->buffer(), range.at("start"))];
    } catch (const std::exception &) {
    }
}

- (BOOL)hostInsertSnippet:(NSString *)snippet atRanges:(const gw::lsp::Json &)ranges forPath:(NSString *)path {
    Tab *tab = [self tabForPath:path];
    if (tab == nullptr || tab != [self currentTab] || tab->document->readOnly) {
        return NO;
    }
    gw::lsp::Json range = ranges.is_array() && !ranges.empty() ? ranges[0] : gw::lsp::Json();
    if (range.is_null()) {
        const gw::TextBuffer &buffer = tab->document->buffer();
        gw::Range selected = tab->document->selection.range();
        range = {{"start", gw::lsp::position(buffer, selected.start)}, {"end", gw::lsp::position(buffer, selected.end)}};
    }
    GWSuggestion *item = [GWSuggestion new];
    item.resolved = YES;
    item.kind = 15;
    item.label = @"snippet";
    item.raw = std::make_shared<gw::lsp::Json>(gw::lsp::Json{
        {"label", "snippet"},
        {"textEdit", {{"range", range}, {"newText", snippet.UTF8String}}},
        {"insertTextFormat", 2},
    });
    [self acceptSuggestion:item];
    return YES;
}

// MARK: - What language servers say

/// `window/showMessage`: a line in the status bar, and in the server's log so it can be read again.
- (void)serverSaid:(NSString *)message type:(int)type server:(NSString *)serverName {
    NSString *prefix = type == 1 ? @"⛔ " : (type == 2 ? @"⚠️ " : @"");
    [_extensionHost appendLog:[NSString stringWithFormat:@"[%d] %@\n", type, message] toChannel:serverName];
    if (type <= 3) {
        [self hostShowStatusMessage:[NSString stringWithFormat:@"%@%@: %@", prefix, serverName, message] seconds:10];
    }
}

/// `$/progress`: "clangd: Indexing 30%" stays in the status bar while the work lasts.
- (void)serverProgress:(NSString *)serverName
                 token:(NSString *)token
                  kind:(NSString *)kind
                 title:(NSString *)title
               message:(NSString *)message
            percentage:(int)percentage {
    NSString *key = [serverName stringByAppendingFormat:@"/%@", token];
    if ([kind isEqualToString:@"end"]) {
        [_serverProgress removeObjectForKey:key];
    } else {
        NSString *previous = _serverProgress[key];
        // A report carries only what changed: keep the title from "begin".
        NSString *heading = title.length > 0 ? title : [previous componentsSeparatedByString:@"  "].firstObject;
        NSMutableString *line = [NSMutableString stringWithFormat:@"%@: %@", serverName, heading ?: @"Working"];
        if (message.length > 0) [line appendFormat:@" %@", message];
        if (percentage >= 0) [line appendFormat:@" %d%%", percentage];
        _serverProgress[key] = [line copy];
    }
    [self updateStatus];
}

/// `window/showMessageRequest`: a question with buttons, as a sheet.
- (void)serverAsked:(NSString *)message
            actions:(NSArray<NSString *> *)actions
             server:(NSString *)serverName
              reply:(void (^)(NSString *))reply {
    NSAlert *alert = [NSAlert new];
    alert.messageText = serverName;
    alert.informativeText = message;
    for (NSString *action in actions) {
        [alert addButtonWithTitle:action];
    }
    if (actions.count == 0) {
        [alert addButtonWithTitle:@"OK"];
    }
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        NSInteger index = response - NSAlertFirstButtonReturn;
        reply(index >= 0 && index < static_cast<NSInteger>(actions.count) ? actions[static_cast<NSUInteger>(index)] : @"");
    }];
}

// MARK: - Extension host

- (NSWindow *)hostWindow {
    return self.window;
}

- (BOOL)hostApplyWorkspaceEdit:(const gw::lsp::Json &)edit {
    return [self applyWorkspaceEdit:edit];
}

- (void)hostOpenFileAtPath:(NSString *)path line:(NSInteger)line character:(NSInteger)character {
    if (line >= 0) {
        [self openPath:path atLine:line + 1];
    } else {
        [self openURL:[NSURL fileURLWithPath:path]];
    }
}

- (BOOL)hostSaveFileAtPath:(NSString *)path {
    for (auto &tab : _tabs) {
        if (tab->document->path() && tab->document->path()->string() == path.UTF8String) {
            return [self saveTab:*tab];
        }
    }
    return NO;
}

- (void)hostSaveAll {
    [self saveAllDocuments:nil];
}

- (void)hostShowStatusMessage:(NSString *)text seconds:(NSTimeInterval)seconds {
    _extensionStatusMessage = text.length > 0 ? [text copy] : nil;
    [self updateStatus];
    if (seconds > 0 && text.length > 0) {
        __weak GWMainWindowController *weakSelf = self;
        NSString *shown = _extensionStatusMessage;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            GWMainWindowController *strongSelf = weakSelf;
            if (strongSelf != nil && [strongSelf->_extensionStatusMessage isEqualToString:shown]) {
                strongSelf->_extensionStatusMessage = nil;
                [strongSelf updateStatus];
            }
        });
    }
}

- (void)hostStatusItemsChanged {
    [self updateStatus];
}

/// Editor commands that extensions ask for by their VS Code names.
- (BOOL)hostRunBuiltinCommand:(NSString *)identifier arguments:(NSArray *)arguments {
    if ([identifier isEqualToString:@"vscode.open"] && arguments.count > 0) {
        id target = arguments[0];
        NSString *text = [target isKindOfClass:NSString.class] ? target : (target[@"external"] ?: target[@"path"]);
        NSURL *url = [text hasPrefix:@"/"] ? [NSURL fileURLWithPath:text] : [NSURL URLWithString:text];
        if (url.isFileURL) {
            [self openURL:url];
        } else if (url != nil) {
            [NSWorkspace.sharedWorkspace openURL:url];
        }
        return url != nil;
    }
    NSString *known = [GWKeybindingService actionNameForCommand:identifier];
    if (known != nil) {
        [NSApp sendAction:NSSelectorFromString(known) to:nil from:self];
        return YES;
    }
    NSDictionary<NSString *, NSString *> *actions = @{
        @"workbench.action.files.save": @"saveDocument:",
        @"workbench.action.files.saveAll": @"saveAllDocuments:",
        @"editor.action.formatDocument": @"formatDocument:",
        @"workbench.action.showCommands": @"showCommandPalette:",
        @"workbench.action.quickOpen": @"quickOpen:",
        @"editor.action.triggerSuggest": @"completeCode:",
        @"workbench.action.openSettings": @"openSettings:",
        @"editor.action.quickFix": @"showQuickFixes:",
    };
    NSString *selectorName = actions[identifier];
    if (selectorName != nil) {
        [NSApp sendAction:NSSelectorFromString(selectorName) to:self from:nil];
        return YES;
    }
    if ([identifier isEqualToString:@"workbench.action.reloadWindow"] || [identifier isEqualToString:@"workbench.action.restartExtensionHost"]) {
        [_extensionHost shutdown];
        [self hostProvidersChanged];
        return YES;
    }
    return NO;
}

/// Extensions now provide features for other languages (or the host was restarted): open files get
/// another look, so ones that now have extension support attach to it.
- (void)hostProvidersChanged {
    for (auto &tab : _tabs) {
        if (tab->kind == Tab::Kind::Text && !tab->isVirtual) {
            [_language trackDocument:tab->document.get()];
        }
    }
    [self updateStatus];
}

/// "1234567" → "1.2M": download counts for the extension browser.
static NSString *CompactCount(long count) {
    if (count >= 1000000) return [NSString stringWithFormat:@"%.1fM", count / 1000000.0];
    if (count >= 1000) return [NSString stringWithFormat:@"%.1fK", count / 1000.0];
    return [NSString stringWithFormat:@"%ld", count];
}

/// Extensions ▸ Search Extensions…: type to search Open VSX (the most downloaded show first),
/// Return installs. The palette lists what the last search found; searches run in the background
/// a moment after typing stops, and the list refreshes when they come back.
- (IBAction)searchExtensions:(id)sender {
    struct SearchState {
        NSString *lastQuery = nil;
        NSUInteger token = 0;
        NSArray<GWPaletteItem *> *results = @[];
        NSString *message = @"Searching Open VSX…";
    };
    auto state = std::make_shared<SearchState>();
    __weak GWMainWindowController *weakSelf = self;

    void (^runSearch)(NSString *) = ^(NSString *query) {
        NSUInteger token = ++state->token;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (token != state->token) {
                return;  // typed more since
            }
            std::string wanted = query.UTF8String;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                std::string error;
                auto found = gw::ExtensionManager::searchOpenVSX(wanted, 30, &error);
                dispatch_async(dispatch_get_main_queue(), ^{
                    GWMainWindowController *strongSelf = weakSelf;
                    if (strongSelf == nil || token != state->token) {
                        return;
                    }
                    NSMutableArray<GWPaletteItem *> *items = [NSMutableArray array];
                    for (const auto &entry : found) {
                        BOOL installed = GWServices.shared.extensions.isInstalled(entry.id);
                        GWPaletteItem *item = [GWPaletteItem new];
                        item.title = entry.displayName.empty() ? @(entry.id.c_str()) : @(entry.displayName.c_str());
                        NSMutableArray<NSString *> *facts = [NSMutableArray array];
                        [facts addObject:@(entry.id.c_str())];
                        [facts addObject:[@"↓ " stringByAppendingString:CompactCount(entry.downloads)]];
                        if (entry.rating > 0) [facts addObject:[NSString stringWithFormat:@"★ %.1f", entry.rating]];
                        if (installed) [facts addObject:@"Installed"];
                        if (!entry.description.empty()) [facts addObject:@(entry.description.c_str())];
                        item.subtitle = [facts componentsJoinedByString:@"  ·  "];
                        item.symbol = installed ? @"checkmark.circle.fill" : @"arrow.down.circle";
                        item.symbolColor = installed ? NSColor.systemGreenColor : NSColor.controlAccentColor;
                        NSString *identifier = @(entry.id.c_str());
                        item.run = ^{
                            [weakSelf installFromSearch:identifier];
                        };
                        [items addObject:item];
                    }
                    state->results = items;
                    state->message = !error.empty() ? @(error.c_str()) : (items.count == 0 ? @"Nothing matches." : @"");
                    [GWPalette.shared refresh];
                });
            });
        });
    };

    [GWPalette.shared showOverWindow:self.window placeholder:@"Search extensions on Open VSX…"
                            provider:^NSArray<GWPaletteItem *> *(NSString *query) {
        if (![query isEqualToString:state->lastQuery]) {
            state->lastQuery = [query copy];
            runSearch(query);
        }
        if (state->results.count == 0 && state->message.length > 0) {
            GWPaletteItem *note = [GWPaletteItem new];
            note.title = state->message;
            note.symbol = @"magnifyingglass";
            note.symbolColor = NSColor.secondaryLabelColor;
            note.run = ^{};
            return @[note];
        }
        return state->results;
    }];
}

- (void)installFromSearch:(NSString *)identifier {
    if (GWServices.shared.extensions.isInstalled(identifier.UTF8String)) {
        [self hostShowStatusMessage:[identifier stringByAppendingString:@" is already installed."] seconds:4];
        return;
    }
    [self hostShowStatusMessage:[NSString stringWithFormat:@"Installing %@…", identifier] seconds:0];
    __weak GWMainWindowController *weakSelf = self;
    [GWServices.shared installExtension:identifier completion:^(BOOL ok, NSString *message) {
        [weakSelf hostShowStatusMessage:message seconds:8];
    }];
}

/// Extension output channels are log files: this opens one in a tab.
- (IBAction)showExtensionLogs:(id)sender {
    NSArray<NSString *> *channels = _extensionHost.logChannels;
    if (channels.count == 0) {
        [self hostShowStatusMessage:@"No extension has written any output yet." seconds:4];
        return;
    }
    NSMutableArray<GWPaletteItem *> *items = [NSMutableArray array];
    __weak GWMainWindowController *weakSelf = self;
    for (NSString *channel in channels) {
        GWPaletteItem *item = [GWPaletteItem new];
        item.title = channel;
        item.subtitle = @"Extension output";
        item.symbol = @"text.alignleft";
        item.symbolColor = NSColor.systemPurpleColor;
        item.run = ^{
            GWMainWindowController *strongSelf = weakSelf;
            NSURL *url = [strongSelf->_extensionHost logURLForChannel:channel];
            if (url != nil) {
                [strongSelf openURL:url];
            }
        };
        [items addObject:item];
    }
    [self showPaletteWithItems:items placeholder:@"Extension output…"];
}

/// Extensions ▸ Manage Extensions…: everything installed, enabled or not; choosing one offers to
/// switch it off or on, or to uninstall it.
- (IBAction)manageExtensions:(id)sender {
    GWServices *services = GWServices.shared;
    struct Entry {
        NSString *identifier;
        NSString *name;
        NSString *version;
        BOOL disabled;
        BOOL hasCode;
    };
    std::vector<Entry> entries;
    for (const gw::Extension &extension : services.extensions.extensions()) {
        entries.push_back({@(extension.id.c_str()), @(extension.displayName.c_str()), @(extension.version.c_str()), NO, extension.hasCode});
    }
    for (const gw::Extension &extension : services.extensions.disabledExtensions()) {
        entries.push_back({@(extension.id.c_str()), @(extension.displayName.c_str()), @(extension.version.c_str()), YES, extension.hasCode});
    }
    std::sort(entries.begin(), entries.end(), [](const Entry &a, const Entry &b) {
        return [a.name caseInsensitiveCompare:b.name] == NSOrderedAscending;
    });
    if (entries.empty()) {
        [self hostShowStatusMessage:@"No extensions installed. Extensions ▸ Search Extensions… finds some." seconds:6];
        return;
    }
    NSMutableArray<GWPaletteItem *> *items = [NSMutableArray array];
    __weak GWMainWindowController *weakSelf = self;
    for (const Entry &entry : entries) {
        GWPaletteItem *item = [GWPaletteItem new];
        item.title = entry.name;
        NSMutableArray<NSString *> *facts = [NSMutableArray arrayWithObjects:entry.identifier, [@"v" stringByAppendingString:entry.version], nil];
        [facts addObject:entry.disabled ? @"Disabled" : (entry.hasCode ? @"Enabled · runs code" : @"Enabled")];
        item.subtitle = [facts componentsJoinedByString:@"  ·  "];
        item.symbol = entry.disabled ? @"slash.circle" : @"puzzlepiece.extension";
        item.symbolColor = entry.disabled ? NSColor.tertiaryLabelColor : NSColor.systemPurpleColor;
        NSString *identifier = entry.identifier;
        NSString *name = entry.name;
        BOOL disabled = entry.disabled;
        item.run = ^{
            [weakSelf chooseActionForExtension:identifier name:name disabled:disabled];
        };
        [items addObject:item];
    }
    [self showPaletteWithItems:items placeholder:@"Manage extensions…"];
}

- (void)chooseActionForExtension:(NSString *)identifier name:(NSString *)name disabled:(BOOL)disabled {
    NSMutableArray<GWPaletteItem *> *items = [NSMutableArray array];
    GWPaletteItem *toggle = [GWPaletteItem new];
    toggle.title = disabled ? [@"Enable " stringByAppendingString:name] : [@"Disable " stringByAppendingString:name];
    toggle.symbol = disabled ? @"checkmark.circle" : @"slash.circle";
    toggle.symbolColor = disabled ? NSColor.systemGreenColor : NSColor.systemOrangeColor;
    toggle.run = ^{
        [GWServices.shared setExtension:identifier enabled:disabled];
    };
    [items addObject:toggle];
    GWPaletteItem *remove = [GWPaletteItem new];
    remove.title = [@"Uninstall " stringByAppendingString:name];
    remove.symbol = @"trash";
    remove.symbolColor = NSColor.systemRedColor;
    remove.run = ^{
        [GWServices.shared uninstallExtension:identifier];
    };
    [items addObject:remove];
    [self showPaletteWithItems:items placeholder:name];
}

/// The theme name in the status bar: a menu of every installed theme, right above the name.
- (void)themeChipClicked:(NSButton *)chip {
    GWServices *services = GWServices.shared;
    NSMenu *menu = [NSMenu new];
    for (NSString *label in services.themeLabels) {
        NSMenuItem *item = [menu addItemWithTitle:label action:@selector(themeMenuItemChosen:) keyEquivalent:@""];
        item.target = self;
        item.state = [label isEqualToString:services.themeLabel] ? NSControlStateValueOn : NSControlStateValueOff;
    }
    // Open upward from the chip: the status bar is at the bottom of the window.
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, 0) inView:chip];
}

- (void)themeMenuItemChosen:(NSMenuItem *)item {
    [GWServices.shared selectThemeNamed:item.title];
}

/// The names of the installed fixed-width font families (the ones that suit code), sorted.
/// Found once; the list of fonts doesn't change while the app runs.
- (NSArray<NSString *> *)monospacedFontFamilies {
    static NSArray<NSString *> *families = nil;
    if (families != nil) {
        return families;
    }
    NSMutableArray<NSString *> *found = [NSMutableArray array];
    NSFontManager *manager = NSFontManager.sharedFontManager;
    for (NSString *family in manager.availableFontFamilies) {
        if ([family hasPrefix:@"."]) {
            continue;  // system-internal families
        }
        NSFont *font = [NSFont fontWithName:family size:12];
        if (font == nil) {
            NSArray *members = [manager availableMembersOfFontFamily:family];
            NSString *firstMember = members.firstObject ? members.firstObject[0] : nil;
            font = firstMember ? [NSFont fontWithName:firstMember size:12] : nil;
        }
        if (font != nil && font.isFixedPitch) {
            [found addObject:family];
        }
    }
    families = [found sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
    return families;
}

/// The font button in the status bar: size controls, then every code font installed.
- (void)fontChipClicked:(NSButton *)chip {
    GWServices *services = GWServices.shared;
    NSMenu *menu = [NSMenu new];

    NSString *sizeTitle = [NSString stringWithFormat:@"Size: %g", services.settings.fontSize];
    NSMenuItem *sizeItem = [menu addItemWithTitle:sizeTitle action:nil keyEquivalent:@""];
    sizeItem.enabled = NO;
    NSMenuItem *bigger = [menu addItemWithTitle:@"Bigger" action:@selector(increaseFontSize:) keyEquivalent:@"="];
    bigger.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    bigger.target = NSApp.delegate;  // (the app delegate handles Bigger Text and Smaller Text)
    NSMenuItem *smaller = [menu addItemWithTitle:@"Smaller" action:@selector(decreaseFontSize:) keyEquivalent:@"-"];
    smaller.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    smaller.target = NSApp.delegate;
    [menu addItem:NSMenuItem.separatorItem];

    NSString *current = @(services.settings.fontFamily.c_str());
    NSMenuItem *defaultItem = [menu addItemWithTitle:@"SF Mono (default)" action:@selector(fontFamilyChosen:) keyEquivalent:@""];
    defaultItem.target = self;
    defaultItem.representedObject = @"";
    defaultItem.state = current.length == 0 ? NSControlStateValueOn : NSControlStateValueOff;
    for (NSString *family in [self monospacedFontFamilies]) {
        NSMenuItem *item = [menu addItemWithTitle:family action:@selector(fontFamilyChosen:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = family;
        item.state = [family isEqualToString:current] ? NSControlStateValueOn : NSControlStateValueOff;
        // Each name is shown in its own font, so you can see what you are picking.
        NSFont *preview = [NSFont fontWithName:family size:13];
        if (preview != nil) {
            item.attributedTitle = [[NSAttributedString alloc] initWithString:family attributes:@{NSFontAttributeName: preview}];
        }
    }
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, 0) inView:chip];
}

- (void)fontFamilyChosen:(NSMenuItem *)item {
    NSString *family = item.representedObject;
    [GWServices.shared updateSettings:^(gw::EditorSettings &settings) {
        settings.fontFamily = family.UTF8String;
    }];
}

/// Extensions ▸ Select Color Theme…: every installed color theme in one list; Return applies it.
- (IBAction)selectColorTheme:(id)sender {
    GWServices *services = GWServices.shared;
    NSString *current = services.themeLabel;
    NSMutableArray<GWPaletteItem *> *items = [NSMutableArray array];
    for (NSString *label in services.themeLabels) {
        BOOL isCurrent = [label isEqualToString:current];
        GWPaletteItem *item = [GWPaletteItem new];
        item.title = label;
        item.symbol = isCurrent ? @"checkmark.circle.fill" : @"paintpalette.fill";
        item.symbolColor = isCurrent ? NSColor.systemGreenColor : NSColor.systemPinkColor;
        item.run = ^{
            [GWServices.shared selectThemeNamed:label];
        };
        [items addObject:item];
    }
    [self showPaletteWithItems:items placeholder:@"Select a color theme…"];
}

/// Extensions ▸ Select File Icon Theme…: the icon themes extensions provide, or the built-in icons.
- (IBAction)selectIconTheme:(id)sender {
    GWServices *services = GWServices.shared;
    NSString *current = services.iconThemeLabel;
    NSMutableArray<GWPaletteItem *> *items = [NSMutableArray array];
    auto addItem = ^(NSString *title, NSString *subtitle, NSString *label) {
        GWPaletteItem *item = [GWPaletteItem new];
        item.title = title;
        item.subtitle = subtitle;
        BOOL isCurrent = (label == nil && current == nil) || [label isEqualToString:current];
        item.symbol = isCurrent ? @"checkmark.circle.fill" : @"photo.on.rectangle";
        item.symbolColor = isCurrent ? NSColor.systemGreenColor : NSColor.secondaryLabelColor;
        item.run = ^{
            [GWServices.shared selectIconThemeLabel:label];
        };
        [items addObject:item];
    };
    addItem(@"Default", @"Glasswork's own icons", nil);
    for (NSString *label in services.iconThemeLabels) {
        addItem(label, @"From an extension", label);
    }
    if (items.count == 1) {
        [self hostShowStatusMessage:@"No file icon themes installed. Search Extensions… for \"icon theme\"." seconds:6];
        return;
    }
    [self showPaletteWithItems:items placeholder:@"Select a file icon theme…"];
}

/// Restarts the extension host (stops it; the next language or command that needs it starts it again).
- (IBAction)restartExtensionHost:(id)sender {
    [_extensionHost shutdown];
    [self hostShowStatusMessage:@"Extensions restarted." seconds:3];
    [_extensionHost startIfExtensionsWantToRun];
    [self hostProvidersChanged];
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

// MARK: - Tasks (build, run, test)

/// Runs a shell command from the project folder in the tasks terminal.
- (void)runTaskCommand:(const std::string &)command {
    [self buildTerminalPanel];
    [self setTerminalVisible:YES];
    NSString *folder = _fileTree.rootURL.path;
    NSString *full = @(command.c_str());
    if (folder.length > 0) {
        full = [NSString stringWithFormat:@"cd %@ && %s", [self shellQuoted:folder], command.c_str()];
    }
    [_terminal runTaskCommand:full];
}

/// ⇧⌘B: pick from what the project can do.
- (IBAction)runTask:(id)sender {
    NSString *folder = _fileTree.rootURL.path;
    if (folder.length == 0) {
        [self showErrorTitle:@"Open a folder first" message:@"Tasks come from the build files in your project folder."];
        return;
    }
    std::vector<gw::Task> tasks = gw::detectTasks(folder.UTF8String);
    if (tasks.empty()) {
        [self showErrorTitle:@"No tasks found" message:@"Glasswork looks for CMakeLists.txt, Package.swift, Cargo.toml, "
                                                       @"go.mod, package.json and Makefiles in the project folder."];
        return;
    }
    NSMutableArray<GWPaletteItem *> *items = [NSMutableArray array];
    __weak GWMainWindowController *weakSelf = self;
    for (const gw::Task &task : tasks) {
        GWPaletteItem *item = [GWPaletteItem new];
        item.title = @(task.label.c_str());
        item.subtitle = @(task.command.c_str());
        switch (task.kind) {
            case gw::Task::Kind::Build: item.symbol = @"hammer.fill"; item.symbolColor = NSColor.systemOrangeColor; break;
            case gw::Task::Kind::Run: item.symbol = @"play.fill"; item.symbolColor = NSColor.systemGreenColor; break;
            case gw::Task::Kind::Test: item.symbol = @"checkmark.seal.fill"; item.symbolColor = NSColor.systemTealColor; break;
            default: item.symbol = @"terminal.fill"; item.symbolColor = NSColor.secondaryLabelColor; break;
        }
        std::string command = task.command;
        item.run = ^{
            GWMainWindowController *strongSelf = weakSelf;
            [strongSelf saveAllDirtyFilesQuietly];
            [strongSelf runTaskCommand:command];
        };
        [items addObject:item];
    }
    [self showPaletteWithItems:items placeholder:@"Run task…"];
}

/// ⌘B: the project's main build.
- (IBAction)buildProject:(id)sender {
    NSString *folder = _fileTree.rootURL.path;
    std::vector<gw::Task> tasks = folder.length > 0 ? gw::detectTasks(folder.UTF8String) : std::vector<gw::Task>();
    for (const gw::Task &task : tasks) {
        if (task.kind == gw::Task::Kind::Build) {
            [self saveAllDirtyFilesQuietly];
            [self runTaskCommand:task.command];
            return;
        }
    }
    [self runTask:sender];  // no build found: show what there is (or explain)
}

/// ⌥⌘R: run the file in front (a script, or a single C/C++ file).
- (IBAction)runCurrentFile:(id)sender {
    Tab *tab = [self currentTab];
    if (tab == nullptr || !tab->document->path()) {
        [self showErrorTitle:@"Nothing to run" message:@"Save the file first."];
        return;
    }
    std::string command = gw::commandToRunFile(*tab->document->path(), tab->document->languageId);
    if (command.empty()) {
        [self showErrorTitle:@"Can't run this file" message:@"Glasswork can run scripts (Python, JavaScript, Swift, shell, "
                                                            @"Ruby, Go…) and single C, C++ and Rust files."];
        return;
    }
    if (tab->document->isDirty()) {
        [self saveTab:*tab];
    }
    [self runTaskCommand:command];
}

/// Saves every file with unsaved changes before a build, the way people expect. Files that
/// changed on disk meanwhile are left alone.
- (void)saveAllDirtyFilesQuietly {
    for (auto &tab : _tabs) {
        if (tab->isVirtual || !tab->document->path() || !tab->document->isDirty() || tab->document->fileChangedOnDisk()) {
            continue;
        }
        [self saveTab:*tab];
    }
}

// MARK: - Debugging

- (void)buildDebugger {
    if (_debugger != nil) {
        return;
    }
    __weak GWMainWindowController *weakSelf = self;
    _executionLine = -1;
    _debugger = [GWDebugger new];
    _debugPanel = [[GWDebugPanel alloc] initWithDebugger:_debugger];
    _debugPanel.onStart = ^{ [weakSelf startDebugging:nil]; };
    _debugger.onChange = ^{
        GWMainWindowController *strongSelf = weakSelf;
        [strongSelf->_debugPanel reload];
        if (strongSelf->_debugger.state != GWDebugStateStopped) {
            strongSelf->_executionLine = -1;
            [strongSelf updateExecutionMarker];
        }
    };
    _debugger.onLocation = ^(GWDebugFrame *frame) {
        [weakSelf showDebugFrame:frame];
    };
    _debugger.onOutput = ^(NSString *text, NSString *category) {
        GWMainWindowController *strongSelf = weakSelf;
        [strongSelf->_debugPanel appendConsole:text category:category];
    };
    _debugger.onError = ^(NSString *message) {
        GWMainWindowController *strongSelf = weakSelf;
        [strongSelf->_debugPanel appendConsole:[message stringByAppendingString:@"\n"] category:@"stderr"];
        [strongSelf showErrorTitle:@"Debugger" message:message];
    };
    _debugger.onEnded = ^(NSInteger code) {
        GWMainWindowController *strongSelf = weakSelf;
        strongSelf->_executionLine = -1;
        [strongSelf updateExecutionMarker];
        [strongSelf->_debugPanel appendConsole:@"Debugging ended.\n" category:@"console"];
    };
}

/// Puts the yellow arrow on the current line if the file in front is the one the debugger is in.
- (void)updateExecutionMarker {
    Tab *tab = [self currentTab];
    BOOL inThisFile = tab != nullptr && tab->document->path() && _executionPath != nil && _executionLine >= 0 &&
                      [_executionPath isEqualToString:@(tab->document->path()->c_str())];
    [_editorView setExecutionLine:inThisFile ? _executionLine : -1];
}

/// Shows where the program is stopped.
- (void)showDebugFrame:(GWDebugFrame *)frame {
    if (frame.path.length == 0 || frame.line <= 0) {
        return;
    }
    _executionPath = frame.path;
    _executionLine = frame.line - 1;
    if (!_root.sidebarVisible) {
        [self toggleSidebar:nil];
    }
    [self setSidebarMode:3];
    if (![[NSFileManager defaultManager] fileExistsAtPath:frame.path]) {
        return;
    }
    [self openPath:frame.path atLine:frame.line];
    [self updateExecutionMarker];
}

// ---- Breakpoints

- (void)loadBreakpointsForFolder:(NSString *)folder {
    _breakpointStore.clear();
    NSArray<NSDictionary *> *saved = [NSUserDefaults.standardUserDefaults arrayForKey:[@"breakpoints:" stringByAppendingString:folder]];
    for (NSDictionary *entry in saved) {
        NSString *path = entry[@"path"];
        if (path.length > 0) {
            _breakpointStore[path.UTF8String].insert(static_cast<size_t>([entry[@"line"] unsignedIntegerValue]));
        }
    }
}

- (void)saveBreakpoints {
    NSString *folder = _fileTree.rootURL.path;
    if (folder.length == 0) {
        return;
    }
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    for (const auto &[path, lines] : _breakpointStore) {
        for (size_t line : lines) {
            [entries addObject:@{@"path": @(path.c_str()), @"line": @(line)}];
        }
    }
    [NSUserDefaults.standardUserDefaults setObject:entries forKey:[@"breakpoints:" stringByAppendingString:folder]];
}

/// Breakpoints of the file in front changed: remember them and tell the debugger.
- (void)breakpointsChanged {
    Tab *tab = [self currentTab];
    if (tab == nullptr || !tab->document->path()) {
        return;
    }
    std::string path = tab->document->path()->string();
    _breakpointStore[path] = tab->document->breakpointLines;
    if (_breakpointStore[path].empty()) {
        _breakpointStore.erase(path);
    }
    [self saveBreakpoints];
    [self syncBreakpointsOfPath:@(path.c_str()) lines:tab->document->breakpointLines];
}

- (void)syncBreakpointsOfPath:(NSString *)path lines:(const std::set<size_t> &)lines {
    NSMutableSet<NSNumber *> *set = [NSMutableSet set];
    for (size_t line : lines) {
        [set addObject:@(line)];
    }
    [_debugger setBreakpointLines:set forPath:path];
}

/// All breakpoints, with the lines as they are now in open files.
- (NSDictionary<NSString *, NSSet<NSNumber *> *> *)currentBreakpoints {
    for (auto &tab : _tabs) {
        if (tab->document->path() && !tab->isVirtual) {
            _breakpointStore[tab->document->path()->string()] = tab->document->breakpointLines;
        }
    }
    NSMutableDictionary<NSString *, NSSet<NSNumber *> *> *result = [NSMutableDictionary dictionary];
    for (const auto &[path, lines] : _breakpointStore) {
        if (lines.empty()) {
            continue;
        }
        NSMutableSet<NSNumber *> *set = [NSMutableSet set];
        for (size_t line : lines) {
            [set addObject:@(line)];
        }
        result[@(path.c_str())] = set;
    }
    return result;
}

- (IBAction)toggleBreakpoint:(id)sender {
    Tab *tab = [self currentTab];
    if (tab == nullptr || !tab->document->path()) {
        NSBeep();
        return;
    }
    [_editorView toggleBreakpointAtLine:tab->document->selection.caret.line];
}

- (IBAction)removeAllBreakpoints:(id)sender {
    for (auto &tab : _tabs) {
        tab->document->breakpointLines.clear();
    }
    for (const auto &[path, lines] : _breakpointStore) {
        [_debugger setBreakpointLines:[NSSet set] forPath:@(path.c_str())];
    }
    _breakpointStore.clear();
    [self saveBreakpoints];
    _editorView.gutterView.needsDisplay = YES;
}

// ---- Starting and stepping

- (IBAction)showDebugPanel:(id)sender {
    [self revealSidebarMode:3];
}

/// F5: start, or carry on if the program is stopped.
- (IBAction)startDebugging:(id)sender {
    [self buildSecondaryPanels];
    if (_debugger.state == GWDebugStateStopped) {
        [_debugger resume];
        return;
    }
    if (_debugger.state != GWDebugStateIdle) {
        return;
    }
    // A program chosen before wins; otherwise the file in front is built and run.
    NSString *folder = _fileTree.rootURL.path;
    NSString *remembered = [self rememberedDebugSetting:@"debugProgram:" forFolder:folder];
    if (remembered.length > 0 && [NSFileManager.defaultManager isExecutableFileAtPath:remembered]) {
        [_debugPanel clearConsole];
        [self launchDebugProgram:remembered arguments:[self rememberedDebugArguments]];
        return;
    }
    Tab *tab = [self currentTab];
    if (tab != nullptr && tab->document->path() && [self canCompileForDebugging:*tab]) {
        [self debugCurrentFile:sender];
        return;
    }
    [self debugExecutable:sender];
}

/// A debugging choice remembered for the open folder (the program, or its arguments), if any.
- (NSString *)rememberedDebugSetting:(NSString *)keyPrefix forFolder:(NSString *)folder {
    if (folder.length == 0) {
        return nil;
    }
    return [NSUserDefaults.standardUserDefaults stringForKey:[keyPrefix stringByAppendingString:folder]];
}

- (NSArray<NSString *> *)rememberedDebugArguments {
    NSString *folder = _fileTree.rootURL.path;
    NSString *text = [self rememberedDebugSetting:@"debugArguments:" forFolder:folder];
    if (text.length == 0) {
        return @[];
    }
    NSMutableArray<NSString *> *words = [NSMutableArray array];
    for (NSString *word in [text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]) {
        if (word.length > 0) {
            [words addObject:word];
        }
    }
    return words;
}

- (BOOL)canCompileForDebugging:(Tab &)tab {
    const std::string &language = tab.document->languageId;
    std::string extension = tab.document->path()->extension().string();
    return (language == "c" && extension == ".c") ||
           (language == "cpp" && (extension == ".cpp" || extension == ".cc" || extension == ".cxx" || extension == ".mm"));
}

/// Builds the file in front with symbols into a temporary program, then debugs that.
- (IBAction)debugCurrentFile:(id)sender {
    Tab *tab = [self currentTab];
    if (tab == nullptr || !tab->document->path() || ![self canCompileForDebugging:*tab]) {
        [self showErrorTitle:@"Can't debug this file" message:@"Glasswork can build a single C or C++ file for debugging. For "
                                                              @"other projects, build them first and use Debug Executable…"];
        return;
    }
    [self buildSecondaryPanels];
    [self saveAllDirtyFilesQuietly];
    [self revealSidebarMode:3];
    [_debugPanel clearConsole];

    std::string source = tab->document->path()->string();
    bool isC = tab->document->languageId == "c";
    NSString *output = [NSTemporaryDirectory() stringByAppendingPathComponent:@"glasswork-debug-program"];
    std::vector<std::string> command = {"/usr/bin/xcrun", isC ? "clang" : "clang++"};
    if (!isC) {
        command.push_back("-std=c++20");
    }
    command.insert(command.end(), {"-g", "-O0", "-Wall", source, "-o", output.UTF8String});
    [_debugPanel appendConsole:[NSString stringWithFormat:@"Building %s…\n", tab->document->path()->filename().c_str()]
                      category:@"console"];
    __weak GWMainWindowController *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        gw::ProcessResult result = gw::runProcess(command);
        dispatch_async(dispatch_get_main_queue(), ^{
            GWMainWindowController *strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            std::string messages = result.output + result.errorOutput;
            if (!messages.empty()) {
                [strongSelf->_debugPanel appendConsole:@(messages.c_str()) category:result.succeeded() ? @"console" : @"stderr"];
            }
            if (!result.succeeded()) {
                [strongSelf showErrorTitle:@"The build failed" message:@"The compiler's messages are in the debug console."];
                return;
            }
            [strongSelf launchDebugProgram:output arguments:@[]];
        });
    });
}

/// Choose a program that is already built (with symbols), and its arguments.
- (IBAction)debugExecutable:(id)sender {
    [self buildSecondaryPanels];
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.message = @"Choose the program to debug (built with debug symbols)";
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    NSString *folder = _fileTree.rootURL.path;
    if (folder.length > 0) {
        NSString *build = [folder stringByAppendingPathComponent:@"build"];
        BOOL isDirectory = NO;
        BOOL hasBuildFolder = [NSFileManager.defaultManager fileExistsAtPath:build isDirectory:&isDirectory] && isDirectory;
        panel.directoryURL = [NSURL fileURLWithPath:hasBuildFolder ? build : folder];
    }
    if ([panel runModal] != NSModalResponseOK) {
        return;
    }
    NSString *program = panel.URL.path;

    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Arguments";
    alert.informativeText = [NSString stringWithFormat:@"Command-line arguments for %@ (leave empty for none).", program.lastPathComponent];
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 320, 24)];
    field.stringValue = [self rememberedDebugSetting:@"debugArguments:" forFolder:folder] ?: @"";
    alert.accessoryView = field;
    [alert addButtonWithTitle:@"Debug"];
    [alert addButtonWithTitle:@"Cancel"];
    alert.window.initialFirstResponder = field;
    if ([alert runModal] != NSAlertFirstButtonReturn) {
        return;
    }
    if (folder.length > 0) {
        [NSUserDefaults.standardUserDefaults setObject:program forKey:[@"debugProgram:" stringByAppendingString:folder]];
        [NSUserDefaults.standardUserDefaults setObject:field.stringValue forKey:[@"debugArguments:" stringByAppendingString:folder]];
    }
    [_debugPanel clearConsole];
    [self launchDebugProgram:program arguments:[self rememberedDebugArguments]];
}

- (void)launchDebugProgram:(NSString *)program arguments:(NSArray<NSString *> *)arguments {
    [self revealSidebarMode:3];
    NSString *folder = _fileTree.rootURL.path ?: NSHomeDirectory();
    [_debugger startProgram:program arguments:arguments workingDirectory:folder breakpoints:[self currentBreakpoints]];
}

- (IBAction)stopDebugging:(id)sender { [_debugger stop]; }
- (IBAction)debugStepOver:(id)sender { [_debugger stepOver]; }
- (IBAction)debugStepInto:(id)sender { [_debugger stepInto]; }
- (IBAction)debugStepOut:(id)sender { [_debugger stepOut]; }

// MARK: - Claude

- (void)updateClaudeChip {
    // Lit up in the accent color while the chat is open.
    NSColor *color = _root.chatVisible ? NSColor.controlAccentColor : GWStatusTextColor();
    NSDictionary *attributes = @{NSFontAttributeName: [NSFont systemFontOfSize:11.5 weight:NSFontWeightSemibold],
                                 NSForegroundColorAttributeName: color};
    NSMutableAttributedString *title = [GWSymbolString(@"sparkles", color, 11) mutableCopy];
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

- (void)debugRunExtensionCommand:(NSString *)identifier {
    [_extensionHost executeCommand:identifier arguments:nil];
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

/// Sends the compiler's or language server's problems for the file in front to Claude to fix.
/// `onlyLine` (from 0) limits it to the problems on one line; pass -1 for the whole file.
- (void)askClaudeToFixProblemsOnLine:(NSInteger)onlyLine {
    Tab *tab = [self currentTab];
    if (tab == nullptr || !tab->document->path()) {
        NSBeep();
        return;
    }
    NSString *relative = [self projectRelativePath:@(tab->document->path()->c_str())];
    NSMutableString *list = [NSMutableString string];
    NSUInteger count = 0;
    for (const GWDiagnostic &diagnostic : [_language diagnosticsForDocument:tab->document.get()]) {
        if (diagnostic.severity > 2 || (onlyLine >= 0 && diagnostic.range.start.line != static_cast<size_t>(onlyLine))) {
            continue;
        }
        [list appendFormat:@"- line %zu (%s): %s\n", diagnostic.range.start.line + 1, diagnostic.severity == 1 ? "error" : "warning",
                           diagnostic.message.c_str()];
        if (++count >= 30) {
            break;
        }
    }
    if (count == 0) {
        [self languageMessage:onlyLine >= 0 ? @"There are no problems on this line." : @"The language server reports no problems in this file."];
        return;
    }
    NSString *prompt = [NSString stringWithFormat:@"Fix these problems in %@:\n%@\nMake the smallest changes that fix them, "
                                                  @"then tell me what you changed.", relative, list];
    [self showChat];
    [_chat sendPrompt:prompt includeSelection:NO];
}

- (IBAction)fixProblemsWithClaude:(id)sender {
    [self askClaudeToFixProblemsOnLine:-1];
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

// MARK: Go back / forward

/// The caret's place now, or nothing when no file is open.
- (std::optional<gw::NavigationLocation>)currentLocation {
    Tab *tab = [self currentTab];
    if (tab == nullptr || !tab->document->path()) {
        return std::nullopt;
    }
    return gw::NavigationLocation{tab->document->path()->string(), tab->document->selection.caret};
}

/// Call just before a jump (definition, go to line, a search result...) so Go Back can return.
- (void)rememberLocationBeforeJump {
    if (_navigating) {
        return;
    }
    if (auto here = [self currentLocation]) {
        _navigation.record(*here);
    }
}

- (void)goToLocation:(const gw::NavigationLocation &)location {
    _navigating = YES;
    [self openURL:[NSURL fileURLWithPath:@(location.path.c_str())]];
    Tab *tab = [self currentTab];
    if (tab != nullptr) {
        [_editorView jumpToPosition:tab->document->buffer().clamp(location.position)];
    }
    _navigating = NO;
}

- (IBAction)goBack:(id)sender {
    auto here = [self currentLocation];
    if (!here) {
        return;
    }
    if (auto target = _navigation.back(*here)) {
        [self goToLocation:*target];
    } else {
        NSBeep();
    }
}

- (IBAction)goForward:(id)sender {
    auto here = [self currentLocation];
    if (!here) {
        return;
    }
    if (auto target = _navigation.forward(*here)) {
        [self goToLocation:*target];
    } else {
        NSBeep();
    }
}

- (void)openPath:(NSString *)path atLine:(NSInteger)line {
    [self rememberLocationBeforeJump];
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

/// The Vim mode or command in progress changed. Suggestions belong to typing, so leaving
/// insert mode closes them.
- (void)vimStatusChanged {
    [self updateStatus];
    if (!_editorView.insertsText) {
        [_suggestions hide];
        ++_suggestionToken;
    }
}

/// Vim's ":" commands that need the window: saving and closing. Returns what to show when one
/// can't be done (Vim's own wording), or nil.
- (NSString *)runVimCommand:(NSString *)command {
    NSScanner *scanner = [NSScanner scannerWithString:command];
    NSString *name = @"";
    [scanner scanCharactersFromSet:NSCharacterSet.letterCharacterSet intoString:&name];
    BOOL force = [scanner scanString:@"!" intoString:nil];
    BOOL save = [@[@"w", @"write", @"wq", @"x", @"xit", @"exit", @"wa", @"wall", @"wqa", @"wqall", @"xa", @"xall"] containsObject:name];
    BOOL quit = [@[@"q", @"quit", @"close", @"clo", @"wq", @"x", @"xit", @"exit", @"qa", @"qall", @"quitall", @"wqa", @"wqall", @"xa", @"xall"] containsObject:name];
    BOOL all = [@[@"wa", @"wall", @"qa", @"qall", @"quitall", @"wqa", @"wqall", @"xa", @"xall"] containsObject:name];
    if (!save && !quit) {
        return [NSString stringWithFormat:@"E492: Not an editor command: %@", command];
    }

    if (save) {
        if (all) {
            [self saveAllDocuments:nil];
        } else if ([self currentTab] != nullptr) {
            [self saveDocument:nil];
        }
    }
    if (!quit) {
        return nil;
    }
    // Closing takes the document away, and the editor is still in the middle of this key, so it
    // is done once the key has been fully handled.
    __weak GWMainWindowController *weakSelf = self;
    if (all || [self currentTab] == nullptr) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf.window performClose:nil];  // asks about anything still unsaved
        });
        return nil;
    }
    Tab *tab = [self currentTab];
    if (!save && tab->document->isDirty() && !force) {
        return @"E37: No write since last change (add ! to override)";
    }
    // Saving may format the file first and finish a moment later: close once it is saved.
    uint64_t identifier = tab->identifier;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf closeVimTab:identifier discarding:force attemptsLeft:15];
    });
    return nil;
}

- (void)closeVimTab:(uint64_t)identifier discarding:(BOOL)discarding attemptsLeft:(int)attempts {
    for (size_t index = 0; index < _tabs.size(); ++index) {
        if (_tabs[index]->identifier != identifier) {
            continue;
        }
        if (!_tabs[index]->document->isDirty() || discarding) {
            [self removeTabAtIndex:static_cast<NSInteger>(index)];
        } else if (attempts > 0) {
            __weak GWMainWindowController *weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [weakSelf closeVimTab:identifier discarding:discarding attemptsLeft:attempts - 1];
            });
        }
        return;
    }
}

/// What Vim's / ? n and N ask for: the find bar does the searching.
- (void)vimAction:(gw::VimAction)action {
    switch (action) {
        case gw::VimAction::Search:
        case gw::VimAction::SearchBackward:
            [self showFind:nil];
            break;
        case gw::VimAction::SearchNext:
            [_findBar findNext];
            break;
        case gw::VimAction::SearchPrevious:
            [_findBar findPrevious];
            break;
    }
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
    __weak GWMainWindowController *weakSelf = self;
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
            [weakSelf rememberLocationBeforeJump];
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
    [_language filesDidChange:paths];
    [_extensionHost filesDidChange:paths];
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
    std::string_view text = tab->document->buffer().line(line);
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

    // Run and debug.
    [self buildDebugger];
    [self addSidebarPanel:_debugPanel.view];

    // Views extensions add.
    [self addSidebarPanel:_extensionViews.sidebarView];

    // Now that they exist, they can be shown, and told about the open folder.
    _extensionViews.sidebarView.hidden = _sidebarMode != 4;
    _sourceControl.view.hidden = _sidebarMode != 1;
    _search.view.hidden = _sidebarMode != 2;
    _debugPanel.view.hidden = _sidebarMode != 3;
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
    _debugPanel.view.hidden = mode != 3;
    _extensionViews.sidebarView.hidden = mode != 4;
    [_extensionViews sidebarVisibilityChanged:mode == 4 && _root.sidebarVisible];
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
- (IBAction)showExtensionViews:(id)sender { [self revealSidebarMode:4]; }

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
        [self loadEditorConfigForTab:*tab];
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
    if (GWIsRemoteURL(folder)) {
        [self runInTerminal:GWRemoteShellCommand(folder)];  // a shell on the other machine
        return;
    }
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
                            NSForegroundColorAttributeName: GWStatusTextColor()};
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
- (void)showVirtualText:(NSString *)text
                  title:(NSString *)title
               language:(std::string)language
                    key:(std::string)key
                   diff:(BOOL)diff {
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

/// For development: run something colorful in a new terminal (see GLASSWORK_ACTIONS).
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

/// Developer check: types "X" at every cursor.
- (IBAction)debugTypeX:(id)sender {
    [self.window makeFirstResponder:_editorView];
    [_editorView insertText:@"X" replacementRange:NSMakeRange(NSNotFound, 0)];
}

/// Developer check: types a newline at every cursor.
- (IBAction)debugPressReturn:(id)sender {
    [self.window makeFirstResponder:_editorView];
    [_editorView doCommandBySelector:@selector(insertNewline:)];
}

- (IBAction)debugTerminalDemo:(id)sender {
    [self runInTerminal:@"clear; printf '\\e[1;31mbold red\\e[0m \\e[4munderline\\e[0m \\e[3mitalic\\e[0m "
                        @"\\e[38;2;255;160;0mtruecolor\\e[0m \\e[7minverse\\e[0m\\n'; ls -la /System | head -8; echo '日本語 ✓ ─│┌┐└┘╭╮'; git -C ~/Code/Glasswork status -sb | head -3"];
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

    NSString *title;
    if (hunk.newCount == 0) {
        title = [NSString stringWithFormat:@"Deleted at line %zu", hunk.newStart + 1];
    } else if (hunk.newCount == 1) {
        title = [NSString stringWithFormat:@"Line %zu", hunk.newStart + 1];
    } else {
        title = [NSString stringWithFormat:@"Lines %zu–%zu", hunk.newStart + 1, hunk.newStart + hunk.newCount];
    }
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

// MARK: - Extension views and webview panels

/// Connects the sidebar for extension views, and the editor tabs for webview panels.
- (void)setUpExtensionViews {
    __weak GWMainWindowController *weakSelf = self;
    _webviewTabViews = [NSMutableDictionary dictionary];
    _extensionViews = [[GWExtensionViews alloc] initWithService:_extensionHost];
    _extensionViews.onOpenPanel = ^(NSString *handle, NSString *title, WKWebView *webView, BOOL preserveFocus) {
        [weakSelf openWebviewTab:handle title:title webView:webView];
    };
    _extensionViews.onRetitlePanel = ^(NSString *handle, NSString *title) {
        Tab *tab = [weakSelf webviewTabWithHandle:handle];
        if (tab != nullptr) {
            tab->document->title = title.UTF8String;
            [weakSelf refresh];
        }
    };
    _extensionViews.onRevealPanel = ^(NSString *handle) {
        GWMainWindowController *strongSelf = weakSelf;
        Tab *tab = [strongSelf webviewTabWithHandle:handle];
        if (tab != nullptr) {
            [strongSelf selectTab:[strongSelf indexOfTab:tab]];
        }
    };
    _extensionViews.onClosePanel = ^(NSString *handle) {
        GWMainWindowController *strongSelf = weakSelf;
        Tab *tab = [strongSelf webviewTabWithHandle:handle];
        if (tab != nullptr) {
            [strongSelf closeTabAtIndex:[strongSelf indexOfTab:tab]];
        }
    };
    // Pages may read the project and the installed extensions unless their extension says otherwise.
    _extensionViews.webviewRoots = ^NSArray<NSString *> *{
        GWMainWindowController *strongSelf = weakSelf;
        NSMutableArray<NSString *> *roots = [NSMutableArray array];
        NSString *project = strongSelf->_fileTree.rootURL.path;
        if (project != nil) {
            [roots addObject:project];
        }
        [roots addObject:@(GWServices.shared.extensions.directory().string().c_str())];
        return roots;
    };
    _extensionViews.onRevealSidebar = ^{
        [weakSelf revealSidebarMode:4];
    };
}

- (Tab *)webviewTabWithHandle:(NSString *)handle {
    for (auto &tab : _tabs) {
        if (tab->kind == Tab::Kind::Webview && tab->webviewHandle == handle.UTF8String) {
            return tab.get();
        }
    }
    return nullptr;
}

- (NSInteger)indexOfTab:(Tab *)wanted {
    for (size_t index = 0; index < _tabs.size(); ++index) {
        if (_tabs[index].get() == wanted) {
            return static_cast<NSInteger>(index);
        }
    }
    return -1;
}

/// A webview panel an extension created becomes a tab.
- (void)openWebviewTab:(NSString *)handle title:(NSString *)title webView:(WKWebView *)webView {
    _webviewTabViews[handle] = webView;
    std::string handleText = handle.UTF8String;
    auto document = std::make_unique<gw::Document>(gw::Document::readOnlyText("", title.UTF8String));
    [self addTab:std::move(document) atIndex:-1 configure:^(Tab &tab) {
        tab.isVirtual = true;
        tab.kind = Tab::Kind::Webview;
        tab.webviewHandle = handleText;
        tab.key = "webview:" + handleText;
        tab.forcedLanguage = "plaintext";
    }];
}

/// Webview panels hear whether theirs is the tab in front.
- (void)tellExtensionsWhichWebviewIsInFront {
    Tab *front = [self currentTab];
    for (auto &tab : _tabs) {
        if (tab->kind == Tab::Kind::Webview) {
            [_extensionViews panelTab:@(tab->webviewHandle.c_str()) isFront:tab.get() == front];
        }
    }
}

// MARK: - Code intelligence

/// Creates the language service and connects it to the editor: problems, hover and completion.
- (void)setUpLanguageService {
    __weak GWMainWindowController *weakSelf = self;
    _language = [GWLanguageService new];
    _language.enabled = GWServices.shared.settings.languageServers;
    _extensionHost = [GWExtensionHostService new];
    _extensionHost.delegate = self;
    _language.extensionProvider = _extensionHost;
    [self setUpExtensionViews];
    _serverProgress = [NSMutableDictionary dictionary];
    [self setUpKeybindings];
    __weak GWExtensionHostService *weakHost = _extensionHost;
    [_language settingsDidChange:[_extensionHost allSettings]];  // what servers see from their first question
    _language.onServerMessage = ^(NSString *serverName, int type, NSString *message) {
        [weakSelf serverSaid:message type:type server:serverName];
    };
    _language.onServerLog = ^(NSString *serverName, NSString *message) {
        [weakHost appendLog:[message stringByAppendingString:@"\n"] toChannel:serverName];
    };
    _language.onServerProgress = ^(NSString *serverName, NSString *token, NSString *kind, NSString *title, NSString *message, int percentage) {
        [weakSelf serverProgress:serverName token:token kind:kind title:title message:message percentage:percentage];
    };
    _language.onServerQuestion = ^(NSString *serverName, NSString *message, NSArray<NSString *> *actions, void (^reply)(NSString *)) {
        [weakSelf serverAsked:message actions:actions server:serverName reply:reply];
    };
    _language.onApplyEdit = ^(const gw::lsp::Json &edit, void (^reply)(BOOL)) {
        reply([weakSelf applyWorkspaceEdit:edit]);
    };
    _language.onDiagnosticsChanged = ^(gw::Document *document) {
        [weakSelf diagnosticsChangedForDocument:document];
    };
    _language.onStatusChanged = ^{
        [weakSelf updateStatus];
        [weakSelf scheduleEditorStateForExtensions];  // the host may just have been given this file
    };
    _language.onInlayHintsChanged = ^(gw::Document *document) {
        GWMainWindowController *strongSelf = weakSelf;
        Tab *tab = [strongSelf currentTab];
        if (tab != nullptr && tab->document.get() == document) {
            [strongSelf->_editorView setInlayHints:[strongSelf->_language inlayHintsForDocument:document]];
        }
    };
    _language.onSemanticTokensChanged = ^(gw::Document *document) {
        GWMainWindowController *strongSelf = weakSelf;
        Tab *tab = [strongSelf currentTab];
        if (tab != nullptr && tab->document.get() == document) {
            [strongSelf->_editorView setSemanticTokens:[strongSelf->_language semanticTokensForDocument:document]];
        }
    };

    _suggestions = [GWSuggestionPopup new];
    _suggestions.onAccept = ^(GWSuggestion *suggestion) {
        [weakSelf acceptSuggestion:suggestion];
    };
    _suggestions.onSelectionChanged = ^(GWSuggestion *suggestion) {
        [weakSelf resolveSuggestionForDocumentation:suggestion];
    };

    _editorView.onBreakpointsChange = ^{
        [weakSelf breakpointsChanged];
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
        if (strongSelf->_suggestions.visible && ![strongSelf caretIsInWordStartingAt:strongSelf->_suggestionWordStart]) {
            [strongSelf->_suggestions hide];  // stale: Return must start a new line, not accept it
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
    std::string_view line = tab->document->buffer().line(caret.line);
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
    if (tab == nullptr) {
        return;
    }
    if (typed == nil) {
        // A deletion or other change (typing over a closing bracket, say): keep the list in
        // step while the caret is still in its word, or drop it.
        if (_suggestions.visible) {
            if ([self caretIsInWordStartingAt:_suggestionWordStart]) {
                [_suggestions filterWithPrefix:[self typedPrefix]];
            } else {
                [_suggestions hide];
                ++_suggestionToken;
            }
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

    // Typing a commit character (a "." or "(" after a name) accepts the highlighted item first.
    GWSuggestion *highlighted = _suggestions.selectedSuggestion;
    if (_suggestions.visible && !wordCharacter && highlighted != nil && typed.length == 1 &&
        [highlighted.commitCharacters containsString:typed]) {
        [self acceptSuggestion:highlighted afterTyping:typed];
        return;
    }

    if (_suggestions.visible && wordCharacter) {
        [_suggestions filterWithPrefix:[self typedPrefix]];
        if (_suggestionsIncomplete) {
            // The server only sent part of its list (a big project, say): ask again with the
            // longer word. The current list stays up meanwhile.
            NSUInteger token = _suggestionToken;
            __weak GWMainWindowController *weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                GWMainWindowController *strongSelf = weakSelf;
                if (strongSelf != nil && token == strongSelf->_suggestionToken && strongSelf->_suggestions.visible) {
                    [strongSelf requestSuggestionsExplicitly:NO];
                }
            });
        }
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

/// Whether the caret is still in the word that starts at `start`: on its line, not before it,
/// with nothing but word letters between. A list for a word the caret has left is stale.
- (BOOL)caretIsInWordStartingAt:(gw::Position)start {
    Tab *tab = [self currentTab];
    if (tab == nullptr) {
        return NO;
    }
    gw::Document *document = tab->document.get();
    gw::Position caret = document->selection.caret;
    if (!document->selection.empty() || caret.line != start.line || caret.column < start.column) {
        return NO;
    }
    std::string_view line = document->buffer().line(caret.line);
    if (caret.column > line.size()) {
        return NO;
    }
    for (size_t column = start.column; column < caret.column; ++column) {
        if (!gw::isWordByte(static_cast<unsigned char>(line[column]))) {
            return NO;
        }
    }
    return YES;
}

/// The caret moved: a list for a word we've left is stale.
- (void)dropSuggestionsIfCaretLeftWord {
    if (_suggestions.visible && ![self caretIsInWordStartingAt:_suggestionWordStart]) {
        [_suggestions hide];
        ++_suggestionToken;
    }
}

- (IBAction)completeCode:(id)sender {
    [self requestSuggestionsExplicitly:YES];
}

- (void)requestSuggestionsExplicitly:(BOOL)explicitly {
    Tab *tab = [self currentTab];
    if (tab == nullptr) {
        return;
    }
    gw::Document *document = tab->document.get();
    // Without a language server (a new file, a plain-text file, one still starting) the words
    // already in the file are offered instead.
    if (!document->path() || !_language.enabled || ![_language serverSupports:@"completionProvider" forDocument:document]) {
        [self showWordSuggestionsAtWordStart:[self wordStartBeforeCaret] explicitly:explicitly];
        return;
    }
    gw::Position caret = document->selection.caret;
    gw::Position wordStart = [self wordStartBeforeCaret];
    NSUInteger token = _suggestionToken;
    __weak GWMainWindowController *weakSelf = self;
    // Tell the server why it is being asked: a request by hand, a trigger character such as ".",
    // or more typing in a list it said was incomplete.
    gw::lsp::Json params = [_language positionParamsForDocument:document position:caret];
    int triggerKind = 1;  // Invoked
    std::string triggerCharacter;
    if (!explicitly && caret.column > 0) {
        std::string before = document->buffer().text({{caret.line, caret.column - 1}, caret});
        NSString *triggers = [_language completionTriggerCharactersForDocument:document];
        if (before.size() == 1 && [triggers containsString:@(before.c_str())]) {
            triggerKind = 2;  // TriggerCharacter
            triggerCharacter = before;
        } else if (_suggestions.visible && _suggestionsIncomplete) {
            triggerKind = 3;  // TriggerForIncompleteCompletions
        }
    }
    params["context"] = {{"triggerKind", triggerKind}};
    if (!triggerCharacter.empty()) {
        params["context"]["triggerCharacter"] = triggerCharacter;
    }
    [_language request:@"textDocument/completion"
                params:params
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

/// Snippets from extensions and the user's snippet files for the current file's language, as
/// completion rows. Accepting one inserts it with Tab stops, like a snippet from a language server.
- (NSArray<GWSuggestion *> *)snippetSuggestions {
    Tab *tab = [self currentTab];
    if (tab == nullptr) {
        return @[];
    }
    NSMutableArray<GWSuggestion *> *items = [NSMutableArray array];
    for (const gw::SnippetDefinition &definition : GWServices.shared.extensions.snippets().forLanguage(tab->document->languageId)) {
        GWSuggestion *item = [GWSuggestion new];
        item.label = @(definition.prefix.c_str());
        item.detail = @(definition.description.c_str());
        item.filterText = item.label;
        item.sortText = [@"9" stringByAppendingString:item.label];  // after what a language server offers
        item.kind = 15;                                              // Snippet
        item.documentation = [NSString stringWithFormat:@"```\n%s\n```", definition.body.c_str()];
        item.raw = std::make_shared<gw::lsp::Json>(gw::lsp::Json{
            {"label", definition.prefix},
            {"detail", definition.description},
            {"insertText", definition.body},
            {"insertTextFormat", 2},
            {"kind", 15},
        });
        item.resolved = YES;  // nothing to ask a server about
        [items addObject:item];
    }
    return items;
}

/// Snippet variables: the file and the clock, plus what is selected, on the clipboard and on the line.
- (gw::SnippetVariables)snippetVariablesForTab:(Tab &)tab {
    std::string path = tab.document->path() ? tab.document->path()->string() : std::string();
    std::string folder = _fileTree.rootURL.path ? std::string(_fileTree.rootURL.path.UTF8String) : std::string();
    gw::SnippetVariables variables = gw::standardSnippetVariables(path, folder);
    gw::Position caret = tab.document->selection.caret;
    if (!tab.document->selection.empty()) {
        variables["TM_SELECTED_TEXT"] = tab.document->buffer().text(tab.document->selection.range());
    } else {
        variables["TM_SELECTED_TEXT"] = std::string();
    }
    variables["TM_CURRENT_LINE"] = std::string(tab.document->buffer().line(caret.line));
    variables["TM_LINE_INDEX"] = std::to_string(caret.line);
    variables["TM_LINE_NUMBER"] = std::to_string(caret.line + 1);
    NSString *clipboard = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
    if (clipboard != nil) {
        variables["CLIPBOARD"] = clipboard.UTF8String;
    }
    const gw::LanguageConfiguration configuration = GWServices.shared.extensions.configuration(tab.document->languageId);
    variables["LINE_COMMENT"] = configuration.lineComment;
    variables["BLOCK_COMMENT_START"] = configuration.blockComment.first;
    variables["BLOCK_COMMENT_END"] = configuration.blockComment.second;
    return variables;
}

/// Text of an LSP documentation field: a plain string or MarkupContent {kind, value}.
static NSString *markupText(const gw::lsp::Json &value) {
    if (value.is_string()) {
        return @(value.get<std::string>().c_str());
    }
    if (value.is_object() && value.contains("value") && value["value"].is_string()) {
        return @(value["value"].get<std::string>().c_str());
    }
    return nil;
}

/// The characters that accept a suggestion when typed, as one string.
static NSString *commitCharactersOf(const gw::lsp::Json &item) {
    NSMutableString *characters = [NSMutableString string];
    if (item.contains("commitCharacters") && item["commitCharacters"].is_array()) {
        for (const gw::lsp::Json &character : item["commitCharacters"]) {
            if (character.is_string()) {
                [characters appendString:@(character.get<std::string>().c_str())];
            }
        }
    }
    return characters;
}

- (void)showSuggestionsFromResult:(const gw::lsp::Json &)result wordStart:(gw::Position)wordStart {
    using Json = gw::lsp::Json;
    if (!_editorView.insertsText) {
        return;  // an answer that arrived after Vim left insert mode
    }
    Json rows = result;
    _suggestionsIncomplete = result.is_object() && result.value("isIncomplete", false);
    if (result.is_object()) {
        rows = result.value("items", Json::array());
    }
    if (!rows.is_array() || rows.empty()) {
        [self showWordSuggestionsAtWordStart:wordStart explicitly:NO];
        return;  // (word suggestions bring the snippets along)
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
        std::string detail = row.value("detail", "");
        if (detail.empty() && row.contains("labelDetails") && row["labelDetails"].is_object()) {
            detail = row["labelDetails"].value("description", "");
        }
        item.detail = @(detail.c_str());
        item.filterText = @(row.value("filterText", label).c_str());
        item.sortText = @(row.value("sortText", label).c_str());
        item.kind = row.value("kind", 0);
        item.preselect = row.value("preselect", false);
        item.deprecated = row.value("deprecated", false);
        if (row.contains("tags") && row["tags"].is_array()) {
            for (const Json &tag : row["tags"]) {
                if (tag.is_number_integer() && tag.get<int>() == 1) {
                    item.deprecated = YES;  // CompletionItemTag.Deprecated
                }
            }
        }
        item.documentation = markupText(row.contains("documentation") ? row["documentation"] : Json());
        item.commitCharacters = commitCharactersOf(row);
        item.raw = std::make_shared<Json>(row);
        [items addObject:item];
        if (items.count >= 400) {
            break;
        }
    }
    [items addObjectsFromArray:[self snippetSuggestions]];
    if (items.count == 0) {
        [self showWordSuggestionsAtWordStart:wordStart explicitly:NO];
        return;
    }
    Tab *tab = [self currentTab];
    if (tab == nullptr) {
        return;
    }
    if (![self caretIsInWordStartingAt:wordStart]) {
        return;  // the answer came after the caret moved on
    }
    _suggestionWordStart = wordStart;
    [_suggestions setItems:items];
    NSRect caretRect = [_editorView screenRectForPosition:tab->document->selection.caret];
    [_suggestions showBelowScreenRect:caretRect parentWindow:self.window];
    [_suggestions filterWithPrefix:[self typedPrefix]];
}

/// Completion from the words already in the file, for when there is nothing better.
- (void)showWordSuggestionsAtWordStart:(gw::Position)wordStart explicitly:(BOOL)explicitly {
    Tab *tab = [self currentTab];
    if (tab == nullptr || !_editorView.insertsText) {
        return;
    }
    gw::Document *document = tab->document.get();
    std::string prefix = std::string([[self typedPrefix] UTF8String]);
    // Automatic word suggestions wait for three letters, so ordinary prose isn't interrupted
    // (Return would accept a suggestion); ⌃Space asks for them at any point.
    BOOL snippetsMatch = NO;
    if (!prefix.empty() && prefix.size() < 3 && !explicitly) {
        // Short prefixes don't offer words (they'd interrupt prose), but a snippet may match.
        for (GWSuggestion *snippet in [self snippetSuggestions]) {
            if (gw::fuzzyScore(prefix, snippet.filterText.UTF8String)) {
                snippetsMatch = YES;
                break;
            }
        }
    }
    if (prefix.size() < 3 && !explicitly && !snippetsMatch) {
        return;
    }
    std::vector<std::string> words = gw::wordSuggestions(document->buffer(), prefix, document->selection.caret);
    using Json = gw::lsp::Json;
    NSMutableArray<GWSuggestion *> *items = [NSMutableArray array];
    [items addObjectsFromArray:[self snippetSuggestions]];
    if (words.empty() && items.count == 0) {
        return;
    }
    for (size_t index = 0; index < words.size(); ++index) {
        GWSuggestion *item = [GWSuggestion new];
        item.label = @(words[index].c_str());
        item.detail = @"word in this file";
        item.filterText = item.label;
        item.sortText = [NSString stringWithFormat:@"%05zu", index];  // keep the most used first
        item.kind = 1;  // Text
        item.raw = std::make_shared<Json>(Json{{"label", words[index]}, {"insertText", words[index]}});
        [items addObject:item];
    }
    if (![self caretIsInWordStartingAt:wordStart]) {
        return;
    }
    _suggestionWordStart = wordStart;
    [_suggestions setItems:items];
    NSRect caretRect = [_editorView screenRectForPosition:document->selection.caret];
    [_suggestions showBelowScreenRect:caretRect parentWindow:self.window];
    [_suggestions filterWithPrefix:[self typedPrefix]];
}

/// For development: inserts a snippet at the caret the way accepting a completion does
/// (see GLASSWORK_ACTIONS), so Tab through the placeholders can be checked without a server.
- (void)debugInsertCallSnippet:(id)sender {
    GWSuggestion *suggestion = [GWSuggestion new];
    suggestion.raw = std::make_shared<gw::lsp::Json>(gw::lsp::Json{
        {"label", "call"},
        {"insertText", "call(${1:first}, ${2:second});$0"},
        {"insertTextFormat", 2},
    });
    [self acceptSuggestion:suggestion];
}

/// Fetches the documentation of the highlighted item (many servers only send it on request),
/// after a short pause so arrowing through the list doesn't send a request per row.
- (void)resolveSuggestionForDocumentation:(GWSuggestion *)suggestion {
    Tab *tab = [self currentTab];
    if (tab == nullptr || suggestion.resolved || suggestion.raw == nullptr) {
        return;
    }
    gw::Document *document = tab->document.get();
    if (![_language serverSupports:@"completionProvider.resolveProvider" forDocument:document]) {
        return;
    }
    NSUInteger token = ++_suggestionResolveToken;
    __weak GWMainWindowController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        GWMainWindowController *strongSelf = weakSelf;
        if (strongSelf == nil || token != strongSelf->_suggestionResolveToken || suggestion != strongSelf->_suggestions.selectedSuggestion) {
            return;
        }
        [strongSelf resolveSuggestion:suggestion document:document then:^{
            [strongSelf->_suggestions documentationChangedForSuggestion:suggestion];
        }];
    });
}

/// Asks the server to complete an item (documentation, details, extra edits such as an import)
/// and merges the answer into it. `then` runs either way.
- (void)resolveSuggestion:(GWSuggestion *)suggestion document:(gw::Document *)document then:(void (^)(void))then {
    if (suggestion.resolved || suggestion.raw == nullptr ||
        ![_language serverSupports:@"completionProvider.resolveProvider" forDocument:document]) {
        then();
        return;
    }
    suggestion.resolved = YES;  // one attempt only
    [_language request:@"completionItem/resolve" params:*suggestion.raw document:document requireSameVersion:NO
            completion:^(const gw::lsp::Json &result, NSString *error) {
        if (error == nil && result.is_object()) {
            auto merged = std::make_shared<gw::lsp::Json>(*suggestion.raw);
            for (const auto &[key, value] : result.items()) {
                (*merged)[key] = value;
            }
            suggestion.raw = merged;
            NSString *documentation = markupText(result.contains("documentation") ? result["documentation"] : gw::lsp::Json());
            if (documentation.length > 0) {
                suggestion.documentation = documentation;
            }
            std::string detail = result.value("detail", "");
            if (!detail.empty()) {
                suggestion.detail = @(detail.c_str());
            }
        }
        then();
    }];
}

- (void)acceptSuggestion:(GWSuggestion *)suggestion {
    [self acceptSuggestion:suggestion afterTyping:nil];
}

/// Inserts the suggestion. With `commitCharacter`, the user typed that character to accept it:
/// it is taken back out first and typed again after the suggestion goes in.
- (void)acceptSuggestion:(GWSuggestion *)suggestion afterTyping:(NSString *)commitCharacter {
    Tab *tab = [self currentTab];
    if (tab == nullptr || suggestion.raw == nullptr) {
        return;
    }
    [_suggestions recordAccepted:suggestion];
    [_suggestions hide];
    ++_suggestionToken;

    if (commitCharacter != nil) {
        gw::Position caret = tab->document->selection.caret;
        if (caret.column > 0) {
            [_editorView replaceRange:gw::Range{{caret.line, caret.column - 1}, caret} withText:""];
        }
    }

    // Servers such as TypeScript's add the import only when the item is resolved: wait for that
    // (a moment), then insert. If the user typed in the meantime the plain item goes in.
    gw::Document *document = tab->document.get();
    uint64_t versionBefore = document->version();
    __weak GWMainWindowController *weakSelf = self;
    [self resolveSuggestion:suggestion document:document then:^{
        GWMainWindowController *strongSelf = weakSelf;
        Tab *current = [strongSelf currentTab];
        if (strongSelf == nil || current == nullptr || current->document.get() != document) {
            return;
        }
        (void)versionBefore;
        [strongSelf insertSuggestion:suggestion];
        if (commitCharacter != nil) {
            [strongSelf->_editorView insertText:commitCharacter replacementRange:NSMakeRange(NSNotFound, 0)];
        }
    }];
}

- (void)insertSuggestion:(GWSuggestion *)suggestion {
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
    // A snippet ("foo(${1:a}, ${2:b})") is inserted as text; its placeholders are visited with Tab.
    bool isSnippet = item.value("insertTextFormat", 1) == 2;
    gw::ParsedSnippet snippet;
    if (isSnippet) {
        std::string_view caretLine = buffer.line(range.start.line);
        size_t indentLength = 0;
        while (indentLength < caretLine.size() && (caretLine[indentLength] == ' ' || caretLine[indentLength] == '\t')) {
            ++indentLength;
        }
        gw::SnippetVariables variables = [self snippetVariablesForTab:*tab];
        snippet = gw::parseSnippet(text, caretLine.substr(0, indentLength), &variables);
        text = snippet.text;
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

    if (isSnippet && !snippet.hasOnlyFinalStop()) {
        // Edits above the insertion (an added #include) moved it down or up by whole lines.
        gw::Position snippetStart = range.start;
        for (size_t index = 1; index < edits.size(); ++index) {
            const gw::Range &other = edits[index].first;
            if (other.start < range.start) {
                long removedLines = static_cast<long>(other.end.line) - static_cast<long>(other.start.line);
                long addedLines = std::count(edits[index].second.begin(), edits[index].second.end(), '\n');
                snippetStart.line = static_cast<size_t>(static_cast<long>(snippetStart.line) + addedLines - removedLines);
            }
        }
        tab->document->startSnippet(snippetStart, snippet);
        [_editorView selectionDidChange];
    }
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
        [self rememberLocationBeforeJump];
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
                if (![strongSelf codeActionCanRun:action document:document]) {
                    continue;
                }
                GWPaletteItem *item = [GWPaletteItem new];
                item.title = @(action.value("title", "Fix").c_str());
                bool isRefactor = action.value("kind", "").rfind("refactor", 0) == 0;
                bool isPreferred = action.value("isPreferred", false);
                item.symbol = isRefactor ? @"wand.and.stars" : (isPreferred ? @"lightbulb.fill" : @"lightbulb");
                item.symbolColor = isRefactor ? NSColor.systemPurpleColor : NSColor.systemYellowColor;
                Json actionCopy = action;
                item.run = ^{
                    [weakSelf runCodeAction:actionCopy document:document resolved:NO];
                };
                [items addObject:item];
            }
        }
        // Claude can always be asked when there is a problem on the line.
        BOOL problemOnLine = NO;
        gw::Position caretNow = document->selection.caret;
        for (const GWDiagnostic &diagnostic : [strongSelf->_language diagnosticsForDocument:document]) {
            if (diagnostic.range.start.line == caretNow.line && diagnostic.severity <= 2) {
                problemOnLine = YES;
                break;
            }
        }
        if (problemOnLine) {
            GWPaletteItem *ask = [GWPaletteItem new];
            ask.title = @"Ask Claude to fix this";
            ask.subtitle = @"Sends the problem to the chat";
            ask.symbol = @"sparkles";
            ask.symbolColor = NSColor.controlAccentColor;
            NSInteger line = static_cast<NSInteger>(caretNow.line);
            ask.run = ^{
                [weakSelf askClaudeToFixProblemsOnLine:line];
            };
            [items addObject:ask];
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

// ---- Symbols (⌘R in this file, ⌘T across the project)

/// SF Symbol and color for an LSP SymbolKind.
static void iconForSymbolKind(int kind, NSString **symbol, NSColor **color) {
    switch (kind) {
        case 5: case 11: case 26:  // class, interface, type parameter
            *symbol = @"c.square.fill";
            *color = NSColor.systemOrangeColor;
            break;
        case 23:  // struct
            *symbol = @"s.square.fill";
            *color = NSColor.systemOrangeColor;
            break;
        case 6: case 9: case 12:  // method, constructor, function
            *symbol = @"f.square.fill";
            *color = NSColor.systemPurpleColor;
            break;
        case 7: case 8:  // property, field
            *symbol = @"p.square.fill";
            *color = NSColor.systemTealColor;
            break;
        case 13: case 14: case 15: case 16: case 17: case 18: case 19: case 20: case 21:  // variables and values
            *symbol = @"v.square.fill";
            *color = NSColor.systemBlueColor;
            break;
        case 2: case 3: case 4:  // module, namespace, package
            *symbol = @"m.square.fill";
            *color = NSColor.systemIndigoColor;
            break;
        case 10: case 22:  // enum, enum member
            *symbol = @"e.square.fill";
            *color = NSColor.systemYellowColor;
            break;
        default:
            *symbol = @"circle.fill";
            *color = NSColor.tertiaryLabelColor;
            break;
    }
}

/// One symbol as a row of the picker.
struct SymbolRow {
    std::string name;
    std::string container;
    int kind = 0;
    gw::lsp::Json location;  // {uri, range} to open
};

/// Flattens a documentSymbol answer (nested DocumentSymbol trees or flat SymbolInformation).
static void collectSymbols(const gw::lsp::Json &symbols, const std::string &container, const std::string &uri,
                           std::vector<SymbolRow> &rows) {
    using Json = gw::lsp::Json;
    if (!symbols.is_array()) {
        return;
    }
    for (const Json &symbol : symbols) {
        if (!symbol.is_object()) {
            continue;
        }
        SymbolRow row;
        row.name = symbol.value("name", "");
        row.kind = symbol.value("kind", 0);
        if (row.name.empty()) {
            continue;
        }
        if (symbol.contains("selectionRange")) {
            // A DocumentSymbol: positions are in this file.
            row.container = container;
            row.location = {{"uri", uri}, {"range", symbol["selectionRange"]}};
            rows.push_back(row);
            if (symbol.contains("children")) {
                std::string childContainer = container.empty() ? row.name : container + "::" + row.name;
                collectSymbols(symbol["children"], childContainer, uri, rows);
            }
        } else if (symbol.contains("location")) {
            // A SymbolInformation.
            row.container = symbol.value("containerName", "");
            row.location = symbol["location"];
            rows.push_back(row);
        }
    }
}

/// Picker rows for symbols matching what was typed, best matches first.
- (NSArray<GWPaletteItem *> *)paletteItemsForSymbols:(std::shared_ptr<std::vector<SymbolRow>>)rows
                                               query:(NSString *)query
                                          showsFiles:(BOOL)showsFiles {
    std::string wanted = query.UTF8String ?: "";
    struct Ranked {
        int score;
        size_t index;
    };
    std::vector<Ranked> ranked;
    for (size_t index = 0; index < rows->size(); ++index) {
        if (wanted.empty()) {
            ranked.push_back({0, index});
            continue;
        }
        std::optional<int> score = gw::fuzzyScore(wanted, (*rows)[index].name);
        if (score) {
            ranked.push_back({*score, index});
        }
    }
    if (!wanted.empty()) {
        std::stable_sort(ranked.begin(), ranked.end(), [](const Ranked &a, const Ranked &b) { return a.score > b.score; });
    }
    NSMutableArray<GWPaletteItem *> *items = [NSMutableArray array];
    __weak GWMainWindowController *weakSelf = self;
    for (const Ranked &entry : ranked) {
        const SymbolRow &row = (*rows)[entry.index];
        GWPaletteItem *item = [GWPaletteItem new];
        item.title = @(row.name.c_str());
        NSString *symbol = nil;
        NSColor *color = nil;
        iconForSymbolKind(row.kind, &symbol, &color);
        item.symbol = symbol;
        item.symbolColor = color;

        NSMutableString *subtitle = [NSMutableString string];
        if (!row.container.empty()) {
            [subtitle appendString:@(row.container.c_str())];
        }
        if (showsFiles && row.location.contains("uri")) {
            std::string path = gw::lsp::pathFromURI(row.location.value("uri", ""));
            if (!path.empty()) {
                if (subtitle.length > 0) {
                    [subtitle appendString:@" · "];
                }
                // Files inside the project show their project path; others just their name.
                NSString *shown = [self projectRelativePath:@(path.c_str())];
                if ([shown hasPrefix:@"/"]) {
                    shown = shown.lastPathComponent;
                }
                [subtitle appendString:shown];
            }
        }
        if (row.location.contains("range")) {
            size_t line = row.location["range"]["start"].value("line", 0) + 1;
            if (subtitle.length > 0) {
                [subtitle appendString:@" · "];
            }
            [subtitle appendFormat:@"line %zu", line];
        }
        item.subtitle = subtitle;

        if (!wanted.empty()) {
            std::optional<gw::FuzzyMatch> match = gw::fuzzyMatch(wanted, row.name);
            NSMutableIndexSet *indexes = [NSMutableIndexSet indexSet];
            if (match) {
                for (uint32_t position : match->positions) {
                    NSString *before = [[NSString alloc] initWithBytes:row.name.data() length:position encoding:NSUTF8StringEncoding];
                    [indexes addIndex:before.length];
                }
            }
            item.matchedIndexes = indexes;
        }
        gw::lsp::Json location = row.location;
        item.run = ^{
            [weakSelf openLanguageLocation:location];
        };
        [items addObject:item];
        if (items.count >= 200) {
            break;
        }
    }
    return items;
}

/// ⌘R: jump to a function, class or other named thing in this file.
- (IBAction)goToSymbolInFile:(id)sender {
    gw::Document *document = [self documentForLanguageCommand];
    if (document == nullptr) {
        return;
    }
    if (![_language serverSupports:@"documentSymbolProvider" forDocument:document]) {
        [self languageMessage:@"The language server for this file can't list its symbols."];
        return;
    }
    gw::lsp::Json params = {{"textDocument", {{"uri", gw::lsp::fileURI(document->path()->string())}}}};
    std::string uri = gw::lsp::fileURI(document->path()->string());
    __weak GWMainWindowController *weakSelf = self;
    [_language request:@"textDocument/documentSymbol" params:params document:document requireSameVersion:NO
            completion:^(const gw::lsp::Json &result, NSString *error) {
        GWMainWindowController *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        if (error != nil) {
            [strongSelf languageMessage:error];
            return;
        }
        auto rows = std::make_shared<std::vector<SymbolRow>>();
        collectSymbols(result, "", uri, *rows);
        if (rows->empty()) {
            [strongSelf languageMessage:@"No symbols found in this file."];
            return;
        }
        [GWPalette.shared showOverWindow:strongSelf.window placeholder:@"Go to symbol in file…"
                                provider:^NSArray<GWPaletteItem *> *(NSString *query) {
            return [weakSelf paletteItemsForSymbols:rows query:query showsFiles:NO] ?: @[];
        }];
    }];
}

/// ⌘T: search every symbol in the project by name.
- (IBAction)goToSymbolInWorkspace:(id)sender {
    gw::Document *document = [self documentForLanguageCommand];
    if (document == nullptr) {
        return;
    }
    if (![_language serverSupports:@"workspaceSymbolProvider" forDocument:document]) {
        [self languageMessage:@"The language server for this file can't search the project's symbols."];
        return;
    }
    __weak GWMainWindowController *weakSelf = self;
    auto latest = std::make_shared<std::shared_ptr<std::vector<SymbolRow>>>(std::make_shared<std::vector<SymbolRow>>());
    auto requestedQuery = std::make_shared<std::string>("\x01");  // never equals a real query
    auto token = std::make_shared<NSUInteger>(0);

    [GWPalette.shared showOverWindow:self.window placeholder:@"Go to symbol in project…"
                            provider:^NSArray<GWPaletteItem *> *(NSString *query) {
        GWMainWindowController *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return @[];
        }
        std::string wanted = query.UTF8String ?: "";
        if (wanted != *requestedQuery) {
            *requestedQuery = wanted;
            NSUInteger myToken = ++(*token);
            // Ask after a short pause, so typing doesn't send a request per letter.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                GWMainWindowController *innerSelf = weakSelf;
                if (innerSelf == nil || myToken != *token || !GWPalette.shared.isShowing) {
                    return;
                }
                Tab *tab = [innerSelf currentTab];
                if (tab == nullptr) {
                    return;
                }
                gw::lsp::Json params = {{"query", wanted}};
                [innerSelf->_language request:@"workspace/symbol" params:params document:tab->document.get() requireSameVersion:NO
                                   completion:^(const gw::lsp::Json &result, NSString *error) {
                    if (error != nil || myToken != *token) {
                        return;
                    }
                    auto rows = std::make_shared<std::vector<SymbolRow>>();
                    collectSymbols(result, "", "", *rows);
                    *latest = rows;
                    [GWPalette.shared refresh];
                }];
            });
        }
        return [strongSelf paletteItemsForSymbols:*latest query:query showsFiles:YES] ?: @[];
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

/// The command a code action wants run: its `command` object, or the action itself when the
/// server answered with a bare Command. Null when there is none.
static gw::lsp::Json commandOfCodeAction(const gw::lsp::Json &action) {
    using Json = gw::lsp::Json;
    if (action.contains("command") && action["command"].is_object() && action["command"].contains("command")) {
        return action["command"];
    }
    if (action.contains("command") && action["command"].is_string()) {
        return action;  // a Command: {title, command, arguments}
    }
    return Json();
}

/// clangd's way of offering a fix: the WorkspaceEdit is the first argument of its command.
static gw::lsp::Json editInCommandArguments(const gw::lsp::Json &action) {
    using Json = gw::lsp::Json;
    Json command = commandOfCodeAction(action);
    if (command.is_object() && command.contains("arguments") && command["arguments"].is_array() &&
        !command["arguments"].empty() && command["arguments"][0].is_object()) {
        const Json &first = command["arguments"][0];
        if (first.contains("documentChanges") || first.contains("changes")) {
            return first;
        }
    }
    return Json();
}

/// Whether choosing this action will do something: it carries an edit or a command, or the
/// server can fill in the edit when asked (`codeAction/resolve`).
- (BOOL)codeActionCanRun:(const gw::lsp::Json &)action document:(gw::Document *)document {
    if (action.contains("edit") && action["edit"].is_object()) {
        return YES;
    }
    if (!commandOfCodeAction(action).is_null()) {
        return YES;
    }
    bool hasData = action.contains("data");
    return hasData && [_language serverSupports:@"codeActionProvider.resolveProvider" forDocument:document];
}

/// Carries out a code action from the Quick Fix list: applies its edit, then runs its command if
/// it has one (a refactoring the server performs itself, usually by asking us to apply edits).
/// An action with neither is first sent back to the server to be completed.
- (void)runCodeAction:(const gw::lsp::Json &)action document:(gw::Document *)document resolved:(BOOL)resolved {
    using Json = gw::lsp::Json;
    __weak GWMainWindowController *weakSelf = self;

    bool hasEdit = action.contains("edit") && action["edit"].is_object();
    Json command = commandOfCodeAction(action);
    Json legacyEdit = editInCommandArguments(action);

    if (hasEdit) {
        [self applyWorkspaceEdit:action["edit"]];
    } else if (!legacyEdit.is_null()) {
        [self applyWorkspaceEdit:legacyEdit];
        return;  // that command only carried the edit
    }

    if (!command.is_null()) {
        if (action.contains("__gwServer") && !command.contains("__gwServer")) {
            command["__gwServer"] = action["__gwServer"];
        }
        [self executeServerCommand:command document:document];
        return;
    }
    if (hasEdit) {
        return;
    }
    if (resolved) {
        [self languageMessage:@"The language server had nothing to do for that."];
        return;
    }
    _statusLeft.stringValue = @"Asking the language server…";
    Json actionCopy = action;
    [_language request:@"codeAction/resolve" params:actionCopy document:document requireSameVersion:YES
            completion:^(const Json &result, NSString *error) {
        GWMainWindowController *strongSelf = weakSelf;
        [strongSelf updateStatus];
        if (strongSelf == nil) {
            return;
        }
        if (error != nil) {
            [strongSelf languageMessage:error];
            return;
        }
        [strongSelf runCodeAction:result document:document resolved:YES];
    }];
}

/// Asks the server to run one of its own commands. Any files it wants changed arrive as
/// `workspace/applyEdit` requests, which the language service passes to applyWorkspaceEdit.
- (void)executeServerCommand:(const gw::lsp::Json &)command document:(gw::Document *)document {
    using Json = gw::lsp::Json;
    Json params = {
        {"command", command.value("command", "")},
        {"arguments", command.contains("arguments") ? command["arguments"] : Json::array()},
    };
    if (command.contains("__gwServer")) {
        params["__gwServer"] = command["__gwServer"];  // the server that offered it runs it
    }
    __weak GWMainWindowController *weakSelf = self;
    _statusLeft.stringValue = @"Running…";
    [_language request:@"workspace/executeCommand" params:params document:document requireSameVersion:NO
            completion:^(const Json &, NSString *error) {
        GWMainWindowController *strongSelf = weakSelf;
        [strongSelf updateStatus];
        if (error != nil) {
            [strongSelf languageMessage:error];
        }
    }];
}

/// Applies a WorkspaceEdit from a server: open files are edited in the editor (undoable),
/// other files are changed on disk.
- (BOOL)applyWorkspaceEdit:(const gw::lsp::Json &)edit {
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
        return NO;
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
        return NO;
    }
    _statusLeft.stringValue = [NSString stringWithFormat:@"Changed %zu place%s in %zu file%s", totalEdits, totalEdits == 1 ? "" : "s",
                               changedFiles, changedFiles == 1 ? "" : "s"];
    return YES;
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
    [self formatDocument:document then:nil];
}

/// Asks the language server to format the document, applies the answer, then runs `after`
/// (whatever the outcome, so a save is never lost to a slow or failing server).
- (void)formatDocument:(gw::Document *)document then:(void (^)(void))after {
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
            if (after == nil) {
                [strongSelf languageMessage:error];
            }
        } else {
            Tab *tab = [strongSelf currentTab];
            bool stillHere = tab != nullptr && tab->document.get() == document;
            if (stillHere && result.is_array() && !result.empty()) {
                auto edits = editsFromLsp(result, document->buffer());
                if (!edits.empty()) {
                    gw::Position caret = document->selection.caret;
                    [strongSelf applyEdits:edits toCurrentDocumentPlacingCaretAfterFirst:NO];
                    [strongSelf->_editorView jumpToPosition:caret];
                }
            }
        }
        if (after != nil) {
            after();
        }
    }];
}

// MARK: Opening and saving

- (void)openURL:(NSURL *)url {
    if (GWIsRemoteURL(url)) {
        [self openRemoteFile:url];  // (remote folders are opened by Open Remote Folder…)
        return;
    }
    NSNumber *directory = nil;
    [url getResourceValue:&directory forKey:NSURLIsDirectoryKey error:nil];
    if (directory.boolValue) {
        if (![self closeTabsBeforeSwitchingToFolder:url]) {
            return;  // the user cancelled when asked about unsaved changes
        }
        _fileTree.rootURL = url;
        [self rebuildFileIndex:url];
        [_git openFolder:url.path];
        [self startWatchingFolder:url.path];
        _chat.projectFolder = url.path;
        _search.rootFolder = url.path;
        _language.rootFolder = url.path;
        _extensionHost.rootFolder = url.path;
        [_extensionHost startIfExtensionsWantToRun];
        _terminal.projectFolder = url.path;
        [self loadBreakpointsForFolder:url.path];
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
    if (isImageExtension(url.pathExtension)) {
        [self openImageAtURL:url];
        return;
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

// MARK: Remote folders (over SSH)

/// Asks for "user@host:/path" and opens that folder on another machine in the sidebar.
- (IBAction)openRemoteFolder:(id)sender {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Open Remote Folder";
    alert.informativeText = @"Type the machine and folder, like  nate@my-server:~/code  or  my-server:/srv/app. "
                            @"This uses your SSH setup, so Tailscale SSH names work.";
    [alert addButtonWithTitle:@"Open"];
    [alert addButtonWithTitle:@"Cancel"];
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 380, 24)];
    field.stringValue = [NSUserDefaults.standardUserDefaults stringForKey:@"lastRemoteFolder"] ?: @"";
    field.placeholderString = @"user@host:/path/to/folder";
    alert.accessoryView = field;
    alert.window.initialFirstResponder = field;
    if ([alert runModal] != NSAlertFirstButtonReturn) {
        return;
    }
    NSString *typed = [field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    std::optional<gw::RemoteLocation> location = gw::parseRemoteLocation(typed.UTF8String);
    if (!location) {
        [self showErrorTitle:@"That isn't a remote folder"
                     message:@"Use the form user@host:/path (for example nate@my-server:~/code)."];
        return;
    }
    [self openRemoteLocation:@(location->destination.c_str()) path:@(location->path.c_str()) typedText:typed];
}

/// Connects (which also expands "~"), then shows the folder. The connection can take a moment,
/// so it happens off the main thread.
- (void)openRemoteLocation:(NSString *)destination path:(NSString *)path typedText:(NSString *)typed {
    __weak GWMainWindowController *weakSelf = self;
    [self hostShowStatusMessage:[NSString stringWithFormat:@"Connecting to %@…", destination] seconds:30];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *error = nil;
        NSString *absolutePath = GWResolveRemotePath(destination, path, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            GWMainWindowController *strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            [strongSelf updateStatus];
            if (absolutePath == nil) {
                [strongSelf showErrorTitle:[NSString stringWithFormat:@"Couldn't open %@", typed] message:error ?: @"Unknown error."];
                return;
            }
            [NSUserDefaults.standardUserDefaults setObject:typed forKey:@"lastRemoteFolder"];
            [strongSelf showRemoteFolder:GWRemoteURL(destination, absolutePath)];
        });
    });
}

- (void)debugOpenRemoteFolder:(NSString *)folder file:(NSString *)file {
    std::optional<gw::RemoteLocation> folderLocation = folder.length ? gw::parseRemoteLocation(folder.UTF8String) : std::nullopt;
    if (folderLocation) {
        [self showRemoteFolder:GWRemoteURL(@(folderLocation->destination.c_str()), @(folderLocation->path.c_str()))];
    }
    std::optional<gw::RemoteLocation> fileLocation = file.length ? gw::parseRemoteLocation(file.UTF8String) : std::nullopt;
    if (fileLocation) {
        [self openRemoteFile:GWRemoteURL(@(fileLocation->destination.c_str()), @(fileLocation->path.c_str()))];
    }
}

/// Puts the remote folder in the sidebar. Search, source control and language servers still look at
/// this Mac, so they are switched off for it.
- (void)showRemoteFolder:(NSURL *)folder {
    if (![self closeTabsBeforeSwitchingToFolder:folder]) {
        return;
    }
    _fileTree.rootURL = folder;
    _chat.projectFolder = nil;
    _search.rootFolder = nil;
    _language.rootFolder = nil;
    _extensionHost.rootFolder = nil;
    _terminal.projectFolder = nil;
    NSString *title = [NSString stringWithFormat:@"%@: %@", GWRemoteDestination(folder), folder.lastPathComponent];
    _sidebarTitle.stringValue = title;
    _openFolderButton.hidden = YES;
    self.window.title = title;
    [self refresh];
}

/// Downloads a remote file to a copy on this Mac and opens it. Saving sends it back.
- (void)openRemoteFile:(NSURL *)url {
    NSString *copyPath = GWLocalCopyPathForRemoteURL(url);
    for (size_t index = 0; index < _tabs.size(); ++index) {
        if (_tabs[index]->remoteURL == url.absoluteString.UTF8String) {
            [self selectTab:static_cast<NSInteger>(index)];
            return;
        }
    }
    __weak GWMainWindowController *weakSelf = self;
    [self hostShowStatusMessage:[NSString stringWithFormat:@"Downloading %@…", url.lastPathComponent] seconds:30];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *error = nil;
        NSData *data = GWReadRemoteFile(url, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            GWMainWindowController *strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            [strongSelf updateStatus];
            if (data == nil) {
                [strongSelf showErrorTitle:@"Couldn't open the file" message:error ?: @"Unknown error."];
                return;
            }
            [strongSelf finishOpeningRemoteFile:url data:data copyPath:copyPath];
        });
    });
}

- (void)finishOpeningRemoteFile:(NSURL *)url data:(NSData *)data copyPath:(NSString *)copyPath {
    NSError *writeError = nil;
    NSString *copyFolder = copyPath.stringByDeletingLastPathComponent;
    BOOL madeFolder = [NSFileManager.defaultManager createDirectoryAtPath:copyFolder withIntermediateDirectories:YES attributes:nil error:&writeError];
    if (!madeFolder || ![data writeToFile:copyPath options:NSDataWritingAtomic error:&writeError]) {
        [self showErrorTitle:@"Couldn't open the file" message:writeError.localizedDescription ?: @"Couldn't make a local copy."];
        return;
    }
    if (looksBinary(copyPath.fileSystemRepresentation)) {
        [self showErrorTitle:[NSString stringWithFormat:@"“%@” is a binary file", url.lastPathComponent]
                     message:@"Glasswork edits text files."];
        return;
    }
    std::string error;
    auto document = gw::Document::open(copyPath.fileSystemRepresentation, &error);
    if (!document) {
        [self showErrorTitle:@"Couldn't open the file" message:@(error.c_str())];
        return;
    }
    std::string remote = url.absoluteString.UTF8String;
    [self addTab:std::make_unique<gw::Document>(std::move(*document)) atIndex:-1 configure:^(Tab &tab) {
        tab.remoteURL = remote;
    }];
}

/// Sends the saved copy of a remote file back to its machine, in the background. The text is read
/// now, so edits made while it uploads are not mixed in.
- (void)uploadTabToRemote:(Tab &)tab {
    NSURL *url = [NSURL URLWithString:@(tab.remoteURL.c_str())];
    NSData *data = [NSData dataWithContentsOfFile:@(tab.document->path()->c_str())];
    if (url == nil || data == nil) {
        [self showErrorTitle:@"Couldn't upload" message:@"The saved copy could not be read."];
        return;
    }
    __weak GWMainWindowController *weakSelf = self;
    NSString *machine = GWRemoteDestination(url);
    [self hostShowStatusMessage:[NSString stringWithFormat:@"Uploading to %@…", machine] seconds:30];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *error = nil;
        BOOL uploaded = GWWriteRemoteFile(url, data, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            GWMainWindowController *strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            if (uploaded) {
                [strongSelf hostShowStatusMessage:[NSString stringWithFormat:@"Saved to %@", machine] seconds:3];
            } else {
                NSString *message = [NSString stringWithFormat:@"“%@” was saved on this Mac but not on %@:\n%@\n\nSave again once the connection works.",
                                     url.lastPathComponent, machine, error ?: @"Unknown error."];
                [strongSelf showErrorTitle:@"Couldn't upload" message:message];
            }
        });
    });
}

/// Opening a different folder starts a new workspace, so the tabs of the old one must go (the
/// tab bar would otherwise keep showing files from the previous folder). Remembers the old
/// folder's tabs first so they come back if it is opened again. Returns NO if the user cancels.
- (BOOL)closeTabsBeforeSwitchingToFolder:(NSURL *)newFolder {
    NSString *oldFolder = _fileTree.rootURL.path;
    BOOL isSameFolder = oldFolder != nil && [oldFolder isEqualToString:newFolder.path];
    if (isSameFolder || _tabs.empty()) {
        return YES;
    }
    for (auto &tab : _tabs) {
        if (tab->document->isDirty() && ![self confirmCloseDocument:*tab->document]) {
            return NO;
        }
    }
    if (oldFolder.length > 0) {
        [self saveSession];
    }
    while (!_tabs.empty()) {
        [self removeTabAtIndex:static_cast<NSInteger>(_tabs.size()) - 1];
    }
    return YES;
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
    [self prepareTabForSaving:tab];
    std::string error;
    if (!tab.document->save(&error)) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Couldn't save";
        alert.informativeText = @(error.c_str());
        [alert runModal];
        return NO;
    }
    [_language documentDidSave:tab.document.get()];
    if (!tab.remoteURL.empty()) {
        [self uploadTabToRemote:tab];
    }
    if (tab.document->path() && tab.document->path()->string() == _keybindings.userFileURL.path.UTF8String) {
        [_keybindings reload];
        [self hostShowStatusMessage:@"Keyboard shortcuts reloaded." seconds:3];
    }
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
    tab.remoteURL.clear();  // saved somewhere new: no longer tied to the other machine
    [self configureLanguageForTab:tab];  // the new name may mean a new language
    if (&tab == [self currentTab]) {
        [_editorView setDocument:tab.document.get() highlighter:tab.highlighter.get() configuration:tab.configuration];
    }
    _fileTree.rootURL = _fileTree.rootURL;  // show the new file
    [self refresh];
    return YES;
}

- (IBAction)saveDocument:(id)sender {
    Tab *tab = [self currentTab];
    if (tab == nullptr) {
        return;
    }
    gw::Document *document = tab->document.get();
    bool canFormat = GWServices.shared.settings.formatOnSave && !tab->isVirtual && document->path().has_value() &&
                     [_language serverSupports:@"documentFormattingProvider" forDocument:document];
    if (!canFormat) {
        [self saveTab:*tab];
        return;
    }
    // Format first, then save whatever the text is by then. If the server is slow, or its
    // answer is dropped because you kept typing, the save still happens after a moment.
    __weak GWMainWindowController *weakSelf = self;
    uint64_t identifier = tab->identifier;
    __block BOOL saved = NO;
    void (^saveOnce)(void) = ^{
        GWMainWindowController *strongSelf = weakSelf;
        if (saved || strongSelf == nil) {
            return;
        }
        saved = YES;
        for (auto &candidate : strongSelf->_tabs) {
            if (candidate->identifier == identifier) {
                [strongSelf saveTab:*candidate];
                break;
            }
        }
    };
    [self formatDocument:document then:saveOnce];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), saveOnce);
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

/// ⇧⌘T: brings back the tab closed most recently, at the line it was on.
- (IBAction)reopenClosedTab:(id)sender {
    while (!_recentlyClosed.empty()) {
        gw::NavigationLocation location = _recentlyClosed.back();
        _recentlyClosed.pop_back();
        NSString *path = @(location.path.c_str());
        if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
            continue;  // deleted since; try the one before
        }
        [self goToLocation:location];
        return;
    }
    NSBeep();
}

/// ⌥⌘S: saves every file that has unsaved changes.
- (IBAction)saveAllDocuments:(id)sender {
    for (auto &tab : _tabs) {
        bool canSave = tab->document->isDirty() && !tab->isVirtual && tab->document->path().has_value();
        if (canSave) {
            [self saveTab:*tab];
        }
    }
}

/// Closes every tab except the one in front. Each file with unsaved changes asks first.
- (IBAction)closeOtherTabs:(id)sender {
    if (_selected < 0) {
        return;
    }
    uint64_t keep = _tabs[static_cast<size_t>(_selected)]->identifier;
    for (NSInteger index = static_cast<NSInteger>(_tabs.size()) - 1; index >= 0; --index) {
        if (_tabs[static_cast<size_t>(index)]->identifier != keep) {
            [self closeTabAtIndex:index];
        }
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
    [_extensionViews sidebarVisibilityChanged:_sidebarMode == 4 && _root.sidebarVisible];
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
    [_extensionHost shutdown];
    if (_keyMonitor != nil) {
        [NSEvent removeMonitor:_keyMonitor];
        _keyMonitor = nil;
    }
    [_debugger stop];
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
    if (folder.length == 0 || GWIsRemoteURL(_fileTree.rootURL)) {
        return;  // (remote folders keep no session)
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
    if (!_tabs.empty() || GWIsRemoteURL(_fileTree.rootURL)) {
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
