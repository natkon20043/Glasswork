#import "AppDelegate.h"

#import "MainWindow.h"
#import "Services.h"
#import "StartupTiming.h"

typedef NS_ENUM(NSInteger, GWSettingToggle) {
    GWSettingRainbow = 1,
    GWSettingOccurrences,
    GWSettingBrackets,
    GWSettingGuides,
    GWSettingDividers,
    GWSettingMinimap,
};

// Modifier keys used by the menus below.
static const NSEventModifierFlags kCommand = NSEventModifierFlagCommand;
static const NSEventModifierFlags kShift = NSEventModifierFlagShift;
static const NSEventModifierFlags kOption = NSEventModifierFlagOption;
static const NSEventModifierFlags kControl = NSEventModifierFlagControl;

/// The key-equivalent text for a special key (an arrow or a function key).
static NSString *SpecialKey(unichar key) {
    return [NSString stringWithFormat:@"%C", key];
}

@implementation GWAppDelegate {
    GWMainWindowController *_window;                          // the first window (the debug hooks use it)
    NSMutableArray<GWMainWindowController *> *_windows;       // every open window
    NSPoint _cascadePoint;
    NSMenu *_themeMenu;
    NSMenu *_installedMenu;
    NSMenu *_recentMenu;
    NSMutableArray<NSURL *> *_pendingURLs;  // files opened before launch finished
}

- (void)applicationWillFinishLaunching:(NSNotification *)notification {
    GWStartupMark(@"applicationWillFinishLaunching");
    _pendingURLs = [NSMutableArray array];
    NSApp.mainMenu = [self buildMainMenu];
    GWStartupMark(@"menu built");
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    GWStartupMark(@"applicationDidFinishLaunching");
    [GWServices.shared bootstrap];
    GWStartupMark(@"services ready (extensions scanned, theme loaded)");
    _windows = [NSMutableArray array];
    _window = [self makeWindowController];
    GWStartupMark(@"main window built");
    [_window showWindow:nil];
    GWStartupMark(@"main window shown");

    NSString *lastFolder = [NSUserDefaults.standardUserDefaults stringForKey:@"lastFolder"];
    BOOL isDirectory = NO;
    if (lastFolder && [NSFileManager.defaultManager fileExistsAtPath:lastFolder isDirectory:&isDirectory] && isDirectory) {
        [_window openURL:[NSURL fileURLWithPath:lastFolder]];
    }
    for (NSURL *url in _pendingURLs) [_window openURL:url];
    [_pendingURLs removeAllObjects];

    // GLASSWORK_ACTIONS="showSourceControl:,quickOpen:" runs those menu actions in order, a
    // moment apart. For checking the interface without clicking (debugging).
    NSString *actions = NSProcessInfo.processInfo.environment[@"GLASSWORK_ACTIONS"];
    if (actions.length) {
        NSArray<NSString *> *names = [actions componentsSeparatedByString:@","];
        for (NSUInteger index = 0; index < names.count; ++index) {
            NSString *name = names[index];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>((2.0 + 1.2 * index) * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                SEL selector = NSSelectorFromString(name);
                if ([self->_window respondsToSelector:selector]) {
                    [NSApp sendAction:selector to:self->_window from:nil];
                } else {
                    // Not a window action: try the editor, then the app itself (New Window…).
                    if (![self->_window debugPerformEditorAction:selector] && [self respondsToSelector:selector]) {
                        [NSApp sendAction:selector to:self from:nil];
                    }
                }
            });
        }
    }

    // GLASSWORK_REMOTE="host:/folder" opens that remote folder, and GLASSWORK_REMOTE_FILE="host:/folder/file"
    // opens a remote file once it is up (debugging, e.g. with a stand-in ssh program).
    NSString *remoteFolder = NSProcessInfo.processInfo.environment[@"GLASSWORK_REMOTE"];
    NSString *remoteFile = NSProcessInfo.processInfo.environment[@"GLASSWORK_REMOTE_FILE"];
    if (remoteFolder.length || remoteFile.length) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [self->_window debugOpenRemoteFolder:remoteFolder file:remoteFile];
        });
    }

    // GLASSWORK_COMMANDS="ext.command,other.command" runs extension commands, a moment apart,
    // after the menu actions (debugging).
    NSString *commands = NSProcessInfo.processInfo.environment[@"GLASSWORK_COMMANDS"];
    if (commands.length) {
        NSArray<NSString *> *identifiers = [commands componentsSeparatedByString:@","];
        for (NSUInteger index = 0; index < identifiers.count; ++index) {
            NSString *identifier = identifiers[index];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>((4.0 + 1.5 * index) * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [self->_window debugRunExtensionCommand:identifier];
            });
        }
    }

    // GLASSWORK_BENCH=1 times typing, scrolling and jumping in the file opened at launch, then quits.
    if (getenv("GLASSWORK_BENCH") != nullptr) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [self->_window runInteractionBenchmark];
        });
    }

    // GLASSWORK_PROMPT="text" sends that message to Claude a few seconds after launch (debugging).
    NSString *prompt = NSProcessInfo.processInfo.environment[@"GLASSWORK_PROMPT"];
    if (prompt.length) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [self->_window debugSendChatPrompt:prompt];
        });
    }

    // GLASSWORK_SNAPSHOT=/path.png renders the editor to an image after a moment (debugging).
    NSString *snapshot = NSProcessInfo.processInfo.environment[@"GLASSWORK_SNAPSHOT"];
    if (snapshot.length) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [self->_window writeEditorSnapshotTo:snapshot];
        });
    }
}

- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
    if (!_window) {
        [_pendingURLs addObjectsFromArray:urls];
        return;
    }
    GWMainWindowController *target = [self frontWindowController];
    for (NSURL *url in urls) [target openURL:url];
    [target showWindow:nil];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    // Every window gets to ask about unsaved changes; cancelling in one keeps the app open.
    for (GWMainWindowController *controller in [_windows copy]) {
        if (![controller confirmCloseAll]) {
            return NSTerminateCancel;
        }
    }
    return NSTerminateNow;
}

// MARK: Windows

/// A new window, kept in the list until it closes.
- (GWMainWindowController *)makeWindowController {
    GWMainWindowController *controller = [GWMainWindowController new];
    [_windows addObject:controller];
    __weak GWAppDelegate *weakSelf = self;
    __weak GWMainWindowController *weakController = controller;
    [NSNotificationCenter.defaultCenter addObserverForName:NSWindowWillCloseNotification object:controller.window queue:nil
                                                usingBlock:^(NSNotification *note) {
        GWAppDelegate *strongSelf = weakSelf;
        GWMainWindowController *closing = weakController;
        if (strongSelf != nil && closing != nil) {
            [strongSelf->_windows removeObject:closing];
        }
    }];
    return controller;
}

/// The controller of the window the user is working in.
- (GWMainWindowController *)frontWindowController {
    for (GWMainWindowController *controller in _windows) {
        if (controller.window == NSApp.keyWindow) {
            return controller;
        }
    }
    return _windows.lastObject ?: _window;
}

- (IBAction)newWindow:(id)sender {
    GWMainWindowController *controller = [self makeWindowController];
    // Offset from the one before, so they don't sit exactly on top of each other.
    NSWindow *front = [self frontWindowController].window;
    if (controller.window != front && front != nil) {
        NSRect frame = front.frame;
        [controller.window setFrame:NSOffsetRect(frame, 28, -28) display:NO];
    }
    [controller showWindow:nil];
}

- (IBAction)openFolderInNewWindow:(id)sender {
    GWMainWindowController *controller = [self makeWindowController];
    NSWindow *front = [self frontWindowController].window;
    if (front != nil && front != controller.window) {
        [controller.window setFrame:NSOffsetRect(front.frame, 28, -28) display:NO];
    }
    [controller showWindow:nil];
    [controller openFolder:nil];
}

// MARK: Menu bar

- (NSMenuItem *)item:(NSString *)title action:(SEL)action key:(NSString *)key modifiers:(NSEventModifierFlags)modifiers {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:key];
    item.keyEquivalentModifierMask = modifiers;
    return item;
}

- (NSMenuItem *)item:(NSString *)title action:(SEL)action key:(NSString *)key {
    return [self item:title action:action key:key modifiers:NSEventModifierFlagCommand];
}

- (NSMenu *)submenu:(NSString *)title items:(NSArray<NSMenuItem *> *)items parent:(NSMenu *)parent {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:title];
    for (NSMenuItem *item in items) [menu addItem:item];
    NSMenuItem *holder = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
    holder.submenu = menu;
    [parent addItem:holder];
    return menu;
}

/// File > Open Recent. The list is rebuilt each time the menu opens, from the folders and
/// files macOS has noted as recent (MainWindow notes them when they are opened).
/// Edit > Transform: case changes and line sorting.
- (NSMenuItem *)transformItem {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Transform"];
    [menu addItem:[self item:@"Make Upper Case" action:@selector(makeUpperCase:) key:@""]];
    [menu addItem:[self item:@"Make Lower Case" action:@selector(makeLowerCase:) key:@""]];
    [menu addItem:[self item:@"Make Title Case" action:@selector(makeTitleCase:) key:@""]];
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItem:[self item:@"Sort Lines Ascending" action:@selector(sortLinesAscending:) key:@""]];
    [menu addItem:[self item:@"Sort Lines Descending" action:@selector(sortLinesDescending:) key:@""]];
    [menu addItem:[self item:@"Remove Duplicate Lines" action:@selector(removeDuplicateLines:) key:@""]];
    NSMenuItem *holder = [[NSMenuItem alloc] initWithTitle:@"Transform" action:nil keyEquivalent:@""];
    holder.submenu = menu;
    return holder;
}

- (NSMenuItem *)openRecentItem {
    _recentMenu = [[NSMenu alloc] initWithTitle:@"Open Recent"];
    _recentMenu.delegate = self;
    NSMenuItem *holder = [[NSMenuItem alloc] initWithTitle:@"Open Recent" action:nil keyEquivalent:@""];
    holder.submenu = _recentMenu;
    return holder;
}

- (void)fillRecentMenu {
    [_recentMenu removeAllItems];
    NSArray<NSURL *> *recent = NSDocumentController.sharedDocumentController.recentDocumentURLs;
    for (NSURL *url in recent) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:url.lastPathComponent action:@selector(openRecent:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = url;
        item.toolTip = url.path;
        NSImage *icon = [NSWorkspace.sharedWorkspace iconForFile:url.path];
        icon.size = NSMakeSize(16, 16);
        item.image = icon;
        [_recentMenu addItem:item];
    }
    if (recent.count == 0) {
        NSMenuItem *empty = [[NSMenuItem alloc] initWithTitle:@"No Recent Items" action:nil keyEquivalent:@""];
        empty.enabled = NO;
        [_recentMenu addItem:empty];
    }
    [_recentMenu addItem:NSMenuItem.separatorItem];
    NSMenuItem *clear = [[NSMenuItem alloc] initWithTitle:@"Clear Menu" action:@selector(clearRecentDocuments:) keyEquivalent:@""];
    clear.target = NSDocumentController.sharedDocumentController;
    [_recentMenu addItem:clear];
}

- (void)openRecent:(NSMenuItem *)sender {
    NSURL *url = sender.representedObject;
    GWMainWindowController *target = [self frontWindowController];
    [target openURL:url];
    [target showWindow:nil];
}

/// The Glasswork menu: about, settings, hide, quit.
- (void)addAppMenuTo:(NSMenu *)main {
    [self submenu:@"Glasswork" items:@[
        [self item:@"About Glasswork" action:@selector(orderFrontStandardAboutPanel:) key:@""],
        NSMenuItem.separatorItem,
        [self item:@"Settings…" action:@selector(openSettings:) key:@","],
        [self item:@"Keyboard Shortcuts (JSON)…" action:@selector(openKeybindings:) key:@""],
        NSMenuItem.separatorItem,
        [self item:@"Hide Glasswork" action:@selector(hide:) key:@"h"],
        [self item:@"Hide Others" action:@selector(hideOtherApplications:) key:@"h" modifiers:kCommand | kOption],
        [self item:@"Show All" action:@selector(unhideAllApplications:) key:@""],
        NSMenuItem.separatorItem,
        [self item:@"Quit Glasswork" action:@selector(terminate:) key:@"q"],
    ] parent:main];
}

/// File: new, open, save, close.
- (void)addFileMenuTo:(NSMenu *)main {
    [self submenu:@"File" items:@[
        [self item:@"New File" action:@selector(newDocument:) key:@"n"],
        [self item:@"New Window" action:@selector(newWindow:) key:@"n" modifiers:kCommand | kShift],
        [self item:@"Open Folder in New Window…" action:@selector(openFolderInNewWindow:) key:@"o" modifiers:kCommand | kOption | kShift],
        [self item:@"Open…" action:@selector(openDocument:) key:@"o"],
        [self item:@"Open Folder…" action:@selector(openFolder:) key:@"o" modifiers:kCommand | kShift],
        [self item:@"Open Remote Folder (SSH)…" action:@selector(openRemoteFolder:) key:@"" modifiers:0],
        [self openRecentItem],
        NSMenuItem.separatorItem,
        [self item:@"Save" action:@selector(saveDocument:) key:@"s"],
        [self item:@"Save As…" action:@selector(saveDocumentAs:) key:@"s" modifiers:kCommand | kShift],
        NSMenuItem.separatorItem,
        [self item:@"Save All" action:@selector(saveAllDocuments:) key:@"s" modifiers:kCommand | kOption],
        NSMenuItem.separatorItem,
        [self item:@"Close Tab" action:@selector(closeTab:) key:@"w"],
        [self item:@"Close Other Tabs" action:@selector(closeOtherTabs:) key:@"t" modifiers:kCommand | kOption],
        [self item:@"Reopen Closed Tab" action:@selector(reopenClosedTab:) key:@"t" modifiers:kCommand | kShift],
        [self item:@"Close Window" action:@selector(performClose:) key:@"w" modifiers:kCommand | kShift],
    ] parent:main];
}

/// Edit: undo, clipboard, line operations, cursors, folding.
- (void)addEditMenuTo:(NSMenu *)main {
    [self submenu:@"Edit" items:@[
        [self item:@"Undo" action:@selector(undo:) key:@"z"],
        [self item:@"Redo" action:@selector(redo:) key:@"z" modifiers:kCommand | kShift],
        NSMenuItem.separatorItem,
        [self item:@"Cut" action:@selector(cut:) key:@"x"],
        [self item:@"Copy" action:@selector(copy:) key:@"c"],
        [self item:@"Paste" action:@selector(paste:) key:@"v"],
        [self item:@"Select All" action:@selector(selectAll:) key:@"a"],
        NSMenuItem.separatorItem,
        [self item:@"Toggle Line Comment" action:@selector(toggleLineComment:) key:@"/"],
        [self item:@"Indent Lines" action:@selector(indentLines:) key:@"]"],
        [self item:@"Outdent Lines" action:@selector(outdentLines:) key:@"["],
        NSMenuItem.separatorItem,
        [self item:@"Move Line Up" action:@selector(moveLinesUp:) key:SpecialKey(NSUpArrowFunctionKey) modifiers:kOption],
        [self item:@"Move Line Down" action:@selector(moveLinesDown:) key:SpecialKey(NSDownArrowFunctionKey) modifiers:kOption],
        [self item:@"Duplicate Line Up" action:@selector(duplicateLinesUp:) key:SpecialKey(NSUpArrowFunctionKey) modifiers:kOption | kShift],
        [self item:@"Duplicate Line Down" action:@selector(duplicateLinesDown:) key:SpecialKey(NSDownArrowFunctionKey) modifiers:kOption | kShift],
        [self item:@"Delete Line" action:@selector(deleteLines:) key:@"k" modifiers:kCommand | kShift],
        [self item:@"Join Lines" action:@selector(joinSelectedLines:) key:@"j" modifiers:kControl],
        [self transformItem],
        [self item:@"Insert Line Below" action:@selector(insertLineBelow:) key:@"\r" modifiers:kCommand],
        [self item:@"Insert Line Above" action:@selector(insertLineAbove:) key:@"\r" modifiers:kCommand | kShift],
        [self item:@"Expand Selection" action:@selector(expandSelection:)
               key:SpecialKey(NSRightArrowFunctionKey)
         modifiers:kControl | kCommand | kShift],
        [self item:@"Shrink Selection" action:@selector(shrinkSelection:)
               key:SpecialKey(NSLeftArrowFunctionKey)
         modifiers:kControl | kCommand | kShift],
        [self item:@"Go to Matching Bracket" action:@selector(goToMatchingBracket:) key:@"\\" modifiers:kCommand | kShift],
        [self item:@"Add Next Occurrence" action:@selector(selectNextOccurrence:) key:@"d"],
        [self item:@"Select All Occurrences" action:@selector(selectAllOccurrences:) key:@"g" modifiers:kControl | kCommand],
        [self item:@"Add Cursor Above" action:@selector(addCursorAbove:) key:SpecialKey(NSUpArrowFunctionKey) modifiers:kCommand | kOption],
        [self item:@"Add Cursor Below" action:@selector(addCursorBelow:) key:SpecialKey(NSDownArrowFunctionKey) modifiers:kCommand | kOption],
        NSMenuItem.separatorItem,
        [self item:@"Fold" action:@selector(foldCode:) key:@"[" modifiers:kCommand | kOption],
        [self item:@"Unfold" action:@selector(unfoldCode:) key:@"]" modifiers:kCommand | kOption],
        [self item:@"Fold All" action:@selector(foldAllCode:) key:@"[" modifiers:kCommand | kOption | kShift],
        [self item:@"Unfold All" action:@selector(unfoldAllCode:) key:@"]" modifiers:kCommand | kOption | kShift],
        [self item:@"Word Wrap" action:@selector(toggleWordWrap:) key:@"z" modifiers:kOption],
        NSMenuItem.separatorItem,
        [self item:@"Inspect Colors…" action:@selector(inspectColors:) key:@"c" modifiers:kCommand | kOption],
    ] parent:main];
}

/// Find: search in the file and in the project.
- (void)addFindMenuTo:(NSMenu *)main {
    [self submenu:@"Find" items:@[
        [self item:@"Find…" action:@selector(showFind:) key:@"f"],
        [self item:@"Find and Replace…" action:@selector(showFindAndReplace:) key:@"f" modifiers:kCommand | kOption],
        [self item:@"Find Next" action:@selector(findNext:) key:@"g"],
        [self item:@"Find Previous" action:@selector(findPrevious:) key:@"g" modifiers:kCommand | kShift],
        [self item:@"Use Selection for Find" action:@selector(useSelectionForFind:) key:@"e"],
        NSMenuItem.separatorItem,
        [self item:@"Find in Files…" action:@selector(findInFiles:) key:@"f" modifiers:kCommand | kShift],
    ] parent:main];
}

/// View: sidebar, tabs, text size and the editor's visual options. Returns the menu so Theme and Editor Opacity can be added to it.
- (NSMenu *)addViewMenuTo:(NSMenu *)main {
    NSMenu *view = [self submenu:@"View" items:@[
        [self item:@"Toggle Sidebar" action:@selector(toggleSidebar:) key:@"b"],
        [self item:@"Show Files" action:@selector(showExplorer:) key:@"e" modifiers:kCommand | kShift],
        [self item:@"Show Source Control" action:@selector(showSourceControl:) key:@"g" modifiers:kControl | kShift],
        [self item:@"Next Tab" action:@selector(selectNextTab:) key:@"]" modifiers:kCommand | kShift],
        [self item:@"Previous Tab" action:@selector(selectPreviousTab:) key:@"[" modifiers:kCommand | kShift],
        [self item:@"Open Markdown Preview" action:@selector(openMarkdownPreview:) key:@"v" modifiers:kCommand | kShift],
        NSMenuItem.separatorItem,
        [self item:@"Bigger Text" action:@selector(increaseFontSize:) key:@"="],
        [self item:@"Smaller Text" action:@selector(decreaseFontSize:) key:@"-"],
        [self item:@"Actual Size" action:@selector(resetFontSize:) key:@"0"],
        NSMenuItem.separatorItem,
        [self settingToggle:@"Rainbow Variables" tag:GWSettingRainbow],
        [self settingToggle:@"Highlight Occurrences" tag:GWSettingOccurrences],
        [self settingToggle:@"Bracket Pair Colors" tag:GWSettingBrackets],
        [self settingToggle:@"Indent Guides" tag:GWSettingGuides],
        [self settingToggle:@"Section Dividers" tag:GWSettingDividers],
        [self settingToggle:@"Minimap" tag:GWSettingMinimap],
        NSMenuItem.separatorItem,
    ] parent:main];
    return view;
}

/// Go: files, symbols, navigation history, code intelligence.
- (void)addGoMenuTo:(NSMenu *)main {
    [self submenu:@"Go" items:@[
        [self item:@"Go to File…" action:@selector(quickOpen:) key:@"p"],
        [self item:@"Command Palette…" action:@selector(showCommandPalette:) key:@"p" modifiers:kCommand | kShift],
        [self item:@"Back" action:@selector(goBack:) key:@"-" modifiers:kControl],
        [self item:@"Forward" action:@selector(goForward:) key:@"-" modifiers:kControl | kShift],
        NSMenuItem.separatorItem,
        [self item:@"Go to Line…" action:@selector(goToLine:) key:@"g" modifiers:kControl],
        [self item:@"Jump to Section…" action:@selector(jumpToSection:) key:@"6" modifiers:kControl],
        [self item:@"Next Change" action:@selector(nextChange:)
               key:SpecialKey(NSDownArrowFunctionKey)
         modifiers:kControl | kOption],
        [self item:@"Previous Change" action:@selector(previousChange:)
               key:SpecialKey(NSUpArrowFunctionKey)
         modifiers:kControl | kOption],
        NSMenuItem.separatorItem,
        [self item:@"Complete Code…" action:@selector(completeCode:) key:@" " modifiers:kControl],
        [self item:@"Go to Definition" action:@selector(goToDefinition:) key:@"d" modifiers:kCommand | kControl],
        [self item:@"Find References…" action:@selector(findReferences:) key:@"r" modifiers:kCommand | kControl],
        [self item:@"Check File for Problems…" action:@selector(checkProblems:) key:@"m" modifiers:kCommand | kShift],
        NSMenuItem.separatorItem,
        [self item:@"Go to Symbol in File…" action:@selector(goToSymbolInFile:) key:@"r"],
        [self item:@"Go to Symbol in Project…" action:@selector(goToSymbolInWorkspace:) key:@"t" modifiers:kCommand],
        [self item:@"Quick Fix…" action:@selector(showQuickFixes:) key:@"." modifiers:kCommand],
        [self item:@"Rename Symbol…" action:@selector(renameSymbol:) key:SpecialKey(NSF2FunctionKey) modifiers:0],
        [self item:@"Format Document" action:@selector(formatDocument:) key:@"f" modifiers:kOption | kShift],
    ] parent:main];
}

/// Run: build, run and the debugger. Debugger keys are the usual F-keys.
- (void)addRunMenuTo:(NSMenu *)main {
    [self submenu:@"Run" items:@[
        [self item:@"Build" action:@selector(buildProject:) key:@"b" modifiers:kCommand | kShift],
        [self item:@"Run Task…" action:@selector(runTask:) key:@"b" modifiers:kCommand | kOption],
        [self item:@"Run Current File" action:@selector(runCurrentFile:) key:@"r" modifiers:kCommand | kOption],
        NSMenuItem.separatorItem,
        [self item:@"Start Debugging / Continue" action:@selector(startDebugging:) key:SpecialKey(NSF5FunctionKey) modifiers:0],
        [self item:@"Debug Current File" action:@selector(debugCurrentFile:) key:SpecialKey(NSF5FunctionKey) modifiers:kOption],
        [self item:@"Debug Executable…" action:@selector(debugExecutable:) key:@""],
        [self item:@"Stop Debugging" action:@selector(stopDebugging:) key:SpecialKey(NSF5FunctionKey) modifiers:kShift],
        NSMenuItem.separatorItem,
        [self item:@"Step Over" action:@selector(debugStepOver:) key:SpecialKey(NSF10FunctionKey) modifiers:0],
        [self item:@"Step Into" action:@selector(debugStepInto:) key:SpecialKey(NSF11FunctionKey) modifiers:0],
        [self item:@"Step Out" action:@selector(debugStepOut:) key:SpecialKey(NSF11FunctionKey) modifiers:kShift],
        NSMenuItem.separatorItem,
        [self item:@"Toggle Breakpoint" action:@selector(toggleBreakpoint:) key:SpecialKey(NSF9FunctionKey) modifiers:0],
        [self item:@"Remove All Breakpoints" action:@selector(removeAllBreakpoints:) key:@""],
        [self item:@"Show Run and Debug" action:@selector(showDebugPanel:) key:@"d" modifiers:kCommand | kShift],
        [self item:@"Show Extension Views" action:@selector(showExtensionViews:) key:@"e" modifiers:kControl | kShift],
    ] parent:main];
}

/// Terminal: show, create and clear terminals.
- (void)addTerminalMenuTo:(NSMenu *)main {
    [self submenu:@"Terminal" items:@[
        [self item:@"Toggle Terminal" action:@selector(toggleTerminal:) key:@"`" modifiers:kControl],
        [self item:@"New Terminal" action:@selector(newTerminal:) key:@"`" modifiers:kControl | kShift],
        [self item:@"Close Terminal" action:@selector(closeTerminal:) key:@""],
        NSMenuItem.separatorItem,
        [self item:@"Clear Terminal" action:@selector(clearTerminal:) key:@"k"],
    ] parent:main];
}

/// Claude: the chat and the one-click requests.
- (void)addClaudeMenuTo:(NSMenu *)main {
    [self submenu:@"Claude" items:@[
        [self item:@"Chat with Claude" action:@selector(toggleChat:) key:@"l"],
        [self item:@"Ask About Selection" action:@selector(askClaudeAboutSelection:) key:@"l" modifiers:kCommand | kShift],
        [self item:@"New Chat" action:@selector(newClaudeChat:) key:@"l" modifiers:kCommand | kOption],
        NSMenuItem.separatorItem,
        [self item:@"Explain Selection" action:@selector(explainSelectionWithClaude:) key:@"e" modifiers:kCommand | kOption],
        [self item:@"Find Problems" action:@selector(findProblemsWithClaude:) key:@""],
        [self item:@"Fix Compiler Problems" action:@selector(fixProblemsWithClaude:) key:@""],
        [self item:@"Write Tests" action:@selector(writeTestsWithClaude:) key:@""],
        [self item:@"Improve This Code" action:@selector(improveWithClaude:) key:@""],
    ] parent:main];
}

/// The Theme and Editor Opacity submenus of View. Their items are filled in when they open.
- (void)addThemeAndOpacityMenusTo:(NSMenu *)view {
    _themeMenu = [self submenu:@"Theme" items:@[] parent:view];
    _themeMenu.delegate = self;
    NSMenu *opacity = [self submenu:@"Editor Opacity" items:@[] parent:view];
    for (NSNumber *percent in @[@100, @90, @80, @70, @62, @50, @40]) {
        NSMenuItem *item = [self item:[NSString stringWithFormat:@"%@%%", percent] action:@selector(chooseOpacity:) key:@""];
        item.tag = percent.integerValue;
        item.target = self;
        [opacity addItem:item];
    }
    opacity.delegate = self;
}

/// Extensions: find, install and manage extensions.
- (void)addExtensionsMenuTo:(NSMenu *)main {
    NSMenu *extensions = [self submenu:@"Extensions" items:@[
        [self item:@"Search Extensions…" action:@selector(searchExtensions:) key:@"x" modifiers:kCommand | kShift],
        [self item:@"Manage Extensions…" action:@selector(manageExtensions:) key:@""],
        [self item:@"Install by ID…" action:@selector(installExtension:) key:@""],
        [self item:@"Browse Open VSX" action:@selector(browseOpenVSX:) key:@""],
        NSMenuItem.separatorItem,
        [self item:@"Select Color Theme…" action:@selector(selectColorTheme:) key:@""],
        [self item:@"Select File Icon Theme…" action:@selector(selectIconTheme:) key:@""],
        [self item:@"Show Extension Output…" action:@selector(showExtensionLogs:) key:@""],
        [self item:@"Restart Extensions" action:@selector(restartExtensionHost:) key:@""],
        NSMenuItem.separatorItem,
    ] parent:main];
    for (NSMenuItem *item in extensions.itemArray) item.target = self;
    _installedMenu = [self submenu:@"Installed" items:@[] parent:extensions];
    _installedMenu.delegate = self;
}

/// Window: the standard window commands; also tells AppKit which menu lists the windows.
- (void)addWindowMenuTo:(NSMenu *)main {
    NSMenu *window = [self submenu:@"Window" items:@[
        [self item:@"Minimize" action:@selector(performMiniaturize:) key:@"m"],
        [self item:@"Zoom" action:@selector(performZoom:) key:@""],
        NSMenuItem.separatorItem,
        [self item:@"Bring All to Front" action:@selector(arrangeInFront:) key:@""],
    ] parent:main];
    NSApp.windowsMenu = window;
}

- (NSMenu *)buildMainMenu {
    NSMenu *main = [NSMenu new];
    [self addAppMenuTo:main];
    [self addFileMenuTo:main];
    [self addEditMenuTo:main];
    [self addFindMenuTo:main];
    NSMenu *view = [self addViewMenuTo:main];
    [self addGoMenuTo:main];
    [self addRunMenuTo:main];
    [self addTerminalMenuTo:main];
    [self addClaudeMenuTo:main];
    [self addThemeAndOpacityMenusTo:view];
    [self addExtensionsMenuTo:main];
    [self addWindowMenuTo:main];

    // The text size items are handled by the app delegate, not by the front window.
    for (NSMenuItem *item in view.itemArray) {
        if (item.action == @selector(increaseFontSize:) || item.action == @selector(decreaseFontSize:) ||
            item.action == @selector(resetFontSize:)) {
            item.target = self;
        }
    }
    return main;
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    GWServices *services = GWServices.shared;
    if (menu == _recentMenu) {
        [self fillRecentMenu];
        return;
    }
    if (menu == _themeMenu) {
        [menu removeAllItems];
        NSArray<NSString *> *labels = services.themeLabels;
        if (labels.count == 0) {
            NSMenuItem *waiting = [self item:@"Themes are still installing…" action:nil key:@""];
            waiting.enabled = NO;
            [menu addItem:waiting];
        }
        for (NSString *label in labels) {
            NSMenuItem *item = [self item:label action:@selector(chooseTheme:) key:@""];
            item.target = self;
            item.state = [label isEqualToString:services.themeLabel] ? NSControlStateValueOn : NSControlStateValueOff;
            [menu addItem:item];
        }
    } else if (menu == _installedMenu) {
        [menu removeAllItems];
        for (const auto &extension : services.extensions.extensions()) {
            NSString *title = [NSString stringWithFormat:@"%s  (%s)", extension.displayName.c_str(), extension.version.c_str()];
            NSMenuItem *item = [self item:title action:nil key:@""];
            NSMenu *actions = [NSMenu new];
            NSMenuItem *uninstall = [self item:@"Uninstall" action:@selector(uninstallExtension:) key:@""];
            uninstall.target = self;
            uninstall.representedObject = @(extension.id.c_str());
            [actions addItem:uninstall];
            item.submenu = actions;
            [menu addItem:item];
        }
        if (menu.numberOfItems == 0) {
            NSMenuItem *none = [self item:@"No extensions installed" action:nil key:@""];
            none.enabled = NO;
            [menu addItem:none];
        }
    } else {  // opacity
        NSInteger current = static_cast<NSInteger>(std::lround(services.editorOpacity * 100));
        for (NSMenuItem *item in menu.itemArray) item.state = item.tag == current ? NSControlStateValueOn : NSControlStateValueOff;
    }
}

// MARK: Actions

- (void)chooseTheme:(NSMenuItem *)sender { [GWServices.shared selectThemeNamed:sender.title]; }

// MARK: Setting toggles (View menu)

- (NSMenuItem *)settingToggle:(NSString *)title tag:(GWSettingToggle)tag {
    NSMenuItem *item = [self item:title action:@selector(toggleSetting:) key:@""];
    item.tag = tag;
    item.target = self;
    return item;
}

/// The setting a toggle controls, so reading and flipping it share one place.
- (bool *)settingForToggle:(GWSettingToggle)tag in:(gw::EditorSettings &)settings {
    switch (tag) {
        case GWSettingRainbow:
            return &settings.colors.rainbowVariables;
        case GWSettingOccurrences:
            return &settings.highlightOccurrences;
        case GWSettingBrackets:
            return &settings.bracketPairColors;
        case GWSettingGuides:
            return &settings.indentGuides;
        case GWSettingDividers:
            return &settings.sectionDividers;
        case GWSettingMinimap:
            return &settings.showMinimap;
    }
    return nullptr;
}

- (void)toggleSetting:(NSMenuItem *)sender {
    GWSettingToggle tag = static_cast<GWSettingToggle>(sender.tag);
    [GWServices.shared updateSettings:^(gw::EditorSettings &settings) {
        bool *value = [self settingForToggle:tag in:settings];
        if (value) {
            *value = !*value;
        }
    }];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.action == @selector(toggleSetting:)) {
        gw::EditorSettings settings = GWServices.shared.settings;
        bool *value = [self settingForToggle:static_cast<GWSettingToggle>(item.tag) in:settings];
        item.state = value && *value ? NSControlStateValueOn : NSControlStateValueOff;
    }
    return YES;
}
- (void)chooseOpacity:(NSMenuItem *)sender { GWServices.shared.editorOpacity = sender.tag / 100.0; }
- (void)increaseFontSize:(id)sender { GWServices.shared.fontSize += 1; }
- (void)decreaseFontSize:(id)sender { GWServices.shared.fontSize -= 1; }
- (void)resetFontSize:(id)sender { GWServices.shared.fontSize = 13; }

- (void)browseOpenVSX:(id)sender {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://open-vsx.org"]];
}

- (void)installExtension:(id)sender {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Install an extension from Open VSX";
    alert.informativeText = @"Enter its ID as publisher.name, for example rust-lang.rust-analyzer or "
                            @"dracula-theme.theme-dracula. Themes, grammars and language settings are used.";
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 320, 24)];
    field.placeholderString = @"publisher.name";
    alert.accessoryView = field;
    alert.window.initialFirstResponder = field;
    [alert addButtonWithTitle:@"Install"];
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] != NSAlertFirstButtonReturn || field.stringValue.length == 0) return;

    [GWServices.shared installExtension:field.stringValue completion:^(BOOL ok, NSString *message) {
        NSAlert *result = [NSAlert new];
        result.messageText = ok ? @"Extension installed" : @"Couldn't install the extension";
        result.informativeText = message;
        [result runModal];
    }];
}

- (void)uninstallExtension:(NSMenuItem *)sender {
    [GWServices.shared uninstallExtension:sender.representedObject];
}

@end
