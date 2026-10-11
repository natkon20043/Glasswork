#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Shortcuts beyond the menus', in VS Code's format: extension `contributes.keybindings` and the
/// user's `keybindings.json`. Keys are checked before the menu, so a binding can replace a menu
/// shortcut. A sequence such as Cmd-K Cmd-S waits for its second key.
@interface GWKeybindingService : NSObject

// ---- Loading
/// Creates the user's file with a few comments if missing.
- (void)createUserFileIfNeeded;
/// Re-reads extension bindings and the user's file.
- (void)reload;

// ---- Key handling
/// YES if the key belongs to a binding (or starts a sequence) and was handled; NO lets it reach the menu and editor.
- (BOOL)handleKeyDown:(NSEvent *)event;
/// "workbench.action.files.save" -> "saveDocument:"; nil when there is no equivalent.
+ (nullable NSString *)actionNameForCommand:(NSString *)identifier;

// ---- Properties
/// ~/Library/Application Support/Glasswork/keybindings.json
@property (nonatomic, readonly) NSURL *userFileURL;

// ---- Callbacks
/// `when` values for right now: editorTextFocus, editorLangId, terminalFocus...
@property (nonatomic, copy, nullable) NSDictionary<NSString *, NSString *> * (^contextProvider)(void);
/// `arguments` is the binding's `args` (a JSON object) or nil.
@property (nonatomic, copy, nullable) void (^runCommand)(NSString *command, id _Nullable arguments);
@property (nonatomic, copy, nullable) void (^showStatus)(NSString *text);

@end

NS_ASSUME_NONNULL_END
