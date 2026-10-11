#pragma once

#import <AppKit/AppKit.h>

#import "ExtensionHostService.h"
#import "WebviewController.h"

NS_ASSUME_NONNULL_BEGIN

/// The UI side of what extensions add: the sidebar listing their tree and webview views, and webview
/// panels opened as editor tabs. Listens to the extension host service and asks the window to open,
/// rename and close those tabs.
@interface GWExtensionViews : NSObject <GWExtensionViewsDelegate>

// ---- Constructors
- (instancetype)initWithService:(GWExtensionHostService *)service;

// ---- Sidebar
/// Call after extensions were installed, removed or switched off.
- (void)reload;
/// Sections tell their extensions whether they are visible.
- (void)sidebarVisibilityChanged:(BOOL)visible;

// ---- Panel tabs
- (void)panelTabClosed:(NSString *)handle;
- (void)panelTab:(NSString *)handle isFront:(BOOL)front;

// ---- Properties
/// One collapsible section per view.
@property (nonatomic, readonly) NSView *sidebarView;
/// Any installed extension contributes a view.
@property (nonatomic, readonly) BOOL hasViews;
/// Folders a webview may read unless its extension names others (the project, the extensions).
@property (nonatomic, copy, nullable) NSArray<NSString *> *(^webviewRoots)(void);

// ---- Callbacks
/// Show `webView` in a new editor tab called `title`.
@property (nonatomic, copy, nullable) void (^onOpenPanel)(NSString *handle, NSString *title, WKWebView *webView, BOOL preserveFocus);
@property (nonatomic, copy, nullable) void (^onRetitlePanel)(NSString *handle, NSString *title);
@property (nonatomic, copy, nullable) void (^onRevealPanel)(NSString *handle);
/// Close its tab without asking.
@property (nonatomic, copy, nullable) void (^onClosePanel)(NSString *handle);
/// `webviewView.show()` or `treeView.reveal`: bring the sidebar up.
@property (nonatomic, copy, nullable) void (^onRevealSidebar)(void);

@end

NS_ASSUME_NONNULL_END
