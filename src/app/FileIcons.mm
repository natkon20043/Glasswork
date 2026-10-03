#import "FileIcons.h"

#import "Services.h"

namespace {

NSColor *Hex(uint32_t rgb) {
    return [NSColor colorWithSRGBRed:((rgb >> 16) & 0xFF) / 255.0 green:((rgb >> 8) & 0xFF) / 255.0 blue:(rgb & 0xFF) / 255.0 alpha:1];
}

struct FileKind {
    const char *symbol;
    uint32_t color;
};

FileKind KindFor(NSString *filename) {
    NSString *name = filename.lowercaseString;
    NSString *extension = name.pathExtension;
    if ([name isEqualToString:@"cmakelists.txt"] || [extension isEqualToString:@"cmake"]) return {"hammer.fill", 0x4BA3E3};
    if ([name isEqualToString:@"makefile"]) return {"hammer.fill", 0x8B9BB4};
    if ([name hasPrefix:@"readme"]) return {"book.fill", 0x5AA9E6};
    if ([name hasPrefix:@"license"]) return {"checkmark.seal.fill", 0xE6B450};
    if ([name hasPrefix:@".git"]) return {"arrow.triangle.branch", 0xF1502F};

    static NSDictionary<NSString *, NSArray *> *byExtension = @{
        @"cpp": @[@"c.square.fill", @0x659AD2], @"cc": @[@"c.square.fill", @0x659AD2], @"cxx": @[@"c.square.fill", @0x659AD2],
        @"hpp": @[@"h.square.fill", @0xA074C4], @"hh": @[@"h.square.fill", @0xA074C4], @"h": @[@"h.square.fill", @0xA074C4],
        @"c": @[@"c.square.fill", @0x7F9CC9], @"m": @[@"m.square.fill", @0x438EFF], @"mm": @[@"m.square.fill", @0x6E8BFF],
        @"swift": @[@"swift", @0xF05138], @"py": @[@"p.square.fill", @0xF6C343], @"js": @[@"j.square.fill", @0xF1DD35],
        @"mjs": @[@"j.square.fill", @0xF1DD35], @"ts": @[@"t.square.fill", @0x3178C6], @"tsx": @[@"t.square.fill", @0x3178C6],
        @"jsx": @[@"j.square.fill", @0x61DAFB], @"rs": @[@"r.square.fill", @0xDEA584], @"go": @[@"g.square.fill", @0x00ADD8],
        @"java": @[@"cup.and.saucer.fill", @0xE76F00], @"json": @[@"curlybraces", @0xCBCB41], @"md": @[@"text.alignleft", @0x519ABA],
        @"yml": @[@"list.bullet.indent", @0xCB5A5A], @"yaml": @[@"list.bullet.indent", @0xCB5A5A], @"toml": @[@"gearshape.fill", @0x9C4221],
        @"html": @[@"chevron.left.forwardslash.chevron.right", @0xE34C26], @"css": @[@"paintbrush.fill", @0x7E57C2],
        @"sh": @[@"terminal.fill", @0x89E051], @"zsh": @[@"terminal.fill", @0x89E051], @"plist": @[@"list.bullet.rectangle.fill", @0x9CA3AF],
        @"in": @[@"doc.badge.gearshape.fill", @0x9CA3AF], @"txt": @[@"doc.text.fill", @0x9CA3AF],
        @"png": @[@"photo.fill", @0xA78BFA], @"jpg": @[@"photo.fill", @0xA78BFA], @"jpeg": @[@"photo.fill", @0xA78BFA],
        @"gif": @[@"photo.fill", @0xA78BFA], @"svg": @[@"photo.fill", @0xFFB13B],
    };
    NSArray *kind = byExtension[extension];
    if (kind) return {[kind[0] UTF8String], static_cast<uint32_t>([kind[1] unsignedIntValue])};
    return {"doc.fill", 0x9CA3AF};
}

}  // namespace

NSString *GWSymbolForFile(NSString *filename) { return @(KindFor(filename).symbol); }

NSColor *GWColorForFile(NSString *filename) { return Hex(KindFor(filename).color); }

NSAttributedString *GWSymbolString(NSString *symbol, NSColor *color, CGFloat pointSize) {
    // The status bar rebuilds these on every keystroke, and making a symbol image is not cheap,
    // so finished images are kept (main thread only, like all the drawing that uses them).
    static NSMutableDictionary<NSString *, NSImage *> *cache = [NSMutableDictionary dictionary];
    NSString *key = [NSString stringWithFormat:@"%@|%.1f|%@", symbol, pointSize, color.description];
    NSImage *tinted = cache[key];
    if (tinted == nil) {
        NSImage *image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
        NSImageSymbolConfiguration *configuration = [[NSImageSymbolConfiguration configurationWithPointSize:pointSize
                                                                                                     weight:NSFontWeightSemibold]
            configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationWithHierarchicalColor:color]];
        tinted = [image imageWithSymbolConfiguration:configuration];
        if (tinted != nil && cache.count < 500) {
            cache[key] = tinted;
        }
    }
    NSTextAttachment *attachment = [NSTextAttachment new];
    attachment.image = tinted;
    NSMutableAttributedString *string = [[NSAttributedString attributedStringWithAttachment:attachment] mutableCopy];
    [string addAttribute:NSBaselineOffsetAttributeName value:@(-1.5) range:NSMakeRange(0, string.length)];
    return string;
}

// MARK: Themed icons

namespace {

/// Loaded SVGs by path, so scrolling a long folder doesn't read the same file again and again.
NSImage *ThemeImageAtPath(const std::filesystem::path &path) {
    static NSMutableDictionary<NSString *, NSImage *> *cache = [NSMutableDictionary dictionary];
    NSString *key = @(path.c_str());
    NSImage *image = cache[key];
    if (image == nil) {
        image = [[NSImage alloc] initWithContentsOfFile:key];
        cache[key] = image ?: (NSImage *)NSNull.null;
    }
    return [image isKindOfClass:NSImage.class] ? image : nil;
}

}  // namespace

NSImage *GWFileIconImage(NSString *filename, BOOL directory, BOOL expanded, CGFloat size) {
    GWServices *services = GWServices.shared;
    if (const gw::IconTheme *theme = services.iconTheme) {
        bool light = !services.theme.isDark();
        std::filesystem::path icon;
        if (directory) {
            icon = theme->iconForFolder(filename.UTF8String, expanded, false, light);
        } else {
            std::string language = services.extensions.languageForFile(filename.UTF8String).value_or("");
            icon = theme->iconForFile(filename.UTF8String, language, light);
        }
        if (!icon.empty()) {
            if (NSImage *image = ThemeImageAtPath(icon)) {
                NSImage *sized = [image copy];
                // An SVG's own size is whatever its author chose; draw them all at the same height.
                CGFloat aspect = image.size.height > 0 ? image.size.width / image.size.height : 1;
                sized.size = NSMakeSize(size * aspect, size);
                return sized;
            }
        }
    }
    NSString *symbol = directory ? @"folder.fill" : GWSymbolForFile(filename);
    NSColor *tint = directory ? NSColor.controlAccentColor : GWColorForFile(filename);
    NSImageSymbolConfiguration *configuration = [[NSImageSymbolConfiguration configurationWithPointSize:size - 1 weight:NSFontWeightMedium]
        configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[tint]]];
    NSImage *image = [[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil] imageWithSymbolConfiguration:configuration];
    return image ?: [NSImage imageWithSystemSymbolName:@"doc.fill" accessibilityDescription:nil];
}
