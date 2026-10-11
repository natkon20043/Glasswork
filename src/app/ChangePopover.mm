#import "ChangePopover.h"

#import "Services.h"

/// Owns the popover's buttons' actions, and stays alive while the popover is showing.
@interface GWChangePopoverController : NSViewController
@property (nonatomic, weak) NSPopover *popover;
@property (nonatomic, copy, nullable) void (^onStage)(void);
@property (nonatomic, copy, nullable) void (^onRevert)(void);
@property (nonatomic, copy, nullable) void (^onPrevious)(void);
@property (nonatomic, copy, nullable) void (^onNext)(void);
@end

@implementation GWChangePopoverController

- (void)stageClicked:(id)sender {
    [self.popover close];
    if (self.onStage) {
        self.onStage();
    }
}

- (void)revertClicked:(id)sender {
    [self.popover close];
    if (self.onRevert) {
        self.onRevert();
    }
}

- (void)previousClicked:(id)sender {
    [self.popover close];
    if (self.onPrevious) {
        self.onPrevious();
    }
}

- (void)nextClicked:(id)sender {
    [self.popover close];
    if (self.onNext) {
        self.onNext();
    }
}

@end

NSAttributedString *GWDiffAttributedText(NSArray<NSString *> *oldLines, NSArray<NSString *> *newLines, CGFloat pointSize) {
    NSFont *font = [NSFont monospacedSystemFontOfSize:pointSize weight:NSFontWeightRegular];
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.lineBreakMode = NSLineBreakByClipping;

    NSColor *removedBackground = [NSColor colorWithSRGBRed:0.97 green:0.32 blue:0.29 alpha:0.20];
    NSColor *addedBackground = [NSColor colorWithSRGBRed:0.25 green:0.73 blue:0.31 alpha:0.20];
    NSMutableAttributedString *text = [NSMutableAttributedString new];

    auto append = ^(NSArray<NSString *> *lines, NSString *prefix, NSColor *background) {
        NSUInteger shown = MIN(lines.count, 60UL);
        for (NSUInteger index = 0; index < shown; ++index) {
            NSString *line = [NSString stringWithFormat:@"%@ %@\n", prefix, lines[index]];
            [text appendAttributedString:[[NSAttributedString alloc] initWithString:line attributes:@{
                NSFontAttributeName: font,
                NSForegroundColorAttributeName: NSColor.labelColor,
                NSBackgroundColorAttributeName: background,
                NSParagraphStyleAttributeName: paragraph,
            }]];
        }
        if (lines.count > shown) {
            NSString *more = [NSString stringWithFormat:@"   … %lu more lines\n", static_cast<unsigned long>(lines.count - shown)];
            [text appendAttributedString:[[NSAttributedString alloc] initWithString:more attributes:@{
                NSFontAttributeName: font,
                NSForegroundColorAttributeName: NSColor.secondaryLabelColor,
            }]];
        }
    };
    append(oldLines, @"−", removedBackground);
    append(newLines, @"+", addedBackground);
    return text;
}


@implementation GWChangePopover

static NSButton *toolButton(NSString *symbol, NSString *title, NSString *tip, id target, SEL action, BOOL destructive) {
    NSImageSymbolConfiguration *configuration = [NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightSemibold];
    NSImage *image = [[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:tip] imageWithSymbolConfiguration:configuration];
    NSButton *button = [NSButton buttonWithTitle:title image:image target:target action:action];
    button.bezelStyle = NSBezelStyleGlass;
    button.toolTip = tip;
    button.imagePosition = title.length > 0 ? NSImageLeading : NSImageOnly;
    if (destructive) {
        button.contentTintColor = NSColor.systemRedColor;
    }
    return button;
}

/// The text of the two versions, with a colored background on every line.
+ (void)showRelativeToRect:(NSRect)rect
                    ofView:(NSView *)view
                     title:(NSString *)title
                  oldLines:(NSArray<NSString *> *)oldLines
                  newLines:(NSArray<NSString *> *)newLines
                     count:(NSString *)summary
                   onStage:(void (^)(void))onStage
                  onRevert:(void (^)(void))onRevert
                onPrevious:(void (^)(void))onPrevious
                    onNext:(void (^)(void))onNext {
    GWChangePopoverController *controller = [GWChangePopoverController new];
    controller.onStage = onStage;
    controller.onRevert = onRevert;
    controller.onPrevious = onPrevious;
    controller.onNext = onNext;

    // Header: what changed, and the buttons.
    NSTextField *titleLabel = [NSTextField labelWithString:title];
    titleLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    NSTextField *summaryLabel = [NSTextField labelWithString:summary];
    summaryLabel.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    summaryLabel.textColor = NSColor.secondaryLabelColor;

    NSView *spacer = [NSView new];
    [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSMutableArray<NSView *> *headerViews = [NSMutableArray arrayWithObjects:titleLabel, summaryLabel, spacer, nil];
    if (onPrevious) {
        [headerViews addObject:toolButton(@"chevron.up", @"", @"Previous change", controller, @selector(previousClicked:), NO)];
    }
    if (onNext) {
        [headerViews addObject:toolButton(@"chevron.down", @"", @"Next change", controller, @selector(nextClicked:), NO)];
    }
    if (onStage) {
        [headerViews addObject:toolButton(@"plus", @"Stage", @"Stage this change", controller, @selector(stageClicked:), NO)];
    }
    if (onRevert) {
        [headerViews addObject:toolButton(@"arrow.uturn.backward", @"Revert", @"Put the committed lines back", controller,
                                          @selector(revertClicked:), YES)];
    }
    NSStackView *header = [NSStackView stackViewWithViews:headerViews];
    header.spacing = 8;
    header.translatesAutoresizingMaskIntoConstraints = NO;

    // Body: the lines.
    NSTextView *body = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 540, 100)];
    body.editable = NO;
    body.drawsBackground = NO;
    body.textContainerInset = NSMakeSize(0, 4);
    body.horizontallyResizable = YES;
    body.textContainer.widthTracksTextView = NO;
    body.textContainer.containerSize = NSMakeSize(4000, CGFLOAT_MAX);
    NSFont *editorFont = [GWServices.shared editorFontBold:NO italic:NO];
    [body.textStorage setAttributedString:GWDiffAttributedText(oldLines, newLines, MAX(11, editorFont.pointSize - 1))];
    [body.layoutManager ensureLayoutForTextContainer:body.textContainer];
    NSRect used = [body.layoutManager usedRectForTextContainer:body.textContainer];

    NSScrollView *scroll = [NSScrollView new];
    scroll.documentView = body;
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = YES;
    scroll.hasHorizontalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.borderType = NSNoBorder;
    scroll.wantsLayer = YES;
    scroll.layer.cornerRadius = 8;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;

    CGFloat bodyHeight = MIN(MAX(used.size.height + 10, 40), 300);
    NSView *content = [NSView new];
    [content addSubview:header];
    [content addSubview:scroll];
    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:content.topAnchor constant:12],
        [header.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:14],
        [header.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-12],
        [scroll.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:10],
        [scroll.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:10],
        [scroll.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-10],
        [scroll.heightAnchor constraintEqualToConstant:bodyHeight],
        [scroll.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-10],
        [content.widthAnchor constraintEqualToConstant:560],
    ]];
    controller.view = content;

    // One at a time, and kept alive while it shows.
    static NSPopover *current = nil;
    [current close];
    NSPopover *popover = [NSPopover new];
    current = popover;
    popover.contentViewController = controller;
    popover.behavior = NSPopoverBehaviorTransient;
    popover.animates = YES;
    controller.popover = popover;
    [popover showRelativeToRect:rect ofView:view preferredEdge:NSRectEdgeMaxX];
}

@end
