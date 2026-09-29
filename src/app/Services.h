#pragma once

#import <AppKit/AppKit.h>

#include "EditorSettings.hpp"
#include "Extensions.hpp"
#include "Styling.hpp"
#include "Theme.hpp"

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const GWThemeDidChangeNotification;
extern NSNotificationName const GWExtensionsDidChangeNotification;
/// Posted whenever settings.json changes (fonts, opacity, colours, toggles).
extern NSNotificationName const GWEditorSettingsDidChangeNotification;

/// App-wide services shared by every window: installed extensions, loaded grammars, the
/// current theme, the user's settings and the stylist that colours code.
@interface GWServices : NSObject

+ (instancetype)shared;

- (gw::ExtensionManager &)extensions;
- (gw::GrammarRegistry &)grammars;
- (const gw::Theme &)theme;
/// Colours a line of code: theme, user colour rules, rainbow variables, named colours.
- (gw::Stylist &)stylist;

// MARK: Settings

/// The user's settings, read from settings.json.
- (const gw::EditorSettings &)settings;
/// ~/Library/Application Support/Glasswork/settings.json
@property (nonatomic, readonly) NSURL *settingsURL;
/// Changes settings, saves settings.json and tells every window.
- (void)updateSettings:(void (^)(gw::EditorSettings &settings))change;
/// Re-reads settings.json (it's also watched, so outside edits apply by themselves).
- (void)reloadSettings;

@property (nonatomic, readonly, copy) NSString *themeLabel;
/// How opaque the editor's backdrop is (0.3–1); the rest shows the glass behind it.
@property (nonatomic) CGFloat editorOpacity;
@property (nonatomic) CGFloat fontSize;
/// True while first-launch extensions are downloading.
@property (nonatomic, readonly) BOOL installingDefaults;

// MARK: Extensions and themes

/// Scans installed extensions and, in the background, installs the default set.
- (void)bootstrap;
- (NSArray<NSString *> *)themeLabels;
- (void)selectThemeNamed:(NSString *)label;

- (void)installExtension:(NSString *)identifier
              completion:(void (^)(BOOL ok, NSString *message))completion;
- (void)uninstallExtension:(NSString *)identifier;

// MARK: Appearance helpers

/// A workbench colour from the theme, e.g. "editor.background".
- (NSColor *)color:(NSString *)key fallback:(NSColor *)fallback;
- (NSColor *)color:(NSString *)key;
- (NSFont *)editorFontBold:(BOOL)bold italic:(BOOL)italic;

@end

NSColor *GWColor(gw::Color color);
gw::Color GWColorFromNSColor(NSColor *color);

NS_ASSUME_NONNULL_END
