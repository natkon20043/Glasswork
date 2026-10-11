#import "Services.h"

#include <filesystem>
#include <fstream>
#include <memory>
#include <set>
#include <sstream>

NSNotificationName const GWThemeDidChangeNotification = @"GWThemeDidChange";
NSNotificationName const GWExtensionsDidChangeNotification = @"GWExtensionsDidChange";
NSNotificationName const GWEditorSettingsDidChangeNotification = @"GWEditorSettingsDidChange";

NSColor *GWColor(gw::Color color) {
    return [NSColor colorWithSRGBRed:gw::red(color) green:gw::green(color) blue:gw::blue(color) alpha:gw::alpha(color)];
}

gw::Color GWColorFromNSColor(NSColor *color) {
    NSColor *srgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    auto byte = [](CGFloat component) {
        return static_cast<uint32_t>(std::lround(std::clamp(component, 0.0, 1.0) * 255));
    };
    return (byte(srgb.redComponent) << 24) | (byte(srgb.greenComponent) << 16) | (byte(srgb.blueComponent) << 8) |
           byte(srgb.alphaComponent);
}

namespace {

/// Extensions installed on first launch: VS Code's own themes plus grammars for common
/// languages, all from Open VSX.
NSArray<NSString *> *DefaultExtensions() {
    return @[
        @"vscode.theme-defaults", @"vscode.cpp", @"vscode.python", @"vscode.javascript", @"vscode.typescript",
        @"vscode.json", @"vscode.markdown", @"vscode.shellscript", @"vscode.make", @"vscode.css", @"vscode.html",
        @"vscode.yaml", @"vscode.rust", @"vscode.go", @"vscode.swift", @"vscode.java", @"vscode.objective-c",
        // Also built in to VS Code: diffs and commit messages (used by the Git views), and
        // the languages people meet next.
        @"vscode.diff", @"vscode.git-base", @"vscode.ini", @"vscode.xml", @"vscode.sql", @"vscode.ruby",
        @"vscode.php", @"vscode.csharp", @"vscode.lua", @"vscode.docker", @"vscode.scss", @"vscode.less",
        @"vscode.powershell", @"vscode.dart", @"vscode.log",
        // Not built in to VS Code, but CMake files are everywhere in C++ projects.
        @"twxs.cmake",
    ];
}

/// Used until extensions (and their themes) are installed, so the first launch still has
/// a coherent look offline.
const char *kFallbackTheme = R"json({
  "name": "Glasswork Dark",
  "type": "dark",
  "colors": {
    "editor.background": "#16181D", "editor.foreground": "#D8DEE9",
    "editorLineNumber.foreground": "#5C6370", "editorLineNumber.activeForeground": "#C8CCD4",
    "editorCursor.foreground": "#7DD3FC", "editor.selectionBackground": "#3B4A6B",
    "sideBar.background": "#14161B", "focusBorder": "#7DD3FC"
  },
  "tokenColors": [
    { "scope": "comment", "settings": { "foreground": "#6B7A8F", "fontStyle": "italic" } },
    { "scope": ["keyword", "storage"], "settings": { "foreground": "#C792EA" } },
    { "scope": "string", "settings": { "foreground": "#F2B880" } },
    { "scope": "constant.numeric", "settings": { "foreground": "#A5E3A0" } },
    { "scope": ["entity.name.function", "support.function"], "settings": { "foreground": "#82AAFF" } },
    { "scope": ["entity.name.type", "support.type"], "settings": { "foreground": "#7FDBCA" } }
  ]
})json";

std::optional<std::string> readFile(NSURL *url) {
    std::ifstream file(url.fileSystemRepresentation, std::ios::binary);
    if (!file) {
        return std::nullopt;
    }
    std::ostringstream contents;
    contents << file.rdbuf();
    return contents.str();
}

}  // namespace

@implementation GWServices {
    std::unique_ptr<gw::ExtensionManager> _extensions;
    std::unique_ptr<gw::GrammarRegistry> _grammars;
    std::optional<gw::IconTheme> _iconTheme;
    NSString *_iconThemeLabel;
    std::vector<std::string> _appliedDisabledExtensions;  // what the extension manager was last given
    std::unique_ptr<gw::Theme> _theme;
    std::unique_ptr<gw::Stylist> _stylist;
    gw::EditorSettings _settings;
    dispatch_source_t _settingsWatcher;
    std::string _lastWrittenSettings;  // to ignore the watcher firing for our own saves
}

+ (instancetype)shared {
    static GWServices *services;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        services = [GWServices new];
    });
    return services;
}

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
                                                          inDomains:NSUserDomainMask].firstObject;
    NSURL *folder = [support URLByAppendingPathComponent:@"Glasswork" isDirectory:YES];
    // For tests: keep settings and extensions in another folder, away from the real ones.
    const char *overrideFolder = getenv("GLASSWORK_SUPPORT_DIR");
    if (overrideFolder != nullptr) {
        folder = [NSURL fileURLWithPath:@(overrideFolder) isDirectory:YES];
    }
    [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
    _settingsURL = [folder URLByAppendingPathComponent:@"settings.json"];

    _extensions = std::make_unique<gw::ExtensionManager>(std::filesystem::path(folder.path.UTF8String) / "extensions");
    _extensions->setUserSnippetsDirectory(std::filesystem::path(folder.path.UTF8String) / "snippets");
    _grammars = std::make_unique<gw::GrammarRegistry>(*_extensions);
    _theme = gw::Theme::parse(kFallbackTheme, true);
    _themeLabel = @"Glasswork Dark";

    [self loadOrCreateSettings];
    [self rebuildStylist];
    [self watchSettingsFile];
    return self;
}

- (gw::ExtensionManager &)extensions { return *_extensions; }
- (gw::GrammarRegistry &)grammars { return *_grammars; }
- (const gw::Theme &)theme { return *_theme; }
- (gw::Stylist &)stylist { return *_stylist; }
- (const gw::EditorSettings &)settings { return _settings; }

// MARK: Settings

- (void)loadOrCreateSettings {
    std::optional<std::string> text = readFile(_settingsURL);
    if (text) {
        std::string error;
        _settings = gw::parseSettings(*text, &error);
        if (!error.empty()) {
            NSLog(@"Glasswork: %s", error.c_str());
        }
        return;
    }

    // First run: start from any choices made in earlier versions (kept in user defaults).
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults objectForKey:@"editorOpacity"]) {
        _settings.editorOpacity = [defaults doubleForKey:@"editorOpacity"];
    }
    if ([defaults objectForKey:@"fontSize"]) {
        _settings.fontSize = [defaults doubleForKey:@"fontSize"];
    }
    NSString *theme = [defaults stringForKey:@"theme"];
    if (theme) {
        _settings.theme = theme.UTF8String;
    }
    [self writeSettings];
}

- (void)writeSettings {
    std::string text = gw::serializeSettings(_settings);
    _lastWrittenSettings = text;
    NSData *data = [NSData dataWithBytes:text.data() length:text.size()];
    [data writeToURL:_settingsURL atomically:YES];
}

- (void)updateSettings:(void (^)(gw::EditorSettings &))change {
    std::string previousTheme = _settings.theme;
    change(_settings);
    [self writeSettings];
    [self settingsDidChangeFromTheme:previousTheme];
}

- (void)reloadSettings {
    std::optional<std::string> text = readFile(_settingsURL);
    if (!text || *text == _lastWrittenSettings) {
        return;  // missing, or just our own save
    }
    std::string previousTheme = _settings.theme;
    std::string error;
    _settings = gw::parseSettings(*text, &error);
    if (!error.empty()) {
        NSLog(@"Glasswork: %s", error.c_str());
    }
    _lastWrittenSettings = *text;
    [self settingsDidChangeFromTheme:previousTheme];
}

- (void)settingsDidChangeFromTheme:(const std::string &)previousTheme {
    if (_settings.disabledExtensions != _appliedDisabledExtensions) {
        // Extensions were switched on or off: read them again with the new list.
        _appliedDisabledExtensions = _settings.disabledExtensions;
        _extensions->setDisabled(std::set<std::string>(_appliedDisabledExtensions.begin(), _appliedDisabledExtensions.end()));
        [self extensionsChanged];
    }
    if (_settings.theme != previousTheme) {
        [self loadTheme:@(_settings.theme.c_str())];  // posts the theme notification itself
    }
    [self reloadIconTheme];
    [self rebuildStylist];
    [NSNotificationCenter.defaultCenter postNotificationName:GWEditorSettingsDidChangeNotification object:self];
}

/// Watches settings.json so edits from any editor apply straight away. Saves replace the
/// file (write then rename), so the watch is re-armed on the new file after each event.
- (void)watchSettingsFile {
    if (_settingsWatcher) {
        dispatch_source_cancel(_settingsWatcher);
        _settingsWatcher = nil;
    }
    int descriptor = open(_settingsURL.fileSystemRepresentation, O_EVTONLY);
    if (descriptor < 0) {
        return;
    }
    dispatch_source_t watcher = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, static_cast<uintptr_t>(descriptor),
                                                       DISPATCH_VNODE_WRITE | DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME,
                                                       dispatch_get_main_queue());
    __weak GWServices *weakSelf = self;
    dispatch_source_set_event_handler(watcher, ^{
        // Give the saving app a moment to finish replacing the file.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            [weakSelf reloadSettings];
            [weakSelf watchSettingsFile];
        });
    });
    dispatch_source_set_cancel_handler(watcher, ^{
        close(descriptor);
    });
    _settingsWatcher = watcher;
    dispatch_resume(watcher);
}

- (void)rebuildStylist {
    _stylist = std::make_unique<gw::Stylist>(*_theme, _settings.colors);
}

// MARK: Extensions

- (void)bootstrap {
    _appliedDisabledExtensions = _settings.disabledExtensions;
    _extensions->setDisabled(std::set<std::string>(_appliedDisabledExtensions.begin(), _appliedDisabledExtensions.end()));
    _extensions->scan();
    [self reloadIconTheme];
    [self applySavedTheme];
    if (getenv("GLASSWORK_NO_DEFAULT_EXTENSIONS") != nullptr) {
        return;  // tests choose which extensions exist
    }

    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    for (NSString *identifier in DefaultExtensions()) {
        if (!_extensions->isInstalled(identifier.UTF8String)) {
            [missing addObject:identifier];
        }
    }
    if (missing.count == 0) {
        return;
    }

    _installingDefaults = YES;
    std::filesystem::path folder = _extensions->directory();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        for (NSString *identifier in missing) {
            auto result = gw::ExtensionManager::installFromOpenVSX(identifier.UTF8String, folder);
            if (!result.ok) {
                NSLog(@"Glasswork: %s", result.message.c_str());
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_installingDefaults = NO;
            [self extensionsChanged];
            [self applySavedTheme];
        });
    });
}

- (void)extensionsChanged {
    _extensions->scan();
    _grammars->clear();
    [self reloadIconTheme];
    [NSNotificationCenter.defaultCenter postNotificationName:GWExtensionsDidChangeNotification object:self];
}

- (void)installExtension:(NSString *)identifier completion:(void (^)(BOOL, NSString *))completion {
    std::filesystem::path folder = _extensions->directory();
    NSString *cleaned = [identifier stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    std::string id = cleaned.UTF8String;
    NSArray<NSString *> *themesBefore = self.themeLabels;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        auto result = gw::ExtensionManager::installFromOpenVSX(id, folder);
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *message = @(result.message.c_str());
            if (result.ok) {
                [self extensionsChanged];
                // Someone who installs a color theme wants to see it, so switch to it right away.
                NSString *newTheme = [self firstThemeNotIn:themesBefore];
                if (newTheme != nil) {
                    [self selectThemeNamed:newTheme];
                    message = [message stringByAppendingFormat:@" Switched to the theme \u201c%@\u201d.", newTheme];
                }
            }
            completion(result.ok, message);
        });
    });
}

- (void)uninstallExtension:(NSString *)identifier {
    _extensions->uninstall(identifier.UTF8String);
    [self extensionsChanged];
}

- (void)setExtension:(NSString *)identifier enabled:(BOOL)enabled {
    std::string id = identifier.UTF8String;
    [self updateSettings:^(gw::EditorSettings &settings) {
        auto &list = settings.disabledExtensions;
        list.erase(std::remove(list.begin(), list.end(), id), list.end());
        if (!enabled) {
            list.push_back(id);
        }
    }];
}

- (BOOL)isExtensionDisabled:(NSString *)identifier {
    const auto &list = _settings.disabledExtensions;
    return std::find(list.begin(), list.end(), std::string(identifier.UTF8String)) != list.end();
}

// MARK: File icon themes

/// Loads the icon theme the settings name, if an installed extension provides it.
- (void)reloadIconTheme {
    _iconTheme.reset();
    _iconThemeLabel = nil;
    if (_settings.iconTheme.empty()) {
        return;
    }
    for (const gw::IconThemeInfo &info : _extensions->iconThemes()) {
        if (info.id == _settings.iconTheme || info.label == _settings.iconTheme) {
            _iconTheme = gw::IconTheme::load(info.path);
            if (_iconTheme) {
                _iconThemeLabel = @(info.label.c_str());
            }
            return;
        }
    }
}

- (const gw::IconTheme *)iconTheme {
    return _iconTheme ? &*_iconTheme : nullptr;
}

- (NSString *)iconThemeLabel {
    return _iconThemeLabel;
}

- (NSArray<NSString *> *)iconThemeLabels {
    NSMutableArray<NSString *> *labels = [NSMutableArray array];
    for (const gw::IconThemeInfo &info : _extensions->iconThemes()) {
        [labels addObject:@(info.label.c_str())];
    }
    return labels;
}

- (void)selectIconThemeLabel:(NSString *)label {
    std::string chosen;
    for (const gw::IconThemeInfo &info : _extensions->iconThemes()) {
        if (label != nil && info.label == label.UTF8String) {
            chosen = info.id;
        }
    }
    [self updateSettings:^(gw::EditorSettings &settings) {
        settings.iconTheme = chosen;
    }];
}

// MARK: Themes

- (NSArray<NSString *> *)themeLabels {
    NSMutableArray *labels = [NSMutableArray array];
    for (const auto &theme : _extensions->themes()) {
        [labels addObject:@(theme.label.c_str())];
    }
    return labels;
}

/// The first installed theme whose name is not in `known`, or nil if there is none.
- (NSString *)firstThemeNotIn:(NSArray<NSString *> *)known {
    for (NSString *label in self.themeLabels) {
        if (![known containsObject:label]) {
            return label;
        }
    }
    return nil;
}

- (void)applySavedTheme {
    if ([self loadTheme:@(_settings.theme.c_str())]) {
        return;
    }
    if ([self loadTheme:@"Dark Modern"]) {
        return;
    }
    [self loadTheme:@"Dark+"];
}

- (void)selectThemeNamed:(NSString *)label {
    [self updateSettings:^(gw::EditorSettings &settings) {
        settings.theme = label.UTF8String;
    }];
}

- (BOOL)loadTheme:(NSString *)label {
    if (!label) {
        return NO;
    }
    for (const auto &info : _extensions->themes()) {
        if (![@(info.label.c_str()) isEqualToString:label]) {
            continue;
        }
        std::string error;
        auto theme = gw::Theme::load(info.path, info.dark(), &error);
        if (!theme) {
            NSLog(@"Glasswork: theme %@ failed: %s", label, error.c_str());
            return NO;
        }
        _theme = std::move(theme);
        _themeLabel = [label copy];
        [self rebuildStylist];  // the stylist refers to the theme
        [NSNotificationCenter.defaultCenter postNotificationName:GWThemeDidChangeNotification object:self];
        return YES;
    }
    return NO;
}

- (NSColor *)color:(NSString *)key fallback:(NSColor *)fallback {
    std::string name = key.UTF8String;
    if (!_theme->hasColor(name)) {
        return fallback;
    }
    return GWColor(_theme->color(name, 0));
}

- (NSColor *)color:(NSString *)key {
    NSColor *fallback = _theme->isDark() ? NSColor.whiteColor : NSColor.blackColor;
    return [self color:key fallback:fallback];
}

// MARK: Editor settings shortcuts

- (CGFloat)editorOpacity { return _settings.editorOpacity; }
- (CGFloat)fontSize { return _settings.fontSize; }

- (void)setEditorOpacity:(CGFloat)editorOpacity {
    [self updateSettings:^(gw::EditorSettings &settings) {
        settings.editorOpacity = std::clamp(static_cast<double>(editorOpacity), 0.3, 1.0);
    }];
}

- (void)setFontSize:(CGFloat)fontSize {
    [self updateSettings:^(gw::EditorSettings &settings) {
        settings.fontSize = std::clamp(static_cast<double>(fontSize), 8.0, 40.0);
    }];
}

- (NSFont *)editorFontBold:(BOOL)bold italic:(BOOL)italic {
    CGFloat size = _settings.fontSize;
    NSFontWeight weight = bold ? NSFontWeightSemibold : NSFontWeightRegular;

    NSFont *font = nil;
    if (!_settings.fontFamily.empty()) {
        // A named family (e.g. "JetBrains Mono"), with the right weight if it has one.
        NSFontDescriptor *descriptor = [NSFontDescriptor fontDescriptorWithFontAttributes:@{
            NSFontFamilyAttribute: @(_settings.fontFamily.c_str()),
            NSFontTraitsAttribute: @{NSFontWeightTrait: @(weight)},
        }];
        font = [NSFont fontWithDescriptor:descriptor size:size];
    }
    if (!font) {
        font = [NSFont monospacedSystemFontOfSize:size weight:weight];
    }

    if (italic) {
        NSFontDescriptorSymbolicTraits traits = font.fontDescriptor.symbolicTraits | NSFontDescriptorTraitItalic;
        NSFont *slanted = [NSFont fontWithDescriptor:[font.fontDescriptor fontDescriptorWithSymbolicTraits:traits] size:size];
        if (slanted) {
            font = slanted;
        }
    }
    return font;
}

@end
