#pragma once

#import <AppKit/AppKit.h>

#import "PixelArt.h"
#import "TabBar.h"

NS_ASSUME_NONNULL_BEGIN

// Side window tab -> what fills the side window.
typedef NS_ENUM(NSInteger, GWBitmapPanel) {
    GWBitmapPanelFiles,
    GWBitmapPanelIssues,
    GWBitmapPanelDebug,
};

/// One line of a GWBitmapList.
@interface GWBitmapRow : NSObject

// ---- Constructors
+ (instancetype)rowWithText:(NSString *)text color:(NSColor *)color;
+ (instancetype)rowWithIcon:(GWPixelIcon)icon iconColor:(NSColor *)iconColor text:(NSString *)text;

// ---- Properties
@property (nonatomic, copy) NSString *text;
@property (nonatomic, copy) NSColor *textColor;
@property (nonatomic) BOOL hasIcon;
@property (nonatomic) GWPixelIcon icon;
@property (nonatomic, copy) NSColor *iconColor;
@property (nonatomic) BOOL highlighted;
@property (nonatomic, strong, nullable) id representedObject;

@end

/// An entry in one of the menu bar's menus. A "&" in the title marks its hotkey letter.
@interface GWBitmapMenuItem : NSObject

// ---- Constructors
+ (instancetype)itemWithTitle:(NSString *)title action:(SEL)action shortcut:(NSString *)shortcut;
+ (instancetype)separator;

// ---- Properties
@property (nonatomic, readonly, copy) NSString *title;
/// -1 for none.
@property (nonatomic, readonly) NSInteger hotkeyIndex;
@property (nonatomic, readonly, nullable) SEL action;
@property (nonatomic, readonly, copy) NSString *shortcut;
@property (nonatomic, readonly) BOOL isSeparator;
/// Drawn with a bullet before it, for the choice that is on.
@property (nonatomic) BOOL checked;
/// Sent along with the action (the item is the sender), to tell apart items sharing one.
@property (nonatomic) NSInteger tag;

@end

/// A menu of the menu bar. "≡" as the title draws the little menu icon.
@interface GWBitmapMenu : NSObject

// ---- Constructors
+ (instancetype)menuWithTitle:(NSString *)title items:(NSArray<GWBitmapMenuItem *> *)items;

// ---- Properties
@property (nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly) NSInteger hotkeyIndex;
@property (nonatomic, readonly, copy) NSArray<GWBitmapMenuItem *> *items;

@end

/// The bitmap app's window, after the DOS IDEs (Borland Turbo C++ and Turbo Pascal, Microsoft QBasic; see
/// "Where Glasswork Bitmap's look comes from" in the README), with Picotron's pixel font and text shadow:
/// a grey menu bar with drop-down menus, the code in a
/// blue window with a double frame (its tabs in the top edge, a scrollbar in the right one, the
/// caret's place in the bottom one), a side window for files, issues and the debugger, and a status
/// line of keys. The code and the side window's content are separate views placed in `editorFrame`
/// and `panelContentFrame`; the menus and dialogs float over everything.
@interface GWBitmapChrome : NSView

// ---- Layout
- (NSRect)editorFrame;
/// Empty while the side window is closed.
- (NSRect)panelContentFrame;

// ---- Menus and dialogs
- (void)openMenuAtIndex:(NSInteger)index;
/// A grey box with a white title strip and an OK button; Return, Escape or a click closes it.
- (void)showDialogWithTitle:(NSString *)title lines:(NSArray<NSString *> *)lines;

// ---- Properties
@property (nonatomic, copy) NSArray<GWBitmapMenu *> *menus;
/// At the right end of the menu bar: the folder's name.
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSArray<GWTabItem *> *tabs;
@property (nonatomic) NSInteger selectedTab;
/// In the code window's bottom edge: the caret's line and column, and Vim's mode.
@property (nonatomic, copy) NSString *position;
@property (nonatomic, copy) NSString *mode;
/// At the right of the status line.
@property (nonatomic, copy) NSString *message;
@property (nonatomic) GWBitmapPanel panel;
@property (nonatomic) BOOL panelOpen;
/// Without a file the code window shows how to open one.
@property (nonatomic) BOOL hasFile;
/// The code's scroll view, which the frame's scrollbar shows and moves.
@property (nonatomic, weak, nullable) NSScrollView *scrollView;
/// How far one click on a scroll arrow moves.
@property (nonatomic) CGFloat lineScroll;

// ---- Callbacks
@property (nonatomic, copy, nullable) void (^onSelectTab)(NSInteger index);
@property (nonatomic, copy, nullable) void (^onCloseTab)(NSInteger index);
@property (nonatomic, copy, nullable) void (^onChoosePanel)(GWBitmapPanel panel);
/// The box at the code window's top right: open or close the side window.
@property (nonatomic, copy, nullable) void (^onTogglePanel)(void);

@end

/// Rows of pixel text with little icons, one line tall each, in a scroll view.
@interface GWBitmapList : NSView

// ---- Properties
@property (nonatomic, copy) NSArray<GWBitmapRow *> *rows;
/// The scroll view holding the list; put it in the side window.
@property (nonatomic, readonly) NSScrollView *scrollView;

// ---- Callbacks
@property (nonatomic, copy, nullable) void (^onChoose)(GWBitmapRow *row);

@end

NS_ASSUME_NONNULL_END
