#import "MarkdownView.h"
#import "Strings.h"

#import "CodeHighlight.h"
#import "Services.h"

#include "Markdown.hpp"

#include <vector>

// ===========================================================================
// A text view that sizes itself

@implementation GWAutoTextView

- (instancetype)initAutoSizing {
    NSTextStorage *storage = [NSTextStorage new];
    NSLayoutManager *layoutManager = [NSLayoutManager new];
    NSTextContainer *container = [[NSTextContainer alloc] initWithSize:NSMakeSize(300, CGFLOAT_MAX)];
    container.lineFragmentPadding = 0;
    container.widthTracksTextView = YES;
    [storage addLayoutManager:layoutManager];
    [layoutManager addTextContainer:container];

    self = [super initWithFrame:NSMakeRect(0, 0, 300, 20) textContainer:container];
    if (self) {
        self.editable = NO;
        self.selectable = YES;
        self.drawsBackground = NO;
        self.textContainerInset = NSZeroSize;
        self.horizontallyResizable = NO;
        self.verticallyResizable = NO;
        self.usesFontPanel = NO;
        self.delegate = self;
        self.linkTextAttributes = @{
            NSForegroundColorAttributeName: NSColor.linkColor,
            NSCursorAttributeName: NSCursor.pointingHandCursor,
        };
        self.translatesAutoresizingMaskIntoConstraints = NO;
        [self setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    }
    return self;
}

- (NSSize)intrinsicContentSize {
    [self.layoutManager ensureLayoutForTextContainer:self.textContainer];
    NSRect used = [self.layoutManager usedRectForTextContainer:self.textContainer];
    return NSMakeSize(NSViewNoIntrinsicMetric, ceil(used.size.height));
}

- (void)setFrameSize:(NSSize)newSize {
    BOOL widthChanged = fabs(newSize.width - self.frame.size.width) > 0.5;
    [super setFrameSize:newSize];
    if (widthChanged) {
        [self invalidateIntrinsicContentSize];
    }
}

- (void)setAttributedContent:(NSAttributedString *)text {
    [self.textStorage setAttributedString:text];
    [self invalidateIntrinsicContentSize];
}

- (BOOL)textView:(NSTextView *)textView clickedOnLink:(id)link atIndex:(NSUInteger)charIndex {
    NSURL *url = [link isKindOfClass:NSURL.class] ? link : [NSURL URLWithString:[link description]];
    if (self.onLink != nil && url != nil && self.onLink(url)) {
        return YES;
    }
    return NO;
}

@end

// ===========================================================================
// Pieces

/// A horizontal scroller that hands vertical scrolling to whoever contains it, so scrolling
/// the chat isn't swallowed when the pointer is over a code block.
@interface GWHorizontalScrollView : NSScrollView
@end

@implementation GWHorizontalScrollView

- (void)scrollWheel:(NSEvent *)event {
    if (fabs(event.scrollingDeltaY) > fabs(event.scrollingDeltaX)) {
        [self.nextResponder scrollWheel:event];
        return;
    }
    [super scrollWheel:event];
}

@end

/// A code block: header with the language and buttons, then the colored code.
@interface GWCodeBlockView : NSView
@property (nonatomic, copy, nullable) void (^onInsert)(NSString *code);
@property (nonatomic, readonly) NSString *code;
- (void)setCode:(NSString *)code language:(NSString *)language fontSize:(CGFloat)fontSize;
@end

@implementation GWCodeBlockView {
    NSTextField *_languageLabel;
    NSButton *_copyButton;
    NSButton *_insertButton;
    GWHorizontalScrollView *_scroll;
    GWAutoTextView *_text;
    NSLayoutConstraint *_heightConstraint;
    NSString *_code;
}

- (NSString *)code { return _code; }

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) {
        return nil;
    }
    self.wantsLayer = YES;
    self.layer.cornerRadius = 10;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.borderWidth = 1;
    self.translatesAutoresizingMaskIntoConstraints = NO;

    _languageLabel = [NSTextField labelWithString:@""];
    _languageLabel.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightSemibold];
    _languageLabel.textColor = NSColor.tertiaryLabelColor;
    _languageLabel.translatesAutoresizingMaskIntoConstraints = NO;

    _copyButton = [self headerButtonWithSymbol:@"doc.on.doc" tip:@"Copy" action:@selector(copyClicked:)];
    _insertButton = [self headerButtonWithSymbol:@"arrow.down.left.square" tip:@"Insert at the cursor" action:@selector(insertClicked:)];

    _text = [[GWAutoTextView alloc] initAutoSizing];
    _text.translatesAutoresizingMaskIntoConstraints = YES;
    _text.textContainer.widthTracksTextView = NO;
    _text.textContainer.containerSize = NSMakeSize(100000, CGFLOAT_MAX);
    _text.textContainerInset = NSMakeSize(12, 8);
    _text.horizontallyResizable = YES;

    _scroll = [GWHorizontalScrollView new];
    _scroll.documentView = _text;
    _scroll.drawsBackground = NO;
    _scroll.hasVerticalScroller = NO;
    _scroll.hasHorizontalScroller = YES;
    _scroll.autohidesScrollers = YES;
    _scroll.scrollerStyle = NSScrollerStyleOverlay;
    _scroll.borderType = NSNoBorder;
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;

    for (NSView *view in @[_languageLabel, _copyButton, _insertButton, _scroll]) {
        [self addSubview:view];
    }
    _heightConstraint = [_scroll.heightAnchor constraintEqualToConstant:40];
    [NSLayoutConstraint activateConstraints:@[
        [_languageLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:7],
        [_languageLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
        [_copyButton.centerYAnchor constraintEqualToAnchor:_languageLabel.centerYAnchor],
        [_copyButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8],
        [_insertButton.centerYAnchor constraintEqualToAnchor:_languageLabel.centerYAnchor],
        [_insertButton.trailingAnchor constraintEqualToAnchor:_copyButton.leadingAnchor constant:-2],
        [_scroll.topAnchor constraintEqualToAnchor:self.topAnchor constant:22],
        [_scroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_scroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_scroll.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-2],
        _heightConstraint,
    ]];
    [self updateColors];
    return self;
}

- (NSButton *)headerButtonWithSymbol:(NSString *)symbol tip:(NSString *)tip action:(SEL)action {
    NSImageSymbolConfiguration *configuration = [NSImageSymbolConfiguration configurationWithPointSize:11 weight:NSFontWeightMedium];
    NSImage *image = [[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:tip] imageWithSymbolConfiguration:configuration];
    NSButton *button = [NSButton buttonWithImage:image target:self action:action];
    button.bordered = NO;
    button.contentTintColor = NSColor.secondaryLabelColor;
    button.toolTip = tip;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button.widthAnchor constraintEqualToConstant:24].active = YES;
    [button.heightAnchor constraintEqualToConstant:22].active = YES;
    return button;
}

- (void)updateColors {
    [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
        NSColor *background = [GWServices.shared color:@"editor.background" fallback:NSColor.textBackgroundColor];
        self.layer.backgroundColor = [background colorWithAlphaComponent:0.55].CGColor;
        self.layer.borderColor = [NSColor.labelColor colorWithAlphaComponent:0.10].CGColor;
    }];
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self updateColors];
}

- (void)setCode:(NSString *)code language:(NSString *)language fontSize:(CGFloat)fontSize {
    _code = [code copy];
    NSString *name = language.length > 0 ? language : @"code";
    NSString *languageId = GWLanguageForFenceTag(language);
    if (languageId.length > 0) {
        NSString *friendly = StringFromUTF8(GWServices.shared.extensions.languageName(languageId.UTF8String));
        if (friendly.length > 0) {
            name = friendly;
        }
    }
    _languageLabel.stringValue = name.uppercaseString;
    _insertButton.hidden = self.onInsert == nil;

    NSAttributedString *attributed = GWHighlightedCode(code, language, fontSize);
    [_text setAttributedContent:attributed];
    [_text.layoutManager ensureLayoutForTextContainer:_text.textContainer];
    NSRect used = [_text.layoutManager usedRectForTextContainer:_text.textContainer];
    NSSize inset = _text.textContainerInset;
    CGFloat width = ceil(used.size.width) + inset.width * 2 + 4;
    CGFloat height = ceil(used.size.height) + inset.height * 2;
    _text.frame = NSMakeRect(0, 0, MAX(width, 200), height);
    _heightConstraint.constant = height;
}

- (void)copyClicked:(id)sender {
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:_code ?: @"" forType:NSPasteboardTypeString];
    NSImageSymbolConfiguration *configuration = [NSImageSymbolConfiguration configurationWithPointSize:11 weight:NSFontWeightSemibold];
    _copyButton.image = [[NSImage imageWithSystemSymbolName:@"checkmark" accessibilityDescription:@"Copied"] imageWithSymbolConfiguration:configuration];
    _copyButton.contentTintColor = NSColor.systemGreenColor;
    __weak GWCodeBlockView *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        GWCodeBlockView *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        NSImageSymbolConfiguration *normal = [NSImageSymbolConfiguration configurationWithPointSize:11 weight:NSFontWeightMedium];
        strongSelf->_copyButton.image = [[NSImage imageWithSystemSymbolName:@"doc.on.doc" accessibilityDescription:@"Copy"]
            imageWithSymbolConfiguration:normal];
        strongSelf->_copyButton.contentTintColor = NSColor.secondaryLabelColor;
    });
}

- (void)insertClicked:(id)sender {
    if (self.onInsert) {
        self.onInsert(_code ?: @"");
    }
}

@end

/// A quote: a bar down the left and quieter text.
@interface GWQuoteView : NSView
@property (nonatomic, readonly) GWAutoTextView *text;
@end

@implementation GWQuoteView {
    NSView *_bar;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        _bar = [NSView new];
        _bar.wantsLayer = YES;
        _bar.layer.cornerRadius = 1.5;
        _bar.translatesAutoresizingMaskIntoConstraints = NO;
        _text = [[GWAutoTextView alloc] initAutoSizing];
        [self addSubview:_bar];
        [self addSubview:_text];
        [NSLayoutConstraint activateConstraints:@[
            [_bar.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:2],
            [_bar.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_bar.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [_bar.widthAnchor constraintEqualToConstant:3],
            [_text.leadingAnchor constraintEqualToAnchor:_bar.trailingAnchor constant:10],
            [_text.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_text.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_text.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        ]];
        [self updateColors];
    }
    return self;
}

- (void)updateColors {
    [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
        self->_bar.layer.backgroundColor = [NSColor.controlAccentColor colorWithAlphaComponent:0.55].CGColor;
    }];
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self updateColors];
}

@end

/// A table: cells in a grid inside a soft border.
@interface GWTableView : NSView
- (void)setRows:(NSArray<NSArray<NSAttributedString *> *> *)rows alignments:(NSString *)alignments hasHeader:(BOOL)hasHeader;
@end

@implementation GWTableView {
    NSGridView *_grid;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.wantsLayer = YES;
        self.layer.cornerRadius = 8;
        self.layer.borderWidth = 1;
        [self updateColors];
    }
    return self;
}

- (void)updateColors {
    [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
        self.layer.borderColor = [NSColor.labelColor colorWithAlphaComponent:0.12].CGColor;
    }];
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self updateColors];
}

- (void)setRows:(NSArray<NSArray<NSAttributedString *> *> *)rows alignments:(NSString *)alignments hasHeader:(BOOL)hasHeader {
    [_grid removeFromSuperview];
    NSUInteger columns = 0;
    for (NSArray *row in rows) {
        columns = MAX(columns, row.count);
    }
    if (columns == 0 || rows.count == 0) {
        return;
    }
    NSMutableArray<NSArray<NSView *> *> *cellRows = [NSMutableArray array];
    for (NSUInteger rowIndex = 0; rowIndex < rows.count; ++rowIndex) {
        NSMutableArray<NSView *> *cells = [NSMutableArray array];
        for (NSUInteger column = 0; column < columns; ++column) {
            NSAttributedString *content = column < rows[rowIndex].count ? rows[rowIndex][column] : [NSAttributedString new];
            NSTextField *field = [NSTextField wrappingLabelWithString:@""];
            field.attributedStringValue = content;
            field.selectable = YES;
            if (column < alignments.length) {
                unichar align = [alignments characterAtIndex:column];
                if (align == 'r') {
                    field.alignment = NSTextAlignmentRight;
                } else if (align == 'c') {
                    field.alignment = NSTextAlignmentCenter;
                } else {
                    field.alignment = NSTextAlignmentLeft;
                }
            }
            [cells addObject:field];
        }
        [cellRows addObject:cells];
    }
    _grid = [NSGridView gridViewWithViews:cellRows];
    _grid.translatesAutoresizingMaskIntoConstraints = NO;
    _grid.columnSpacing = 18;
    _grid.rowSpacing = 6;
    [self addSubview:_grid];
    [NSLayoutConstraint activateConstraints:@[
        [_grid.topAnchor constraintEqualToAnchor:self.topAnchor constant:8],
        [_grid.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-8],
        [_grid.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
        [_grid.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-12],
    ]];
}

@end

// ===========================================================================
// Items: what the view is showing, so updates can reuse views

typedef NS_ENUM(NSInteger, GWMDItemKind) {
    GWMDItemKindText,
    GWMDItemKindCode,
    GWMDItemKindQuote,
    GWMDItemKindTable,
    GWMDItemKindRule,
};

@interface GWMDItem : NSObject
@property (nonatomic) GWMDItemKind kind;
@property (nonatomic, copy) NSAttributedString *attributed;
@property (nonatomic, copy) NSString *code;
@property (nonatomic, copy) NSString *language;
@property (nonatomic, copy) NSArray<NSArray<NSAttributedString *> *> *rows;
@property (nonatomic, copy) NSString *alignments;
@property (nonatomic) BOOL hasHeader;
@property (nonatomic, strong) NSView *view;
- (BOOL)hasSameContentAs:(GWMDItem *)other;
@end

@implementation GWMDItem

- (BOOL)hasSameContentAs:(GWMDItem *)other {
    if (self.kind != other.kind) {
        return NO;
    }
    switch (self.kind) {
        case GWMDItemKindText:
        case GWMDItemKindQuote:
            return [self.attributed isEqualToAttributedString:other.attributed];
        case GWMDItemKindCode:
            return [self.code isEqualToString:other.code] && [self.language isEqualToString:other.language];
        case GWMDItemKindTable: {
            if (self.rows.count != other.rows.count || self.hasHeader != other.hasHeader) {
                return NO;
            }
            for (NSUInteger row = 0; row < self.rows.count; ++row) {
                if (self.rows[row].count != other.rows[row].count) {
                    return NO;
                }
                for (NSUInteger column = 0; column < self.rows[row].count; ++column) {
                    if (![self.rows[row][column] isEqualToAttributedString:other.rows[row][column]]) {
                        return NO;
                    }
                }
            }
            return YES;
        }
        case GWMDItemKindRule:
            return YES;
    }
    return NO;
}

@end

// ===========================================================================
// The Markdown view

@implementation GWMarkdownView {
    NSStackView *_stack;
    NSMutableArray<GWMDItem *> *_items;
    NSString *_source;
    NSMutableDictionary<NSString *, NSNumber *> *_pathCache;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _fontSize = 13.5;
        _items = [NSMutableArray array];
        _pathCache = [NSMutableDictionary dictionary];
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
    }
    return self;
}

// ---------------------------------------------------------------------------
// MARK: Attributed text

- (NSFont *)bodyFontBold:(BOOL)bold italic:(BOOL)italic size:(CGFloat)size {
    NSFont *font = [NSFont systemFontOfSize:size weight:bold ? NSFontWeightSemibold : NSFontWeightRegular];
    if (italic) {
        NSFontDescriptor *descriptor = [font.fontDescriptor fontDescriptorWithSymbolicTraits:font.fontDescriptor.symbolicTraits | NSFontDescriptorTraitItalic];
        NSFont *italicFont = [NSFont fontWithDescriptor:descriptor size:size];
        if (italicFont != nil) {
            font = italicFont;
        }
    }
    return font;
}

/// Is this `code` text the name of a file in the project? Then it becomes a link.
- (NSURL *)linkForCodeText:(NSString *)text {
    if (_projectRoot.length == 0 || text.length < 3 || text.length > 300) {
        return nil;
    }
    // "path/to/file.ext", optionally followed by ":line" or ":line:column".
    static NSRegularExpression *pattern;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pattern = [NSRegularExpression regularExpressionWithPattern:@"^([\\w./@+\\-]+\\.[A-Za-z0-9]{1,8})(?::(\\d+)(?::\\d+)?)?$" options:0 error:nil];
    });
    NSTextCheckingResult *match = [pattern firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    if (match == nil) {
        return nil;
    }
    NSString *path = [text substringWithRange:[match rangeAtIndex:1]];
    NSString *absolute = [path hasPrefix:@"/"] ? path : [_projectRoot stringByAppendingPathComponent:path];
    NSNumber *cached = _pathCache[absolute];
    if (cached == nil) {
        BOOL isDirectory = NO;
        BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:absolute isDirectory:&isDirectory] && !isDirectory;
        cached = @(exists);
        _pathCache[absolute] = cached;
    }
    if (!cached.boolValue) {
        return nil;
    }
    NSString *line = [match rangeAtIndex:2].location != NSNotFound ? [text substringWithRange:[match rangeAtIndex:2]] : @"";
    NSURLComponents *components = [NSURLComponents new];
    components.scheme = @"glasswork-open";
    components.host = @"file";
    components.path = absolute;
    if (line.length > 0) {
        components.queryItems = @[[NSURLQueryItem queryItemWithName:@"line" value:line]];
    }
    return components.URL;
}

- (void)appendSpans:(const gw::markdown::Spans &)spans
                 to:(NSMutableAttributedString *)text
               size:(CGFloat)size
              color:(NSColor *)color
          forceBold:(BOOL)forceBold {
    for (const gw::markdown::Span &span : spans) {
        NSString *content = StringFromUTF8(span.text);
        BOOL bold = (span.style & gw::markdown::kBold) != 0 || forceBold;
        BOOL italic = (span.style & gw::markdown::kItalic) != 0;
        NSMutableDictionary *attributes = [NSMutableDictionary dictionary];
        attributes[NSForegroundColorAttributeName] = color;

        if (span.style & gw::markdown::kCode) {
            attributes[NSFontAttributeName] = [NSFont monospacedSystemFontOfSize:size - 1.5 weight:bold ? NSFontWeightSemibold : NSFontWeightRegular];
            attributes[NSBackgroundColorAttributeName] = [NSColor.labelColor colorWithAlphaComponent:0.10];
            NSURL *fileLink = [self linkForCodeText:content];
            if (fileLink != nil) {
                attributes[NSLinkAttributeName] = fileLink;
                attributes[NSForegroundColorAttributeName] = NSColor.linkColor;
            }
            // A little air inside the shaded box.
            content = [NSString stringWithFormat:@" %@ ", content];
        } else {
            attributes[NSFontAttributeName] = [self bodyFontBold:bold italic:italic size:size];
        }
        if (span.style & gw::markdown::kStrike) {
            attributes[NSStrikethroughStyleAttributeName] = @(NSUnderlineStyleSingle);
        }
        if ((span.style & gw::markdown::kLink) && !span.url.empty()) {
            NSURL *url = [NSURL URLWithString:StringFromUTF8(span.url)];
            if (url != nil) {
                attributes[NSLinkAttributeName] = url;
                attributes[NSForegroundColorAttributeName] = NSColor.linkColor;
            }
        }
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:content attributes:attributes]];
    }
}

- (NSParagraphStyle *)paragraphStyleWithSpacing:(CGFloat)spacing indent:(CGFloat)indent hanging:(CGFloat)hanging {
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.lineSpacing = 2.5;
    style.paragraphSpacing = spacing;
    style.firstLineHeadIndent = indent;
    style.headIndent = indent + hanging;
    if (hanging > 0) {
        style.tabStops = @[[[NSTextTab alloc] initWithType:NSLeftTabStopType location:indent + hanging]];
        style.defaultTabInterval = hanging;
    }
    return style;
}

/// One paragraph, heading or list item as attributed text (ending in a newline).
- (NSAttributedString *)attributedForBlock:(const gw::markdown::Block &)block {
    NSMutableAttributedString *text = [NSMutableAttributedString new];
    CGFloat size = _fontSize;
    NSColor *color = NSColor.labelColor;
    NSParagraphStyle *style = nil;
    BOOL bold = NO;

    switch (block.kind) {
        case gw::markdown::Block::Kind::Heading: {
            CGFloat sizes[] = {0, 5, 3, 1.5, 0.5, 0, 0};
            size = _fontSize + sizes[MIN(block.level, 6)];
            bold = YES;
            style = [self paragraphStyleWithSpacing:6 indent:0 hanging:0];
            break;
        }
        case gw::markdown::Block::Kind::ListItem: {
            CGFloat indent = 4 + block.level * 18;
            style = [self paragraphStyleWithSpacing:3 indent:indent hanging:18];
            NSString *marker = nil;
            if (block.ordered) {
                marker = [NSString stringWithFormat:@"%d.", block.number];
            } else {
                NSArray<NSString *> *bullets = @[@"•", @"◦", @"▪"];
                marker = bullets[static_cast<NSUInteger>(block.level) % bullets.count];
            }
            NSDictionary *markerAttributes = @{
                NSFontAttributeName: [self bodyFontBold:block.ordered italic:NO size:size],
                NSForegroundColorAttributeName: [NSColor.secondaryLabelColor colorWithAlphaComponent:0.9],
            };
            [text appendAttributedString:[[NSAttributedString alloc] initWithString:[marker stringByAppendingString:@"\t"] attributes:markerAttributes]];
            break;
        }
        default:
            style = [self paragraphStyleWithSpacing:8 indent:0 hanging:0];
            break;
    }
    [self appendSpans:block.spans to:text size:size color:color forceBold:bold];
    [text appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"]];
    [text addAttribute:NSParagraphStyleAttributeName value:style range:NSMakeRange(0, text.length)];
    return text;
}

// ---------------------------------------------------------------------------
// MARK: Building and updating items

- (NSArray<GWMDItem *> *)itemsForBlocks:(const std::vector<gw::markdown::Block> &)blocks {
    NSMutableArray<GWMDItem *> *items = [NSMutableArray array];
    NSMutableAttributedString *run = nil;  // consecutive text-like blocks share one text view

    auto finishRun = [&]() {
        if (run == nil) {
            return;
        }
        // The last paragraph needs no space after it.
        if (run.length > 0 && [run.string characterAtIndex:run.length - 1] == '\n') {
            [run deleteCharactersInRange:NSMakeRange(run.length - 1, 1)];
        }
        GWMDItem *item = [GWMDItem new];
        item.kind = GWMDItemKindText;
        item.attributed = run;
        [items addObject:item];
        run = nil;
    };

    for (const gw::markdown::Block &block : blocks) {
        switch (block.kind) {
            case gw::markdown::Block::Kind::Paragraph:
            case gw::markdown::Block::Kind::Heading:
            case gw::markdown::Block::Kind::ListItem:
                if (run == nil) {
                    run = [NSMutableAttributedString new];
                }
                [run appendAttributedString:[self attributedForBlock:block]];
                break;

            case gw::markdown::Block::Kind::Quote: {
                finishRun();
                NSMutableAttributedString *text = [NSMutableAttributedString new];
                [self appendSpans:block.spans to:text size:_fontSize color:NSColor.secondaryLabelColor forceBold:NO];
                [text addAttribute:NSParagraphStyleAttributeName value:[self paragraphStyleWithSpacing:0 indent:0 hanging:0]
                             range:NSMakeRange(0, text.length)];
                GWMDItem *item = [GWMDItem new];
                item.kind = GWMDItemKindQuote;
                item.attributed = text;
                [items addObject:item];
                break;
            }

            case gw::markdown::Block::Kind::CodeBlock: {
                finishRun();
                GWMDItem *item = [GWMDItem new];
                item.kind = GWMDItemKindCode;
                item.code = StringFromUTF8(block.code);
                item.language = StringFromUTF8(block.language);
                [items addObject:item];
                break;
            }

            case gw::markdown::Block::Kind::Rule: {
                finishRun();
                GWMDItem *item = [GWMDItem new];
                item.kind = GWMDItemKindRule;
                [items addObject:item];
                break;
            }

            case gw::markdown::Block::Kind::Table: {
                finishRun();
                NSMutableArray<NSArray<NSAttributedString *> *> *rows = [NSMutableArray array];
                for (size_t rowIndex = 0; rowIndex < block.rows.size(); ++rowIndex) {
                    NSMutableArray<NSAttributedString *> *cells = [NSMutableArray array];
                    for (const gw::markdown::Spans &cell : block.rows[rowIndex]) {
                        NSMutableAttributedString *text = [NSMutableAttributedString new];
                        BOOL isHeader = block.hasHeader && rowIndex == 0;
                        [self appendSpans:cell to:text size:_fontSize - 0.5 color:NSColor.labelColor forceBold:isHeader];
                        [cells addObject:text];
                    }
                    [rows addObject:cells];
                }
                GWMDItem *item = [GWMDItem new];
                item.kind = GWMDItemKindTable;
                item.rows = rows;
                item.hasHeader = block.hasHeader;
                item.alignments = StringFromUTF8(block.alignments);
                [items addObject:item];
                break;
            }
        }
    }
    finishRun();
    return items;
}

- (BOOL)handleLink:(NSURL *)url {
    if ([url.scheme isEqualToString:@"glasswork-open"]) {
        NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
        NSInteger line = 0;
        for (NSURLQueryItem *item in components.queryItems) {
            if ([item.name isEqualToString:@"line"]) {
                line = item.value.integerValue;
            }
        }
        if (self.onOpenPath) {
            self.onOpenPath(components.path, line);
        }
        return YES;
    }
    return NO;  // let the system open web links
}

/// Makes the view for an item and puts it in the stack.
- (NSView *)makeViewForItem:(GWMDItem *)item {
    __weak GWMarkdownView *weakSelf = self;
    switch (item.kind) {
        case GWMDItemKindText: {
            GWAutoTextView *text = [[GWAutoTextView alloc] initAutoSizing];
            text.onLink = ^BOOL(NSURL *url) { return [weakSelf handleLink:url]; };
            [text setAttributedContent:item.attributed];
            return text;
        }
        case GWMDItemKindQuote: {
            GWQuoteView *quote = [GWQuoteView new];
            quote.text.onLink = ^BOOL(NSURL *url) { return [weakSelf handleLink:url]; };
            [quote.text setAttributedContent:item.attributed];
            return quote;
        }
        case GWMDItemKindCode: {
            GWCodeBlockView *code = [GWCodeBlockView new];
            if (_onInsertCode != nil) {
                code.onInsert = ^(NSString *text) {
                    if (weakSelf.onInsertCode) {
                        weakSelf.onInsertCode(text);
                    }
                };
            }
            [code setCode:item.code language:item.language fontSize:_fontSize - 1.5];
            return code;
        }
        case GWMDItemKindTable: {
            GWTableView *table = [GWTableView new];
            [table setRows:item.rows alignments:item.alignments hasHeader:item.hasHeader];
            return table;
        }
        case GWMDItemKindRule: {
            NSBox *rule = [NSBox new];
            rule.boxType = NSBoxSeparator;
            rule.translatesAutoresizingMaskIntoConstraints = NO;
            return rule;
        }
    }
    return nil;
}

/// Puts new content into a view that already shows the same kind of item.
- (void)updateView:(NSView *)view withItem:(GWMDItem *)item {
    switch (item.kind) {
        case GWMDItemKindText:
            [(GWAutoTextView *)view setAttributedContent:item.attributed];
            break;
        case GWMDItemKindQuote:
            [((GWQuoteView *)view).text setAttributedContent:item.attributed];
            break;
        case GWMDItemKindCode:
            [(GWCodeBlockView *)view setCode:item.code language:item.language fontSize:_fontSize - 1.5];
            break;
        case GWMDItemKindTable:
            [(GWTableView *)view setRows:item.rows alignments:item.alignments hasHeader:item.hasHeader];
            break;
        case GWMDItemKindRule:
            break;
    }
}

- (void)setMarkdown:(NSString *)markdown {
    if ([markdown isEqualToString:_source]) {
        return;
    }
    _source = [markdown copy];
    std::vector<gw::markdown::Block> blocks = gw::markdown::parse(markdown.UTF8String ?: "");
    NSArray<GWMDItem *> *fresh = [self itemsForBlocks:blocks];

    // Keep views for the start that hasn't changed kind; rebuild from the first mismatch.
    NSUInteger keep = 0;
    while (keep < fresh.count && keep < _items.count && fresh[keep].kind == _items[keep].kind) {
        ++keep;
    }
    for (NSUInteger index = 0; index < keep; ++index) {
        GWMDItem *old = _items[index];
        if (![old hasSameContentAs:fresh[index]]) {
            [self updateView:old.view withItem:fresh[index]];
        }
        fresh[index].view = old.view;
    }
    for (NSUInteger index = keep; index < _items.count; ++index) {
        [_items[index].view removeFromSuperview];
    }
    for (NSUInteger index = keep; index < fresh.count; ++index) {
        NSView *view = [self makeViewForItem:fresh[index]];
        fresh[index].view = view;
        [_stack addArrangedSubview:view];
        [view.widthAnchor constraintEqualToAnchor:_stack.widthAnchor].active = YES;
    }
    _items = [fresh mutableCopy];
    [self invalidateIntrinsicContentSize];
}

@end
