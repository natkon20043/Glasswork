#import "FileIcons.h"

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
    NSImage *image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
    NSImageSymbolConfiguration *configuration = [[NSImageSymbolConfiguration configurationWithPointSize:pointSize
                                                                                                 weight:NSFontWeightSemibold]
        configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationWithHierarchicalColor:color]];
    NSTextAttachment *attachment = [NSTextAttachment new];
    attachment.image = [image imageWithSymbolConfiguration:configuration];
    NSMutableAttributedString *string = [[NSAttributedString attributedStringWithAttachment:attachment] mutableCopy];
    [string addAttribute:NSBaselineOffsetAttributeName value:@(-1.5) range:NSMakeRange(0, string.length)];
    return string;
}
