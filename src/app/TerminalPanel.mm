#import "TerminalPanel.h"

#import "TerminalSession.h"
#import "TerminalView.h"

// ===========================================================================
// A tab

@interface GWTerminalTab : NSView
@property (nonatomic, copy) NSString *title;
@property (nonatomic) BOOL selected;
@property (nonatomic, copy, nullable) void (^onSelect)(void);
@property (nonatomic, copy, nullable) void (^onClose)(void);
@end

@implementation GWTerminalTab {
    NSTextField *_label;
    NSButton *_close;
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

    NSImageView *icon = [NSImageView imageViewWithImage:[[NSImage imageWithSystemSymbolName:@"terminal" accessibilityDescription:nil]
        imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:10.5 weight:NSFontWeightMedium]]];
    icon.contentTintColor = NSColor.secondaryLabelColor;
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    _label = [NSTextField labelWithString:@""];
    _label.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    _label.lineBreakMode = NSLineBreakByTruncatingTail;
    _label.translatesAutoresizingMaskIntoConstraints = NO;
    _close = [NSButton buttonWithImage:[[NSImage imageWithSystemSymbolName:@"xmark" accessibilityDescription:@"Close"]
        imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:8.5 weight:NSFontWeightBold]]
                                target:self action:@selector(closeClicked:)];
    _close.bordered = NO;
    _close.contentTintColor = NSColor.tertiaryLabelColor;
    _close.translatesAutoresizingMaskIntoConstraints = NO;

    for (NSView *view in @[icon, _label, _close]) {
        [self addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [self.heightAnchor constraintEqualToConstant:24],
        [icon.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:9],
        [icon.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_label.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:6],
        [_label.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_label.widthAnchor constraintLessThanOrEqualToConstant:150],
        [_close.leadingAnchor constraintEqualToAnchor:_label.trailingAnchor constant:4],
        [_close.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-6],
        [_close.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_close.widthAnchor constraintEqualToConstant:16],
    ]];
    [self updateColors];
    return self;
}

- (void)setTitle:(NSString *)title {
    _title = [title copy];
    _label.stringValue = title;
}

- (void)setSelected:(BOOL)selected {
    _selected = selected;
    _label.textColor = selected ? NSColor.labelColor : NSColor.secondaryLabelColor;
    [self updateColors];
}

- (void)updateColors {
    [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
        CGFloat alpha = self->_selected ? 0.14 : (self->_hovered ? 0.07 : 0);
        self.layer.backgroundColor = [NSColor.labelColor colorWithAlphaComponent:alpha].CGColor;
    }];
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self updateColors];
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
    if (self.onSelect) self.onSelect();
}

- (void)closeClicked:(id)sender {
    if (self.onClose) self.onClose();
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }

@end

// ===========================================================================
// The panel

@implementation GWTerminalPanel {
    NSView *_view;
    NSStackView *_tabRow;
    NSView *_content;
    GWTerminalView *_terminalView;

    NSMutableArray<GWTerminalSession *> *_sessions;
    NSMutableArray<GWTerminalTab *> *_tabs;
    NSInteger _selected;
    NSTimer *_titleTimer;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _sessions = [NSMutableArray array];
        _tabs = [NSMutableArray array];
        _selected = -1;
        [self buildViews];
    }
    return self;
}

- (void)dealloc {
    [_titleTimer invalidate];
    for (GWTerminalSession *session in _sessions) {
        [session terminate];
    }
}

- (NSView *)view { return _view; }
- (NSUInteger)terminalCount { return _sessions.count; }

- (NSButton *)headerButton:(NSString *)symbol tip:(NSString *)tip action:(SEL)action {
    NSImage *image = [[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:tip]
        imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightMedium]];
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

    _tabRow = [NSStackView new];
    _tabRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    _tabRow.spacing = 4;
    _tabRow.translatesAutoresizingMaskIntoConstraints = NO;

    NSButton *add = [self headerButton:@"plus" tip:@"New terminal  ⌃⇧`" action:@selector(addClicked:)];
    NSButton *kill = [self headerButton:@"trash" tip:@"Close this terminal" action:@selector(killClicked:)];
    NSButton *hide = [self headerButton:@"chevron.down" tip:@"Hide the terminal  ⌃`" action:@selector(hideClicked:)];
    NSView *spacer = [NSView new];
    [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *header = [NSStackView stackViewWithViews:@[_tabRow, add, spacer, kill, hide]];
    header.spacing = 4;
    header.translatesAutoresizingMaskIntoConstraints = NO;

    _terminalView = [[GWTerminalView alloc] initWithFrame:NSZeroRect];
    _terminalView.translatesAutoresizingMaskIntoConstraints = NO;
    __weak GWTerminalPanel *weakSelf = self;
    _terminalView.onOpenPath = ^(NSString *path, NSInteger line, NSInteger column) {
        GWTerminalPanel *strongSelf = weakSelf;
        if (strongSelf.onOpenPath) strongSelf.onOpenPath(path, line, column);
    };
    _terminalView.baseFolderProvider = ^NSString *{ return weakSelf.projectFolder; };

    [_view addSubview:header];
    [_view addSubview:_terminalView];
    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:_view.topAnchor constant:8],
        [header.leadingAnchor constraintEqualToAnchor:_view.leadingAnchor constant:14],
        [header.trailingAnchor constraintEqualToAnchor:_view.trailingAnchor constant:-10],
        [header.heightAnchor constraintEqualToConstant:26],
        [_terminalView.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:4],
        [_terminalView.leadingAnchor constraintEqualToAnchor:_view.leadingAnchor constant:4],
        [_terminalView.trailingAnchor constraintEqualToAnchor:_view.trailingAnchor constant:-4],
        [_terminalView.bottomAnchor constraintEqualToAnchor:_view.bottomAnchor constant:-6],
    ]];

    // The program in the foreground changes without telling us; look now and then.
    _titleTimer = [NSTimer scheduledTimerWithTimeInterval:1.5 repeats:YES block:^(NSTimer *timer) {
        GWTerminalPanel *strongSelf = weakSelf;
        for (GWTerminalSession *session in strongSelf->_sessions) {
            [session refreshProcessName];
        }
    }];
}

// ---------------------------------------------------------------------------
// MARK: Terminals

- (void)newTerminalRunning:(NSString *)command {
    // A new terminal starts where the last one was, else in the project.
    NSString *folder = _selected >= 0 ? [_sessions[static_cast<NSUInteger>(_selected)] currentDirectory] : nil;
    if (folder == nil) {
        folder = self.projectFolder;
    }
    GWTerminalSession *session = [[GWTerminalSession alloc] initWithFolder:folder command:command columns:100 rows:20];
    __weak GWTerminalPanel *weakSelf = self;
    __weak GWTerminalSession *weakSession = session;
    session.onTitleChange = ^{
        [weakSelf refreshTabTitles];
    };
    session.onExit = ^(int code) {
        [weakSelf sessionEnded:weakSession code:code];
    };
    [_sessions addObject:session];

    GWTerminalTab *tab = [GWTerminalTab new];
    tab.onSelect = ^{
        GWTerminalPanel *strongSelf = weakSelf;
        NSUInteger index = [strongSelf->_tabs indexOfObject:[strongSelf tabForSession:weakSession]];
        if (index != NSNotFound) [strongSelf selectIndex:static_cast<NSInteger>(index)];
    };
    tab.onClose = ^{
        [weakSelf closeSession:weakSession];
    };
    [_tabs addObject:tab];
    [_tabRow addArrangedSubview:tab];
    [self selectIndex:static_cast<NSInteger>(_sessions.count) - 1];
    [self refreshTabTitles];
}

- (GWTerminalTab *)tabForSession:(GWTerminalSession *)session {
    NSUInteger index = [_sessions indexOfObject:session];
    return index == NSNotFound ? nil : _tabs[index];
}

- (void)selectIndex:(NSInteger)index {
    if (index < 0 || index >= static_cast<NSInteger>(_sessions.count)) {
        _selected = -1;
        _terminalView.session = nil;
        return;
    }
    _selected = index;
    for (NSUInteger tabIndex = 0; tabIndex < _tabs.count; ++tabIndex) {
        _tabs[tabIndex].selected = static_cast<NSInteger>(tabIndex) == index;
    }
    _terminalView.session = _sessions[static_cast<NSUInteger>(index)];
    [self focusTerminal];
}

- (void)refreshTabTitles {
    for (NSUInteger index = 0; index < _sessions.count; ++index) {
        _tabs[index].title = _sessions[index].displayTitle;
    }
}

- (void)closeSession:(GWTerminalSession *)session {
    NSUInteger index = [_sessions indexOfObject:session];
    if (index == NSNotFound) {
        return;
    }
    [session terminate];
    [_tabRow removeArrangedSubview:_tabs[index]];
    [_tabs[index] removeFromSuperview];
    [_tabs removeObjectAtIndex:index];
    [_sessions removeObjectAtIndex:index];
    if (_sessions.count == 0) {
        _selected = -1;
        _terminalView.session = nil;
        if (self.onHide) self.onHide();
        return;
    }
    [self selectIndex:MIN(static_cast<NSInteger>(index), static_cast<NSInteger>(_sessions.count) - 1)];
}

- (void)closeCurrentTerminal {
    if (_selected >= 0) {
        [self closeSession:_sessions[static_cast<NSUInteger>(_selected)]];
    }
}

/// The shell ended (the user typed "exit", or the program finished). A clean end closes the tab;
/// a failure stays so the message can be read.
- (void)sessionEnded:(GWTerminalSession *)session code:(int)code {
    if (session == nil) {
        return;
    }
    if (code == 0 || code == 129 /* hung up */) {
        [self closeSession:session];
        return;
    }
    NSString *message = [NSString stringWithFormat:@"\r\n\x1b[2m[process exited with code %d]\x1b[0m\r\n", code];
    session.screen.write(message.UTF8String);
    [self.view setNeedsDisplay:YES];
    [self refreshTabTitles];
}

- (void)focusTerminal {
    [_view.window makeFirstResponder:_terminalView];
}

- (void)sendText:(NSString *)text {
    if (_selected >= 0) {
        [_sessions[static_cast<NSUInteger>(_selected)] sendText:text];
    }
}

- (void)addClicked:(id)sender { [self newTerminalRunning:nil]; }
- (void)killClicked:(id)sender { [self closeCurrentTerminal]; }
- (void)hideClicked:(id)sender {
    if (self.onHide) self.onHide();
}

@end
