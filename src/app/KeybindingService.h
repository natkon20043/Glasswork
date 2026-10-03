#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Keyboard shortcuts beyond the menus': those extensions declare (`contributes.keybindings`) and
/// the user's own `keybindings.json`, in VS Code's format. Key presses are looked at before the
/// menu sees them, so a binding can also replace a menu shortcut. A sequence such as ⌘K ⌘S waits
/// for its second key.
@interface GWKeybindingService : NSObject

/// `when` clause values for right now: editorTextFocus, editorLangId, terminalFocus…
@property (nonatomic, copy, nullable) NSDictionary<NSString *, NSString *> * (^contextProvider)(void);
/// Runs a command by its VS Code id, with the binding's `args` (a JSON object or nil).
@property (nonatomic, copy, nullable) void (^runCommand)(NSString *command, id _Nullable arguments);
/// Shows a line in the status bar ("(⌘K) was pressed. Waiting for the next key…").
@property (nonatomic, copy, nullable) void (^showStatus)(NSString *text);

/// ~/Library/Application Support/Glasswork/keybindings.json
@property (nonatomic, readonly) NSURL *userFileURL;
/// Creates the user's file with a few comments, if it doesn't exist yet.
- (void)createUserFileIfNeeded;

/// Reads the extensions' bindings and the user's file again.
- (void)reload;

/// Looks at a key press. Returns YES if it belongs to a binding (or to the start of a sequence)
/// and was dealt with, NO to let it carry on to the menu and the editor.
- (BOOL)handleKeyDown:(NSEvent *)event;

/// The responder-chain action that does a built-in VS Code command ("workbench.action.files.save" →
/// "saveDocument:"), or nil when we have no equivalent.
+ (nullable NSString *)actionNameForCommand:(NSString *)identifier;

@end

NS_ASSUME_NONNULL_END
