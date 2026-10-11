#pragma once

#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>

#include "LspServer.hpp"

NS_ASSUME_NONNULL_BEGIN

/// One extension webview in a WKWebView. The page talks to its extension as in VS Code:
/// `acquireVsCodeApi()` gives `postMessage`, `getState` and `setState`, and extension messages arrive as
/// `message` events on `window`. Files from `webview.asWebviewUri` load through the `gw-resource:` scheme,
/// which serves local files from the folders the webview may read.
@interface GWWebviewController : NSObject

// ---- Constructors
/// `defaultRoots` are readable when the extension named none.
- (instancetype)initWithHandle:(NSString *)handle defaultRoots:(NSArray<NSString *> *)defaultRoots;

// ---- Content
/// `{enableScripts, localResourceRoots (array or null), retainContextWhenHidden}`
- (void)applyOptions:(const gw::lsp::Json &)options;
- (void)setHTML:(NSString *)html;
/// Delivered to the page's `message` listeners once it has loaded.
- (void)postMessage:(const gw::lsp::Json &)message completion:(void (^_Nullable)(BOOL delivered))completion;

// ---- Properties
@property (nonatomic, readonly, copy) NSString *handle;
@property (nonatomic, readonly) WKWebView *webView;

// ---- Callbacks
/// The page called `vscode.postMessage`.
@property (nonatomic, copy, nullable) void (^onMessage)(const gw::lsp::Json &message);
/// The page has a `command:` link; the string is the whole link.
@property (nonatomic, copy, nullable) void (^onCommandLink)(NSString *link);

@end

NS_ASSUME_NONNULL_END
