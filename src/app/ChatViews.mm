#import "ChatViews.h"

#import "ChangePopover.h"
#import "MarkdownView.h"
#import "Services.h"

#include <string>
#include <vector>

// ===========================================================================
// Helpers

namespace {

NSImage *symbolImage(NSString *name, CGFloat size, NSFontWeight weight = NSFontWeightMedium) {
    NSImageSymbolConfiguration *configuration = [NSImageSymbolConfiguration configurationWithPointSize:size weight:weight];
    NSImage *image = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
    if (image == nil) {
        image = [NSImage imageWithSystemSymbolName:@"questionmark.circle" accessibilityDescription:nil];
    }
    return [image imageWithSymbolConfiguration:configuration];
}

NSString *stringFromJson(const gw::claude::Json &object, const char *key) {
    if (!object.is_object()) {
        return @"";
    }
    auto found = object.find(key);
    if (found == object.end() || !found->is_string()) {
        return @"";
    }
    return @(found->get<std::string>().c_str()) ?: @"";
}

NSArray<NSString *> *linesOf(NSString *text) {
    if (text.length == 0) {
        return @[];
    }
    NSMutableArray<NSString *> *lines = [[text componentsSeparatedByString:@"\n"] mutableCopy];
    if (lines.count > 1 && [lines.lastObject length] == 0) {
        [lines removeLastObject];
    }
    return lines;
}

NSString *symbolForTool(const std::string &name) {
    if (name == "Read") return @"doc.text";
    if (name == "Write") return @"doc.badge.plus";
    if (name == "Edit" || name == "MultiEdit") return @"pencil";
    if (name == "NotebookEdit") return @"book";
    if (name == "Bash") return @"terminal";
    if (name == "Grep") return @"magnifyingglass";
    if (name == "Glob") return @"square.grid.2x2";
    if (name == "WebFetch" || name == "WebSearch") return @"globe";
    if (name == "Task" || name == "Agent") return @"person.2";
    if (name == "TodoWrite") return @"checklist";
    if (name == "ExitPlanMode") return @"list.bullet.clipboard";
    if (name == "AskUserQuestion") return @"questionmark.bubble";
    return @"wrench.and.screwdriver";
}

/// A rounded, softly tinted rectangle the chat uses for cards and bubbles.
void styleCard(NSView *view, CGFloat radius) {
    view.wantsLayer = YES;
    view.layer.cornerRadius = radius;
    view.layer.cornerCurve = kCACornerCurveContinuous;
    view.layer.borderWidth = 1;
}

}  // namespace

// ===========================================================================
// User messages

@implementation GWChatUserView {
    NSView *_bubble;
    GWAutoTextView *_text;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) {
        return nil;
    }
    self.translatesAutoresizingMaskIntoConstraints = NO;
    _bubble = [NSView new];
    styleCard(_bubble, 14);
    _bubble.translatesAutoresizingMaskIntoConstraints = NO;
    _text = [[GWAutoTextView alloc] initAutoSizing];
    [_bubble addSubview:_text];
    [self addSubview:_bubble];
    [NSLayoutConstraint activateConstraints:@[
        [_text.topAnchor constraintEqualToAnchor:_bubble.topAnchor constant:9],
        [_text.bottomAnchor constraintEqualToAnchor:_bubble.bottomAnchor constant:-9],
        [_text.leadingAnchor constraintEqualToAnchor:_bubble.leadingAnchor constant:13],
        [_text.trailingAnchor constraintEqualToAnchor:_bubble.trailingAnchor constant:-13],
        [_bubble.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_bubble.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_bubble.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_bubble.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.leadingAnchor constant:36],
    ]];
    [self updateColors];
    return self;
}

- (void)updateColors {
    [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
        self->_bubble.layer.backgroundColor = [NSColor.controlAccentColor colorWithAlphaComponent:0.20].CGColor;
        self->_bubble.layer.borderColor = [NSColor.controlAccentColor colorWithAlphaComponent:0.34].CGColor;
    }];
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self updateColors];
}

- (void)setText:(NSString *)text {
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.lineSpacing = 2.5;
    NSAttributedString *attributed = [[NSAttributedString alloc] initWithString:text attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:13.5],
        NSForegroundColorAttributeName: NSColor.labelColor,
        NSParagraphStyleAttributeName: style,
    }];
    [_text setAttributedContent:attributed];
}

@end

// ===========================================================================
// Notices

@implementation GWChatNoticeView {
    NSImageView *_icon;
    NSTextField *_label;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) {
        return nil;
    }
    self.translatesAutoresizingMaskIntoConstraints = NO;
    _icon = [NSImageView new];
    _icon.translatesAutoresizingMaskIntoConstraints = NO;
    _label = [NSTextField wrappingLabelWithString:@""];
    _label.font = [NSFont systemFontOfSize:12];
    _label.selectable = YES;
    _label.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_icon];
    [self addSubview:_label];
    [NSLayoutConstraint activateConstraints:@[
        [_icon.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:2],
        [_icon.topAnchor constraintEqualToAnchor:self.topAnchor constant:2],
        [_icon.widthAnchor constraintEqualToConstant:14],
        [_label.leadingAnchor constraintEqualToAnchor:_icon.trailingAnchor constant:7],
        [_label.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_label.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_label.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    ]];
    return self;
}

- (void)setText:(NSString *)text isError:(BOOL)isError {
    _label.stringValue = text;
    _label.textColor = isError ? NSColor.systemRedColor : NSColor.secondaryLabelColor;
    _icon.image = symbolImage(isError ? @"exclamationmark.triangle.fill" : @"info.circle", 11);
    _icon.contentTintColor = isError ? NSColor.systemRedColor : NSColor.tertiaryLabelColor;
}

@end

// ===========================================================================
// Working indicator

@implementation GWChatWorkingView {
    NSProgressIndicator *_spinner;
    NSTextField *_label;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) {
        return nil;
    }
    self.translatesAutoresizingMaskIntoConstraints = NO;
    _spinner = [NSProgressIndicator new];
    _spinner.style = NSProgressIndicatorStyleSpinning;
    _spinner.controlSize = NSControlSizeSmall;
    _spinner.translatesAutoresizingMaskIntoConstraints = NO;
    _label = [NSTextField labelWithString:@"Working…"];
    _label.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    _label.textColor = NSColor.secondaryLabelColor;
    _label.lineBreakMode = NSLineBreakByTruncatingTail;
    _label.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_spinner];
    [self addSubview:_label];
    [NSLayoutConstraint activateConstraints:@[
        [_spinner.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:2],
        [_spinner.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_spinner.widthAnchor constraintEqualToConstant:16],
        [_spinner.heightAnchor constraintEqualToConstant:16],
        [_label.leadingAnchor constraintEqualToAnchor:_spinner.trailingAnchor constant:8],
        [_label.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor],
        [_label.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [self.heightAnchor constraintEqualToConstant:22],
    ]];
    return self;
}

- (void)setText:(NSString *)text { _label.stringValue = text; }
- (void)startAnimating { [_spinner startAnimation:nil]; }
- (void)stopAnimating { [_spinner stopAnimation:nil]; }

@end

// ===========================================================================
// Thinking

@interface GWThinkingView : NSView
- (void)setText:(NSString *)text finished:(BOOL)finished;
@end

@implementation GWThinkingView {
    NSTextField *_label;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) {
        return nil;
    }
    self.translatesAutoresizingMaskIntoConstraints = NO;
    _label = [NSTextField wrappingLabelWithString:@""];
    _label.font = [NSFont systemFontOfSize:12];
    _label.textColor = NSColor.tertiaryLabelColor;
    _label.selectable = YES;
    _label.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_label];
    [NSLayoutConstraint activateConstraints:@[
        [_label.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_label.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_label.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:2],
        [_label.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    ]];
    return self;
}

- (void)setText:(NSString *)text finished:(BOOL)finished {
    // Claude's private reasoning is usually not sent, so only a hint is shown while it thinks.
    if (text.length > 0) {
        _label.stringValue = text;
        self.hidden = NO;
    } else if (!finished) {
        _label.stringValue = @"Thinking…";
        self.hidden = NO;
    } else {
        self.hidden = YES;
    }
}

@end

// ===========================================================================
// Tool cards

/// A tool Claude used (or wants to use): what it is, what it did, and, when it asks, the
/// buttons to allow or deny it.
@interface GWToolCardView : NSView
@property (nonatomic, copy, nullable) NSString *projectRoot;
@property (nonatomic, copy, nullable) void (^onOpenPath)(NSString *path, NSInteger line);
@property (nonatomic, copy, nullable) void (^onPermission)(NSString *requestId, GWPermissionChoice choice, NSString *_Nullable message);
- (void)updateWithTool:(const gw::claude::ToolCall &)tool turnIsRunning:(BOOL)running;
@end

@implementation GWToolCardView {
    NSImageView *_icon;
    NSTextField *_title;
    NSTextField *_detail;
    NSTextField *_counts;
    NSImageView *_status;
    NSProgressIndicator *_spinner;
    NSButton *_openButton;
    NSImageView *_chevron;
    NSView *_header;

    NSStackView *_stack;
    NSView *_detailContainer;
    NSView *_detailContent;
    NSView *_permissionRow;
    NSTextField *_permissionText;
    NSButton *_denyButton;
    NSButton *_allowButton;
    NSButton *_allowAllButton;

    BOOL _expanded;
    BOOL _userToggled;
    std::string _requestId;
    std::string _toolName;
    std::string _filePath;
    NSString *_detailSignature;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) {
        return nil;
    }
    self.translatesAutoresizingMaskIntoConstraints = NO;
    styleCard(self, 10);
    [self buildViews];
    [self updateColors];
    return self;
}

- (void)updateColors {
    [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
        self.layer.backgroundColor = [NSColor.labelColor colorWithAlphaComponent:0.05].CGColor;
        self.layer.borderColor = [NSColor.labelColor colorWithAlphaComponent:0.10].CGColor;
    }];
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self updateColors];
}

- (NSTextField *)labelWithSize:(CGFloat)size weight:(NSFontWeight)weight color:(NSColor *)color {
    NSTextField *label = [NSTextField labelWithString:@""];
    label.font = [NSFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    label.lineBreakMode = NSLineBreakByTruncatingMiddle;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

- (void)buildViews {
    // Header
    _header = [NSView new];
    _header.translatesAutoresizingMaskIntoConstraints = NO;
    _icon = [NSImageView new];
    _icon.translatesAutoresizingMaskIntoConstraints = NO;
    _icon.contentTintColor = NSColor.secondaryLabelColor;
    _title = [self labelWithSize:12.5 weight:NSFontWeightSemibold color:NSColor.labelColor];
    _detail = [self labelWithSize:12.5 weight:NSFontWeightRegular color:NSColor.secondaryLabelColor];
    [_detail setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    _counts = [self labelWithSize:11.5 weight:NSFontWeightMedium color:NSColor.tertiaryLabelColor];
    _status = [NSImageView new];
    _status.translatesAutoresizingMaskIntoConstraints = NO;
    _spinner = [NSProgressIndicator new];
    _spinner.style = NSProgressIndicatorStyleSpinning;
    _spinner.controlSize = NSControlSizeSmall;
    _spinner.translatesAutoresizingMaskIntoConstraints = NO;
    _spinner.hidden = YES;
    _openButton = [NSButton buttonWithImage:symbolImage(@"arrow.up.right.square", 11) target:self action:@selector(openClicked:)];
    _openButton.bordered = NO;
    _openButton.contentTintColor = NSColor.secondaryLabelColor;
    _openButton.toolTip = @"Open the file";
    _openButton.translatesAutoresizingMaskIntoConstraints = NO;
    _openButton.hidden = YES;
    _chevron = [NSImageView imageViewWithImage:symbolImage(@"chevron.right", 9, NSFontWeightBold)];
    _chevron.contentTintColor = NSColor.tertiaryLabelColor;
    _chevron.translatesAutoresizingMaskIntoConstraints = NO;

    for (NSView *view in @[_icon, _title, _detail, _counts, _openButton, _spinner, _status, _chevron]) {
        [_header addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [_header.heightAnchor constraintEqualToConstant:32],
        [_icon.leadingAnchor constraintEqualToAnchor:_header.leadingAnchor constant:10],
        [_icon.centerYAnchor constraintEqualToAnchor:_header.centerYAnchor],
        [_icon.widthAnchor constraintEqualToConstant:16],
        [_title.leadingAnchor constraintEqualToAnchor:_icon.trailingAnchor constant:8],
        [_title.centerYAnchor constraintEqualToAnchor:_header.centerYAnchor],
        [_detail.leadingAnchor constraintEqualToAnchor:_title.trailingAnchor constant:6],
        [_detail.centerYAnchor constraintEqualToAnchor:_header.centerYAnchor],
        [_counts.leadingAnchor constraintGreaterThanOrEqualToAnchor:_detail.trailingAnchor constant:8],
        [_counts.centerYAnchor constraintEqualToAnchor:_header.centerYAnchor],
        [_openButton.leadingAnchor constraintEqualToAnchor:_counts.trailingAnchor constant:4],
        [_openButton.centerYAnchor constraintEqualToAnchor:_header.centerYAnchor],
        [_openButton.widthAnchor constraintEqualToConstant:20],
        [_status.leadingAnchor constraintEqualToAnchor:_openButton.trailingAnchor constant:4],
        [_status.centerYAnchor constraintEqualToAnchor:_header.centerYAnchor],
        [_status.widthAnchor constraintEqualToConstant:16],
        [_spinner.centerXAnchor constraintEqualToAnchor:_status.centerXAnchor],
        [_spinner.centerYAnchor constraintEqualToAnchor:_status.centerYAnchor],
        [_spinner.widthAnchor constraintEqualToConstant:14],
        [_spinner.heightAnchor constraintEqualToConstant:14],
        [_chevron.leadingAnchor constraintEqualToAnchor:_status.trailingAnchor constant:6],
        [_chevron.trailingAnchor constraintEqualToAnchor:_header.trailingAnchor constant:-10],
        [_chevron.centerYAnchor constraintEqualToAnchor:_header.centerYAnchor],
        [_chevron.widthAnchor constraintEqualToConstant:10],
    ]];
    NSClickGestureRecognizer *click = [[NSClickGestureRecognizer alloc] initWithTarget:self action:@selector(headerClicked:)];
    [_header addGestureRecognizer:click];

    // Detail: the diff, command or plan.
    _detailContainer = [NSView new];
    _detailContainer.translatesAutoresizingMaskIntoConstraints = NO;
    _detailContainer.hidden = YES;

    // Permission row
    _permissionRow = [NSView new];
    _permissionRow.translatesAutoresizingMaskIntoConstraints = NO;
    _permissionRow.hidden = YES;
    _permissionText = [self labelWithSize:12 weight:NSFontWeightMedium color:NSColor.secondaryLabelColor];
    _permissionText.lineBreakMode = NSLineBreakByTruncatingTail;
    _denyButton = [NSButton buttonWithTitle:@"Deny" target:self action:@selector(denyClicked:)];
    _allowButton = [NSButton buttonWithTitle:@"Allow" target:self action:@selector(allowClicked:)];
    _allowAllButton = [NSButton buttonWithTitle:@"Allow all edits" target:self action:@selector(allowAllClicked:)];
    for (NSButton *button in @[_denyButton, _allowButton, _allowAllButton]) {
        button.bezelStyle = NSBezelStyleGlass;
        button.controlSize = NSControlSizeSmall;
        button.translatesAutoresizingMaskIntoConstraints = NO;
    }
    _allowButton.bezelColor = NSColor.controlAccentColor;
    NSStackView *buttons = [NSStackView stackViewWithViews:@[_denyButton, _allowAllButton, _allowButton]];
    buttons.spacing = 6;
    buttons.translatesAutoresizingMaskIntoConstraints = NO;
    [_permissionRow addSubview:_permissionText];
    [_permissionRow addSubview:buttons];
    [NSLayoutConstraint activateConstraints:@[
        [_permissionRow.heightAnchor constraintEqualToConstant:38],
        [_permissionText.leadingAnchor constraintEqualToAnchor:_permissionRow.leadingAnchor constant:12],
        [_permissionText.centerYAnchor constraintEqualToAnchor:_permissionRow.centerYAnchor],
        [buttons.trailingAnchor constraintEqualToAnchor:_permissionRow.trailingAnchor constant:-10],
        [buttons.centerYAnchor constraintEqualToAnchor:_permissionRow.centerYAnchor],
        [_permissionText.trailingAnchor constraintLessThanOrEqualToAnchor:buttons.leadingAnchor constant:-8],
    ]];

    _stack = [NSStackView stackViewWithViews:@[_header, _detailContainer, _permissionRow]];
    _stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    _stack.alignment = NSLayoutAttributeLeading;
    _stack.spacing = 0;
    _stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_stack];
    [NSLayoutConstraint activateConstraints:@[
        [_stack.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_header.widthAnchor constraintEqualToAnchor:_stack.widthAnchor],
        [_detailContainer.widthAnchor constraintEqualToAnchor:_stack.widthAnchor],
        [_permissionRow.widthAnchor constraintEqualToAnchor:_stack.widthAnchor],
    ]];
}

// ---------------------------------------------------------------------------
// MARK: Content

/// The lines of a unified patch (from Claude Code's result), colored by kind.
- (NSAttributedString *)patchText:(const gw::claude::Json &)patch {
    NSFont *font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.lineBreakMode = NSLineBreakByCharWrapping;
    NSMutableAttributedString *text = [NSMutableAttributedString new];
    NSColor *removedBackground = [NSColor colorWithSRGBRed:0.97 green:0.32 blue:0.29 alpha:0.20];
    NSColor *addedBackground = [NSColor colorWithSRGBRed:0.25 green:0.73 blue:0.31 alpha:0.20];

    NSUInteger shownLines = 0;
    for (const auto &hunk : patch) {
        if (!hunk.is_object() || !hunk.contains("lines") || !hunk["lines"].is_array()) {
            continue;
        }
        if (text.length > 0) {
            [text appendAttributedString:[[NSAttributedString alloc] initWithString:@"⋯\n" attributes:@{
                NSFontAttributeName: font, NSForegroundColorAttributeName: NSColor.tertiaryLabelColor, NSParagraphStyleAttributeName: style}]];
        }
        for (const auto &lineValue : hunk["lines"]) {
            if (!lineValue.is_string() || shownLines >= 80) {
                continue;
            }
            NSString *line = @(lineValue.get<std::string>().c_str()) ?: @"";
            unichar marker = line.length > 0 ? [line characterAtIndex:0] : ' ';
            NSColor *background = nil;
            NSColor *foreground = NSColor.secondaryLabelColor;
            if (marker == '+') {
                background = addedBackground;
                foreground = NSColor.labelColor;
            } else if (marker == '-') {
                background = removedBackground;
                foreground = NSColor.labelColor;
            }
            NSMutableDictionary *attributes = [@{NSFontAttributeName: font, NSForegroundColorAttributeName: foreground,
                                                 NSParagraphStyleAttributeName: style} mutableCopy];
            if (background != nil) {
                attributes[NSBackgroundColorAttributeName] = background;
            }
            [text appendAttributedString:[[NSAttributedString alloc] initWithString:[line stringByAppendingString:@"\n"] attributes:attributes]];
            ++shownLines;
        }
    }
    return text;
}

/// A short preview of what a tool will do or did, or nil if there is nothing to show.
- (NSView *)detailViewForTool:(const gw::claude::ToolCall &)tool signature:(NSString **)signature {
    const gw::claude::Json &input = tool.input;
    NSMutableString *sig = [NSMutableString stringWithFormat:@"%zu|%d|%zu|", tool.inputText.size(), tool.hasResult, tool.resultText.size()];

    // Edits: prefer Claude Code's own patch, which has context lines.
    if (tool.changesFiles()) {
        NSAttributedString *diff = nil;
        if (tool.hasResult && tool.resultDetail.is_object() && tool.resultDetail.contains("structuredPatch") &&
            tool.resultDetail["structuredPatch"].is_array() && !tool.resultDetail["structuredPatch"].empty()) {
            diff = [self patchText:tool.resultDetail["structuredPatch"]];
        } else if (tool.inputComplete && input.is_object()) {
            NSArray<NSString *> *oldLines = @[];
            NSArray<NSString *> *newLines = @[];
            if (tool.name == "Edit") {
                oldLines = linesOf(stringFromJson(input, "old_string"));
                newLines = linesOf(stringFromJson(input, "new_string"));
            } else if (tool.name == "MultiEdit" && input.contains("edits") && input["edits"].is_array()) {
                NSMutableArray<NSString *> *olds = [NSMutableArray array];
                NSMutableArray<NSString *> *news = [NSMutableArray array];
                for (const auto &edit : input["edits"]) {
                    [olds addObjectsFromArray:linesOf(stringFromJson(edit, "old_string"))];
                    [news addObjectsFromArray:linesOf(stringFromJson(edit, "new_string"))];
                }
                oldLines = olds;
                newLines = news;
            } else if (tool.name == "Write") {
                newLines = linesOf(stringFromJson(input, "content"));
            }
            if (oldLines.count > 0 || newLines.count > 0) {
                NSMutableAttributedString *text = [GWDiffAttributedText(oldLines, newLines, 11) mutableCopy];
                NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
                style.lineBreakMode = NSLineBreakByCharWrapping;
                [text addAttribute:NSParagraphStyleAttributeName value:style range:NSMakeRange(0, text.length)];
                diff = text;
            }
        }
        if (diff != nil && diff.length > 0) {
            [sig appendFormat:@"diff%lu", static_cast<unsigned long>(diff.length)];
            *signature = sig;
            GWAutoTextView *view = [[GWAutoTextView alloc] initAutoSizing];
            [view setAttributedContent:diff];
            return view;
        }
    }

    if (tool.name == "Bash" && tool.inputComplete && input.is_object()) {
        NSString *command = stringFromJson(input, "command");
        NSMutableString *body = [NSMutableString stringWithFormat:@"$ %@", command];
        if (tool.hasResult && tool.resultText.size() > 0) {
            NSArray<NSString *> *lines = linesOf(@(tool.resultText.c_str()) ?: @"");
            NSUInteger shown = MIN(lines.count, 24UL);
            [body appendString:@"\n"];
            [body appendString:[[lines subarrayWithRange:NSMakeRange(0, shown)] componentsJoinedByString:@"\n"]];
            if (lines.count > shown) {
                [body appendFormat:@"\n… %lu more lines", static_cast<unsigned long>(lines.count - shown)];
            }
        }
        [sig appendFormat:@"bash%lu", static_cast<unsigned long>(body.length)];
        *signature = sig;
        NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
        style.lineBreakMode = NSLineBreakByCharWrapping;
        NSColor *color = tool.hasResult && tool.resultIsError ? NSColor.systemRedColor : NSColor.labelColor;
        NSAttributedString *text = [[NSAttributedString alloc] initWithString:body attributes:@{
            NSFontAttributeName: [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular],
            NSForegroundColorAttributeName: color,
            NSParagraphStyleAttributeName: style,
        }];
        GWAutoTextView *view = [[GWAutoTextView alloc] initAutoSizing];
        [view setAttributedContent:text];
        return view;
    }

    if (tool.name == "ExitPlanMode" && input.is_object()) {
        NSString *plan = stringFromJson(input, "plan");
        if (plan.length > 0) {
            [sig appendFormat:@"plan%lu", static_cast<unsigned long>(plan.length)];
            *signature = sig;
            GWMarkdownView *markdown = [GWMarkdownView new];
            markdown.fontSize = 12.5;
            markdown.projectRoot = self.projectRoot;
            markdown.translatesAutoresizingMaskIntoConstraints = NO;
            [markdown setMarkdown:plan];
            return markdown;
        }
    }

    // Failures are worth showing for any tool.
    if (tool.hasResult && tool.resultIsError && !tool.resultText.empty()) {
        [sig appendString:@"error"];
        *signature = sig;
        GWAutoTextView *view = [[GWAutoTextView alloc] initAutoSizing];
        [view setAttributedContent:[[NSAttributedString alloc] initWithString:@(tool.resultText.c_str()) ?: @"" attributes:@{
            NSFontAttributeName: [NSFont systemFontOfSize:11.5],
            NSForegroundColorAttributeName: NSColor.systemRedColor,
        }]];
        return view;
    }
    *signature = sig;
    return nil;
}

- (void)updateWithTool:(const gw::claude::ToolCall &)tool turnIsRunning:(BOOL)running {
    _toolName = tool.name;
    _filePath = tool.filePath();
    _requestId = tool.permissionRequestId;

    _icon.image = symbolImage(symbolForTool(tool.name), 12);

    // "Edit  hello.txt" → bold "Edit" and quieter "hello.txt".
    std::string summary = tool.summary();
    size_t gap = summary.find("  ");
    NSString *name = @(tool.name.c_str());
    NSString *rest = @"";
    if (gap != std::string::npos) {
        rest = @(summary.substr(gap + 2).c_str()) ?: @"";
    }
    _title.stringValue = tool.name == "ExitPlanMode" ? @"Plan" : (name ?: @"Tool");
    _detail.stringValue = rest;
    _detail.toolTip = @(_filePath.c_str());
    _openButton.hidden = _filePath.empty();

    // Status glyph.
    _spinner.hidden = YES;
    [_spinner stopAnimation:nil];
    _status.hidden = NO;
    NSString *statusSymbol = nil;
    NSColor *statusColor = NSColor.tertiaryLabelColor;
    BOOL pending = tool.approval == gw::claude::Approval::Pending;
    if (pending) {
        statusSymbol = @"lock.fill";
        statusColor = NSColor.systemOrangeColor;
    } else if (tool.approval == gw::claude::Approval::Denied && (!tool.hasResult || tool.resultIsError)) {
        statusSymbol = @"nosign";
        statusColor = NSColor.systemRedColor;
    } else if (tool.hasResult && tool.resultIsError) {
        statusSymbol = @"xmark.circle.fill";
        statusColor = NSColor.systemRedColor;
    } else if (tool.hasResult) {
        statusSymbol = @"checkmark.circle.fill";
        statusColor = [NSColor.systemGreenColor colorWithAlphaComponent:0.85];
    } else if (running) {
        _status.hidden = YES;
        _spinner.hidden = NO;
        [_spinner startAnimation:nil];
    }
    if (statusSymbol != nil) {
        _status.image = symbolImage(statusSymbol, 12);
        _status.contentTintColor = statusColor;
    }

    // Detail
    NSString *signature = nil;
    NSView *detail = [self detailViewForTool:tool signature:&signature];
    if (![signature isEqualToString:_detailSignature]) {
        _detailSignature = signature;
        [_detailContent removeFromSuperview];
        _detailContent = detail;
        if (detail != nil) {
            [_detailContainer addSubview:detail];
            detail.translatesAutoresizingMaskIntoConstraints = NO;
            [NSLayoutConstraint activateConstraints:@[
                [detail.topAnchor constraintEqualToAnchor:_detailContainer.topAnchor constant:2],
                [detail.bottomAnchor constraintEqualToAnchor:_detailContainer.bottomAnchor constant:-10],
                [detail.leadingAnchor constraintEqualToAnchor:_detailContainer.leadingAnchor constant:12],
                [detail.trailingAnchor constraintEqualToAnchor:_detailContainer.trailingAnchor constant:-12],
            ]];
        }
    }

    // Change counts next to the name, from what the edit did.
    _counts.stringValue = @"";
    if (tool.changesFiles() && tool.inputComplete && tool.input.is_object()) {
        NSUInteger removed = 0;
        NSUInteger added = 0;
        if (tool.name == "Edit") {
            removed = linesOf(stringFromJson(tool.input, "old_string")).count;
            added = linesOf(stringFromJson(tool.input, "new_string")).count;
        } else if (tool.name == "Write") {
            added = linesOf(stringFromJson(tool.input, "content")).count;
        }
        if (added > 0 || removed > 0) {
            _counts.stringValue = [NSString stringWithFormat:@"+%lu  −%lu", static_cast<unsigned long>(added), static_cast<unsigned long>(removed)];
        }
    }

    // Permission row
    _permissionRow.hidden = !pending;
    if (pending) {
        NSString *question = nil;
        NSString *file = _filePath.empty() ? @"" : [@(_filePath.c_str()) lastPathComponent];
        if (tool.name == "Bash") {
            question = @"Run this command?";
        } else if (tool.name == "ExitPlanMode") {
            question = @"Start with this plan?";
        } else if (tool.changesFiles()) {
            question = file.length > 0 ? [NSString stringWithFormat:@"Change %@?", file] : @"Make this change?";
        } else {
            question = [NSString stringWithFormat:@"Allow %@?", name];
        }
        _permissionText.stringValue = question;
        _allowAllButton.hidden = !tool.changesFiles();
        if (tool.name == "ExitPlanMode") {
            _allowButton.title = @"Approve";
            _denyButton.title = @"Keep planning";
        } else {
            _allowButton.title = @"Allow";
            _denyButton.title = @"Deny";
        }
    }

    // Open while asking, so the user sees what they are approving; otherwise closed unless
    // they opened it themselves.
    BOOL hasDetail = _detailContent != nil;
    if (!_userToggled) {
        _expanded = pending && hasDetail;
    }
    [self applyExpansion];
    _chevron.hidden = !hasDetail;
}

- (void)applyExpansion {
    BOOL show = _expanded && _detailContent != nil;
    _detailContainer.hidden = !show;
    _chevron.image = symbolImage(show ? @"chevron.down" : @"chevron.right", 9, NSFontWeightBold);
}

// ---------------------------------------------------------------------------
// MARK: Actions

- (void)headerClicked:(NSClickGestureRecognizer *)gesture {
    if (_detailContent == nil) {
        return;
    }
    _userToggled = YES;
    _expanded = !_expanded;
    [self applyExpansion];
}

- (void)openClicked:(id)sender {
    if (!_filePath.empty() && self.onOpenPath) {
        self.onOpenPath(@(_filePath.c_str()), 0);
    }
}

- (void)denyClicked:(id)sender {
    if (self.onPermission) {
        NSString *message = _toolName == "ExitPlanMode" ? @"The user wants to keep planning. Ask what to change." : nil;
        self.onPermission(@(_requestId.c_str()), GWPermissionChoiceDeny, message);
    }
}

- (void)allowClicked:(id)sender {
    if (self.onPermission) {
        self.onPermission(@(_requestId.c_str()), GWPermissionChoiceAllow, nil);
    }
}

- (void)allowAllClicked:(id)sender {
    if (self.onPermission) {
        self.onPermission(@(_requestId.c_str()), GWPermissionChoiceAllowAllEdits, nil);
    }
}

@end

// ===========================================================================
// Assistant messages

@implementation GWChatAssistantView {
    NSStackView *_stack;
    NSMutableArray<NSView *> *_blockViews;
    NSMutableArray<NSNumber *> *_blockKinds;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) {
        return nil;
    }
    self.translatesAutoresizingMaskIntoConstraints = NO;
    _blockViews = [NSMutableArray array];
    _blockKinds = [NSMutableArray array];
    _stack = [NSStackView new];
    _stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    _stack.alignment = NSLayoutAttributeLeading;
    _stack.spacing = 8;
    _stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_stack];
    [NSLayoutConstraint activateConstraints:@[
        [_stack.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    ]];
    return self;
}

- (NSView *)makeViewForBlockKind:(gw::claude::Block::Kind)kind {
    __weak GWChatAssistantView *weakSelf = self;
    switch (kind) {
        case gw::claude::Block::Kind::Text: {
            GWMarkdownView *markdown = [GWMarkdownView new];
            markdown.translatesAutoresizingMaskIntoConstraints = NO;
            markdown.projectRoot = self.projectRoot;
            markdown.onOpenPath = ^(NSString *path, NSInteger line) {
                if (weakSelf.onOpenPath) {
                    weakSelf.onOpenPath(path, line);
                }
            };
            markdown.onInsertCode = ^(NSString *code) {
                if (weakSelf.onInsertCode) {
                    weakSelf.onInsertCode(code);
                }
            };
            return markdown;
        }
        case gw::claude::Block::Kind::Thinking:
            return [GWThinkingView new];
        case gw::claude::Block::Kind::Tool: {
            GWToolCardView *card = [GWToolCardView new];
            card.projectRoot = self.projectRoot;
            card.onOpenPath = ^(NSString *path, NSInteger line) {
                if (weakSelf.onOpenPath) {
                    weakSelf.onOpenPath(path, line);
                }
            };
            card.onPermission = ^(NSString *requestId, GWPermissionChoice choice, NSString *message) {
                if (weakSelf.onPermission) {
                    weakSelf.onPermission(requestId, choice, message);
                }
            };
            return card;
        }
    }
    return nil;
}

- (void)updateWithMessage:(const gw::claude::Message &)message turnIsRunning:(BOOL)running {
    // Drop views from the first block whose kind no longer matches.
    NSUInteger keep = 0;
    while (keep < message.blocks.size() && keep < _blockViews.count &&
           _blockKinds[keep].integerValue == static_cast<NSInteger>(message.blocks[keep].kind)) {
        ++keep;
    }
    while (_blockViews.count > keep) {
        [_blockViews.lastObject removeFromSuperview];
        [_blockViews removeLastObject];
        [_blockKinds removeLastObject];
    }
    for (size_t index = keep; index < message.blocks.size(); ++index) {
        NSView *view = [self makeViewForBlockKind:message.blocks[index].kind];
        [_stack addArrangedSubview:view];
        // Text and cards use the full width; the stack's leading alignment keeps them left.
        [view.widthAnchor constraintEqualToAnchor:_stack.widthAnchor].active = YES;
        [_blockViews addObject:view];
        [_blockKinds addObject:@(static_cast<NSInteger>(message.blocks[index].kind))];
    }

    for (size_t index = 0; index < message.blocks.size(); ++index) {
        const gw::claude::Block &block = message.blocks[index];
        NSView *view = _blockViews[index];
        switch (block.kind) {
            case gw::claude::Block::Kind::Text:
                ((GWMarkdownView *)view).projectRoot = self.projectRoot;
                [(GWMarkdownView *)view setMarkdown:@(block.text.c_str()) ?: @""];
                break;
            case gw::claude::Block::Kind::Thinking:
                [(GWThinkingView *)view setText:@(block.text.c_str()) ?: @"" finished:block.finished];
                break;
            case gw::claude::Block::Kind::Tool:
                [(GWToolCardView *)view updateWithTool:block.tool turnIsRunning:running && !block.tool.hasResult];
                break;
        }
    }
}

@end
