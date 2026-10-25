#import "ExtensionViews.h"
#import "Strings.h"

#import <objc/runtime.h>

#import "FileIcons.h"

#include "Keybindings.hpp"

using Json = gw::lsp::Json;

namespace {

NSString *StringFromJson(const Json &value) {
    return value.is_string() ? StringFromUTF8(value.get<std::string>()) : nil;
}

/// VS Code's own icon set ("codicons") has no files here, so the common ones map to the nearest
/// SF Symbol and the rest become a small dot.
NSString *SymbolForCodicon(NSString *name) {
    static NSDictionary<NSString *, NSString *> *symbols;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        symbols = @{
            @"file": @"doc", @"file-text": @"doc.text", @"file-code": @"doc.text", @"file-media": @"photo",
            @"file-pdf": @"doc.richtext", @"file-binary": @"doc", @"file-zip": @"doc.zipper", @"files": @"doc.on.doc",
            @"folder": @"folder", @"folder-opened": @"folder", @"folder-active": @"folder.fill", @"root-folder": @"folder.fill",
            @"symbol-file": @"doc", @"symbol-folder": @"folder", @"symbol-namespace": @"square.stack.3d.up",
            @"symbol-class": @"cube", @"symbol-method": @"function", @"symbol-function": @"function", @"symbol-field": @"tag",
            @"symbol-property": @"wrench", @"symbol-variable": @"x.squareroot", @"symbol-constant": @"number",
            @"symbol-enum": @"list.bullet", @"symbol-interface": @"square.on.square", @"symbol-struct": @"cube.transparent",
            @"symbol-module": @"shippingbox", @"symbol-package": @"shippingbox", @"symbol-key": @"key", @"symbol-string": @"textformat",
            @"symbol-event": @"bolt", @"symbol-operator": @"plusminus", @"symbol-keyword": @"textformat.abc",
            @"circle-filled": @"circle.fill", @"circle-outline": @"circle", @"circle-large-filled": @"circle.fill",
            @"circle-large-outline": @"circle", @"dot": @"circle.fill", @"primitive-dot": @"circle.fill",
            @"check": @"checkmark", @"pass": @"checkmark.circle", @"pass-filled": @"checkmark.circle.fill",
            @"error": @"xmark.circle.fill", @"warning": @"exclamationmark.triangle.fill", @"info": @"info.circle",
            @"issues": @"exclamationmark.circle", @"bug": @"ladybug", @"debug": @"ladybug", @"close": @"xmark", @"x": @"xmark",
            @"add": @"plus", @"plus": @"plus", @"remove": @"minus", @"edit": @"pencil", @"trash": @"trash", @"refresh": @"arrow.clockwise",
            @"sync": @"arrow.triangle.2.circlepath", @"play": @"play.fill", @"debug-start": @"play.fill", @"run": @"play.fill",
            @"stop-circle": @"stop.circle", @"debug-stop": @"stop.fill", @"pause": @"pause.fill", @"history": @"clock.arrow.circlepath",
            @"clock": @"clock", @"watch": @"clock", @"search": @"magnifyingglass", @"filter": @"line.3.horizontal.decrease",
            @"gear": @"gearshape", @"settings-gear": @"gearshape", @"settings": @"slider.horizontal.3", @"tools": @"wrench.and.screwdriver",
            @"git-branch": @"arrow.triangle.branch", @"git-commit": @"circle.dotted", @"git-merge": @"arrow.triangle.merge",
            @"git-pull-request": @"arrow.triangle.pull", @"repo": @"book.closed", @"repo-forked": @"arrow.triangle.branch",
            @"tag": @"tag", @"star": @"star", @"star-full": @"star.fill", @"heart": @"heart", @"bookmark": @"bookmark",
            @"link": @"link", @"globe": @"globe", @"cloud": @"cloud", @"server": @"server.rack", @"database": @"cylinder",
            @"terminal": @"terminal", @"code": @"chevron.left.forwardslash.chevron.right", @"package": @"shippingbox",
            @"extensions": @"puzzlepiece.extension", @"lock": @"lock", @"unlock": @"lock.open", @"key": @"key",
            @"person": @"person", @"account": @"person.crop.circle", @"mail": @"envelope", @"comment": @"bubble.left",
            @"bell": @"bell", @"lightbulb": @"lightbulb", @"rocket": @"paperplane", @"zap": @"bolt.fill", @"flame": @"flame",
            @"home": @"house", @"list-unordered": @"list.bullet", @"list-tree": @"list.bullet.indent", @"graph": @"chart.xyaxis.line",
            @"beaker": @"testtube.2", @"book": @"book", @"notebook": @"book", @"table": @"tablecells", @"json": @"curlybraces",
            @"symbol-misc": @"circle.fill", @"chevron-right": @"chevron.right", @"chevron-down": @"chevron.down",
            @"arrow-right": @"arrow.right", @"arrow-up": @"arrow.up", @"arrow-down": @"arrow.down", @"eye": @"eye",
            @"copy": @"doc.on.doc", @"save": @"square.and.arrow.down", @"cloud-download": @"icloud.and.arrow.down",
            @"cloud-upload": @"icloud.and.arrow.up", @"loading": @"arrow.triangle.2.circlepath", @"question": @"questionmark.circle",
        };
    });
    return symbols[name] ?: @"circle.fill";
}

/// True when `text` contains any of the words.
BOOL ContainsAnyWord(NSString *text, NSArray<NSString *> *words) {
    for (NSString *word in words) {
        if ([text containsString:word]) {
            return YES;
        }
    }
    return NO;
}

/// A theme color id from an extension ("charts.red", "testing.iconPassed") as a color, going by
/// the color words in its name. Nil when the name doesn't hint at a color.
NSColor *ColorForThemeId(NSString *identifier) {
    NSString *lower = identifier.lowercaseString;
    if (ContainsAnyWord(lower, @[@"red", @"error", @"failed"])) {
        return NSColor.systemRedColor;
    }
    if (ContainsAnyWord(lower, @[@"green", @"passed", @"added"])) {
        return NSColor.systemGreenColor;
    }
    if (ContainsAnyWord(lower, @[@"yellow", @"warning", @"modified"])) {
        return NSColor.systemYellowColor;
    }
    if (ContainsAnyWord(lower, @[@"orange"])) {
        return NSColor.systemOrangeColor;
    }
    if (ContainsAnyWord(lower, @[@"blue", @"info"])) {
        return NSColor.systemBlueColor;
    }
    if (ContainsAnyWord(lower, @[@"purple", @"magenta"])) {
        return NSColor.systemPurpleColor;
    }
    return nil;
}

/// A `command:` link's command and arguments: `command:ext.run?%5B1%2C%22two%22%5D`.
void ParseCommandLink(NSString *link, NSString *__autoreleasing *command, NSArray *__autoreleasing *arguments) {
    NSString *body = [link substringFromIndex:MIN((NSUInteger)8, link.length)];  // after "command:"
    NSRange question = [body rangeOfString:@"?"];
    *command = question.location == NSNotFound ? body : [body substringToIndex:question.location];
    *arguments = nil;
    if (question.location == NSNotFound) {
        return;
    }
    NSString *encoded = [body substringFromIndex:question.location + 1];
    NSData *data = [encoded.stringByRemovingPercentEncoding dataUsingEncoding:NSUTF8StringEncoding];
    id parsed = data != nil ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if ([parsed isKindOfClass:NSArray.class]) {
        *arguments = parsed;
    } else if (parsed != nil) {
        *arguments = @[parsed];
    }
}

}  // namespace

// MARK: - Tree nodes

@interface GWViewNode : NSObject
@property (nonatomic, copy) NSString *handle;
@property (nonatomic, copy) NSString *label;
@property (nonatomic, copy, nullable) NSString *descriptionText;
@property (nonatomic, copy, nullable) NSString *tooltip;
@property (nonatomic, copy, nullable) NSString *iconTheme;
@property (nonatomic, copy, nullable) NSString *iconColor;
@property (nonatomic, copy, nullable) NSString *iconPath;
@property (nonatomic, copy, nullable) NSString *resourcePath;
@property (nonatomic, copy, nullable) NSString *contextValue;
@property (nonatomic) BOOL collapsible;
@property (nonatomic) BOOL startsExpanded;
@property (nonatomic) BOOL hasCommand;
@property (nonatomic, weak, nullable) GWViewNode *parent;
/// Nil until the children were asked for.
@property (nonatomic, copy, nullable) NSArray<GWViewNode *> *children;
/// The labels from the top down, used to keep a node open across refreshes.
@property (nonatomic, copy) NSString *key;
@end

@implementation GWViewNode
@end

static GWViewNode *NodeFromJson(const Json &json, GWViewNode *parent) {
    GWViewNode *node = [GWViewNode new];
    node.handle = StringFromJson(json["handle"]) ?: @"";
    node.label = StringFromJson(json["label"]) ?: @"";
    node.descriptionText = StringFromJson(json["description"]);
    node.tooltip = StringFromJson(json["tooltip"]);
    node.resourcePath = StringFromJson(json["resourcePath"]);
    node.contextValue = StringFromJson(json["contextValue"]);
    if (json.contains("icon") && json["icon"].is_object()) {
        node.iconTheme = StringFromJson(json["icon"]["theme"]);
        node.iconColor = StringFromJson(json["icon"]["color"]);
        node.iconPath = StringFromJson(json["icon"]["path"]);
    }
    node.collapsible = json.value("collapsible", false);
    node.startsExpanded = json.value("expanded", false);
    node.hasCommand = json.value("hasCommand", false);
    node.parent = parent;
    node.key = parent != nil ? [NSString stringWithFormat:@"%@/%@", parent.key, node.label] : node.label;
    return node;
}

// MARK: - The outline

/// An outline view that asks for a context menu per row.
@interface GWViewOutline : NSOutlineView
@property (nonatomic, copy, nullable) NSMenu *(^menuForRow)(NSInteger row);
@end

@implementation GWViewOutline

- (NSMenu *)menuForEvent:(NSEvent *)event {
    NSInteger row = [self rowAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    if (row < 0 || self.menuForRow == nil) {
        return nil;
    }
    [self selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
    return self.menuForRow(row);
}

@end

// MARK: - Section header

@interface GWSectionHeader : NSView
@property (nonatomic, copy) NSString *title;
@property (nonatomic) BOOL expanded;
@property (nonatomic, copy, nullable) void (^onToggle)(void);
/// Builds the "…" menu; nil hides the button.
@property (nonatomic, copy, nullable) NSMenu *(^actionsMenu)(void);
- (void)setDetail:(nullable NSString *)detail;
@end

@implementation GWSectionHeader {
    NSImageView *_chevron;
    NSTextField *_titleField;
    NSTextField *_detailField;
    NSButton *_actions;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        NSImage *chevronImage = [NSImage imageWithSystemSymbolName:@"chevron.right" accessibilityDescription:nil];
        _chevron = [NSImageView imageViewWithImage:chevronImage];
        _chevron.contentTintColor = NSColor.secondaryLabelColor;
        _chevron.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:9 weight:NSFontWeightBold];
        _titleField = [NSTextField labelWithString:@""];
        _titleField.font = [NSFont systemFontOfSize:11 weight:NSFontWeightBold];
        _titleField.textColor = NSColor.secondaryLabelColor;
        _titleField.lineBreakMode = NSLineBreakByTruncatingTail;
        _detailField = [NSTextField labelWithString:@""];
        _detailField.font = [NSFont systemFontOfSize:11];
        _detailField.textColor = NSColor.tertiaryLabelColor;
        _detailField.lineBreakMode = NSLineBreakByTruncatingTail;
        [_detailField setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                               forOrientation:NSLayoutConstraintOrientationHorizontal];
        _actions = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"ellipsis" accessibilityDescription:@"Actions"]
                                      target:self action:@selector(showActions:)];
        _actions.bordered = NO;
        _actions.contentTintColor = NSColor.secondaryLabelColor;
        _actions.hidden = YES;
        for (NSView *view in @[_chevron, _titleField, _detailField, _actions]) {
            view.translatesAutoresizingMaskIntoConstraints = NO;
            [self addSubview:view];
        }
        [NSLayoutConstraint activateConstraints:@[
            [self.heightAnchor constraintEqualToConstant:26],
            [_chevron.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:10],
            [_chevron.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_chevron.widthAnchor constraintEqualToConstant:12],
            [_titleField.leadingAnchor constraintEqualToAnchor:_chevron.trailingAnchor constant:4],
            [_titleField.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_detailField.leadingAnchor constraintEqualToAnchor:_titleField.trailingAnchor constant:6],
            [_detailField.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_detailField.trailingAnchor constraintLessThanOrEqualToAnchor:_actions.leadingAnchor constant:-4],
            [_actions.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8],
            [_actions.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_actions.widthAnchor constraintEqualToConstant:22],
        ]];
        NSClickGestureRecognizer *click = [[NSClickGestureRecognizer alloc] initWithTarget:self
                                                                                    action:@selector(clicked:)];
        [self addGestureRecognizer:click];
    }
    return self;
}

- (void)setTitle:(NSString *)title {
    _title = [title copy];
    _titleField.stringValue = title.uppercaseString;
}

- (void)setDetail:(NSString *)detail {
    _detailField.stringValue = detail ?: @"";
}

- (void)setExpanded:(BOOL)expanded {
    _expanded = expanded;
    NSString *name = expanded ? @"chevron.down" : @"chevron.right";
    _chevron.image = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
}

- (void)setActionsMenu:(NSMenu *(^)(void))actionsMenu {
    _actionsMenu = [actionsMenu copy];
    _actions.hidden = actionsMenu == nil;
}

- (void)clicked:(NSClickGestureRecognizer *)gesture {
    if (self.onToggle) {
        self.onToggle();
    }
}

- (void)showActions:(NSButton *)sender {
    NSMenu *menu = self.actionsMenu ? self.actionsMenu() : nil;
    if (menu.numberOfItems > 0) {
        [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSHeight(sender.bounds) + 2) inView:sender];
    }
}

@end

// MARK: - Sections

@class GWWebviewSection;

/// What a section needs from the object that owns it.
@protocol GWViewSectionOwner <NSObject>
@property (nonatomic, readonly) GWExtensionHostService *service;
- (void)sectionNeedsLayout;
/// A webview section was opened: ask the extension for its page.
- (void)resolveWebviewForSection:(GWWebviewSection *)section;
@end

@interface GWViewSection : NSObject
@property (nonatomic, readonly) GWContributedView *contributed;
@property (nonatomic, readonly) NSStackView *view;
@property (nonatomic, readonly) BOOL expanded;
- (instancetype)initWithView:(GWContributedView *)contributed owner:(id<GWViewSectionOwner>)owner;
- (void)setExpanded:(BOOL)expanded;
/// The extension registered (or re-registered) the view.
- (void)didRegister;
- (void)didUnregister;
- (void)dataChanged;
- (void)stateChangedTitle:(nullable NSString *)title
              description:(nullable NSString *)description
                  message:(nullable NSString *)message;
- (void)reset;
- (void)setPanelVisible:(BOOL)visible;
- (void)revealHandle:(NSString *)handle;
@end

@interface GWTreeSection : GWViewSection <NSOutlineViewDataSource, NSOutlineViewDelegate>
@end

@interface GWWebviewSection : GWViewSection
@property (nonatomic, readonly, nullable) GWWebviewController *controller;
/// The host resolved the view: show its page.
- (void)attachController:(GWWebviewController *)controller;
@property (nonatomic) BOOL resolving;
@end

@implementation GWViewSection {
@protected
    __weak id<GWViewSectionOwner> _owner;
    GWSectionHeader *_header;
    NSView *_body;
    BOOL _panelVisible;
}

- (instancetype)initWithView:(GWContributedView *)contributed owner:(id<GWViewSectionOwner>)owner {
    if ((self = [super init])) {
        _contributed = contributed;
        _owner = owner;
        _header = [[GWSectionHeader alloc] initWithFrame:NSZeroRect];
        _header.title = contributed.name;
        __weak GWViewSection *weakSelf = self;
        _header.onToggle = ^{
            GWViewSection *strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            [strongSelf setExpanded:!strongSelf->_expanded];
        };
        _view = [NSStackView stackViewWithViews:@[_header]];
        _view.orientation = NSUserInterfaceLayoutOrientationVertical;
        _view.spacing = 0;
        _view.alignment = NSLayoutAttributeLeading;
        _view.translatesAutoresizingMaskIntoConstraints = NO;
        [_header.widthAnchor constraintEqualToAnchor:_view.widthAnchor].active = YES;
    }
    return self;
}

- (void)installBody:(NSView *)body {
    _body = body;
    body.translatesAutoresizingMaskIntoConstraints = NO;
    [_view addArrangedSubview:body];
    [body.widthAnchor constraintEqualToAnchor:_view.widthAnchor].active = YES;
    body.hidden = !_expanded;
}

- (void)setExpanded:(BOOL)expanded {
    _expanded = expanded;
    _header.expanded = expanded;
    _body.hidden = !expanded;
    [_owner sectionNeedsLayout];
    [self expansionChanged];
}

- (void)expansionChanged {}
- (void)didRegister {}
- (void)didUnregister {}
- (void)dataChanged {}
- (void)stateChangedTitle:(NSString *)title description:(NSString *)description message:(NSString *)message {}
- (void)reset {}
- (void)setPanelVisible:(BOOL)visible { _panelVisible = visible; }
- (void)revealHandle:(NSString *)handle {}

@end

// ---- Tree section

@implementation GWTreeSection {
    GWViewOutline *_outline;
    NSTextField *_messageField;
    NSLayoutConstraint *_outlineHeight;
    NSArray<GWViewNode *> *_roots;
    NSMutableSet<NSString *> *_openKeys;
    NSMutableSet<NSString *> *_seenKeys;
    BOOL _activated;
    BOOL _loadedOnce;
    NSString *_extensionMessage;
    NSInteger _generation;  // bumps on every reload so late answers from an older one are dropped
    BOOL _sentVisible;
}

- (instancetype)initWithView:(GWContributedView *)contributed owner:(id<GWViewSectionOwner>)owner {
    if ((self = [super initWithView:contributed owner:owner])) {
        _openKeys = [NSMutableSet set];
        _seenKeys = [NSMutableSet set];

        _outline = [GWViewOutline new];
        _outline.headerView = nil;
        _outline.backgroundColor = NSColor.clearColor;
        _outline.rowHeight = 22;
        _outline.indentationPerLevel = 14;
        _outline.style = NSTableViewStyleSourceList;
        _outline.selectionHighlightStyle = NSTableViewSelectionHighlightStyleRegular;
        _outline.autoresizesOutlineColumn = NO;
        NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"node"];
        column.resizingMask = NSTableColumnAutoresizingMask;
        [_outline addTableColumn:column];
        _outline.outlineTableColumn = column;
        _outline.dataSource = self;
        _outline.delegate = self;
        _outline.target = self;
        _outline.action = @selector(rowClicked:);
        __weak GWTreeSection *weakSelf = self;
        _outline.menuForRow = ^NSMenu *(NSInteger row) {
            return [weakSelf contextMenuForRow:row];
        };

        _messageField = [NSTextField wrappingLabelWithString:@""];
        _messageField.font = [NSFont systemFontOfSize:12];
        _messageField.textColor = NSColor.secondaryLabelColor;
        _messageField.hidden = YES;

        NSStackView *body = [NSStackView stackViewWithViews:@[_messageField, _outline]];
        body.orientation = NSUserInterfaceLayoutOrientationVertical;
        body.alignment = NSLayoutAttributeLeading;
        body.spacing = 2;
        body.edgeInsets = NSEdgeInsetsMake(0, 10, 6, 6);
        _outline.translatesAutoresizingMaskIntoConstraints = NO;
        _messageField.translatesAutoresizingMaskIntoConstraints = NO;
        [_outline.widthAnchor constraintEqualToAnchor:body.widthAnchor constant:-16].active = YES;
        [_messageField.widthAnchor constraintEqualToAnchor:body.widthAnchor constant:-26].active = YES;
        _outlineHeight = [_outline.heightAnchor constraintEqualToConstant:0];
        _outlineHeight.active = YES;
        [self installBody:body];

        _header.actionsMenu = ^NSMenu *{
            return [weakSelf titleMenu];
        };
    }
    return self;
}

// MARK: Loading

- (GWExtensionHostService *)service {
    return _owner.service;
}

/// The start of every message about this view: `{"id": <view id>}`, plus the node's handle if given.
- (Json)messageForHandle:(nullable NSString *)handle {
    Json message = {{"id", self.contributed.identifier.UTF8String}};
    if (handle != nil) {
        message["handle"] = handle.UTF8String;
    }
    return message;
}

/// Nothing is asked of an extension until its view can actually be seen.
- (void)loadIfShownAndNeeded {
    if (_panelVisible && self.expanded && !_loadedOnce) {
        [self loadRoots];
    }
}

- (void)expansionChanged {
    [self loadIfShownAndNeeded];
    [self sendVisibility];
}

- (void)setPanelVisible:(BOOL)visible {
    [super setPanelVisible:visible];
    [self loadIfShownAndNeeded];
    [self sendVisibility];
}

- (void)sendVisibility {
    BOOL visible = _panelVisible && self.expanded;
    if (visible != _sentVisible) {
        _sentVisible = visible;
        Json message = [self messageForHandle:nil];
        message["visible"] = visible == YES;
        [self.service sendViewNotification:@"tree/visibility" params:message];
    }
}

- (void)didRegister {
    if (_panelVisible && self.expanded) {
        [self loadRoots];
    }
}

- (void)didUnregister {
    _roots = nil;
    _loadedOnce = NO;
    [self refreshDisplay];
}

- (void)dataChanged {
    if (_panelVisible && self.expanded) {
        [self loadRoots];
    }
}

- (void)reset {
    _activated = NO;
    _loadedOnce = NO;
    _sentVisible = NO;
    ++_generation;
    _roots = nil;
    [self refreshDisplay];
}

- (void)stateChangedTitle:(NSString *)title description:(NSString *)description message:(NSString *)message {
    if (title != nil) {
        _header.title = title;
    }
    [_header setDetail:description];
    _extensionMessage = message;
    [self refreshDisplay];
}

/// Asks the host for the top level, waking the extension first if it hasn't started.
- (void)loadRoots {
    _loadedOnce = YES;
    NSInteger generation = ++_generation;
    __weak GWTreeSection *weakSelf = self;
    void (^ask)(void) = ^{
        [weakSelf requestChildrenOf:nil generation:generation attempt:0];
    };
    if (_activated) {
        ask();
        return;
    }
    [self.service activateView:self.contributed.identifier completion:^(BOOL ok) {
        GWTreeSection *strongSelf = weakSelf;
        if (strongSelf == nil || generation != strongSelf->_generation) {
            return;
        }
        if (!ok) {
            strongSelf->_loadedOnce = NO;
            strongSelf->_extensionMessage = @"The extension host isn't running.";
            [strongSelf refreshDisplay];
            return;
        }
        strongSelf->_activated = YES;
        ask();
    }];
}

/// Children of a node (nil: the top level). The extension may register its provider a moment
/// after it activates, so an unknown view is asked about a few more times.
- (void)requestChildrenOf:(GWViewNode *)parent generation:(NSInteger)generation attempt:(int)attempt {
    Json params = [self messageForHandle:parent.handle];
    __weak GWTreeSection *weakSelf = self;
    [self.service sendViewRequest:@"tree/children" params:params completion:^(const Json &result, NSString *error) {
        GWTreeSection *strongSelf = weakSelf;
        if (strongSelf == nil || generation != strongSelf->_generation) {
            return;
        }
        if (error == nil && result.value("missing", false) && attempt < 8) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [weakSelf requestChildrenOf:parent generation:generation attempt:attempt + 1];
            });
            return;
        }
        NSMutableArray<GWViewNode *> *nodes = [NSMutableArray array];
        if (error == nil && result.contains("nodes") && result["nodes"].is_array()) {
            for (const Json &item : result["nodes"]) {
                [nodes addObject:NodeFromJson(item, parent)];
            }
        }
        [strongSelf receivedChildren:nodes forParent:parent];
    }];
}

- (void)receivedChildren:(NSArray<GWViewNode *> *)nodes forParent:(GWViewNode *)parent {
    for (GWViewNode *node in nodes) {
        // A node the extension shows open starts open, once; after that the user decides.
        if (![_seenKeys containsObject:node.key]) {
            [_seenKeys addObject:node.key];
            if (node.startsExpanded && node.collapsible) {
                [_openKeys addObject:node.key];
            }
        }
    }
    if (parent == nil) {
        _roots = nodes;
        [_outline reloadData];
    } else {
        parent.children = nodes;
        [_outline reloadItem:parent reloadChildren:YES];
    }
    [self reopenOpenNodesAmong:nodes];
    [self refreshDisplay];
}

/// After new data arrived, opens the nodes that were open before.
- (void)reopenOpenNodesAmong:(NSArray<GWViewNode *> *)nodes {
    for (GWViewNode *node in nodes) {
        if (node.collapsible && [_openKeys containsObject:node.key] && ![_outline isItemExpanded:node]) {
            [_outline expandItem:node];  // asks for its children through outlineViewItemWillExpand
        }
    }
}

/// Resizes the section to its rows (the sidebar scrolls as a whole) and shows a message if it has one.
- (void)refreshDisplay {
    NSString *message = _extensionMessage.length > 0 ? _extensionMessage : nil;
    if (message == nil && _loadedOnce && _roots != nil && _roots.count == 0) {
        message = @"Nothing to show.";
    }
    _messageField.stringValue = message ?: @"";
    _messageField.hidden = message == nil;
    CGFloat rows = (CGFloat)_outline.numberOfRows;
    _outlineHeight.constant = rows * (_outline.rowHeight + _outline.intercellSpacing.height);
    [_owner sectionNeedsLayout];
}

// MARK: Data source

- (NSInteger)outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(GWViewNode *)item {
    return item == nil ? (NSInteger)_roots.count : (NSInteger)item.children.count;
}

- (id)outlineView:(NSOutlineView *)outlineView child:(NSInteger)index ofItem:(GWViewNode *)item {
    return item == nil ? _roots[(NSUInteger)index] : item.children[(NSUInteger)index];
}

- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(GWViewNode *)item {
    return item.collapsible;
}

// MARK: Delegate

- (NSView *)outlineView:(NSOutlineView *)outlineView
     viewForTableColumn:(NSTableColumn *)column
                   item:(GWViewNode *)node {
    NSTableCellView *cell = [outlineView makeViewWithIdentifier:@"node" owner:self];
    if (cell == nil) {
        cell = [NSTableCellView new];
        cell.identifier = @"node";
        NSImageView *icon = [NSImageView new];
        icon.imageScaling = NSImageScaleProportionallyUpOrDown;
        NSTextField *label = [NSTextField labelWithString:@""];
        label.font = [NSFont systemFontOfSize:12.5];
        label.lineBreakMode = NSLineBreakByTruncatingTail;
        NSTextField *detail = [NSTextField labelWithString:@""];
        detail.font = [NSFont systemFontOfSize:11.5];
        detail.textColor = NSColor.secondaryLabelColor;
        detail.lineBreakMode = NSLineBreakByTruncatingTail;
        // When the sidebar is narrow, the description gives way before the name does.
        [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultHigh
                                        forOrientation:NSLayoutConstraintOrientationHorizontal];
        [detail setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                         forOrientation:NSLayoutConstraintOrientationHorizontal];
        for (NSView *view in @[icon, label, detail]) {
            view.translatesAutoresizingMaskIntoConstraints = NO;
            [cell addSubview:view];
        }
        cell.imageView = icon;
        cell.textField = label;
        [NSLayoutConstraint activateConstraints:@[
            [icon.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:2],
            [icon.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [icon.widthAnchor constraintEqualToConstant:16],
            [icon.heightAnchor constraintEqualToConstant:16],
            [label.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:6],
            [label.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [detail.leadingAnchor constraintEqualToAnchor:label.trailingAnchor constant:6],
            [detail.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [detail.trailingAnchor constraintLessThanOrEqualToAnchor:cell.trailingAnchor constant:-4],
        ]];
        objc_setAssociatedObject(cell, "detail", detail, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    cell.textField.stringValue = node.label;
    NSTextField *detail = objc_getAssociatedObject(cell, "detail");
    detail.stringValue = node.descriptionText ?: @"";
    cell.imageView.image = [self iconForNode:node];
    cell.imageView.contentTintColor = [self tintForNode:node];
    cell.toolTip = node.tooltip ?: [self fallbackTooltipForNode:node];
    return cell;
}

/// With no tooltip from the extension, the row's own text (it may be cut off by a narrow sidebar).
- (NSString *)fallbackTooltipForNode:(GWViewNode *)node {
    if (node.descriptionText.length == 0) {
        return node.label;
    }
    return [NSString stringWithFormat:@"%@ %@", node.label, node.descriptionText];
}

- (NSImage *)iconForNode:(GWViewNode *)node {
    if (node.iconPath != nil) {
        NSImage *image = [[NSImage alloc] initWithContentsOfFile:node.iconPath];
        if (image != nil) {
            return image;
        }
    }
    if (node.iconTheme != nil) {
        NSImage *symbol = [NSImage imageWithSystemSymbolName:SymbolForCodicon(node.iconTheme) accessibilityDescription:nil];
        NSImageSymbolConfiguration *size = [NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightRegular];
        return [symbol imageWithSymbolConfiguration:size];
    }
    if (node.resourcePath != nil) {
        BOOL directory = node.collapsible;
        return GWFileIconImage(node.resourcePath.lastPathComponent, directory, NO, 16);
    }
    NSImage *dot = [NSImage imageWithSystemSymbolName:@"circle.fill" accessibilityDescription:nil];
    NSImageSymbolConfiguration *tiny = [NSImageSymbolConfiguration configurationWithPointSize:4 weight:NSFontWeightRegular];
    return [dot imageWithSymbolConfiguration:tiny];
}

- (NSColor *)tintForNode:(GWViewNode *)node {
    if (node.iconPath != nil || (node.iconTheme == nil && node.resourcePath != nil)) {
        return nil;  // real pictures keep their own colors
    }
    NSColor *themed = nil;
    if (node.iconColor != nil) {
        themed = ColorForThemeId(node.iconColor);
    }
    if (themed == nil) {
        return NSColor.secondaryLabelColor;
    }
    return themed;
}

- (void)outlineViewItemWillExpand:(NSNotification *)notification {
    GWViewNode *node = notification.userInfo[@"NSObject"];
    if (node.children == nil) {
        [self requestChildrenOf:node generation:_generation attempt:0];
    }
}

- (void)outlineViewItemDidExpand:(NSNotification *)notification {
    GWViewNode *node = notification.userInfo[@"NSObject"];
    [_openKeys addObject:node.key];
    [self.service sendViewNotification:@"tree/expand" params:[self messageForHandle:node.handle]];
    if (node.children != nil) {
        [self reopenOpenNodesAmong:node.children];
    }
    [self refreshDisplay];
}

- (void)outlineViewItemDidCollapse:(NSNotification *)notification {
    GWViewNode *node = notification.userInfo[@"NSObject"];
    [_openKeys removeObject:node.key];
    [self.service sendViewNotification:@"tree/collapse" params:[self messageForHandle:node.handle]];
    [self refreshDisplay];
}

- (void)outlineViewSelectionDidChange:(NSNotification *)notification {
    __block Json handles = Json::array();
    [_outline.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop) {
        GWViewNode *node = [self->_outline itemAtRow:(NSInteger)row];
        if (node != nil) {
            handles.push_back(node.handle.UTF8String);
        }
    }];
    Json message = [self messageForHandle:nil];
    message["handles"] = handles;
    [self.service sendViewNotification:@"tree/select" params:message];
}

/// A click runs the node's command; a node with children also opens or closes.
- (void)rowClicked:(id)sender {
    NSInteger row = _outline.clickedRow;
    GWViewNode *node = row >= 0 ? [_outline itemAtRow:row] : nil;
    if (node == nil) {
        return;
    }
    if (node.hasCommand) {
        [self.service sendViewRequest:@"tree/click" params:[self messageForHandle:node.handle]
                           completion:^(const Json &, NSString *) {}];
    }
    if (node.collapsible) {
        if ([_outline isItemExpanded:node]) {
            [_outline collapseItem:node];
        } else {
            [_outline expandItem:node];
        }
    }
}

- (void)revealHandle:(NSString *)handle {
    NSInteger count = _outline.numberOfRows;
    for (NSInteger row = 0; row < count; ++row) {
        GWViewNode *node = [_outline itemAtRow:row];
        if ([node.handle isEqualToString:handle]) {
            [_outline selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
            [_outline scrollRowToVisible:row];
            return;
        }
    }
}

// MARK: Menus

/// Menu entries from the manifest whose `when` clause holds for this view (and node).
- (NSMenu *)menuFromEntries:(const Json &)entries node:(GWViewNode *)node {
    std::map<std::string, std::string> context = {{"view", self.contributed.identifier.UTF8String}};
    if (node != nil) {
        context["viewItem"] = (node.contextValue ?: @"").UTF8String;
        context["viewItem.collapsible"] = node.collapsible ? "true" : "false";
    }
    NSMenu *menu = [NSMenu new];
    menu.autoenablesItems = NO;
    NSString *lastGroup = nil;
    for (const Json &entry : entries) {
        std::string when = entry.value("when", "");
        if (!when.empty() && !gw::evaluateWhenClause(when, context)) {
            continue;
        }
        NSString *command = StringFromUTF8(entry.value("command", ""));
        NSString *title = [self.service titleForCommand:command];
        if (title == nil) {
            continue;
        }
        NSString *group = StringFromUTF8(entry.value("group", ""));
        group = [group componentsSeparatedByString:@"@"].firstObject;
        if (lastGroup != nil && ![lastGroup isEqualToString:group] && menu.numberOfItems > 0) {
            [menu addItem:NSMenuItem.separatorItem];
        }
        lastGroup = group;
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:@selector(runMenuCommand:) keyEquivalent:@""];
        item.target = self;
        item.enabled = YES;
        item.representedObject = @{@"command": command, @"handle": node.handle ?: @""};
        [menu addItem:item];
    }
    return menu;
}

- (NSMenu *)contextMenuForRow:(NSInteger)row {
    GWViewNode *node = [_outline itemAtRow:row];
    Json entries = [self.service contributedViewMenus].value("view/item/context", Json::array());
    NSMenu *menu = [self menuFromEntries:entries node:node];
    return menu.numberOfItems > 0 ? menu : nil;
}

- (NSMenu *)titleMenu {
    Json entries = [self.service contributedViewMenus].value("view/title", Json::array());
    NSMenu *menu = [self menuFromEntries:entries node:nil];
    return menu.numberOfItems > 0 ? menu : nil;
}

- (void)runMenuCommand:(NSMenuItem *)item {
    NSDictionary *info = item.representedObject;
    NSString *handle = info[@"handle"];
    if (handle.length == 0) {
        [self.service executeCommand:info[@"command"] arguments:nil];  // a title action has no element
        return;
    }
    Json message = [self messageForHandle:handle];
    message["command"] = [info[@"command"] UTF8String];
    [self.service sendViewRequest:@"tree/runCommand" params:message completion:^(const Json &, NSString *) {}];
}

@end

// ---- Webview section

@implementation GWWebviewSection {
    NSView *_holder;
    NSLayoutConstraint *_holderHeight;
}

@synthesize resolving = _resolving;

- (instancetype)initWithView:(GWContributedView *)contributed owner:(id<GWViewSectionOwner>)owner {
    if ((self = [super initWithView:contributed owner:owner])) {
        _holder = [NSView new];
        _holder.wantsLayer = YES;
        _holderHeight = [_holder.heightAnchor constraintEqualToConstant:340];
        _holderHeight.active = YES;
        [self installBody:_holder];
    }
    return self;
}

- (GWExtensionHostService *)service {
    return _owner.service;
}

- (void)attachController:(GWWebviewController *)controller {
    _controller = controller;
    controller.webView.frame = _holder.bounds;
    controller.webView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [_holder addSubview:controller.webView];
}

- (void)expansionChanged {
    [self resolveIfNeeded];
}

- (void)didRegister {
    [self resolveIfNeeded];
}

- (void)setPanelVisible:(BOOL)visible {
    [super setPanelVisible:visible];
    [self resolveIfNeeded];
}

- (void)resolveIfNeeded {
    if (_panelVisible && self.expanded && _controller == nil && !_resolving) {
        [_owner resolveWebviewForSection:self];
    }
}

- (void)reset {
    [_controller.webView removeFromSuperview];
    _controller = nil;
    _resolving = NO;
}

@end

// MARK: - The coordinator

/// A flipped view so the sections stack from the top of the scroll view.
@interface GWViewsDocumentView : NSView
@end

@implementation GWViewsDocumentView
- (BOOL)isFlipped {
    return YES;
}
@end

@interface GWExtensionViews () <GWViewSectionOwner>
@end

@implementation GWExtensionViews {
    GWExtensionHostService *_service;
    NSScrollView *_scroll;
    GWViewsDocumentView *_document;
    NSStackView *_stack;
    NSTextField *_emptyLabel;
    NSMutableDictionary<NSString *, GWViewSection *> *_sections;
    NSMutableDictionary<NSString *, GWWebviewController *> *_webviews;  // handle → page, for panels and views
    NSMutableSet<NSString *> *_panelHandles;
    BOOL _sidebarVisible;
}

- (instancetype)initWithService:(GWExtensionHostService *)service {
    if ((self = [super init])) {
        _service = service;
        _service.viewsDelegate = self;
        _sections = [NSMutableDictionary dictionary];
        _webviews = [NSMutableDictionary dictionary];
        _panelHandles = [NSMutableSet set];

        _stack = [NSStackView new];
        _stack.orientation = NSUserInterfaceLayoutOrientationVertical;
        _stack.alignment = NSLayoutAttributeLeading;
        _stack.spacing = 4;
        _stack.translatesAutoresizingMaskIntoConstraints = NO;

        _emptyLabel = [NSTextField wrappingLabelWithString:
            @"Extensions that add views to the sidebar (a file outline, a to-do list, a dashboard…) show them here."];
        _emptyLabel.font = [NSFont systemFontOfSize:12];
        _emptyLabel.textColor = NSColor.secondaryLabelColor;
        _emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;

        _document = [GWViewsDocumentView new];
        [_document addSubview:_stack];
        _scroll = [NSScrollView new];
        _scroll.hasVerticalScroller = YES;
        _scroll.drawsBackground = NO;
        _scroll.autohidesScrollers = YES;
        _scroll.documentView = _document;
        _document.translatesAutoresizingMaskIntoConstraints = NO;
        [NSLayoutConstraint activateConstraints:@[
            [_stack.topAnchor constraintEqualToAnchor:_document.topAnchor constant:4],
            [_stack.leadingAnchor constraintEqualToAnchor:_document.leadingAnchor],
            [_stack.trailingAnchor constraintEqualToAnchor:_document.trailingAnchor],
            [_stack.bottomAnchor constraintEqualToAnchor:_document.bottomAnchor constant:-8],
            [_document.widthAnchor constraintEqualToAnchor:_scroll.contentView.widthAnchor],
        ]];
        [self reload];
    }
    return self;
}

- (NSView *)sidebarView {
    return _scroll;
}

- (GWExtensionHostService *)service {
    return _service;
}

- (BOOL)hasViews {
    return _service.contributedViews.count > 0;
}

- (void)sectionNeedsLayout {
    [_document setNeedsLayout:YES];
}

// MARK: Building the sections

- (void)reload {
    for (GWViewSection *section in _sections.allValues) {
        [section reset];
    }
    [_sections removeAllObjects];
    for (NSView *view in [_stack.arrangedSubviews copy]) {
        [_stack removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    NSArray<GWContributedView *> *views = _service.contributedViews;
    if (views.count == 0) {
        [_stack addArrangedSubview:_emptyLabel];
        [_emptyLabel.widthAnchor constraintEqualToAnchor:_stack.widthAnchor constant:-28].active = YES;
        return;
    }
    NSString *lastContainer = nil;
    for (GWContributedView *contributed in views) {
        BOOL newContainer = lastContainer == nil || ![contributed.containerIdentifier isEqualToString:lastContainer];
        if (newContainer) {
            lastContainer = contributed.containerIdentifier;
            [self addContainerCaption:contributed];
        }
        GWViewSection *section = contributed.isWebview
            ? [[GWWebviewSection alloc] initWithView:contributed owner:self]
            : [[GWTreeSection alloc] initWithView:contributed owner:self];
        _sections[contributed.identifier] = section;
        [_stack addArrangedSubview:section.view];
        [section.view.widthAnchor constraintEqualToAnchor:_stack.widthAnchor].active = YES;
    }
    // The first view of each container starts open, so the sidebar isn't a column of closed headers.
    NSMutableSet<NSString *> *opened = [NSMutableSet set];
    for (GWContributedView *contributed in views) {
        if (![opened containsObject:contributed.containerIdentifier]) {
            [opened addObject:contributed.containerIdentifier];
            [_sections[contributed.identifier] setExpanded:YES];
        }
    }
}

- (void)addContainerCaption:(GWContributedView *)contributed {
    NSTextField *caption = [NSTextField labelWithString:contributed.containerTitle];
    caption.font = [NSFont systemFontOfSize:15 weight:NSFontWeightBold];
    caption.lineBreakMode = NSLineBreakByTruncatingTail;
    caption.translatesAutoresizingMaskIntoConstraints = NO;
    [_stack addArrangedSubview:caption];
    [_stack setCustomSpacing:6 afterView:caption];
    [caption.leadingAnchor constraintEqualToAnchor:_stack.leadingAnchor constant:18].active = YES;
}

- (void)sidebarVisibilityChanged:(BOOL)visible {
    _sidebarVisible = visible;
    for (GWViewSection *section in _sections.allValues) {
        [section setPanelVisible:visible];
    }
}

// MARK: Webview views in the sidebar

- (void)resolveWebviewForSection:(GWWebviewSection *)section {
    section.resolving = YES;
    NSString *viewIdentifier = section.contributed.identifier;
    __weak GWExtensionViews *weakSelf = self;
    [_service activateView:viewIdentifier completion:^(BOOL ok) {
        GWExtensionViews *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        if (!ok) {
            section.resolving = NO;
            return;
        }
        [strongSelf->_service sendViewRequest:@"view/resolve" params:Json{{"id", viewIdentifier.UTF8String}}
                                   completion:^(const Json &result, NSString *error) {
            section.resolving = NO;
            if (error != nil || !result.value("ok", false)) {
                return;  // the extension hasn't registered it yet; didRegister tries again
            }
            NSString *handle = StringFromJson(result["handle"]);
            if (handle == nil) {
                return;
            }
            GWWebviewController *controller = [weakSelf makeControllerForHandle:handle];
            [controller applyOptions:result.value("options", Json::object())];
            NSString *html = StringFromJson(result["html"]);
            if (html.length > 0) {
                [controller setHTML:html];
            }
            [section attachController:controller];
        }];
    }];
}

/// A page for a handle, wired so its messages and command links reach the extension.
- (GWWebviewController *)makeControllerForHandle:(NSString *)handle {
    NSArray<NSString *> *roots = self.webviewRoots ? self.webviewRoots() : @[];
    GWWebviewController *controller = [[GWWebviewController alloc] initWithHandle:handle defaultRoots:roots];
    __weak GWExtensionViews *weakSelf = self;
    controller.onMessage = ^(const Json &message) {
        Json envelope = {{"handle", handle.UTF8String}, {"message", message}};
        [weakSelf.service sendViewNotification:@"webview/message" params:envelope];
    };
    controller.onCommandLink = ^(NSString *link) {
        NSString *command = nil;
        NSArray *arguments = nil;
        ParseCommandLink(link, &command, &arguments);
        [weakSelf.service executeCommand:command arguments:arguments];
    };
    _webviews[handle] = controller;
    return controller;
}

// MARK: GWExtensionViewsDelegate

- (void)hostViewNotification:(NSString *)method params:(const Json &)incoming {
    Json params = incoming;  // a copy, so a missing key reads as null instead of undefined
    NSString *identifier = StringFromJson(params.value("id", Json()));
    NSString *handle = StringFromJson(params.value("handle", Json()));

    if ([method isEqualToString:@"view/registered"]) {
        [_sections[identifier] didRegister];
    } else if ([method isEqualToString:@"view/unregistered"]) {
        [_sections[identifier] didUnregister];
    } else if ([method isEqualToString:@"view/changed"]) {
        [_sections[identifier] dataChanged];
    } else if ([method isEqualToString:@"view/state"]) {
        [_sections[identifier] stateChangedTitle:StringFromJson(params.value("title", Json()))
                                     description:StringFromJson(params.value("description", Json()))
                                         message:StringFromJson(params.value("message", Json()))];
    } else if ([method isEqualToString:@"view/reveal"]) {
        if (_onRevealSidebar) {
            _onRevealSidebar();
        }
        GWViewSection *section = _sections[identifier];
        [section setExpanded:YES];
        if (handle != nil) {
            [section revealHandle:handle];
        }
    } else if ([method isEqualToString:@"webview/create"]) {
        [self createPanelWithParams:params];
    } else if ([method isEqualToString:@"webview/html"]) {
        [_webviews[handle] setHTML:StringFromJson(params.value("html", Json())) ?: @""];
    } else if ([method isEqualToString:@"webview/options"]) {
        [_webviews[handle] applyOptions:params.value("options", Json::object())];
    } else if ([method isEqualToString:@"webview/title"]) {
        if (_onRetitlePanel && handle != nil) {
            _onRetitlePanel(handle, StringFromJson(params.value("title", Json())) ?: @"");
        }
    } else if ([method isEqualToString:@"webview/reveal"]) {
        if (_onRevealPanel && handle != nil) {
            _onRevealPanel(handle);
        }
    } else if ([method isEqualToString:@"webview/dispose"]) {
        [_panelHandles removeObject:handle];
        [_webviews removeObjectForKey:handle];
        if (_onClosePanel && handle != nil) {
            _onClosePanel(handle);
        }
    }
}

- (void)createPanelWithParams:(const Json &)incoming {
    Json params = incoming;  // a copy, so a missing key reads as null instead of undefined
    NSString *handle = StringFromJson(params.value("handle", Json()));
    if (handle == nil) {
        return;
    }
    GWWebviewController *controller = [self makeControllerForHandle:handle];
    [controller applyOptions:params.value("options", Json::object())];
    [_panelHandles addObject:handle];
    if (_onOpenPanel) {
        NSString *title = StringFromJson(params.value("title", Json())) ?: @"";
        BOOL preserveFocus = params.value("preserveFocus", false);
        _onOpenPanel(handle, title, controller.webView, preserveFocus);
    }
}

- (void)hostViewRequest:(NSString *)method params:(const Json &)incoming reply:(void (^)(const Json &))reply {
    Json params = incoming;  // a copy, so a missing key reads as null instead of undefined
    if ([method isEqualToString:@"webview/postMessage"]) {
        GWWebviewController *controller = _webviews[StringFromJson(params.value("handle", Json())) ?: @""];
        if (controller == nil) {
            reply(Json{{"delivered", false}});
            return;
        }
        [controller postMessage:params.value("message", Json()) completion:^(BOOL delivered) {
            reply(Json{{"delivered", delivered == YES}});
        }];
        return;
    }
    reply(Json());
}

- (void)hostViewsDidReset {
    for (GWViewSection *section in _sections.allValues) {
        [section reset];
    }
    for (NSString *handle in [_panelHandles copy]) {
        if (_onClosePanel) {
            _onClosePanel(handle);
        }
    }
    [_panelHandles removeAllObjects];
    [_webviews removeAllObjects];
}

// MARK: Panels

- (void)panelTabClosed:(NSString *)handle {
    [_panelHandles removeObject:handle];
    [_webviews removeObjectForKey:handle];
    [_service sendViewNotification:@"webview/disposed" params:Json{{"handle", handle.UTF8String}}];
}

- (void)panelTab:(NSString *)handle isFront:(BOOL)front {
    Json state = {{"handle", handle.UTF8String}, {"active", front == YES}, {"visible", front == YES}};
    [_service sendViewNotification:@"webview/viewState" params:state];
}

@end
