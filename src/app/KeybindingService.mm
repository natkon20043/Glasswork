#import "KeybindingService.h"

#import "Services.h"

#include "Jsonc.hpp"
#include "Keybindings.hpp"

#include <fstream>
#include <sstream>

namespace {

/// How long the first key of a sequence stays valid.
constexpr NSTimeInterval kSequenceTimeout = 2.0;

/// The name VS Code uses for a pressed key, or empty if it isn't one we can name.
std::string KeyNameForEvent(NSEvent *event) {
    switch (event.keyCode) {
        case 36: case 76: return "enter";
        case 48: return "tab";
        case 49: return "space";
        case 51: return "backspace";
        case 117: return "delete";
        case 53: return "escape";
        case 123: return "left";
        case 124: return "right";
        case 125: return "down";
        case 126: return "up";
        case 115: return "home";
        case 119: return "end";
        case 116: return "pageup";
        case 121: return "pagedown";
        case 122: return "f1";  case 120: return "f2";  case 99: return "f3";  case 118: return "f4";
        case 96: return "f5";   case 97: return "f6";   case 98: return "f7";  case 100: return "f8";
        case 101: return "f9";  case 109: return "f10"; case 103: return "f11"; case 111: return "f12";
        default: break;
    }
    NSString *characters = event.charactersIgnoringModifiers.lowercaseString;
    if (characters.length == 0) {
        return "";
    }
    std::string key = characters.UTF8String;
    // With Shift held, symbols come back shifted ("!" for Shift-1); VS Code names the key itself.
    static const std::map<std::string, std::string> unshifted = {
        {"!", "1"}, {"@", "2"}, {"#", "3"}, {"$", "4"}, {"%", "5"}, {"^", "6"}, {"&", "7"}, {"*", "8"},
        {"(", "9"}, {")", "0"}, {"_", "-"}, {"+", "="}, {"{", "["}, {"}", "]"}, {"|", "\\"}, {":", ";"},
        {"\"", "'"}, {"<", ","}, {">", "."}, {"?", "/"}, {"~", "`"},
    };
    auto found = unshifted.find(key);
    return found == unshifted.end() ? key : found->second;
}

gw::KeyChord ChordForEvent(NSEvent *event) {
    gw::KeyChord chord;
    NSEventModifierFlags flags = event.modifierFlags;
    chord.command = (flags & NSEventModifierFlagCommand) != 0;
    chord.control = (flags & NSEventModifierFlagControl) != 0;
    chord.option = (flags & NSEventModifierFlagOption) != 0;
    chord.shift = (flags & NSEventModifierFlagShift) != 0;
    chord.key = KeyNameForEvent(event);
    return chord;
}

std::string ChordText(const gw::KeyChord &chord) {
    std::string text;
    if (chord.control) text += "⌃";
    if (chord.option) text += "⌥";
    if (chord.shift) text += "⇧";
    if (chord.command) text += "⌘";
    std::string key = chord.key;
    if (key.size() == 1) {
        key = [@(key.c_str()) uppercaseString].UTF8String;  // "k" is shown as K, like the menus do
    }
    return text + key;
}

}  // namespace

@implementation GWKeybindingService {
    gw::KeybindingTable _table;
    std::vector<gw::KeyChord> _pending;
    NSDate *_pendingSince;
}

- (NSURL *)userFileURL {
    return [[GWServices.shared.settingsURL URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"keybindings.json"];
}

- (void)createUserFileIfNeeded {
    NSURL *url = self.userFileURL;
    if ([NSFileManager.defaultManager fileExistsAtPath:url.path]) {
        return;
    }
    NSString *template_ = @"// Place your key bindings in this file. They override the defaults.\n"
                          @"// Commands are VS Code's ids (\"workbench.action.files.save\") or an extension's own.\n"
                          @"// A key can be a sequence: \"cmd+k cmd+s\". Start a command with \"-\" to remove a binding.\n"
                          @"[\n"
                          @"    // { \"key\": \"cmd+shift+u\", \"command\": \"editor.action.transformToUppercase\", \"when\": "
                          @"\"editorTextFocus\" }\n"
                          @"]\n";
    [template_ writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (void)reload {
    _table.clear();
    _pending.clear();
    nlohmann::json contributed = nlohmann::json::parse(GWServices.shared.extensions.contributedKeybindingsJson(), nullptr, false);
    _table.add(contributed, false);

    std::ifstream input(self.userFileURL.path.UTF8String);
    if (input) {
        std::stringstream text;
        text << input.rdbuf();
        _table.add(gw::parseJsonc(text.str()), true);
    }
}

- (void)clearPending {
    _pending.clear();
    _pendingSince = nil;
}

- (BOOL)handleKeyDown:(NSEvent *)event {
    if (_table.size() == 0 || event.isARepeat) {
        return NO;
    }
    gw::KeyChord chord = ChordForEvent(event);
    if (chord.key.empty()) {
        return NO;
    }
    // A bare letter or digit is typing, never a shortcut, unless a sequence is waiting for it.
    bool hasModifier = chord.command || chord.control || chord.option;
    bool isFunctionKey = chord.key.size() >= 2 && chord.key[0] == 'f' && isdigit(chord.key[1]);
    bool isEscape = chord.key == "escape";
    if (_pending.empty() && !hasModifier && !isFunctionKey && !isEscape) {
        return NO;
    }

    if (!_pending.empty() && [_pendingSince timeIntervalSinceNow] < -kSequenceTimeout) {
        [self clearPending];
    }
    std::vector<gw::KeyChord> pressed = _pending;
    pressed.push_back(chord);

    NSDictionary<NSString *, NSString *> *contextObjects = self.contextProvider ? self.contextProvider() : @{};
    std::map<std::string, std::string> context;
    for (NSString *name in contextObjects) {
        context[name.UTF8String] = contextObjects[name].UTF8String;
    }

    gw::KeybindingTable::Match match = _table.match(pressed, context);
    if (match.kind == gw::KeybindingTable::MatchKind::Complete) {
        NSString *command = @(match.binding->command.c_str());
        id arguments = nil;
        if (!match.binding->arguments.is_null()) {
            std::string text = match.binding->arguments.dump();
            arguments = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:text.data() length:text.size()]
                                                        options:NSJSONReadingFragmentsAllowed error:nil];
        }
        [self clearPending];
        if (self.showStatus) self.showStatus(@"");
        if (self.runCommand) self.runCommand(command, arguments);
        return YES;
    }
    if (match.kind == gw::KeybindingTable::MatchKind::Prefix) {
        _pending = pressed;
        _pendingSince = [NSDate date];
        NSMutableString *shown = [NSMutableString string];
        for (const gw::KeyChord &pendingChord : _pending) {
            if (shown.length > 0) [shown appendString:@" "];
            [shown appendString:@(ChordText(pendingChord).c_str())];
        }
        if (self.showStatus) self.showStatus([NSString stringWithFormat:@"(%@) was pressed. Waiting for the next key of the "
                                                                        @"sequence…", shown]);
        return YES;
    }
    if (!_pending.empty()) {
        // The second key doesn't complete anything: say so, and don't let it type or run something else.
        NSMutableString *shown = [NSMutableString string];
        for (const gw::KeyChord &pendingChord : pressed) {
            if (shown.length > 0) [shown appendString:@" "];
            [shown appendString:@(ChordText(pendingChord).c_str())];
        }
        [self clearPending];
        if (self.showStatus) self.showStatus([NSString stringWithFormat:@"(%@) is not a command.", shown]);
        return YES;
    }
    return NO;
}

+ (NSString *)actionNameForCommand:(NSString *)identifier {
    static NSDictionary<NSString *, NSString *> *actions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        actions = @{
            // Files and windows
            @"workbench.action.files.save": @"saveDocument:",
            @"workbench.action.files.saveAs": @"saveDocumentAs:",
            @"workbench.action.files.saveAll": @"saveAllDocuments:",
            @"workbench.action.files.newUntitledFile": @"newDocument:",
            @"workbench.action.files.openFolder": @"openFolder:",
            @"workbench.action.newWindow": @"newWindow:",
            @"workbench.action.closeActiveEditor": @"closeTab:",
            @"workbench.action.closeOtherEditors": @"closeOtherTabs:",
            @"workbench.action.reopenClosedEditor": @"reopenClosedTab:",
            @"workbench.action.nextEditor": @"selectNextTab:",
            @"workbench.action.previousEditor": @"selectPreviousTab:",
            // Going places
            @"workbench.action.quickOpen": @"quickOpen:",
            @"workbench.action.showCommands": @"showCommandPalette:",
            @"workbench.action.gotoLine": @"goToLine:",
            @"workbench.action.gotoSymbol": @"goToSymbolInFile:",
            @"workbench.action.showAllSymbols": @"goToSymbolInWorkspace:",
            @"workbench.action.navigateBack": @"goBack:",
            @"workbench.action.navigateForward": @"goForward:",
            @"editor.action.revealDefinition": @"goToDefinition:",
            @"editor.action.goToReferences": @"findReferences:",
            @"editor.action.rename": @"renameSymbol:",
            @"editor.action.jumpToBracket": @"goToMatchingBracket:",
            @"editor.action.marker.next": @"nextChange:",
            // Panels
            @"workbench.view.explorer": @"showExplorer:",
            @"workbench.view.scm": @"showSourceControl:",
            @"workbench.view.debug": @"showDebugPanel:",
            @"workbench.view.extensions": @"searchExtensions:",
            @"workbench.action.toggleSidebarVisibility": @"toggleSidebar:",
            @"workbench.action.terminal.toggleTerminal": @"toggleTerminal:",
            @"workbench.action.terminal.new": @"newTerminal:",
            @"workbench.action.terminal.clear": @"clearTerminal:",
            @"workbench.action.openSettings": @"openSettings:",
            @"workbench.action.restartExtensionHost": @"restartExtensionHost:",
            // Searching
            @"actions.find": @"showFind:",
            @"editor.action.startFindReplace": @"showFindAndReplace:",
            @"editor.action.nextMatchFindAction": @"findNext:",
            @"editor.action.previousMatchFindAction": @"findPrevious:",
            @"workbench.action.findInFiles": @"findInFiles:",
            @"editor.action.addSelectionToNextFindMatch": @"selectNextOccurrence:",
            @"editor.action.selectHighlights": @"selectAllOccurrences:",
            // Editing
            @"editor.action.formatDocument": @"formatDocument:",
            @"editor.action.triggerSuggest": @"completeCode:",
            @"editor.action.quickFix": @"showQuickFixes:",
            @"editor.action.commentLine": @"toggleLineComment:",
            @"editor.action.indentLines": @"indentLines:",
            @"editor.action.outdentLines": @"outdentLines:",
            @"editor.action.deleteLines": @"deleteLines:",
            @"editor.action.insertLineBefore": @"insertLineAbove:",
            @"editor.action.insertLineAfter": @"insertLineBelow:",
            @"editor.action.copyLinesDownAction": @"duplicateLinesDown:",
            @"editor.action.copyLinesUpAction": @"duplicateLinesUp:",
            @"editor.action.moveLinesDownAction": @"moveLinesDown:",
            @"editor.action.moveLinesUpAction": @"moveLinesUp:",
            @"editor.action.joinLines": @"joinSelectedLines:",
            @"editor.action.transformToUppercase": @"makeUpperCase:",
            @"editor.action.transformToLowercase": @"makeLowerCase:",
            @"editor.action.transformToTitlecase": @"makeTitleCase:",
            @"editor.action.sortLinesAscending": @"sortLinesAscending:",
            @"editor.action.sortLinesDescending": @"sortLinesDescending:",
            @"editor.action.removeDuplicateLines": @"removeDuplicateLines:",
            @"editor.action.insertCursorAbove": @"addCursorAbove:",
            @"editor.action.insertCursorBelow": @"addCursorBelow:",
            @"editor.action.smartSelect.expand": @"expandSelection:",
            @"editor.action.smartSelect.shrink": @"shrinkSelection:",
            @"editor.fold": @"foldCode:",
            @"editor.unfold": @"unfoldCode:",
            @"editor.foldAll": @"foldAllCode:",
            @"editor.unfoldAll": @"unfoldAllCode:",
            @"editor.action.toggleWordWrap": @"toggleWordWrap:",
            @"undo": @"undo:",
            @"redo": @"redo:",
            @"editor.action.selectAll": @"selectAll:",
            @"editor.action.clipboardCopyAction": @"copy:",
            @"editor.action.clipboardCutAction": @"cut:",
            @"editor.action.clipboardPasteAction": @"paste:",
            // Running
            @"workbench.action.tasks.build": @"buildProject:",
            @"workbench.action.tasks.runTask": @"runTask:",
            @"workbench.action.debug.start": @"startDebugging:",
            @"workbench.action.debug.stop": @"stopDebugging:",
            @"workbench.action.debug.stepOver": @"debugStepOver:",
            @"workbench.action.debug.stepInto": @"debugStepInto:",
            @"workbench.action.debug.stepOut": @"debugStepOut:",
            @"editor.debug.action.toggleBreakpoint": @"toggleBreakpoint:",
            // View
            @"workbench.action.zoomIn": @"increaseFontSize:",
            @"workbench.action.zoomOut": @"decreaseFontSize:",
            @"workbench.action.zoomReset": @"resetFontSize:",
            @"markdown.showPreview": @"openMarkdownPreview:",
        };
    });
    return actions[identifier];
}

@end
