#import "CodeHighlight.h"
#import "Strings.h"

#import "Services.h"

#include "Highlighter.hpp"
#include "TextBuffer.hpp"

namespace {

/// What people write after the opening ``` mapped to VS Code language ids.
NSDictionary<NSString *, NSString *> *fenceAliases() {
    static NSDictionary *aliases;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        aliases = @{
            @"c++": @"cpp", @"cc": @"cpp", @"cxx": @"cpp", @"hpp": @"cpp", @"h": @"c", @"objc": @"objective-c",
            @"objectivec": @"objective-c", @"objc++": @"objective-cpp", @"objcpp": @"objective-cpp", @"mm": @"objective-cpp",
            @"m": @"objective-c", @"js": @"javascript", @"jsx": @"javascriptreact", @"mjs": @"javascript",
            @"ts": @"typescript", @"tsx": @"typescriptreact", @"py": @"python", @"python3": @"python",
            @"sh": @"shellscript", @"bash": @"shellscript", @"zsh": @"shellscript", @"shell": @"shellscript",
            @"console": @"shellscript", @"fish": @"shellscript", @"rs": @"rust", @"yml": @"yaml", @"md": @"markdown",
            @"cs": @"csharp", @"c#": @"csharp", @"rb": @"ruby", @"golang": @"go", @"kt": @"kotlin", @"ps1": @"powershell",
            @"dockerfile": @"dockerfile", @"docker": @"dockerfile", @"patch": @"diff", @"html": @"html", @"htm": @"html",
            @"jsonc": @"jsonc", @"json5": @"json", @"txt": @"plaintext", @"text": @"plaintext", @"cmake": @"cmake",
            @"makefile": @"makefile", @"make": @"makefile", @"toml": @"toml", @"ini": @"ini", @"xml": @"xml",
            @"svg": @"xml", @"sql": @"sql", @"php": @"php", @"lua": @"lua", @"swift": @"swift", @"java": @"java",
            @"css": @"css", @"scss": @"scss", @"less": @"less", @"dart": @"dart", @"c": @"c", @"cpp": @"cpp",
            @"python": @"python", @"javascript": @"javascript", @"typescript": @"typescript", @"rust": @"rust",
            @"go": @"go", @"json": @"json", @"yaml": @"yaml", @"markdown": @"markdown", @"diff": @"diff",
            @"shellscript": @"shellscript", @"objective-c": @"objective-c", @"objective-cpp": @"objective-cpp",
        };
    });
    return aliases;
}

}  // namespace

NSString *GWLanguageForFenceTag(NSString *tag) {
    NSString *lowered = tag.lowercaseString;
    NSString *alias = fenceAliases()[lowered];
    return alias ?: @"";
}

NSAttributedString *GWHighlightedCode(NSString *code, NSString *language, CGFloat pointSize) {
    GWServices *services = GWServices.shared;

    // The editor's font in each style, at this size; the plain one stands in for any that is missing.
    auto editorFont = [&](BOOL isBold, BOOL isItalic) {
        NSFontDescriptor *descriptor = [services editorFontBold:isBold italic:isItalic].fontDescriptor;
        return [NSFont fontWithDescriptor:descriptor size:pointSize];
    };
    NSFont *regular = editorFont(NO, NO) ?: [NSFont monospacedSystemFontOfSize:pointSize weight:NSFontWeightRegular];
    NSFont *bold = editorFont(YES, NO) ?: regular;
    NSFont *italic = editorFont(NO, YES) ?: regular;
    NSFont *boldItalic = editorFont(YES, YES) ?: regular;

    NSColor *foreground = [services color:@"editor.foreground" fallback:NSColor.labelColor];
    NSDictionary *plain = @{NSFontAttributeName: regular, NSForegroundColorAttributeName: foreground};

    NSString *languageId = GWLanguageForFenceTag(language);
    if (languageId.length == 0) {
        languageId = language;
    }
    gw::tm::Grammar *grammar = nullptr;
    if (languageId.length > 0) {
        grammar = services.grammars.forLanguage(languageId.UTF8String);
    }
    if (grammar == nullptr) {
        return [[NSAttributedString alloc] initWithString:code attributes:plain];
    }

    gw::TextBuffer buffer(code.UTF8String ?: "");
    gw::Highlighter highlighter(grammar);
    NSMutableAttributedString *result = [NSMutableAttributedString new];

    for (size_t line = 0; line < buffer.lineCount(); ++line) {
        if (line > 0) {
            [result appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:plain]];
        }
        std::string_view text = buffer.line(line);
        const std::vector<gw::tm::Token> *tokens = highlighter.tokens(buffer, line);
        if (tokens == nullptr || text.empty()) {
            NSString *lineText = StringFromUTF8(std::string(text));
            [result appendAttributedString:[[NSAttributedString alloc] initWithString:lineText attributes:plain]];
            continue;
        }

        std::vector<gw::StyledSpan> spans = services.stylist.styleLine(text, *tokens);
        size_t written = 0;  // bytes of this line already added
        auto append = [&](size_t from, size_t to, NSDictionary *attributes) {
            if (to <= from) {
                return;
            }
            NSString *piece = [[NSString alloc] initWithBytes:text.data() + from length:to - from encoding:NSUTF8StringEncoding];
            if (piece != nil) {
                [result appendAttributedString:[[NSAttributedString alloc] initWithString:piece attributes:attributes]];
            }
        };
        for (const gw::StyledSpan &span : spans) {
            append(written, span.start, plain);  // gaps between spans
            NSFont *font = regular;
            if (span.style.bold && span.style.italic) {
                font = boldItalic;
            } else if (span.style.bold) {
                font = bold;
            } else if (span.style.italic) {
                font = italic;
            }
            NSMutableDictionary *attributes = [NSMutableDictionary dictionary];
            attributes[NSFontAttributeName] = font;
            attributes[NSForegroundColorAttributeName] = GWColor(span.style.foreground);
            if (span.style.underline) {
                attributes[NSUnderlineStyleAttributeName] = @(NSUnderlineStyleSingle);
            }
            if (span.style.background) {
                attributes[NSBackgroundColorAttributeName] = GWColor(*span.style.background);
            }
            append(span.start, span.end, attributes);
            written = std::max<size_t>(written, span.end);
        }
        append(written, text.size(), plain);
    }
    return result;
}
