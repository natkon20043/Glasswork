// Draws the Glasswork Bitmap app icon at every size macOS needs and writes an .iconset folder: a
// little DOS-style editor (grey menu bar, blue window with a double frame, colored code, status line)
// on a 32 x 32 grid of square pixels.
//
//   clang++ -std=c++17 -fobjc-arc -framework AppKit resources/make_bitmap_icon.mm -o make_bitmap_icon
//   ./make_bitmap_icon GlassworkBitmap.iconset && iconutil -c icns GlassworkBitmap.iconset -o GlassworkBitmap.icns

#import <AppKit/AppKit.h>

static NSColor *ega(unsigned rgb) {
    return [NSColor colorWithSRGBRed:((rgb >> 16) & 0xFF) / 255.0 green:((rgb >> 8) & 0xFF) / 255.0 blue:(rgb & 0xFF) / 255.0 alpha:1];
}

/// Fills grid cells from (x, y), `width` across and `height` down; y counts from the top.
static void cells(NSRect body, int x, int y, int width, int height, NSColor *color) {
    CGFloat cell = body.size.width / 32;
    [color setFill];
    NSRectFill(NSMakeRect(NSMinX(body) + x * cell, NSMaxY(body) - (y + height) * cell, width * cell, height * cell));
}

static void drawIcon(CGFloat size) {
    CGFloat inset = size * 0.055;
    NSRect body = NSMakeRect(inset, inset, size - 2 * inset, size - 2 * inset);
    CGFloat radius = body.size.width * 0.225;
    NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect:body xRadius:radius yRadius:radius];

    [NSGraphicsContext saveGraphicsState];
    NSShadow *shadow = [NSShadow new];
    shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.35];
    shadow.shadowBlurRadius = size * 0.03;
    shadow.shadowOffset = NSMakeSize(0, -size * 0.012);
    [shadow set];
    [ega(0x0000AA) setFill];
    [shape fill];
    [NSGraphicsContext restoreGraphicsState];

    [NSGraphicsContext saveGraphicsState];
    [shape addClip];
    [NSGraphicsContext.currentContext setShouldAntialias:NO];
    NSColor *grey = ega(0xAAAAAA), *black = ega(0x000000), *red = ega(0xAA0000), *white = ega(0xFFFFFF);
    NSColor *yellow = ega(0xFFFF55), *cyan = ega(0x00AAAA), *lightCyan = ega(0x55FFFF), *green = ega(0x55FF55);
    NSColor *magenta = ega(0xFF55FF), *desktop = ega(0x000055);

    cells(body, 0, 0, 32, 32, desktop);
    // Menu bar: the red menu mark, then dark words.
    cells(body, 0, 0, 32, 5, grey);
    cells(body, 5, 2, 2, 1, red);
    cells(body, 9, 2, 4, 1, black);
    cells(body, 14, 2, 4, 1, black);
    cells(body, 19, 2, 3, 1, black);
    // The window, its hard shadow, and the double frame.
    cells(body, 3, 8, 25, 19, black);
    cells(body, 2, 6, 25, 20, ega(0x0000AA));
    cells(body, 2, 7, 25, 1, white);
    cells(body, 2, 24, 25, 1, white);
    cells(body, 2, 7, 1, 18, white);
    cells(body, 26, 7, 1, 18, white);
    cells(body, 4, 9, 21, 1, white);
    cells(body, 4, 22, 21, 1, white);
    cells(body, 4, 9, 1, 14, white);
    cells(body, 24, 9, 1, 14, white);
    // The selected tab on the top edge.
    cells(body, 8, 6, 9, 3, cyan);
    cells(body, 10, 7, 5, 1, black);
    // Code.
    cells(body, 6, 11, 4, 1, white);
    cells(body, 11, 11, 7, 1, yellow);
    cells(body, 8, 13, 6, 1, yellow);
    cells(body, 15, 13, 5, 1, lightCyan);
    cells(body, 8, 15, 4, 1, green);
    cells(body, 13, 15, 2, 1, magenta);
    cells(body, 6, 17, 3, 1, white);
    cells(body, 6, 20, 2, 1, white);  // the cursor
    // Status line.
    cells(body, 0, 28, 32, 4, grey);
    cells(body, 3, 29, 2, 1, red);
    cells(body, 6, 29, 4, 1, black);
    cells(body, 12, 29, 2, 1, red);
    cells(body, 15, 29, 3, 1, black);
    [NSGraphicsContext restoreGraphicsState];

    [[NSColor colorWithWhite:1 alpha:0.35] setStroke];
    NSBezierPath *rim = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(body, size * 0.003, size * 0.003) xRadius:radius yRadius:radius];
    rim.lineWidth = MAX(1, size * 0.005);
    [rim stroke];
}

int main(int argc, char **argv) {
    @autoreleasepool {
        NSString *folder = argc > 1 ? @(argv[1]) : @"GlassworkBitmap.iconset";
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
