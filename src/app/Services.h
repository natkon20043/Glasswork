#pragma once

#import <AppKit/AppKit.h>

#include "BitmapMode.hpp"
#include "EditorSettings.hpp"
#include "Extensions.hpp"
#include "Styling.hpp"
#include "Theme.hpp"

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const GWThemeDidChangeNotification;
extern NSNotificationName const GWExtensionsDidChangeNotification;
/// Fonts, opacity, colors, toggles.
extern NSNotificationName const GWEditorSettingsDidChangeNotification;

/// App-wide services shared by every window: extensions, grammars, theme, settings and the code stylist.
@interface GWServices : NSObject

// ---- Constructors
+ (instancetype)shared;

// ---- Startup
/// Scans installed extensions and installs the default set in the background.
- (void)bootstrap;

// ---- Core objects
- (gw::ExtensionManager &)extensions;
- (gw::GrammarRegistry &)grammars;
- (const gw::Theme &)theme;
/// Theme, user color rules, rainbow variables, named colors.
- (gw::Stylist &)stylist;

// ---- Settings
- (const gw::EditorSettings &)settings;
/// Saves settings.json and tells every window.
- (void)updateSettings:(void (^)(gw::EditorSettings &settings))change;
/// The file is also watched, so outside edits apply by themselves.
- (void)reloadSettings;

// ---- Themes
- (NSArray<NSString *> *)themeLabels;
- (void)selectThemeNamed:(NSString *)label;

// ---- Icon themes
/// Null means the built-in symbols.
- (const gw::IconTheme *)iconTheme;
- (NSArray<NSString *> *)iconThemeLabels;
/// Nil goes back to the built-in icons.
- (void)selectIconThemeLabel:(nullable NSString *)label;

// ---- Extensions
/// `identifier` is "publisher.name". Grammars, themes, snippets, icons, keybindings and code stop or start at once.
- (void)setExtension:(NSString *)identifier enabled:(BOOL)enabled;
- (BOOL)isExtensionDisabled:(NSString *)identifier;
- (void)installExtension:(NSString *)identifier
              completion:(void (^)(BOOL ok, NSString *message))completion;
- (void)uninstallExtension:(NSString *)identifier;

// ---- Appearance helpers
/// A workbench color such as "editor.background".
- (NSColor *)color:(NSString *)key fallback:(NSColor *)fallback;
- (NSColor *)color:(NSString *)key;
- (NSFont *)editorFontBold:(BOOL)bold italic:(BOOL)italic;
/// Glasswork Bitmap's colors, as chosen in its Options menu.
- (const gw::bitmap::Scheme &)bitmapScheme;

// ---- Properties
/// ~/Library/Application Support/Glasswork/settings.json
@property (nonatomic, readonly) NSURL *settingsURL;
@property (nonatomic, readonly, copy) NSString *themeLabel;
/// Nil for the built-in icons.
@property (nonatomic, readonly, copy, nullable) NSString *iconThemeLabel;
/// 0.3 to 1; the rest shows the glass behind.
@property (nonatomic) CGFloat editorOpacity;
@property (nonatomic) CGFloat fontSize;
/// First-launch extensions are downloading.
@property (nonatomic, readonly) BOOL installingDefaults;

@end

NSColor *GWColor(gw::Color color);
gw::Color GWColorFromNSColor(NSColor *color);

/// `color` (laid over `background` if it is see-through), pushed towards white or black just far
/// enough to reach `minimumRatio` contrast against `background` (WCAG scale: 4.5 is comfortable
/// body text, 3 is the least that stays legible). Colors that already read well come back unchanged.
NSColor *GWReadableColor(NSColor *color, NSColor *background, CGFloat minimumRatio);

/// The text color for the status bar: bright enough to read over glass in light and dark mode.
NSColor *GWStatusTextColor();

NS_ASSUME_NONNULL_END
