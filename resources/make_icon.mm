// Draws the Glasswork app icon at every size macOS needs and writes an .iconset folder.
//
//   clang++ -std=c++17 -fobjc-arc -framework AppKit resources/make_icon.mm -o make_icon
//   ./make_icon Glasswork.iconset && iconutil -c icns Glasswork.iconset -o Glasswork.icns

#import <AppKit/AppKit.h>

static NSColor *color(CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    return [NSColor colorWithSRGBRed:r green:g blue:b alpha:a];
}

/// The icon drawn into a `size` × `size` square.
static void drawIcon(CGFloat size) {
    CGFloat inset = size * 0.055;
    NSRect body = NSMakeRect(inset, inset, size - 2 * inset, size - 2 * inset);
    CGFloat radius = body.size.width * 0.225;
    NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect:body xRadius:radius yRadius:radius];

    // A soft shadow under the whole icon.
    [NSGraphicsContext saveGraphicsState];
    NSShadow *shadow = [NSShadow new];
    shadow.shadowColor = color(0, 0, 0, 0.35);
    shadow.shadowBlurRadius = size * 0.03;
    shadow.shadowOffset = NSMakeSize(0, -size * 0.012);
    [shadow set];
    [color(0.1, 0.1, 0.2, 1) setFill];
    [shape fill];
    [NSGraphicsContext restoreGraphicsState];

    [NSGraphicsContext saveGraphicsState];
    [shape addClip];

    // Deep night-sky base.
    NSGradient *base = [[NSGradient alloc] initWithColors:@[color(0.10, 0.12, 0.30, 1), color(0.20, 0.10, 0.36, 1), color(0.32, 0.12, 0.42, 1)]];
    [base drawInRect:body angle:-55];

    // Aurora glows.
    struct Glow { CGFloat x, y, r; CGFloat red, green, blue, alpha; } glows[] = {
        {0.18, 0.86, 0.75, 0.15, 0.80, 0.95, 0.75},
        {0.85, 0.15, 0.80, 0.85, 0.30, 0.95, 0.70},
        {0.55, 0.55, 0.55, 0.30, 0.45, 1.00, 0.45},
    };
    for (auto &glow : glows) {
        NSPoint center = NSMakePoint(NSMinX(body) + body.size.width * glow.x, NSMinY(body) + body.size.height * glow.y);
        NSGradient *gradient = [[NSGradient alloc] initWithColors:@[color(glow.red, glow.green, glow.blue, glow.alpha), color(glow.red, glow.green, glow.blue, 0)]];
        [gradient drawFromCenter:center radius:0 toCenter:center radius:body.size.width * glow.r options:0];
    }

    // Glass sheen across the top.
    NSGradient *sheen = [[NSGradient alloc] initWithColors:@[color(1, 1, 1, 0.34), color(1, 1, 1, 0.08), color(1, 1, 1, 0)]
                                              atLocations:(CGFloat[]){0, 0.42, 0.75} colorSpace:NSColorSpace.sRGBColorSpace];
    [sheen drawInRect:body angle:-90];

    // An inner glass panel behind the symbol.
    NSRect panel = NSInsetRect(body, body.size.width * 0.17, body.size.height * 0.17);
    NSBezierPath *panelShape = [NSBezierPath bezierPathWithRoundedRect:panel xRadius:radius * 0.55 yRadius:radius * 0.55];
    [color(1, 1, 1, 0.10) setFill];
    [panelShape fill];
    [color(1, 1, 1, 0.34) setStroke];
    panelShape.lineWidth = MAX(1, size * 0.004);
    [panelShape stroke];
    [NSGraphicsContext restoreGraphicsState];

    // The </> symbol.
    NSImageSymbolConfiguration *configuration = [NSImageSymbolConfiguration configurationWithPointSize:size * 0.36 weight:NSFontWeightSemibold];
    NSImage *symbol = [[NSImage imageWithSystemSymbolName:@"chevron.left.forwardslash.chevron.right" accessibilityDescription:nil]
        imageWithSymbolConfiguration:configuration];
    NSImage *white = [symbol imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[color(1, 1, 1, 0.97)]]];
    // The symbol comes at a small natural size; scale it to a good part of the panel.
    NSSize natural = white.size;
    CGFloat targetWidth = panel.size.width * 0.66;
    CGFloat targetHeight = targetWidth * natural.height / natural.width;
    NSRect glyphRect = NSMakeRect(NSMidX(body) - targetWidth / 2, NSMidY(body) - targetHeight / 2, targetWidth, targetHeight);
    [NSGraphicsContext saveGraphicsState];
    NSShadow *glow = [NSShadow new];
    glow.shadowColor = color(0.55, 0.65, 1, 0.9);
    glow.shadowBlurRadius = size * 0.035;
    [glow set];
    [white drawInRect:glyphRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
    [NSGraphicsContext restoreGraphicsState];

    // A crisp rim.
    [color(1, 1, 1, 0.45) setStroke];
    shape.lineWidth = MAX(1, size * 0.006);
    NSBezierPath *rim = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(body, size * 0.003, size * 0.003) xRadius:radius yRadius:radius];
    rim.lineWidth = MAX(1, size * 0.005);
    [rim stroke];
}

int main(int argc, char **argv) {
    @autoreleasepool {
        NSString *folder = argc > 1 ? @(argv[1]) : @"Glasswork.iconset";
        [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
        struct Size { int points; int scale; } sizes[] = {{16, 1}, {16, 2}, {32, 1}, {32, 2}, {128, 1}, {128, 2}, {256, 1}, {256, 2}, {512, 1}, {512, 2}};
        for (auto entry : sizes) {
            int pixels = entry.points * entry.scale;
            NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nil pixelsWide:pixels pixelsHigh:pixels bitsPerSample:8
                                                                          samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace
                                                                              bytesPerRow:0 bitsPerPixel:0];
            NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
            [NSGraphicsContext saveGraphicsState];
            NSGraphicsContext.currentContext = context;
            context.imageInterpolation = NSImageInterpolationHigh;
            drawIcon(pixels);
            [NSGraphicsContext restoreGraphicsState];
            NSString *name = entry.scale == 1 ? [NSString stringWithFormat:@"icon_%dx%d.png", entry.points, entry.points]
                                              : [NSString stringWithFormat:@"icon_%dx%d@2x.png", entry.points, entry.points];
            NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
            [png writeToFile:[folder stringByAppendingPathComponent:name] atomically:YES];
        }
    }
    return 0;
}
