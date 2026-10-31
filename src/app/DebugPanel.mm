#import "DebugPanel.h"

#import "Debugger.h"
#import "PixelArt.h"
#import "Services.h"

#include "BitmapMode.hpp"

/// The size of a font pixel in the retro panel: small, since the panel is narrow.
static constexpr CGFloat kRetroPixel = 1.5;

/// A row whose selection is a flat band of the bitmap scheme's selection color.
@interface GWRetroDebugRowView : NSTableRowView
@end

@implementation GWRetroDebugRowView
- (void)drawSelectionInRect:(NSRect)dirtyRect {
    [GWColor(GWServices.shared.bitmapScheme.selection) setFill];
    NSRectFill(self.bounds);
}
@end

static NSButton *toolButton(NSString *symbol, NSString *tooltip, id target, SEL action) {
    NSButton *button = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:tooltip]
                                          target:target
                                          action:action];
    button.bezelStyle = NSBezelStyleRegularSquare;
    button.bordered = NO;
    button.toolTip = tooltip;
    button.contentTintColor = NSColor.secondaryLabelColor;
    button.imageScaling = NSImageScaleProportionallyDown;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button.widthAnchor constraintEqualToConstant:28].active = YES;
    [button.heightAnchor constraintEqualToConstant:26].active = YES;
    return button;
}

static NSTextField *sectionTitle(NSString *text) {
    NSTextField *label = [NSTextField labelWithString:@""];
    label.attributedStringValue = [[NSAttributedString alloc] initWithString:text attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:10.5 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: NSColor.tertiaryLabelColor,
        NSKernAttributeName: @1.2,
    }];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

@interface GWDebugPanel () <NSTableViewDataSource, NSTableViewDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate>
@end

@implementation GWDebugPanel {
    GWDebugger *_debugger;
    NSView *_view;
    NSTextField *_statusLabel;
    NSButton *_startButton;
    NSStackView *_toolbar;
    NSButton *_resumeButton, *_pauseButton, *_overButton, *_intoButton, *_outButton, *_stopButton;
    NSTableView *_stackTable;
    NSOutlineView *_variablesOutline;
    NSArray<GWDebugVariable *> *_scopes;
    NSTextView *_console;
    NSTextField *_input;
    NSView *_sessionArea;   // everything below the toolbar, shown while debugging
    NSView *_startArea;     // the big Start button, shown when idle
    NSTextField *_hint;
    NSArray<NSTextField *> *_sectionTitles;
    NSInteger _variablesRequestFrame;
}

- (instancetype)initWithDebugger:(GWDebugger *)debugger {
    if ((self = [super init])) {
        _debugger = debugger;
        _scopes = @[];
        _variablesRequestFrame = -1;
        [self build];
    }
    return self;
}

- (NSView *)view { return _view; }

// ---------------------------------------------------------------------------
// MARK: Building

- (NSScrollView *)scrollViewFor:(NSView *)content {
    NSScrollView *scroll = [NSScrollView new];
    scroll.documentView = content;
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.scrollerStyle = NSScrollerStyleOverlay;
    scroll.automaticallyAdjustsContentInsets = NO;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    return scroll;
}

- (void)build {
    _view = [NSView new];

    // ---- Toolbar
    _resumeButton = toolButton(@"play.fill", @"Continue  F5", self, @selector(resumeClicked:));
    _pauseButton = toolButton(@"pause.fill", @"Pause", self, @selector(pauseClicked:));
    _overButton = toolButton(@"arrow.turn.down.right", @"Step Over  F10", self, @selector(overClicked:));
    _intoButton = toolButton(@"arrow.down.to.line", @"Step Into  F11", self, @selector(intoClicked:));
    _outButton = toolButton(@"arrow.up.to.line", @"Step Out  ⇧F11", self, @selector(outClicked:));
    _stopButton = toolButton(@"stop.fill", @"Stop  ⇧F5", self, @selector(stopClicked:));
    _stopButton.contentTintColor = NSColor.systemRedColor;
    _toolbar = [NSStackView stackViewWithViews:@[_resumeButton, _pauseButton, _overButton, _intoButton, _outButton, _stopButton]];
    _toolbar.spacing = 2;
    _toolbar.translatesAutoresizingMaskIntoConstraints = NO;

    _statusLabel = [NSTextField labelWithString:@"Not running"];
    _statusLabel.font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium];
    _statusLabel.textColor = NSColor.secondaryLabelColor;
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *title = sectionTitle(@"RUN AND DEBUG");
    [_view addSubview:title];
    [_view addSubview:_statusLabel];
    [_view addSubview:_toolbar];

    // ---- Start area (idle)
    _startArea = [NSView new];
    _startArea.translatesAutoresizingMaskIntoConstraints = NO;
    _startButton = [NSButton buttonWithTitle:@"Start Debugging" target:self action:@selector(startClicked:)];
    _startButton.bezelStyle = NSBezelStyleGlass;
    _startButton.translatesAutoresizingMaskIntoConstraints = NO;
    NSTextField *hint = [NSTextField wrappingLabelWithString:@"Click just left of the line numbers (or press F9) to set breakpoints. F5 builds and runs "
                                                             @"the current file (or the program you chose) under the debugger."];
    hint.font = [NSFont systemFontOfSize:11.5];
    hint.textColor = NSColor.tertiaryLabelColor;
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    _hint = hint;
    [_startArea addSubview:_startButton];
    [_startArea addSubview:hint];
    [_view addSubview:_startArea];

    // ---- Session area
    _sessionArea = [NSView new];
    _sessionArea.translatesAutoresizingMaskIntoConstraints = NO;
    [_view addSubview:_sessionArea];

    NSTextField *stackTitle = sectionTitle(@"CALL STACK");
    _stackTable = [NSTableView new];
    NSTableColumn *stackColumn = [[NSTableColumn alloc] initWithIdentifier:@"frame"];
    stackColumn.resizingMask = NSTableColumnAutoresizingMask;
    [_stackTable addTableColumn:stackColumn];
    _stackTable.headerView = nil;
    _stackTable.rowHeight = 34;
    _stackTable.backgroundColor = NSColor.clearColor;
    _stackTable.style = NSTableViewStyleSourceList;
    _stackTable.dataSource = self;
    _stackTable.delegate = self;
    NSScrollView *stackScroll = [self scrollViewFor:_stackTable];

    NSTextField *variablesTitle = sectionTitle(@"VARIABLES");
    _variablesOutline = [NSOutlineView new];
    NSTableColumn *nameColumn = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    nameColumn.width = 100;
    nameColumn.minWidth = 60;
    NSTableColumn *valueColumn = [[NSTableColumn alloc] initWithIdentifier:@"value"];
    valueColumn.width = 130;
    [_variablesOutline addTableColumn:nameColumn];
    [_variablesOutline addTableColumn:valueColumn];
    _variablesOutline.outlineTableColumn = nameColumn;
    _variablesOutline.headerView = nil;
    _variablesOutline.rowHeight = 22;
    _variablesOutline.indentationPerLevel = 12;
    _variablesOutline.backgroundColor = NSColor.clearColor;
    _variablesOutline.style = NSTableViewStyleSourceList;
    _variablesOutline.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
    _variablesOutline.dataSource = self;
    _variablesOutline.delegate = self;
    NSScrollView *variablesScroll = [self scrollViewFor:_variablesOutline];

    NSTextField *consoleTitle = sectionTitle(@"CONSOLE");
    _console = [NSTextView new];
    _console.editable = NO;
    _console.drawsBackground = NO;
    _console.font = [NSFont monospacedSystemFontOfSize:11.5 weight:NSFontWeightRegular];
    _console.textColor = NSColor.labelColor;
    _console.textContainerInset = NSMakeSize(4, 4);
    _console.autoresizingMask = NSViewWidthSizable;
    NSScrollView *consoleScroll = [self scrollViewFor:_console];
    _input = [NSTextField textFieldWithString:@""];
    _input.placeholderString = @"Evaluate an expression…";
    _input.font = [NSFont monospacedSystemFontOfSize:11.5 weight:NSFontWeightRegular];
    _input.bezelStyle = NSTextFieldRoundedBezel;
    _input.delegate = self;
    _input.translatesAutoresizingMaskIntoConstraints = NO;

    for (NSView *view in @[stackTitle, stackScroll, variablesTitle, variablesScroll, consoleTitle, consoleScroll, _input]) {
        [_sessionArea addSubview:view];
    }
    _sectionTitles = @[title, stackTitle, variablesTitle, consoleTitle];

    NSDictionary *views = NSDictionaryOfVariableBindings(title, _statusLabel, _toolbar, _startArea, _sessionArea);
    (void)views;
    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:_view.topAnchor constant:4],
        [title.leadingAnchor constraintEqualToAnchor:_view.leadingAnchor constant:18],
        [_statusLabel.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:4],
        [_statusLabel.leadingAnchor constraintEqualToAnchor:_view.leadingAnchor constant:18],
        [_toolbar.topAnchor constraintEqualToAnchor:_statusLabel.bottomAnchor constant:6],
        [_toolbar.leadingAnchor constraintEqualToAnchor:_view.leadingAnchor constant:12],

        [_startArea.topAnchor constraintEqualToAnchor:_toolbar.bottomAnchor constant:14],
        [_startArea.leadingAnchor constraintEqualToAnchor:_view.leadingAnchor constant:14],
        [_startArea.trailingAnchor constraintEqualToAnchor:_view.trailingAnchor constant:-14],
        [_startButton.topAnchor constraintEqualToAnchor:_startArea.topAnchor],
        [_startButton.leadingAnchor constraintEqualToAnchor:_startArea.leadingAnchor],
        [_startButton.trailingAnchor constraintEqualToAnchor:_startArea.trailingAnchor],
        [hint.topAnchor constraintEqualToAnchor:_startButton.bottomAnchor constant:12],
        [hint.leadingAnchor constraintEqualToAnchor:_startArea.leadingAnchor constant:4],
        [hint.trailingAnchor constraintEqualToAnchor:_startArea.trailingAnchor constant:-4],
        [hint.bottomAnchor constraintEqualToAnchor:_startArea.bottomAnchor],

        [_sessionArea.topAnchor constraintEqualToAnchor:_toolbar.bottomAnchor constant:8],
        [_sessionArea.leadingAnchor constraintEqualToAnchor:_view.leadingAnchor],
        [_sessionArea.trailingAnchor constraintEqualToAnchor:_view.trailingAnchor],
        [_sessionArea.bottomAnchor constraintEqualToAnchor:_view.bottomAnchor],

        [stackTitle.topAnchor constraintEqualToAnchor:_sessionArea.topAnchor],
        [stackTitle.leadingAnchor constraintEqualToAnchor:_sessionArea.leadingAnchor constant:18],
        [stackScroll.topAnchor constraintEqualToAnchor:stackTitle.bottomAnchor constant:4],
        [stackScroll.leadingAnchor constraintEqualToAnchor:_sessionArea.leadingAnchor constant:6],
        [stackScroll.trailingAnchor constraintEqualToAnchor:_sessionArea.trailingAnchor constant:-6],
        [stackScroll.heightAnchor constraintEqualToConstant:110],

        [variablesTitle.topAnchor constraintEqualToAnchor:stackScroll.bottomAnchor constant:8],
        [variablesTitle.leadingAnchor constraintEqualToAnchor:_sessionArea.leadingAnchor constant:18],
        [variablesScroll.topAnchor constraintEqualToAnchor:variablesTitle.bottomAnchor constant:4],
        [variablesScroll.leadingAnchor constraintEqualToAnchor:_sessionArea.leadingAnchor constant:6],
        [variablesScroll.trailingAnchor constraintEqualToAnchor:_sessionArea.trailingAnchor constant:-6],

        [consoleTitle.topAnchor constraintEqualToAnchor:variablesScroll.bottomAnchor constant:8],
        [consoleTitle.leadingAnchor constraintEqualToAnchor:_sessionArea.leadingAnchor constant:18],
        [consoleScroll.topAnchor constraintEqualToAnchor:consoleTitle.bottomAnchor constant:4],
        [consoleScroll.leadingAnchor constraintEqualToAnchor:_sessionArea.leadingAnchor constant:6],
        [consoleScroll.trailingAnchor constraintEqualToAnchor:_sessionArea.trailingAnchor constant:-6],
        [consoleScroll.heightAnchor constraintEqualToConstant:130],
        [_input.topAnchor constraintEqualToAnchor:consoleScroll.bottomAnchor constant:6],
        [_input.leadingAnchor constraintEqualToAnchor:_sessionArea.leadingAnchor constant:10],
        [_input.trailingAnchor constraintEqualToAnchor:_sessionArea.trailingAnchor constant:-10],
        [_input.bottomAnchor constraintEqualToAnchor:_sessionArea.bottomAnchor constant:-10],
    ]];
    [self reload];
}

// ---------------------------------------------------------------------------
// MARK: Look

- (void)setRetro:(BOOL)retro {
    if (_retro == retro) {
        return;
    }
    _retro = retro;
    [self applyLook];
}

- (void)refreshLook {
    if (_retro) {
        [self applyLook];
    }
}

/// The scheme's colors in the retro look, or the system's in the glass one.
- (const gw::bitmap::Scheme &)colors {
    return GWServices.shared.bitmapScheme;
}

- (void)applyLook {
    BOOL retro = _retro;
    const gw::bitmap::Scheme &colors = self.colors;
    NSColor *white = GWColor(colors.text);
    for (NSTextField *title in _sectionTitles) {
        NSString *text = title.stringValue;
        if (retro) {
            title.attributedStringValue = [[NSAttributedString alloc] initWithString:text attributes:GWPixelTextAttributes(kRetroPixel, GWColor(colors.textAccent))];
        } else {
            title.attributedStringValue = sectionTitle(text).attributedStringValue;
        }
    }
    _statusLabel.font = retro ? GWPixelFont(kRetroPixel) : [NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium];
    _statusLabel.textColor = retro ? white : NSColor.secondaryLabelColor;
    _hint.font = retro ? GWPixelFont(kRetroPixel) : [NSFont systemFontOfSize:11.5];
    _hint.textColor = retro ? GWColor(colors.textDim) : NSColor.tertiaryLabelColor;
    for (NSButton *button in @[_resumeButton, _pauseButton, _overButton, _intoButton, _outButton]) {
        button.contentTintColor = retro ? white : NSColor.secondaryLabelColor;
    }
    _startButton.bordered = !retro;
    if (retro) {
        _startButton.attributedTitle = [[NSAttributedString alloc] initWithString:@"→ Start Debugging"
                                                                       attributes:GWPixelTextAttributes(GWChromePixel(), white)];
    } else {
        _startButton.title = @"Start Debugging";
        _startButton.bezelStyle = NSBezelStyleGlass;
    }

    NSFont *consoleFont = retro ? GWPixelFont(kRetroPixel) : [NSFont monospacedSystemFontOfSize:11.5 weight:NSFontWeightRegular];
    _console.font = consoleFont;
    [_console.textStorage addAttribute:NSFontAttributeName value:consoleFont range:NSMakeRange(0, _console.textStorage.length)];
    _input.font = consoleFont;
    _input.bezeled = !retro;
    _input.drawsBackground = retro;
    _input.backgroundColor = GWColor(colors.input);
    _input.textColor = retro ? GWColor(colors.inputText) : NSColor.labelColor;
    if (!retro) {
        _input.bezelStyle = NSTextFieldRoundedBezel;
    }
    // Source lists re-font their cells for the row size and paint a sidebar backdrop; the retro look
    // wants its own pixel text on the panel's color.
    for (NSTableView *table in @[_stackTable, _variablesOutline]) {
        table.style = retro ? NSTableViewStylePlain : NSTableViewStyleSourceList;
        table.rowSizeStyle = retro ? NSTableViewRowSizeStyleCustom : NSTableViewRowSizeStyleDefault;
        table.backgroundColor = NSColor.clearColor;
    }
    _variablesOutline.rowHeight = 22;
    _variablesOutline.tableColumns.firstObject.width = retro ? 130 : 100;  // pixel names are wider
    _stackTable.rowHeight = retro ? 40 : 34;
    [_stackTable reloadData];
    [_variablesOutline reloadData];
}

// ---------------------------------------------------------------------------
// MARK: State

- (void)reload {
    GWDebugState state = _debugger.state;
    _startArea.hidden = state != GWDebugStateIdle;
    _sessionArea.hidden = state == GWDebugStateIdle;
    _resumeButton.enabled = state == GWDebugStateStopped;
    _pauseButton.enabled = state == GWDebugStateRunning;
    _overButton.enabled = _intoButton.enabled = _outButton.enabled = state == GWDebugStateStopped;
    _stopButton.enabled = state != GWDebugStateIdle;
    switch (state) {
        case GWDebugStateIdle: _statusLabel.stringValue = @"Not running"; break;
        case GWDebugStateStarting: _statusLabel.stringValue = @"Starting…"; break;
        case GWDebugStateRunning: _statusLabel.stringValue = @"Running"; break;
        case GWDebugStateStopped: _statusLabel.stringValue = @"Paused"; break;
    }
    [_stackTable reloadData];
    if (state == GWDebugStateStopped && _debugger.frames.count > 0) {
        [_stackTable selectRowIndexes:[NSIndexSet indexSetWithIndex:static_cast<NSUInteger>(_debugger.selectedFrameIndex)]
                 byExtendingSelection:NO];
        [self reloadVariables];
    } else {
        _scopes = @[];
        _variablesRequestFrame = -1;
        [_variablesOutline reloadData];
    }
}

- (void)reloadVariables {
    NSInteger frameIndex = _debugger.selectedFrameIndex;
    if (frameIndex == _variablesRequestFrame && _scopes.count > 0) {
        return;  // already showing this frame
    }
    _variablesRequestFrame = frameIndex;
    __weak GWDebugPanel *weakSelf = self;
    [_debugger fetchScopes:^(NSArray<GWDebugVariable *> *scopes) {
        GWDebugPanel *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        strongSelf->_scopes = scopes;
        [strongSelf->_variablesOutline reloadData];
        // Open the first scope ("Locals") right away, since that is what one wants to see.
        if (scopes.count > 0) {
            GWDebugVariable *first = scopes.firstObject;
            [strongSelf->_debugger fetchChildrenOf:first completion:^{
                [strongSelf->_variablesOutline reloadItem:first reloadChildren:YES];
                [strongSelf->_variablesOutline expandItem:first];
            }];
        }
    }];
}

// ---------------------------------------------------------------------------
// MARK: Console

- (void)appendConsole:(NSString *)text category:(NSString *)category {
    NSColor *color = _retro ? GWColor(self.colors.text) : NSColor.labelColor;
    if ([category isEqualToString:@"stderr"]) {
        color = _retro ? GWColor(self.colors.error) : NSColor.systemRedColor;
    } else if ([category isEqualToString:@"console"]) {
        color = _retro ? GWColor(self.colors.textDim) : NSColor.secondaryLabelColor;
    }
    NSAttributedString *piece = [[NSAttributedString alloc] initWithString:text attributes:@{
        NSFontAttributeName: _console.font,
        NSForegroundColorAttributeName: color,
    }];
    [_console.textStorage appendAttributedString:piece];
    [_console scrollRangeToVisible:NSMakeRange(_console.string.length, 0)];
}

- (void)clearConsole {
    [_console.textStorage setAttributedString:[NSAttributedString new]];
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)command {
    if (command != @selector(insertNewline:)) {
        return NO;
    }
    NSString *expression = [_input.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (expression.length == 0) {
        return YES;
    }
    _input.stringValue = @"";
    [self appendConsole:[NSString stringWithFormat:@"> %@\n", expression] category:@"console"];
    __weak GWDebugPanel *weakSelf = self;
    [_debugger evaluate:expression completion:^(NSString *result, NSString *error) {
        if (result != nil) {
            [weakSelf appendConsole:[result stringByAppendingString:@"\n"] category:@"stdout"];
        } else {
            NSString *problem = error ?: @"No result.";
            [weakSelf appendConsole:[problem stringByAppendingString:@"\n"] category:@"stderr"];
        }
    }];
    return YES;
}

// ---------------------------------------------------------------------------
// MARK: Buttons

- (void)startClicked:(id)sender { if (self.onStart) self.onStart(); }
- (void)resumeClicked:(id)sender { [_debugger resume]; }
- (void)pauseClicked:(id)sender { [_debugger pause]; }
- (void)overClicked:(id)sender { [_debugger stepOver]; }
- (void)intoClicked:(id)sender { [_debugger stepInto]; }
- (void)outClicked:(id)sender { [_debugger stepOut]; }
- (void)stopClicked:(id)sender { [_debugger stop]; }

// ---------------------------------------------------------------------------
// MARK: Call stack table

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return static_cast<NSInteger>(_debugger.frames.count);
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    GWDebugFrame *frame = _debugger.frames[static_cast<NSUInteger>(row)];
    NSTableCellView *cell = [tableView makeViewWithIdentifier:@"frameCell" owner:self];
    if (cell == nil) {
        cell = [NSTableCellView new];
        cell.identifier = @"frameCell";
        NSTextField *label = [NSTextField labelWithString:@""];
        label.lineBreakMode = NSLineBreakByTruncatingTail;
        label.maximumNumberOfLines = 2;
        label.translatesAutoresizingMaskIntoConstraints = NO;
        [cell addSubview:label];
        cell.textField = label;
        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:4],
            [label.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-4],
            [label.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        ]];
    }
    NSDictionary *nameAttributes = @{
        NSFontAttributeName: [NSFont systemFontOfSize:12.5 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: NSColor.labelColor,
    };
    NSDictionary *placeAttributes = @{
        NSFontAttributeName: [NSFont systemFontOfSize:11],
        NSForegroundColorAttributeName: NSColor.tertiaryLabelColor,
    };
    if (_retro) {
        nameAttributes = GWPixelTextAttributes(kRetroPixel, GWColor(self.colors.text));
        placeAttributes = GWPixelTextAttributes(kRetroPixel, GWColor(self.colors.textDim));
    }
    NSMutableAttributedString *text = [[NSMutableAttributedString alloc] initWithString:frame.name attributes:nameAttributes];
    if (frame.path.length > 0) {
        NSString *place = [NSString stringWithFormat:@"\n%@:%ld", frame.path.lastPathComponent, (long)frame.line];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:place attributes:placeAttributes]];
    }
    cell.textField.attributedStringValue = text;
    return cell;
}

- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row {
    return _retro ? [GWRetroDebugRowView new] : nil;
}

- (NSTableRowView *)outlineView:(NSOutlineView *)outlineView rowViewForItem:(id)item {
    return _retro ? [GWRetroDebugRowView new] : nil;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    NSInteger row = _stackTable.selectedRow;
    if (row >= 0 && row != _debugger.selectedFrameIndex) {
        [_debugger selectFrameAtIndex:row];
    }
}

// ---------------------------------------------------------------------------
// MARK: Variables outline

- (NSInteger)outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(GWDebugVariable *)item {
    if (item == nil) {
        return static_cast<NSInteger>(_scopes.count);
    }
    return static_cast<NSInteger>(item.children.count);
}

- (id)outlineView:(NSOutlineView *)outlineView child:(NSInteger)index ofItem:(GWDebugVariable *)item {
    return item == nil ? _scopes[static_cast<NSUInteger>(index)] : item.children[static_cast<NSUInteger>(index)];
}

- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(GWDebugVariable *)item {
    return item.reference != 0;
}

- (void)outlineViewItemWillExpand:(NSNotification *)notification {
    GWDebugVariable *item = notification.userInfo[@"NSObject"];
    if (item.children == nil) {
        __weak GWDebugPanel *weakSelf = self;
        [_debugger fetchChildrenOf:item completion:^{
            GWDebugPanel *strongSelf = weakSelf;
            if (strongSelf != nil) {
                [strongSelf->_variablesOutline reloadItem:item reloadChildren:YES];
            }
        }];
    }
}

- (NSView *)outlineView:(NSOutlineView *)outlineView
     viewForTableColumn:(NSTableColumn *)tableColumn
                   item:(GWDebugVariable *)item {
    BOOL isName = [tableColumn.identifier isEqualToString:@"name"];
    NSString *identifier = isName ? @"nameCell" : @"valueCell";
    NSTableCellView *cell = [outlineView makeViewWithIdentifier:identifier owner:self];
    if (cell == nil) {
        cell = [NSTableCellView new];
        cell.identifier = identifier;
        NSTextField *label = [NSTextField labelWithString:@""];
        label.lineBreakMode = NSLineBreakByTruncatingTail;
        label.font = isName ? [NSFont systemFontOfSize:12.5] : [NSFont monospacedSystemFontOfSize:11.5 weight:NSFontWeightRegular];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        [cell addSubview:label];
        cell.textField = label;
        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:2],
            [label.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-2],
            [label.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        ]];
    }
    if (isName) {
        cell.textField.stringValue = item.name;
        cell.textField.textColor = item.value.length == 0 && item.type.length == 0 ? NSColor.secondaryLabelColor : NSColor.labelColor;
    } else {
        cell.textField.stringValue = item.value ?: @"";
        cell.textField.textColor = NSColor.systemTealColor;
        cell.textField.toolTip = item.type.length > 0 ? [NSString stringWithFormat:@"%@ — %@", item.type, item.value] : item.value;
    }
    if (_retro) {
        // Names white (scopes yellow), values in the code's string cyan.
        BOOL isScope = item.value.length == 0 && item.type.length == 0;
        const gw::bitmap::Scheme &colors = self.colors;
        gw::Color color = isName ? (isScope ? colors.textAccent : colors.text) : colors.link;
        NSMutableDictionary *attributes = [GWPixelTextAttributes(kRetroPixel, GWColor(color)) mutableCopy];
        NSMutableParagraphStyle *oneLine = [NSMutableParagraphStyle new];
        oneLine.lineBreakMode = NSLineBreakByTruncatingTail;  // a long name is cut, never wrapped
        attributes[NSParagraphStyleAttributeName] = oneLine;
        cell.textField.attributedStringValue = [[NSAttributedString alloc] initWithString:cell.textField.stringValue attributes:attributes];
    } else {
        cell.textField.font = isName ? [NSFont systemFontOfSize:12.5] : [NSFont monospacedSystemFontOfSize:11.5 weight:NSFontWeightRegular];
    }
    return cell;
}

@end
