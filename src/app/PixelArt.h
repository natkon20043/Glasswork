#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

// Icon name -> the little picture GWDrawPixelIcon draws, one font pixel per dot.
typedef NS_ENUM(NSInteger, GWPixelIcon) {
    GWPixelIconMenu,
    GWPixelIconFolder,
    GWPixelIconFile,
    GWPixelIconPlus,
    GWPixelIconAlert,
    GWPixelIconUp,
    GWPixelIconDown,
};

// ---- Fonts
/// The pixel font with every font pixel `pixel` points square.
NSFont *GWPixelFont(CGFloat pixel);
/// The size of a pixel in the window's own bars and panels, whatever the editor's font size.
CGFloat GWChromePixel(void);

// ---- Text
/// How far the shadow behind pixel text spreads: a dark halo around the hard one-pixel drop, so
/// light text stands out on any background.
CGFloat GWPixelShadowBlur(CGFloat pixel);
/// Text attributes with the pixel shadow, for text fields and attributed strings.
NSDictionary<NSAttributedStringKey, id> *GWPixelTextAttributes(CGFloat pixel, NSColor *color);
/// The same without the shadow, for dark text on light boxes.
NSDictionary<NSAttributedStringKey, id> *GWPixelPlainAttributes(CGFloat pixel, NSColor *color);
/// Draws one line in a flipped view with its line box's top left at `origin`; `shadow` puts a black
/// pixel shadow behind it. Returns its width.
CGFloat GWDrawPixelText(NSString *text, NSPoint origin, CGFloat pixel, NSColor *color, BOOL shadow);
CGFloat GWPixelTextWidth(NSString *text, CGFloat pixel);

// ---- Icons
NSSize GWPixelIconSize(GWPixelIcon icon, CGFloat pixel);
/// In a flipped view, top left at `origin`; `shadow` adds the black pixel shadow.
void GWDrawPixelIcon(GWPixelIcon icon, NSPoint origin, CGFloat pixel, NSColor *color, BOOL shadow);

/// A DOS-style box: a flat body with a thin frame line inside its edge and a hard black shadow down
/// and to the right. The shadow is part of the view, so the view is `shadowSize` bigger than the body.
@interface GWRetroBox : NSView

// ---- Geometry
- (NSRect)bodyRect;
/// Inside the frame line.
- (NSRect)contentRect;
+ (CGFloat)shadowSize;
/// Box size around content of `size`.
+ (NSSize)sizeForContentSize:(NSSize)size;

// ---- Properties
@property (nonatomic, copy) NSColor *fillColor;
@property (nonatomic, copy) NSColor *lineColor;

@end

/// Lines of pixel text, wrapped: the body of a popup or dialog.
@interface GWRetroTextView : NSView

// ---- Content
/// `indent` is in characters.
- (void)addLine:(NSString *)text color:(NSColor *)color indent:(NSUInteger)indent;
/// Wraps the lines at `columns` and returns the size they need, with a character of room at the sides.
- (NSSize)fittingSizeForColumns:(NSUInteger)columns maxLines:(NSUInteger)maxLines;

// ---- Properties
@property (nonatomic) CGFloat pixel;
/// The black pixel shadow under the text (for light text on dark boxes).
@property (nonatomic) BOOL textShadow;
/// How many of the first lines sit on a band of `bandColor`, like a dialog's title.
@property (nonatomic) NSUInteger bandLines;
@property (nonatomic, copy) NSColor *bandColor;
/// For the lines on the band; nil keeps each line's own color.
@property (nonatomic, copy, nullable) NSColor *bandTextColor;

@end

NS_ASSUME_NONNULL_END
