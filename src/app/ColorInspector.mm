#import "ColorInspector.h"
#import "Strings.h"

#import "EditorView.h"
#import "Services.h"

#include "EditorSettings.hpp"

#include <functional>
#include <string>
#include <vector>

namespace {

/// Where an edit in the panel goes: the name's style, or the rule for one scope.
using StyleEditor = std::function<void(gw::EditorSettings &, const std::function<void(gw::StyleOverride &)> &)>;

}  // namespace

/// One row of controls: text color, highlight color, bold, italic, underline, clear.
@interface GWStyleRow : NSObject
@property (nonatomic, strong) NSStackView *view;
@property (nonatomic, strong) NSColorWell *textWell;
@property (nonatomic, strong) NSColorWell *highlightWell;
@property (nonatomic, strong) NSButton *bold;
@property (nonatomic, strong) NSButton *italic;
@property (nonatomic, strong) NSButton *underline;
@property (nonatomic, strong) NSButton *clear;
@end

@implementation GWStyleRow
@end

@implementation GWColorInspector {
    NSPanel *_panel;
    __weak GWEditorView *_editor;

    NSTextField *_nameTitle;
    GWStyleRow *_nameRow;
    NSPopUpButton *_scopePicker;
    GWStyleRow *_scopeRow;

    std::string _word;
    std::vector<std::string> _scopes;  // innermost first
}

+ (instancetype)shared {
    static GWColorInspector *inspector;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        inspector = [GWColorInspector new];
    });
    return inspector;
}

// MARK: Building the panel

- (NSTextField *)label:(NSString *)text size:(CGFloat)size weight:(NSFontWeight)weight {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = [NSFont systemFontOfSize:size weight:weight];
    return label;
}

- (NSButton *)toggleWithSymbol:(NSString *)symbol tip:(NSString *)tip action:(SEL)action {
    NSImage *image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:tip];
    NSButton *button = [NSButton buttonWithImage:image target:self action:action];
    button.buttonType = NSButtonTypePushOnPushOff;
    button.bezelStyle = NSBezelStyleGlass;
    button.toolTip = tip;
    return button;
}

- (GWStyleRow *)makeRowWithTextAction:(SEL)textAction
                      highlightAction:(SEL)highlightAction
                           fontAction:(SEL)fontAction
                          clearAction:(SEL)clearAction {
    GWStyleRow *row = [GWStyleRow new];
    row.textWell = [NSColorWell colorWellWithStyle:NSColorWellStyleMinimal];
    row.textWell.target = self;
    row.textWell.action = textAction;
    row.textWell.toolTip = @"Text color";
    row.highlightWell = [NSColorWell colorWellWithStyle:NSColorWellStyleMinimal];
    row.highlightWell.target = self;
    row.highlightWell.action = highlightAction;
    row.highlightWell.toolTip = @"Highlight (background) color";

    row.bold = [self toggleWithSymbol:@"bold" tip:@"Bold" action:fontAction];
    row.italic = [self toggleWithSymbol:@"italic" tip:@"Italic" action:fontAction];
    row.underline = [self toggleWithSymbol:@"underline" tip:@"Underline" action:fontAction];
    row.clear = [NSButton buttonWithTitle:@"Clear" target:self action:clearAction];
    row.clear.bezelStyle = NSBezelStyleGlass;

    NSTextField *text = [self label:@"Text" size:11 weight:NSFontWeightMedium];
    NSTextField *highlight = [self label:@"Highlight" size:11 weight:NSFontWeightMedium];
    text.textColor = NSColor.secondaryLabelColor;
    highlight.textColor = NSColor.secondaryLabelColor;
    row.view = [NSStackView stackViewWithViews:@[text, row.textWell, highlight, row.highlightWell,
                                                 row.bold, row.italic, row.underline, row.clear]];
    row.view.spacing = 8;
    [row.view setCustomSpacing:14 afterView:row.highlightWell];
    [row.view setCustomSpacing:14 afterView:row.underline];
    return row;
}

- (void)buildPanel {
    _panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 470, 250)
                                        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                  NSWindowStyleMaskUtilityWindow | NSWindowStyleMaskFullSizeContentView |
                                                  NSWindowStyleMaskNonactivatingPanel
                                          backing:NSBackingStoreBuffered
                                            defer:NO];
    _panel.title = @"Colors";
    _panel.titlebarAppearsTransparent = YES;
    _panel.floatingPanel = YES;
    _panel.becomesKeyOnlyIfNeeded = YES;
    _panel.hidesOnDeactivate = YES;
    _panel.opaque = NO;
    _panel.backgroundColor = NSColor.clearColor;

    _nameTitle = [self label:@"This name" size:13 weight:NSFontWeightSemibold];
    NSTextField *nameHint = [self label:@"Applies everywhere this name appears in code." size:11 weight:NSFontWeightRegular];
    nameHint.textColor = NSColor.secondaryLabelColor;
    _nameRow = [self makeRowWithTextAction:@selector(nameTextChanged:)
                           highlightAction:@selector(nameHighlightChanged:)
                                fontAction:@selector(nameFontChanged:)
                               clearAction:@selector(clearName:)];

    NSTextField *scopeTitle = [self label:@"This kind of code" size:13 weight:NSFontWeightSemibold];
    _scopePicker = [NSPopUpButton new];
    _scopePicker.target = self;
    _scopePicker.action = @selector(scopePicked:);
    _scopePicker.toolTip = @"TextMate scopes at the caret, innermost first";
    _scopeRow = [self makeRowWithTextAction:@selector(scopeTextChanged:)
                            highlightAction:@selector(scopeHighlightChanged:)
                                 fontAction:@selector(scopeFontChanged:)
                                clearAction:@selector(clearScope:)];

    NSStackView *stack = [NSStackView stackViewWithViews:@[_nameTitle, nameHint, _nameRow.view,
                                                           scopeTitle, _scopePicker, _scopeRow.view]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 6;
    [stack setCustomSpacing:20 afterView:_nameRow.view];
    stack.edgeInsets = NSEdgeInsetsMake(40, 20, 20, 20);

    NSGlassEffectView *glass = [NSGlassEffectView new];
    glass.cornerRadius = 22;
    glass.contentView = stack;
    _panel.contentView = glass;
}

// MARK: Showing

- (void)showForEditor:(GWEditorView *)editor {
    if (!_panel) {
        [self buildPanel];
    }
    _editor = editor;
    [self refresh];
    if (!_panel.isVisible) {
        NSRect window = editor.window.frame;
        [_panel setFrameTopLeftPoint:NSMakePoint(NSMaxX(window) - NSWidth(_panel.frame) - 40, NSMaxY(window) - 90)];
    }
    [_panel orderFront:nil];
}

- (void)refresh {
    if (!_panel.isVisible && _editor == nil) {
        return;
    }
    GWEditorView *editor = _editor;
    if (!editor) {
        return;
    }
    _word = [editor wordAtCaret];
    _scopes = [editor scopesAtCaret];

    // The name section.
    BOOL hasWord = !_word.empty();
    _nameTitle.stringValue = hasWord ? [NSString stringWithFormat:@"“%@”", StringFromUTF8(_word)] : @"No name at the caret";
    for (NSView *control in _nameRow.view.arrangedSubviews) {
        if ([control isKindOfClass:NSControl.class]) {
            ((NSControl *)control).enabled = hasWord;
        }
    }
    const auto &identifiers = GWServices.shared.settings.colors.identifiers;
    auto found = identifiers.find(_word);
    [self showStyle:(found != identifiers.end() ? found->second : gw::StyleOverride{})
          current:[editor styleAtCaret]
            inRow:_nameRow];

    // The scope section.
    NSString *previouslyPicked = _scopePicker.titleOfSelectedItem;
    [_scopePicker removeAllItems];
    for (const std::string &scope : _scopes) {
        [_scopePicker addItemWithTitle:StringFromUTF8(scope)];
    }
    if (previouslyPicked && [_scopePicker itemWithTitle:previouslyPicked]) {
        [_scopePicker selectItemWithTitle:previouslyPicked];
    }
    _scopePicker.enabled = !_scopes.empty();
    [self showPickedScopeStyle];
}

/// Puts a stored style into a row's controls. Where nothing is stored, the wells show what
/// the code looks like right now (`current`), so you can see what you're about to change.
- (void)showStyle:(const gw::StyleOverride &)style
          current:(std::optional<gw::TextStyle>)current
            inRow:(GWStyleRow *)row {
    NSColor *unset = [NSColor.labelColor colorWithAlphaComponent:0.15];

    if (style.foreground) {
        row.textWell.color = GWColor(*style.foreground);
    } else if (current) {
        row.textWell.color = GWColor(current->foreground);
    } else {
        row.textWell.color = unset;
    }

    if (style.background) {
        row.highlightWell.color = GWColor(*style.background);
    } else if (current && current->background) {
        row.highlightWell.color = GWColor(*current->background);
    } else {
        row.highlightWell.color = NSColor.clearColor;  // no highlight: an empty swatch
    }

    row.bold.state = style.bold.value_or(false) ? NSControlStateValueOn : NSControlStateValueOff;
    row.italic.state = style.italic.value_or(false) ? NSControlStateValueOn : NSControlStateValueOff;
    row.underline.state = style.underline.value_or(false) ? NSControlStateValueOn : NSControlStateValueOff;
}

- (std::string)pickedScope {
    NSString *title = _scopePicker.titleOfSelectedItem;
    return title ? std::string(title.UTF8String) : std::string();
}

- (void)showPickedScopeStyle {
    std::string scope = [self pickedScope];
    gw::StyleOverride style;
    for (const gw::ScopeStyleRule &rule : GWServices.shared.settings.colors.scopeRules) {
        if (rule.scope == scope) {
            style = rule.style;
        }
    }
    GWEditorView *editor = _editor;
    std::optional<gw::TextStyle> current;
    if (editor) {
        current = [editor styleForScopeAtCaret:scope];
    }
    [self showStyle:style current:current inRow:_scopeRow];
}

// MARK: Saving changes

/// Changes the style stored for the name under the caret.
- (void)editNameStyle:(void (^)(gw::StyleOverride &style))change {
    if (_word.empty()) {
        return;
    }
    std::string word = _word;
    [GWServices.shared updateSettings:^(gw::EditorSettings &settings) {
        change(settings.colors.identifiers[word]);
        if (settings.colors.identifiers[word].empty()) {
            settings.colors.identifiers.erase(word);
        }
    }];
}

/// Changes (or creates) the rule for the scope picked in the pop-up.
- (void)editScopeStyle:(void (^)(gw::StyleOverride &style))change {
    std::string scope = [self pickedScope];
    if (scope.empty()) {
        return;
    }
    [GWServices.shared updateSettings:^(gw::EditorSettings &settings) {
        auto &rules = settings.colors.scopeRules;
        auto rule = std::find_if(rules.begin(), rules.end(), [&](const gw::ScopeStyleRule &each) {
            return each.scope == scope;
        });
        if (rule == rules.end()) {
            rules.push_back({scope, {}});
            rule = rules.end() - 1;
        }
        change(rule->style);
        if (rule->style.empty()) {
            rules.erase(rule);
        }
    }];
}

- (void)applyFontButtonsOfRow:(GWStyleRow *)row to:(gw::StyleOverride &)style {
    style.bold = row.bold.state == NSControlStateValueOn;
    style.italic = row.italic.state == NSControlStateValueOn;
    style.underline = row.underline.state == NSControlStateValueOn;
    // Off everywhere means "not customised", so the theme's own style shows through.
    if (!*style.bold && !*style.italic && !*style.underline) {
        style.bold.reset();
        style.italic.reset();
        style.underline.reset();
    }
}

- (void)nameTextChanged:(NSColorWell *)well {
    gw::Color color = GWColorFromNSColor(well.color);
    [self editNameStyle:^(gw::StyleOverride &style) {
        style.foreground = color;
    }];
}

- (void)nameHighlightChanged:(NSColorWell *)well {
    gw::Color color = GWColorFromNSColor(well.color);
    [self editNameStyle:^(gw::StyleOverride &style) {
        style.background = color;
    }];
}

- (void)nameFontChanged:(id)sender {
    GWStyleRow *row = _nameRow;
    [self editNameStyle:^(gw::StyleOverride &style) {
        [self applyFontButtonsOfRow:row to:style];
    }];
}

- (void)clearName:(id)sender {
    [self editNameStyle:^(gw::StyleOverride &style) {
        style = gw::StyleOverride{};
    }];
    [self refresh];
}

- (void)scopePicked:(id)sender {
    [self showPickedScopeStyle];
}

- (void)scopeTextChanged:(NSColorWell *)well {
    gw::Color color = GWColorFromNSColor(well.color);
    [self editScopeStyle:^(gw::StyleOverride &style) {
        style.foreground = color;
    }];
}

- (void)scopeHighlightChanged:(NSColorWell *)well {
    gw::Color color = GWColorFromNSColor(well.color);
    [self editScopeStyle:^(gw::StyleOverride &style) {
        style.background = color;
    }];
}

- (void)scopeFontChanged:(id)sender {
    GWStyleRow *row = _scopeRow;
    [self editScopeStyle:^(gw::StyleOverride &style) {
        [self applyFontButtonsOfRow:row to:style];
    }];
}

- (void)clearScope:(id)sender {
    [self editScopeStyle:^(gw::StyleOverride &style) {
        style = gw::StyleOverride{};
    }];
    [self showPickedScopeStyle];
}

@end
