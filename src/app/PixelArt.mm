#import "PixelArt.h"

#import <CoreText/CoreText.h>

#include "PixelFont.hpp"

#include <algorithm>
#include <string_view>
#include <vector>

// MARK: - Font

/// The font made from the core's glyphs, created once and never registered system-wide.
static CTFontDescriptorRef PixelFontDescriptor() {
    static CTFontDescriptorRef descriptor = [] {
        std::vector<uint8_t> bytes = gw::pixelfont::trueTypeData();
        NSData *data = [NSData dataWithBytes:bytes.data() length:bytes.size()];
        return CTFontManagerCreateFontDescriptorFromData((__bridge CFDataRef)data);
    }();
    return descriptor;
}

NSFont *GWPixelFont(CGFloat pixel) {
    static NSMutableDictionary<NSNumber *, NSFont *> *cache = [NSMutableDictionary dictionary];
    NSNumber *key = @(pixel);
    NSFont *font = cache[key];
    if (font != nil) {
        return font;
    }
    CGFloat size = pixel * gw::pixelfont::kPixelsPerEm;
    CTFontDescriptorRef descriptor = PixelFontDescriptor();
    if (descriptor != nullptr) {
        font = (__bridge_transfer NSFont *)CTFontCreateWithFontDescriptor(descriptor, size, nullptr);
    }
    if (font == nil) {
        font = [NSFont monospacedSystemFontOfSize:size * 0.6 weight:NSFontWeightRegular];  // never expected
    }
    cache[key] = font;
    return font;
}

CGFloat GWChromePixel(void) { return 2; }

// MARK: - Text

CGFloat GWPixelShadowBlur(CGFloat pixel) { return 1.5 * pixel; }

NSDictionary<NSAttributedStringKey, id> *GWPixelTextAttributes(CGFloat pixel, NSColor *color) {
    NSShadow *shadow = [NSShadow new];
    shadow.shadowOffset = NSMakeSize(pixel, -pixel);  // unflipped: right and down
    shadow.shadowBlurRadius = GWPixelShadowBlur(pixel);
    shadow.shadowColor = NSColor.blackColor;
    return @{NSFontAttributeName: GWPixelFont(pixel), NSForegroundColorAttributeName: color, NSShadowAttributeName: shadow};
}

NSDictionary<NSAttributedStringKey, id> *GWPixelPlainAttributes(CGFloat pixel, NSColor *color) {
    return @{NSFontAttributeName: GWPixelFont(pixel), NSForegroundColorAttributeName: color};
}

CGFloat GWPixelTextWidth(NSString *text, CGFloat pixel) {
    return [text sizeWithAttributes:@{NSFontAttributeName: GWPixelFont(pixel)}].width;
}

CGFloat GWDrawPixelText(NSString *text, NSPoint origin, CGFloat pixel, NSColor *color, BOOL shadow) {
    NSDictionary *attributes = shadow ? GWPixelTextAttributes(pixel, color) : GWPixelPlainAttributes(pixel, color);
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    CGContextSaveGState(context);
    CGContextSetShouldAntialias(context, false);
    [text drawAtPoint:origin withAttributes:attributes];
    CGContextRestoreGState(context);
    return [text sizeWithAttributes:attributes].width;
}

// MARK: - Icons

namespace {

using IconArt = std::vector<std::string_view>;

const IconArt &ArtFor(GWPixelIcon icon) {
    static const IconArt menu = {"#########", ".........", ".........", "#########", ".........", ".........", "#########"};
    static const IconArt folder = {"####.....", "#########", "#########", "#########", "#########", "#########", "#########"};
    static const IconArt file = {"#######", "#.....#", "#.###.#", "#.....#", "#.###.#", "#.....#", "#.###.#", "#######"};
    static const IconArt plus = {"..###..", "..###..", "#######", "#######", "#######", "..###..", "..###.."};
    static const IconArt alert = {"...#...", "..###..", "..#.#..", ".##.##.", ".#####.", "##.#.##", "#######"};
    static const IconArt up = {"..#..", ".###.", "#####"};
    static const IconArt down = {"#####", ".###.", "..#.."};
    switch (icon) {
        case GWPixelIconMenu: return menu;
        case GWPixelIconFolder: return folder;
        case GWPixelIconFile: return file;
        case GWPixelIconPlus: return plus;
        case GWPixelIconAlert: return alert;
        case GWPixelIconUp: return up;
        case GWPixelIconDown: return down;
    }
    return menu;
}

void FillArt(const IconArt &art, NSPoint origin, CGFloat pixel) {
    for (size_t row = 0; row < art.size(); ++row) {
        const std::string_view line = art[row];
        size_t column = 0;
        while (column < line.size()) {
            if (line[column] != '#') {
                ++column;
                continue;
            }
            size_t start = column;
            while (column < line.size() && line[column] == '#') {
                ++column;
            }
            NSRectFill(NSMakeRect(origin.x + start * pixel, origin.y + row * pixel, (column - start) * pixel, pixel));
        }
    }
}

}  // namespace

NSSize GWPixelIconSize(GWPixelIcon icon, CGFloat pixel) {
    const IconArt &art = ArtFor(icon);
    size_t width = 0;
    for (std::string_view line : art) {
        width = std::max(width, line.size());
    }
    return NSMakeSize(width * pixel, art.size() * pixel);
}

void GWDrawPixelIcon(GWPixelIcon icon, NSPoint origin, CGFloat pixel, NSColor *color, BOOL shadow) {
    const IconArt &art = ArtFor(icon);
    if (shadow) {
        [NSColor.blackColor setFill];
        FillArt(art, NSMakePoint(origin.x + pixel, origin.y + pixel), pixel);
    }
    [color setFill];
    FillArt(art, origin, pixel);
}

// MARK: - Popup pieces

@implementation GWRetroBox

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _fillColor = NSColor.lightGrayColor;
        _lineColor = NSColor.blackColor;
    }
    return self;
}

- (BOOL)isFlipped { return YES; }

+ (CGFloat)shadowSize { return 4 * GWChromePixel(); }

+ (NSSize)sizeForContentSize:(NSSize)size {
    CGFloat inset = 4 * GWChromePixel();
    return NSMakeSize(size.width + 2 * inset + self.shadowSize, size.height + 2 * inset + self.shadowSize);
}

- (NSRect)bodyRect {
    CGFloat shadow = GWRetroBox.shadowSize;
    NSRect bounds = self.bounds;
    return NSMakeRect(0, 0, std::max(0.0, NSWidth(bounds) - shadow), std::max(0.0, NSHeight(bounds) - shadow));
}

- (NSRect)contentRect {
    CGFloat inset = 4 * GWChromePixel();
    return NSInsetRect(self.bodyRect, inset, inset);
}

- (void)drawRect:(NSRect)dirtyRect {
    CGFloat pixel = GWChromePixel();
    CGFloat shadow = GWRetroBox.shadowSize;
    NSRect body = self.bodyRect;
    [NSColor.blackColor setFill];
    NSRectFill(NSOffsetRect(body, shadow, shadow));
    [_fillColor setFill];
    NSRectFill(body);
    // The frame line, two pixels in.
    NSRect line = NSInsetRect(body, 2 * pixel, 2 * pixel);
    [_lineColor setFill];
    NSFrameRectWithWidth(line, pixel);
}

@end

namespace {

struct RetroLine {
    NSString *text;
    NSColor *color;
    NSUInteger indent;
};

/// `text` cut at spaces into pieces of at most `columns` characters (longer words are split).
NSArray<NSString *> *WrappedPieces(NSString *text, NSUInteger columns) {
    if (columns == 0 || text.length <= columns) {
        return @[text];
    }
    NSMutableArray<NSString *> *pieces = [NSMutableArray array];
    NSMutableString *current = [NSMutableString string];
    for (NSString *word in [text componentsSeparatedByString:@" "]) {
        NSString *rest = word;
        while (rest.length > columns) {
            if (current.length > 0) {
                [pieces addObject:[current copy]];
                [current setString:@""];
            }
            NSRange cut = [rest rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, columns)];
            [pieces addObject:[rest substringWithRange:cut]];
            rest = [rest substringFromIndex:NSMaxRange(cut)];
        }
        NSUInteger needed = current.length == 0 ? rest.length : current.length + 1 + rest.length;
        if (needed > columns && current.length > 0) {
            [pieces addObject:[current copy]];
            [current setString:rest];
        } else {
            if (current.length > 0) {
                [current appendString:@" "];
            }
            [current appendString:rest];
        }
    }
    [pieces addObject:[current copy]];
    return pieces;
}

}  // namespace

@implementation GWRetroTextView {
    std::vector<RetroLine> _lines;
    std::vector<RetroLine> _laidOut;  // after wrapping
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _pixel = GWChromePixel();
        _bandColor = NSColor.whiteColor;
    }
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)addLine:(NSString *)text color:(NSColor *)color indent:(NSUInteger)indent {
    _lines.push_back({[text copy], color, indent});
}

- (NSSize)fittingSizeForColumns:(NSUInteger)columns maxLines:(NSUInteger)maxLines {
    _laidOut.clear();
    for (const RetroLine &line : _lines) {
        NSUInteger room = columns > line.indent ? columns - line.indent : 1;
        for (NSString *piece in WrappedPieces(line.text, room)) {
            if (_laidOut.size() >= maxLines) {
                break;
            }
            _laidOut.push_back({piece, line.color, line.indent});
        }
    }
    CGFloat charWidth = gw::pixelfont::kAdvance * _pixel;
    CGFloat width = 0;
    for (const RetroLine &line : _laidOut) {
        width = std::max(width, line.indent * charWidth + GWPixelTextWidth(line.text, _pixel));
    }
    self.needsDisplay = YES;
    return NSMakeSize(std::ceil(width + 2 * charWidth), _laidOut.size() * gw::pixelfont::kLineHeight * _pixel);
}

- (void)drawRect:(NSRect)dirtyRect {
    CGFloat charWidth = gw::pixelfont::kAdvance * _pixel;
    CGFloat lineHeight = gw::pixelfont::kLineHeight * _pixel;
    if (_bandLines > 0) {
        [_bandColor setFill];
        NSRectFill(NSMakeRect(0, 0, NSWidth(self.bounds), std::min(_bandLines, static_cast<NSUInteger>(_laidOut.size())) * lineHeight));
    }
    CGFloat y = 0;
    for (size_t index = 0; index < _laidOut.size(); ++index) {
        const RetroLine &line = _laidOut[index];
        NSColor *color = index < _bandLines && _bandTextColor != nil ? _bandTextColor : line.color;
        GWDrawPixelText(line.text, NSMakePoint(charWidth * (1 + line.indent), y), _pixel, color, _textShadow);
        y += lineHeight;
    }
}

@end
