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

@implementation GWAppDelegate {
    GWMainWindowController *_window;                          // the first window (the debug hooks use it)
    NSMutableArray<GWMainWindowController *> *_windows;       // every open window
    NSPoint _cascadePoint;
    NSMenu *_themeMenu;
    NSMenu *_installedMenu;
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

- (NSMenu *)buildMainMenu {
    NSMenu *main = [NSMenu new];
    const NSEventModifierFlags command = NSEventModifierFlagCommand, shift = NSEventModifierFlagShift,
                               option = NSEventModifierFlagOption;

    [self submenu:@"Glasswork" items:@[
        [self item:@"About Glasswork" action:@selector(orderFrontStandardAboutPanel:) key:@""],
        NSMenuItem.separatorItem,
        [self item:@"Settings…" action:@selector(openSettings:) key:@","],
        NSMenuItem.separatorItem,
        [self item:@"Hide Glasswork" action:@selector(hide:) key:@"h"],
        [self item:@"Hide Others" action:@selector(hideOtherApplications:) key:@"h" modifiers:command | option],
        [self item:@"Show All" action:@selector(unhideAllApplications:) key:@""],
        NSMenuItem.separatorItem,
        [self item:@"Quit Glasswork" action:@selector(terminate:) key:@"q"],
    ] parent:main];

    [self submenu:@"File" items:@[
        [self item:@"New File" action:@selector(newDocument:) key:@"n"],
        [self item:@"New Window" action:@selector(newWindow:) key:@"n" modifiers:command | shift],
        [self item:@"Open Folder in New Window…" action:@selector(openFolderInNewWindow:) key:@"o" modifiers:command | option | shift],
        [self item:@"Open…" action:@selector(openDocument:) key:@"o"],
        [self item:@"Open Folder…" action:@selector(openFolder:) key:@"o" modifiers:command | shift],
        NSMenuItem.separatorItem,
        [self item:@"Save" action:@selector(saveDocument:) key:@"s"],
        [self item:@"Save As…" action:@selector(saveDocumentAs:) key:@"s" modifiers:command | shift],
        NSMenuItem.separatorItem,
        [self item:@"Close Tab" action:@selector(closeTab:) key:@"w"],
        [self item:@"Close Window" action:@selector(performClose:) key:@"w" modifiers:command | shift],
    ] parent:main];

    [self submenu:@"Edit" items:@[
        [self item:@"Undo" action:@selector(undo:) key:@"z"],
        [self item:@"Redo" action:@selector(redo:) key:@"z" modifiers:command | shift],
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
        [self item:@"Move Line Up" action:@selector(moveLinesUp:) key:[NSString stringWithFormat:@"%C", (unichar)NSUpArrowFunctionKey] modifiers:option],
        [self item:@"Move Line Down" action:@selector(moveLinesDown:) key:[NSString stringWithFormat:@"%C", (unichar)NSDownArrowFunctionKey] modifiers:option],
        [self item:@"Duplicate Line Up" action:@selector(duplicateLinesUp:) key:[NSString stringWithFormat:@"%C", (unichar)NSUpArrowFunctionKey] modifiers:option | shift],
        [self item:@"Duplicate Line Down" action:@selector(duplicateLinesDown:) key:[NSString stringWithFormat:@"%C", (unichar)NSDownArrowFunctionKey] modifiers:option | shift],
        [self item:@"Delete Line" action:@selector(deleteLines:) key:@"k" modifiers:command | shift],
        [self item:@"Insert Line Below" action:@selector(insertLineBelow:) key:@"\r" modifiers:command],
        [self item:@"Insert Line Above" action:@selector(insertLineAbove:) key:@"\r" modifiers:command | shift],
        [self item:@"Add Next Occurrence" action:@selector(selectNextOccurrence:) key:@"d"],
        [self item:@"Select All Occurrences" action:@selector(selectAllOccurrences:) key:@"g" modifiers:NSEventModifierFlagControl | command],
        [self item:@"Add Cursor Above" action:@selector(addCursorAbove:) key:[NSString stringWithFormat:@"%C", (unichar)NSUpArrowFunctionKey] modifiers:command | option],
        [self item:@"Add Cursor Below" action:@selector(addCursorBelow:) key:[NSString stringWithFormat:@"%C", (unichar)NSDownArrowFunctionKey] modifiers:command | option],
        NSMenuItem.separatorItem,
        [self item:@"Fold" action:@selector(foldCode:) key:@"[" modifiers:command | option],
        [self item:@"Unfold" action:@selector(unfoldCode:) key:@"]" modifiers:command | option],
        [self item:@"Fold All" action:@selector(foldAllCode:) key:@"[" modifiers:command | option | shift],
        [self item:@"Unfold All" action:@selector(unfoldAllCode:) key:@"]" modifiers:command | option | shift],
        [self item:@"Word Wrap" action:@selector(toggleWordWrap:) key:@"z" modifiers:option],
        NSMenuItem.separatorItem,
        [self item:@"Inspect Colours…" action:@selector(inspectColors:) key:@"c" modifiers:command | option],
    ] parent:main];

    [self submenu:@"Find" items:@[
        [self item:@"Find…" action:@selector(showFind:) key:@"f"],
        [self item:@"Find and Replace…" action:@selector(showFindAndReplace:) key:@"f" modifiers:command | option],
        [self item:@"Find Next" action:@selector(findNext:) key:@"g"],
        [self item:@"Find Previous" action:@selector(findPrevious:) key:@"g" modifiers:command | shift],
        [self item:@"Use Selection for Find" action:@selector(useSelectionForFind:) key:@"e"],
        NSMenuItem.separatorItem,
        [self item:@"Find in Files…" action:@selector(findInFiles:) key:@"f" modifiers:command | shift],
    ] parent:main];

    NSMenu *view = [self submenu:@"View" items:@[
        [self item:@"Toggle Sidebar" action:@selector(toggleSidebar:) key:@"b"],
        [self item:@"Show Files" action:@selector(showExplorer:) key:@"e" modifiers:command | shift],
        [self item:@"Show Source Control" action:@selector(showSourceControl:) key:@"g" modifiers:NSEventModifierFlagControl | shift],
        [self item:@"Next Tab" action:@selector(selectNextTab:) key:@"]" modifiers:command | shift],
        [self item:@"Previous Tab" action:@selector(selectPreviousTab:) key:@"[" modifiers:command | shift],
        [self item:@"Open Markdown Preview" action:@selector(openMarkdownPreview:) key:@"v" modifiers:command | shift],
        NSMenuItem.separatorItem,
        [self item:@"Bigger Text" action:@selector(increaseFontSize:) key:@"="],
        [self item:@"Smaller Text" action:@selector(decreaseFontSize:) key:@"-"],
        [self item:@"Actual Size" action:@selector(resetFontSize:) key:@"0"],
        NSMenuItem.separatorItem,
        [self settingToggle:@"Rainbow Variables" tag:GWSettingRainbow],
        [self settingToggle:@"Highlight Occurrences" tag:GWSettingOccurrences],
        [self settingToggle:@"Bracket Pair Colours" tag:GWSettingBrackets],
        [self settingToggle:@"Indent Guides" tag:GWSettingGuides],
        [self settingToggle:@"Section Dividers" tag:GWSettingDividers],
        [self settingToggle:@"Minimap" tag:GWSettingMinimap],
        NSMenuItem.separatorItem,
    ] parent:main];

    [self submenu:@"Go" items:@[
        [self item:@"Go to File…" action:@selector(quickOpen:) key:@"p"],
        [self item:@"Command Palette…" action:@selector(showCommandPalette:) key:@"p" modifiers:command | shift],
        [self item:@"Go to Line…" action:@selector(goToLine:) key:@"g" modifiers:NSEventModifierFlagControl],
        [self item:@"Jump to Section…" action:@selector(jumpToSection:) key:@"6" modifiers:NSEventModifierFlagControl],
        [self item:@"Next Change" action:@selector(nextChange:)
               key:[NSString stringWithFormat:@"%C", (unichar)NSDownArrowFunctionKey]
         modifiers:NSEventModifierFlagControl | option],
        [self item:@"Previous Change" action:@selector(previousChange:)
               key:[NSString stringWithFormat:@"%C", (unichar)NSUpArrowFunctionKey]
         modifiers:NSEventModifierFlagControl | option],
        NSMenuItem.separatorItem,
        [self item:@"Complete Code…" action:@selector(completeCode:) key:@" " modifiers:NSEventModifierFlagControl],
        [self item:@"Go to Definition" action:@selector(goToDefinition:) key:@"d" modifiers:command | NSEventModifierFlagControl],
        [self item:@"Find References…" action:@selector(findReferences:) key:@"r" modifiers:command | NSEventModifierFlagControl],
        [self item:@"Check File for Problems…" action:@selector(checkProblems:) key:@"m" modifiers:command | shift],
        NSMenuItem.separatorItem,
        [self item:@"Go to Symbol in File…" action:@selector(goToSymbolInFile:) key:@"r"],
        [self item:@"Go to Symbol in Project…" action:@selector(goToSymbolInWorkspace:) key:@"t" modifiers:command],
        [self item:@"Quick Fix…" action:@selector(showQuickFixes:) key:@"." modifiers:command],
        [self item:@"Rename Symbol…" action:@selector(renameSymbol:) key:[NSString stringWithFormat:@"%C", (unichar)NSF2FunctionKey] modifiers:0],
        [self item:@"Format Document" action:@selector(formatDocument:) key:@"f" modifiers:option | shift],
    ] parent:main];
    NSString *f5 = [NSString stringWithFormat:@"%C", (unichar)NSF5FunctionKey];
    NSString *f9 = [NSString stringWithFormat:@"%C", (unichar)NSF9FunctionKey];
    NSString *f10 = [NSString stringWithFormat:@"%C", (unichar)NSF10FunctionKey];
    NSString *f11 = [NSString stringWithFormat:@"%C", (unichar)NSF11FunctionKey];
    [self submenu:@"Run" items:@[
        [self item:@"Build" action:@selector(buildProject:) key:@"b" modifiers:command | shift],
        [self item:@"Run Task…" action:@selector(runTask:) key:@"b" modifiers:command | option],
        [self item:@"Run Current File" action:@selector(runCurrentFile:) key:@"r" modifiers:command | option],
        NSMenuItem.separatorItem,
        [self item:@"Start Debugging / Continue" action:@selector(startDebugging:) key:f5 modifiers:0],
        [self item:@"Debug Current File" action:@selector(debugCurrentFile:) key:f5 modifiers:option],
        [self item:@"Debug Executable…" action:@selector(debugExecutable:) key:@""],
        [self item:@"Stop Debugging" action:@selector(stopDebugging:) key:f5 modifiers:shift],
        NSMenuItem.separatorItem,
        [self item:@"Step Over" action:@selector(debugStepOver:) key:f10 modifiers:0],
        [self item:@"Step Into" action:@selector(debugStepInto:) key:f11 modifiers:0],
        [self item:@"Step Out" action:@selector(debugStepOut:) key:f11 modifiers:shift],
        NSMenuItem.separatorItem,
        [self item:@"Toggle Breakpoint" action:@selector(toggleBreakpoint:) key:f9 modifiers:0],
        [self item:@"Remove All Breakpoints" action:@selector(removeAllBreakpoints:) key:@""],
        [self item:@"Show Run and Debug" action:@selector(showDebugPanel:) key:@"d" modifiers:command | shift],
    ] parent:main];

    [self submenu:@"Terminal" items:@[
        [self item:@"Toggle Terminal" action:@selector(toggleTerminal:) key:@"`" modifiers:NSEventModifierFlagControl],
        [self item:@"New Terminal" action:@selector(newTerminal:) key:@"`" modifiers:NSEventModifierFlagControl | shift],
        [self item:@"Close Terminal" action:@selector(closeTerminal:) key:@""],
        NSMenuItem.separatorItem,
        [self item:@"Clear Terminal" action:@selector(clearTerminal:) key:@"k"],
    ] parent:main];

    [self submenu:@"Claude" items:@[
        [self item:@"Chat with Claude" action:@selector(toggleChat:) key:@"l"],
        [self item:@"Ask About Selection" action:@selector(askClaudeAboutSelection:) key:@"l" modifiers:command | shift],
        [self item:@"New Chat" action:@selector(newClaudeChat:) key:@"l" modifiers:command | option],
        NSMenuItem.separatorItem,
        [self item:@"Explain Selection" action:@selector(explainSelectionWithClaude:) key:@"e" modifiers:command | option],
        [self item:@"Find Problems" action:@selector(findProblemsWithClaude:) key:@""],
        [self item:@"Fix Compiler Problems" action:@selector(fixProblemsWithClaude:) key:@""],
        [self item:@"Write Tests" action:@selector(writeTestsWithClaude:) key:@""],
        [self item:@"Improve This Code" action:@selector(improveWithClaude:) key:@""],
    ] parent:main];
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

    NSMenu *extensions = [self submenu:@"Extensions" items:@[
        [self item:@"Install from Open VSX…" action:@selector(installExtension:) key:@"x" modifiers:command | shift],
        [self item:@"Browse Open VSX" action:@selector(browseOpenVSX:) key:@""],
        NSMenuItem.separatorItem,
    ] parent:main];
    for (NSMenuItem *item in extensions.itemArray) item.target = self;
    _installedMenu = [self submenu:@"Installed" items:@[] parent:extensions];
    _installedMenu.delegate = self;

    NSMenu *window = [self submenu:@"Window" items:@[
        [self item:@"Minimize" action:@selector(performMiniaturize:) key:@"m"],
        [self item:@"Zoom" action:@selector(performZoom:) key:@""],
        NSMenuItem.separatorItem,
        [self item:@"Bring All to Front" action:@selector(arrangeInFront:) key:@""],
    ] parent:main];
    NSApp.windowsMenu = window;

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
