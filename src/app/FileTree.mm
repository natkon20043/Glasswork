#import "FileTree.h"

#import "FileIcons.h"

// ===========================================================================
// One file or folder

/// Folder contents load the first time they're expanded.
@interface GWFileNode : NSObject
@property (nonatomic, copy) NSURL *url;
@property (nonatomic) BOOL isDirectory;
@property (nonatomic, nullable, copy) NSArray<GWFileNode *> *children;
@end

@implementation GWFileNode

/// Reads the folder from disk. Nodes for items that were already known are reused, so what was
/// loaded and expanded inside them stays that way.
- (NSArray<GWFileNode *> *)readChildrenReusing:(NSArray<GWFileNode *> *)existing {
    NSMutableDictionary<NSString *, GWFileNode *> *known = [NSMutableDictionary dictionary];
    for (GWFileNode *node in existing) {
        known[node.url.path] = node;
    }
    NSArray<NSURL *> *urls = [NSFileManager.defaultManager contentsOfDirectoryAtURL:self.url
                                                        includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                                                                           options:0
                                                                             error:nil];
    NSMutableArray<GWFileNode *> *nodes = [NSMutableArray array];
    for (NSURL *url in urls) {
        NSString *name = url.lastPathComponent;
        // Git's own folder and macOS's clutter are never wanted in the tree.
        if ([name isEqualToString:@".git"] || [name isEqualToString:@".DS_Store"] || [name hasSuffix:@".glasswork-save"] ||
            [name hasSuffix:@".glasswork-replace"]) {
            continue;
        }
        GWFileNode *node = known[url.path];
        if (node == nil) {
            node = [GWFileNode new];
            node.url = url;
        }
        NSNumber *directory = nil;
        [url getResourceValue:&directory forKey:NSURLIsDirectoryKey error:nil];
        node.isDirectory = directory.boolValue;
        [nodes addObject:node];
    }
    // Folders first, then files, each alphabetically the way Finder sorts.
    [nodes sortUsingComparator:^NSComparisonResult(GWFileNode *a, GWFileNode *b) {
        if (a.isDirectory != b.isDirectory) return a.isDirectory ? NSOrderedAscending : NSOrderedDescending;
        return [a.url.lastPathComponent localizedStandardCompare:b.url.lastPathComponent];
    }];
    return nodes;
}

- (NSArray<GWFileNode *> *)loadedChildren {
    if (!self.isDirectory) return @[];
    if (self.children) return self.children;
    self.children = [self readChildrenReusing:@[]];
    return self.children;
}

@end

// ===========================================================================
// An outline that asks for a context menu

@interface GWOutlineView : NSOutlineView
@property (nonatomic, copy, nullable) NSMenu * (^menuForRow)(NSInteger row);
@end

@implementation GWOutlineView

- (NSMenu *)menuForEvent:(NSEvent *)event {
    NSInteger row = [self rowAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    if (row >= 0) {
        [self selectRowIndexes:[NSIndexSet indexSetWithIndex:static_cast<NSUInteger>(row)] byExtendingSelection:NO];
    }
    return self.menuForRow ? self.menuForRow(row) : nil;
}

@end

// ===========================================================================
// The tree

@implementation GWFileTree {
    GWOutlineView *_outline;
    GWFileNode *_root;
    GWFileNode *_menuNode;  // the item a context menu was opened on
}

- (instancetype)init {
    if ((self = [super init])) {
        _outline = [GWOutlineView new];
        NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"name"];
        [_outline addTableColumn:column];
        _outline.outlineTableColumn = column;
        _outline.headerView = nil;
        _outline.style = NSTableViewStyleSourceList;
        _outline.backgroundColor = NSColor.clearColor;
        _outline.rowHeight = 24;
        _outline.indentationPerLevel = 12;
        _outline.dataSource = self;
        _outline.delegate = self;
        _outline.target = self;
        _outline.action = @selector(clicked:);
        _outline.doubleAction = @selector(clicked:);
        [_outline registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
        [_outline setDraggingSourceOperationMask:NSDragOperationEvery forLocal:YES];
        [_outline setDraggingSourceOperationMask:NSDragOperationCopy forLocal:NO];
        __weak GWFileTree *weakSelf = self;
        _outline.menuForRow = ^NSMenu *(NSInteger row) { return [weakSelf menuForRow:row]; };

        _view = [NSScrollView new];
        _view.documentView = _outline;
        _view.drawsBackground = NO;
        _view.hasVerticalScroller = YES;
        _view.autohidesScrollers = YES;
        _view.scrollerStyle = NSScrollerStyleOverlay;
        _view.automaticallyAdjustsContentInsets = NO;
    }
    return self;
}

- (void)setRootURL:(NSURL *)rootURL {
    _rootURL = [rootURL copy];
    if (rootURL) {
        _root = [GWFileNode new];
        _root.url = rootURL;
        _root.isDirectory = YES;
    } else {
        _root = nil;
    }
    [self reload];
}

- (void)reload {
    if (_root == nil) {
        [_outline reloadData];
        return;
    }
    [self reloadNode:_root];
}

/// Re-reads a node's children (and those of loaded folders below it), keeping what is expanded.
- (void)reloadNode:(GWFileNode *)node {
    if (node.children == nil) {
        // Not loaded yet, so there is nothing on screen to refresh.
        if (node == _root) [_outline reloadData];
        return;
    }
    node.children = [node readChildrenReusing:node.children];
    for (GWFileNode *child in node.children) {
        if (child.isDirectory && child.children != nil) [self reloadNode:child];
    }
    if (node == _root) {
        [_outline reloadData];
    } else {
        [_outline reloadItem:node reloadChildren:YES];
    }
}

/// The node for a folder or file, if it is in the loaded part of the tree.
- (GWFileNode *)nodeForURL:(NSURL *)url {
    if (_root == nil) return nil;
    NSString *target = url.URLByStandardizingPath.path;
    if ([target isEqualToString:_root.url.URLByStandardizingPath.path]) return _root;
    GWFileNode *node = _root;
    NSString *prefix = _root.url.URLByStandardizingPath.path;
    if (![target hasPrefix:[prefix stringByAppendingString:@"/"]]) return nil;
    NSArray<NSString *> *parts = [[target substringFromIndex:prefix.length + 1] componentsSeparatedByString:@"/"];
    for (NSString *part in parts) {
        GWFileNode *next = nil;
        for (GWFileNode *child in node.children) {
            if ([child.url.lastPathComponent isEqualToString:part]) {
                next = child;
                break;
            }
        }
        if (next == nil) return nil;
        node = next;
    }
    return node;
}

- (void)reloadDirectory:(NSURL *)folder {
    GWFileNode *node = [self nodeForURL:folder];
    if (node != nil && node.isDirectory && node.children != nil) {
        node.children = [node readChildrenReusing:node.children];
        if (node == _root) {
            [_outline reloadData];
        } else {
            [_outline reloadItem:node reloadChildren:YES];
        }
    }
}

- (void)collapseAll {
    [_outline collapseItem:nil collapseChildren:YES];
}

- (void)clicked:(id)sender {
    GWFileNode *node = [_outline itemAtRow:_outline.clickedRow];
    if (!node) return;
    if (node.isDirectory) {
        if ([_outline isItemExpanded:node]) {
            [_outline collapseItem:node];
        } else {
            [_outline expandItem:node];
        }
    } else if (self.onOpenFile) {
        self.onOpenFile(node.url);
    }
}

// ---------------------------------------------------------------------------
// MARK: Data source

- (NSInteger)outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(GWFileNode *)item {
    GWFileNode *node = item ?: _root;
    return node ? static_cast<NSInteger>([node loadedChildren].count) : 0;
}

- (id)outlineView:(NSOutlineView *)outlineView child:(NSInteger)index ofItem:(GWFileNode *)item {
    GWFileNode *node = item ?: _root;
    return [node loadedChildren][static_cast<NSUInteger>(index)];
}

- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(GWFileNode *)item {
    return item.isDirectory;
}

- (NSView *)outlineView:(NSOutlineView *)outlineView viewForTableColumn:(NSTableColumn *)tableColumn item:(GWFileNode *)item {
    NSTableCellView *cell = [outlineView makeViewWithIdentifier:@"file" owner:self];
    if (!cell) {
        cell = [NSTableCellView new];
        cell.identifier = @"file";
        NSImageView *icon = [NSImageView new];
        NSTextField *label = [NSTextField labelWithString:@""];
        label.lineBreakMode = NSLineBreakByTruncatingMiddle;
        label.font = [NSFont systemFontOfSize:13];
        icon.translatesAutoresizingMaskIntoConstraints = NO;
        label.translatesAutoresizingMaskIntoConstraints = NO;
        [cell addSubview:icon];
        [cell addSubview:label];
        cell.imageView = icon;
        cell.textField = label;
        [NSLayoutConstraint activateConstraints:@[
            [icon.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:2],
            [icon.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [icon.widthAnchor constraintEqualToConstant:16],
            [label.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:6],
            [label.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-4],
            [label.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        ]];
    }
    NSString *name = item.url.lastPathComponent;
    cell.textField.stringValue = name;
    BOOL expanded = item.isDirectory && [outlineView isItemExpanded:item];
    cell.imageView.image = GWFileIconImage(name, item.isDirectory, expanded, 14);
    cell.imageView.contentTintColor = nil;  // the image carries its own colors
    return cell;
}

- (void)refreshIcons {
    NSInteger rows = _outline.numberOfRows;
    if (rows > 0) {
        [_outline reloadDataForRowIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, static_cast<NSUInteger>(rows))]
                            columnIndexes:[NSIndexSet indexSetWithIndex:0]];
    }
}

// A folder's icon differs open and closed (in icon themes that say so).
- (void)outlineViewItemDidExpand:(NSNotification *)notification {
    id item = notification.userInfo[@"NSObject"];
    NSInteger row = item ? [_outline rowForItem:item] : -1;
    if (row >= 0) {
        [_outline reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:static_cast<NSUInteger>(row)]
                            columnIndexes:[NSIndexSet indexSetWithIndex:0]];
    }
}

- (void)outlineViewItemDidCollapse:(NSNotification *)notification {
    [self outlineViewItemDidExpand:notification];
}

// ---------------------------------------------------------------------------
// MARK: Choosing where things go

- (NSURL *)targetFolder {
    GWFileNode *selected = _outline.selectedRow >= 0 ? [_outline itemAtRow:_outline.selectedRow] : nil;
    if (selected == nil) return _root.url;
    return selected.isDirectory ? selected.url : selected.url.URLByDeletingLastPathComponent;
}

- (void)reportError:(NSString *)title message:(NSString *)message {
    if (self.onError) {
        self.onError(title, message);
    }
}

/// A name that isn't taken in the folder: "notes.txt", "notes copy.txt", "notes copy 2.txt"…
- (NSURL *)uniqueURLForName:(NSString *)name inFolder:(NSURL *)folder suffix:(NSString *)suffix {
    NSString *stem = name.stringByDeletingPathExtension;
    NSString *extension = name.pathExtension;
    NSURL *candidate = [folder URLByAppendingPathComponent:name];
    NSInteger number = 1;
    while ([NSFileManager.defaultManager fileExistsAtPath:candidate.path]) {
        NSString *numbered = number == 1 ? [NSString stringWithFormat:@"%@%@", stem, suffix]
                                         : [NSString stringWithFormat:@"%@%@ %ld", stem, suffix, static_cast<long>(number)];
        if (extension.length > 0) numbered = [numbered stringByAppendingPathExtension:extension];
        candidate = [folder URLByAppendingPathComponent:numbered];
        ++number;
    }
    return candidate;
}

/// Shows a small dialog asking for a name. The completion gets nil if cancelled.
- (void)askForNameWithTitle:(NSString *)title
                    message:(NSString *)message
                    initial:(NSString *)initial
                 selectStem:(BOOL)selectStem
                 completion:(void (^)(NSString *_Nullable name))completion {
    NSAlert *alert = [NSAlert new];
    alert.messageText = title;
    alert.informativeText = message;
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 300, 24)];
    field.stringValue = initial;
    alert.accessoryView = field;
    [alert addButtonWithTitle:@"OK"];
    [alert addButtonWithTitle:@"Cancel"];
    alert.window.initialFirstResponder = field;
    NSWindow *window = _view.window;
    void (^finish)(NSModalResponse) = ^(NSModalResponse response) {
        NSString *name = [field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        completion(response == NSAlertFirstButtonReturn && name.length > 0 ? name : nil);
    };
    if (window) {
        [alert beginSheetModalForWindow:window completionHandler:finish];
        // Select just the name part of "notes.txt", so typing replaces it and keeps the extension.
        [window makeFirstResponder:field];
        if (selectStem && initial.pathExtension.length > 0) {
            field.currentEditor.selectedRange = NSMakeRange(0, initial.stringByDeletingPathExtension.length);
        }
    } else {
        finish([alert runModal]);
    }
}

// ---------------------------------------------------------------------------
// MARK: Creating

- (void)createItemInFolder:(NSURL *)folder isDirectory:(BOOL)isDirectory {
    NSString *title = isDirectory ? @"New Folder" : @"New File";
    NSString *message = [NSString stringWithFormat:@"In “%@”. You can write a path like src/util/helpers.cpp to make folders "
                                                   @"too.", folder.lastPathComponent];
    [self askForNameWithTitle:title message:message initial:isDirectory ? @"" : @"untitled.txt" selectStem:!isDirectory
                   completion:^(NSString *name) {
        if (name == nil) return;
        if ([name hasPrefix:@"/"] || [name containsString:@".."]) {
            [self reportError:@"That name won't work" message:@"Use a name or a relative path without “..”."];
            return;
        }
        NSURL *destination = [folder URLByAppendingPathComponent:name];
        if ([NSFileManager.defaultManager fileExistsAtPath:destination.path]) {
            [self reportError:@"That already exists" message:[NSString stringWithFormat:@"“%@” is already in this folder.", name]];
            return;
        }
        NSError *error = nil;
        NSURL *parent = isDirectory ? destination : destination.URLByDeletingLastPathComponent;
        if (![NSFileManager.defaultManager createDirectoryAtURL:parent withIntermediateDirectories:YES attributes:nil error:&error]) {
            [self reportError:@"Couldn't create the folder" message:error.localizedDescription];
            return;
        }
        if (!isDirectory && ![NSFileManager.defaultManager createFileAtPath:destination.path contents:[NSData data] attributes:nil]) {
            [self reportError:@"Couldn't create the file" message:@"Check that you can write in this folder."];
            return;
        }
        [self revealNewItem:destination];
        if (!isDirectory && self.onOpenFile) self.onOpenFile(destination);
    }];
}

- (void)createFileInFolder:(NSURL *)folder { [self createItemInFolder:folder isDirectory:NO]; }
- (void)createFolderInFolder:(NSURL *)folder { [self createItemInFolder:folder isDirectory:YES]; }

/// Shows the tree with a new item selected.
- (void)revealNewItem:(NSURL *)url {
    // Make sure each folder on the way is loaded and open.
    NSURL *folder = url.URLByDeletingLastPathComponent;
    NSMutableArray<NSURL *> *chain = [NSMutableArray array];
    NSString *rootPath = _root.url.URLByStandardizingPath.path;
    NSURL *cursor = folder;
    while ([cursor.URLByStandardizingPath.path hasPrefix:rootPath] && ![cursor.URLByStandardizingPath.path isEqualToString:rootPath]) {
        [chain insertObject:cursor atIndex:0];
        cursor = cursor.URLByDeletingLastPathComponent;
    }
    [self reloadDirectory:_root.url];
    for (NSURL *directory in chain) {
        GWFileNode *node = [self nodeForURL:directory];
        if (node == nil) {
            [self reloadDirectory:directory.URLByDeletingLastPathComponent];
            node = [self nodeForURL:directory];
        }
        if (node != nil) {
            [node loadedChildren];
            [_outline expandItem:node];
        }
    }
    [self reloadDirectory:folder];
    GWFileNode *created = [self nodeForURL:url];
    if (created != nil) {
        NSInteger row = [_outline rowForItem:created];
        if (row >= 0) {
            [_outline selectRowIndexes:[NSIndexSet indexSetWithIndex:static_cast<NSUInteger>(row)] byExtendingSelection:NO];
            [_outline scrollRowToVisible:row];
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: Context menu

- (NSMenu *)contextMenuForRow:(NSInteger)row {
    return [self menuForRow:row];
}

- (NSMenu *)menuForRow:(NSInteger)row {
    GWFileNode *node = row >= 0 ? [_outline itemAtRow:row] : nil;
    _menuNode = node;
    NSURL *folder = node == nil ? _root.url : (node.isDirectory ? node.url : node.url.URLByDeletingLastPathComponent);
    if (folder == nil) return nil;

    NSMenu *menu = [NSMenu new];
    auto add = ^NSMenuItem *(NSString *title, SEL action) {
        NSMenuItem *item = [menu addItemWithTitle:title action:action keyEquivalent:@""];
        item.target = self;
        return item;
    };
    add(@"New File…", @selector(menuNewFile:)).representedObject = folder;
    add(@"New Folder…", @selector(menuNewFolder:)).representedObject = folder;
    if (node != nil) {
        [menu addItem:NSMenuItem.separatorItem];
        add(@"Rename…", @selector(menuRename:));
        add(@"Duplicate", @selector(menuDuplicate:));
        add(@"Move to Trash", @selector(menuTrash:));
        [menu addItem:NSMenuItem.separatorItem];
        add(@"Copy Path", @selector(menuCopyPath:));
        add(@"Copy Relative Path", @selector(menuCopyRelativePath:));
        add(@"Reveal in Finder", @selector(menuReveal:));
    }
    [menu addItem:NSMenuItem.separatorItem];
    add(@"Open in Terminal", @selector(menuOpenInTerminal:)).representedObject = folder;
    add(@"Find in Folder…", @selector(menuFindInFolder:)).representedObject = folder;
    if (node != nil) {
        add(@"Ask Claude About This…", @selector(menuAskClaude:));
    }
    return menu;
}

- (void)menuNewFile:(NSMenuItem *)item { [self createFileInFolder:item.representedObject]; }
- (void)menuNewFolder:(NSMenuItem *)item { [self createFolderInFolder:item.representedObject]; }

- (void)menuRename:(NSMenuItem *)item {
    GWFileNode *node = _menuNode;
    if (node == nil) return;
    [self askForNameWithTitle:@"Rename" message:[NSString stringWithFormat:@"Give “%@” a new name.", node.url.lastPathComponent]
                      initial:node.url.lastPathComponent selectStem:!node.isDirectory completion:^(NSString *name) {
        if (name == nil || [name isEqualToString:node.url.lastPathComponent]) return;
        if ([name containsString:@"/"]) {
            [self reportError:@"That name won't work" message:@"A name can't contain a slash."];
            return;
        }
        NSURL *destination = [node.url.URLByDeletingLastPathComponent URLByAppendingPathComponent:name];
        if ([NSFileManager.defaultManager fileExistsAtPath:destination.path]) {
            [self reportError:@"That already exists" message:[NSString stringWithFormat:@"“%@” is already in this folder.", name]];
            return;
        }
        [self moveItemAtURL:node.url toURL:destination];
    }];
}

/// Moves or renames on disk, tells the window, and refreshes the two folders involved.
- (BOOL)moveItemAtURL:(NSURL *)source toURL:(NSURL *)destination {
    NSError *error = nil;
    if (![NSFileManager.defaultManager moveItemAtURL:source toURL:destination error:&error]) {
        [self reportError:@"Couldn't move it" message:error.localizedDescription];
        return NO;
    }
    if (self.onItemMoved) self.onItemMoved(source, destination);
    [self reloadDirectory:source.URLByDeletingLastPathComponent];
    if (![source.URLByDeletingLastPathComponent isEqual:destination.URLByDeletingLastPathComponent]) {
        [self reloadDirectory:destination.URLByDeletingLastPathComponent];
    }
    return YES;
}

- (void)menuDuplicate:(NSMenuItem *)item {
    GWFileNode *node = _menuNode;
    if (node == nil) return;
    NSURL *copy = [self uniqueURLForName:node.url.lastPathComponent inFolder:node.url.URLByDeletingLastPathComponent suffix:@" copy"];
    NSError *error = nil;
    if (![NSFileManager.defaultManager copyItemAtURL:node.url toURL:copy error:&error]) {
        [self reportError:@"Couldn't duplicate it" message:error.localizedDescription];
        return;
    }
    [self revealNewItem:copy];
}

- (void)menuTrash:(NSMenuItem *)item {
    GWFileNode *node = _menuNode;
    if (node == nil) return;
    NSError *error = nil;
    if (![NSFileManager.defaultManager trashItemAtURL:node.url resultingItemURL:nil error:&error]) {
        [self reportError:@"Couldn't move it to the Trash" message:error.localizedDescription];
        return;
    }
    if (self.onItemTrashed) self.onItemTrashed(node.url);
    [self reloadDirectory:node.url.URLByDeletingLastPathComponent];
}

- (void)menuCopyPath:(NSMenuItem *)item {
    if (_menuNode == nil) return;
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:_menuNode.url.path forType:NSPasteboardTypeString];
}

- (void)menuCopyRelativePath:(NSMenuItem *)item {
    if (_menuNode == nil || _root == nil) return;
    NSString *prefix = [_root.url.path stringByAppendingString:@"/"];
    NSString *path = [_menuNode.url.path hasPrefix:prefix] ? [_menuNode.url.path substringFromIndex:prefix.length] : _menuNode.url.path;
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:path forType:NSPasteboardTypeString];
}

- (void)menuReveal:(NSMenuItem *)item {
    if (_menuNode != nil) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[_menuNode.url]];
}

- (void)menuOpenInTerminal:(NSMenuItem *)item {
    if (self.onOpenInTerminal) self.onOpenInTerminal(item.representedObject);
}

- (void)menuFindInFolder:(NSMenuItem *)item {
    if (self.onFindInFolder) self.onFindInFolder(item.representedObject);
}

- (void)menuAskClaude:(NSMenuItem *)item {
    if (self.onAskClaude && _menuNode != nil) self.onAskClaude(_menuNode.url);
}

// ---------------------------------------------------------------------------
// MARK: Drag and drop

- (id<NSPasteboardWriting>)outlineView:(NSOutlineView *)outlineView pasteboardWriterForItem:(GWFileNode *)item {
    return item.url;
}

- (NSDragOperation)outlineView:(NSOutlineView *)outlineView
                  validateDrop:(id<NSDraggingInfo>)info
                  proposedItem:(GWFileNode *)item
            proposedChildIndex:(NSInteger)index {
    if (_root == nil) return NSDragOperationNone;
    // Dropping on a file means dropping in its folder; between rows means the folder they are in.
    GWFileNode *target = item;
    if (target != nil && !target.isDirectory) {
        GWFileNode *parent = [outlineView parentForItem:target];
        [outlineView setDropItem:parent dropChildIndex:NSOutlineViewDropOnItemIndex];
    } else {
        [outlineView setDropItem:target dropChildIndex:NSOutlineViewDropOnItemIndex];
    }
    BOOL copy = (NSEvent.modifierFlags & NSEventModifierFlagOption) != 0;
    return copy ? NSDragOperationCopy : NSDragOperationMove;
}

- (BOOL)outlineView:(NSOutlineView *)outlineView
         acceptDrop:(id<NSDraggingInfo>)info
               item:(GWFileNode *)item
         childIndex:(NSInteger)index {
    NSURL *folder = item != nil ? item.url : _root.url;
    NSArray<NSURL *> *urls = [info.draggingPasteboard readObjectsForClasses:@[NSURL.class]
                                                                    options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    BOOL copy = (NSEvent.modifierFlags & NSEventModifierFlagOption) != 0;
    NSString *rootPath = _root.url.URLByStandardizingPath.path;
    BOOL any = NO;
    for (NSURL *source in urls) {
        BOOL insideTree = [source.URLByStandardizingPath.path hasPrefix:[rootPath stringByAppendingString:@"/"]];
        NSURL *destination = [self uniqueURLForName:source.lastPathComponent inFolder:folder suffix:@" copy"];
        // A folder can't go into itself.
        if ([folder.URLByStandardizingPath.path hasPrefix:[source.URLByStandardizingPath.path stringByAppendingString:@"/"]] ||
            [folder.URLByStandardizingPath isEqual:source.URLByStandardizingPath]) {
            continue;
        }
        if (insideTree && !copy) {
            if ([source.URLByDeletingLastPathComponent.URLByStandardizingPath isEqual:folder.URLByStandardizingPath]) continue;
            any |= [self moveItemAtURL:source toURL:destination];
        } else {
            NSError *error = nil;
            if ([NSFileManager.defaultManager copyItemAtURL:source toURL:destination error:&error]) {
                any = YES;
            } else {
                [self reportError:@"Couldn't copy it" message:error.localizedDescription];
            }
        }
    }
    if (any) [self reloadDirectory:folder];
    return any;
}

@end
