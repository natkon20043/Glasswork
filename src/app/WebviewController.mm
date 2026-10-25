#import "WebviewController.h"
#import "Strings.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

using Json = gw::lsp::Json;

static NSString *const kResourceScheme = @"gw-resource";

/// What a page gets as `acquireVsCodeApi`.
static NSString *const kBridgeScript = @""
    "(function () {"
    "  var savedState;"
    "  var acquired = false;"
    "  var api = {"
    "    postMessage: function (message) {"
    "      window.webkit.messageHandlers.glasswork.postMessage({message: message === undefined ? null : message});"
    "    },"
    "    getState: function () { return savedState; },"
    "    setState: function (state) { savedState = state; return state; }"
    "  };"
    "  window.acquireVsCodeApi = function () {"
    "    if (acquired) { throw new Error('An instance of the VS Code API has already been acquired'); }"
    "    acquired = true;"
    "    return api;"
    "  };"
    "})();";

/// The colors and fonts VS Code gives every webview as CSS variables, so pages written for it
/// look right here too.
static NSString *ThemeStyleScript(BOOL dark) {
    NSDictionary<NSString *, NSString *> *variables = dark ? @{
        @"--vscode-editor-background": @"#1e1e1e",
        @"--vscode-editor-foreground": @"#d4d4d4",
        @"--vscode-foreground": @"#cccccc",
        @"--vscode-descriptionForeground": @"#9d9d9d",
        @"--vscode-errorForeground": @"#f48771",
        @"--vscode-textLink-foreground": @"#3794ff",
        @"--vscode-textLink-activeForeground": @"#3794ff",
        @"--vscode-button-background": @"#0e639c",
        @"--vscode-button-foreground": @"#ffffff",
        @"--vscode-button-hoverBackground": @"#1177bb",
        @"--vscode-button-secondaryBackground": @"#3a3d41",
        @"--vscode-button-secondaryForeground": @"#ffffff",
        @"--vscode-input-background": @"#3c3c3c",
        @"--vscode-input-foreground": @"#cccccc",
        @"--vscode-input-border": @"#3c3c3c",
        @"--vscode-focusBorder": @"#007fd4",
        @"--vscode-panel-border": @"#80808059",
        @"--vscode-widget-border": @"#303031",
        @"--vscode-sideBar-background": @"#252526",
        @"--vscode-list-hoverBackground": @"#2a2d2e",
        @"--vscode-list-activeSelectionBackground": @"#04395e",
        @"--vscode-textCodeBlock-background": @"#0a0a0a66",
        @"--vscode-badge-background": @"#4d4d4d",
        @"--vscode-badge-foreground": @"#ffffff",
    } : @{
        @"--vscode-editor-background": @"#ffffff",
        @"--vscode-editor-foreground": @"#000000",
        @"--vscode-foreground": @"#616161",
        @"--vscode-descriptionForeground": @"#717171",
        @"--vscode-errorForeground": @"#a1260d",
        @"--vscode-textLink-foreground": @"#006ab1",
        @"--vscode-textLink-activeForeground": @"#006ab1",
        @"--vscode-button-background": @"#007acc",
        @"--vscode-button-foreground": @"#ffffff",
        @"--vscode-button-hoverBackground": @"#0062a3",
        @"--vscode-button-secondaryBackground": @"#5f6a79",
        @"--vscode-button-secondaryForeground": @"#ffffff",
        @"--vscode-input-background": @"#ffffff",
        @"--vscode-input-foreground": @"#616161",
        @"--vscode-input-border": @"#cecece",
        @"--vscode-focusBorder": @"#0090f1",
        @"--vscode-panel-border": @"#80808059",
        @"--vscode-widget-border": @"#c8c8c8",
        @"--vscode-sideBar-background": @"#f3f3f3",
        @"--vscode-list-hoverBackground": @"#e8e8e8",
        @"--vscode-list-activeSelectionBackground": @"#0060c0",
        @"--vscode-textCodeBlock-background": @"#dcdcdc66",
        @"--vscode-badge-background": @"#c4c4c4",
        @"--vscode-badge-foreground": @"#333333",
    };
    NSMutableString *css = [NSMutableString stringWithString:@":root {"];
    for (NSString *name in variables) {
        [css appendFormat:@"%@: %@;", name, variables[name]];
    }
    [css appendString:@"--vscode-font-family: -apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif;"
                       "--vscode-font-size: 13px; --vscode-font-weight: normal;"
                       "--vscode-editor-font-family: Menlo, Monaco, monospace; --vscode-editor-font-size: 12px; }"
                       "html { background: var(--vscode-editor-background); }"
                       "body { background: var(--vscode-editor-background); color: var(--vscode-editor-foreground);"
                       "font-family: var(--vscode-font-family); font-size: var(--vscode-font-size); margin: 0; padding: 0 20px; }"
                       "a { color: var(--vscode-textLink-foreground); }"];
    NSString *escaped = [css stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
    NSString *kind = dark ? @"vscode-dark" : @"vscode-light";
    return [NSString stringWithFormat:
            @"(function () {"
             "  var style = document.createElement('style');"
             "  style.id = '_defaultStyles';"
             "  style.textContent = '%@';"
             "  (document.head || document.documentElement).insertBefore(style, (document.head || "
             "document.documentElement).firstChild);"
             "  document.body && document.body.classList.add('%@');"
             "  document.documentElement.setAttribute('data-vscode-theme-kind', '%@');"
             "})();", escaped, kind, kind];
}

// MARK: - Serving local files

@interface GWResourceSchemeHandler : NSObject <WKURLSchemeHandler>
@property (nonatomic, copy) NSArray<NSString *> *roots;
@end

@implementation GWResourceSchemeHandler

- (BOOL)isAllowed:(NSString *)path {
    NSString *resolved = [path stringByResolvingSymlinksInPath];
    for (NSString *root in self.roots) {
        NSString *base = [root stringByResolvingSymlinksInPath];
        if ([resolved isEqualToString:base] || [resolved hasPrefix:[base stringByAppendingString:@"/"]]) {
            return YES;
        }
    }
    return NO;
}

- (void)webView:(WKWebView *)webView startURLSchemeTask:(id<WKURLSchemeTask>)task {
    NSURL *url = task.request.URL;
    NSString *path = url.path.stringByRemovingPercentEncoding ?: url.path;
    BOOL allowed = path.length > 0 && [self isAllowed:path];
    NSData *data = allowed ? [NSData dataWithContentsOfFile:path] : nil;
    if (data == nil) {
        NSHTTPURLResponse *missing = [[NSHTTPURLResponse alloc] initWithURL:url statusCode:allowed ? 404 : 403 HTTPVersion:@"HTTP/1.1"
                                                               headerFields:@{@"Access-Control-Allow-Origin": @"*"}];
        [task didReceiveResponse:missing];
        [task didFinish];
        return;
    }
    UTType *type = [UTType typeWithFilenameExtension:path.pathExtension];
    NSString *mime = type.preferredMIMEType ?: @"application/octet-stream";
    NSDictionary *headers = @{
        @"Content-Type": mime,
        @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)data.length],
        @"Access-Control-Allow-Origin": @"*",
        @"Cache-Control": @"no-cache",
    };
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:url statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:headers];
    [task didReceiveResponse:response];
    [task didReceiveData:data];
    [task didFinish];
}

- (void)webView:(WKWebView *)webView stopURLSchemeTask:(id<WKURLSchemeTask>)task {
}

@end

// MARK: - Messages from the page

/// Passes the page's messages on to the controller without keeping it alive: WebKit holds its
/// message handlers strongly, and the controller owns the web view, so registering the
/// controller itself would keep both alive for good.
@interface GWWeakMessageHandler : NSObject <WKScriptMessageHandler>
@property (nonatomic, weak) id<WKScriptMessageHandler> target;
@end

@implementation GWWeakMessageHandler

- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message {
    [self.target userContentController:controller didReceiveScriptMessage:message];
}

@end

// MARK: - The controller

@interface GWWebviewController () <WKScriptMessageHandler, WKNavigationDelegate>
@end

@implementation GWWebviewController {
    GWResourceSchemeHandler *_resources;
    NSArray<NSString *> *_defaultRoots;
    BOOL _scriptsEnabled;
    BOOL _loaded;
    NSMutableArray<void (^)(void)> *_waitingForLoad;
}

- (instancetype)initWithHandle:(NSString *)handle defaultRoots:(NSArray<NSString *> *)defaultRoots {
    if ((self = [super init])) {
        _handle = [handle copy];
        _defaultRoots = [defaultRoots copy];
        _waitingForLoad = [NSMutableArray array];
        _resources = [GWResourceSchemeHandler new];
        _resources.roots = _defaultRoots;

        WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
        [configuration setURLSchemeHandler:_resources forURLScheme:kResourceScheme];
        GWWeakMessageHandler *handler = [GWWeakMessageHandler new];
        handler.target = self;
        [configuration.userContentController addScriptMessageHandler:handler name:@"glasswork"];
        NSArray<NSAppearanceName> *appearances = @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua];
        BOOL dark = [NSApp.effectiveAppearance bestMatchFromAppearancesWithNames:appearances] == NSAppearanceNameDarkAqua;
        // The bridge must exist before the page's own scripts run; the theme only once there is a page.
        WKUserScript *bridge = [[WKUserScript alloc] initWithSource:kBridgeScript
                                                      injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                   forMainFrameOnly:YES];
        WKUserScript *theme = [[WKUserScript alloc] initWithSource:ThemeStyleScript(dark)
                                                     injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
                                                  forMainFrameOnly:YES];
        [configuration.userContentController addUserScript:bridge];
        [configuration.userContentController addUserScript:theme];
        _webView = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300) configuration:configuration];
        _webView.navigationDelegate = self;
        _webView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        if (@available(macOS 13.3, *)) {
            _webView.inspectable = YES;
        }
    }
    return self;
}

- (void)dealloc {
    [_webView.configuration.userContentController removeScriptMessageHandlerForName:@"glasswork"];
}

- (void)applyOptions:(const Json &)options {
    _scriptsEnabled = NO;
    if (options.contains("enableScripts") && options["enableScripts"].is_boolean()) {
        _scriptsEnabled = options["enableScripts"].get<bool>();
    }
    NSMutableArray<NSString *> *roots = [NSMutableArray array];
    if (options.contains("localResourceRoots") && options["localResourceRoots"].is_array()) {
        for (const Json &root : options["localResourceRoots"]) {
            if (root.is_string()) {
                [roots addObject:StringFromUTF8(root.get<std::string>())];
            }
        }
    } else {
        [roots addObjectsFromArray:_defaultRoots];
    }
    _resources.roots = roots;
}

- (void)setHTML:(NSString *)html {
    _loaded = NO;
    NSURL *base = [NSURL URLWithString:[kResourceScheme stringByAppendingString:@"://local/"]];
    [_webView loadHTMLString:html baseURL:base];
}

- (void)postMessage:(const Json &)message completion:(void (^)(BOOL))completion {
    std::string text = message.dump();
    NSString *script = [NSString stringWithFormat:@"window.dispatchEvent(new MessageEvent('message', {data: "
                                                  @"%@}));", StringFromUTF8(text)];
    __weak GWWebviewController *weakSelf = self;
    void (^deliver)(void) = ^{
        GWWebviewController *strongSelf = weakSelf;
        if (strongSelf == nil) {
            if (completion) {
                completion(NO);
            }
            return;
        }
        [strongSelf->_webView evaluateJavaScript:script completionHandler:^(id, NSError *error) {
            if (completion) {
                completion(error == nil);
            }
        }];
    };
    if (_loaded) {
        deliver();
    } else {
        [_waitingForLoad addObject:[deliver copy]];
    }
}

// MARK: WKScriptMessageHandler

- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message {
    if (!_scriptsEnabled || self.onMessage == nil || ![message.body isKindOfClass:NSDictionary.class]) {
        return;
    }
    id payload = ((NSDictionary *)message.body)[@"message"];
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"m": payload ?: NSNull.null} options:0 error:nil];
    if (data == nil) {
        return;
    }
    Json wrapper = Json::parse(std::string(static_cast<const char *>(data.bytes), data.length), nullptr, false);
    if (wrapper.is_object() && wrapper.contains("m")) {
        self.onMessage(wrapper["m"]);
    }
}

// MARK: WKNavigationDelegate

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    _loaded = YES;
    NSArray<void (^)(void)> *waiting = [_waitingForLoad copy];
    [_waitingForLoad removeAllObjects];
    for (void (^deliver)(void) in waiting) {
        deliver();
    }
}

- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)action
                        preferences:(WKWebpagePreferences *)preferences
                    decisionHandler:(void (^)(WKNavigationActionPolicy, WKWebpagePreferences *))decisionHandler {
    preferences.allowsContentJavaScript = _scriptsEnabled;
    NSURL *url = action.request.URL;
    NSString *scheme = url.scheme.lowercaseString;
    if (action.navigationType != WKNavigationTypeLinkActivated) {
        // The page itself stays on its own content: the main frame may not be sent off to a web
        // site, which would then get the bridge to the extension. Frames inside it may load
        // anything; they get no bridge.
        BOOL mainFrame = action.targetFrame == nil || action.targetFrame.isMainFrame;
        BOOL ownContent = [scheme isEqualToString:kResourceScheme] || [scheme isEqualToString:@"about"];
        if (!mainFrame || ownContent) {
            decisionHandler(WKNavigationActionPolicyAllow, preferences);
            return;
        }
        if ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) {
            [NSWorkspace.sharedWorkspace openURL:url];
        }
        decisionHandler(WKNavigationActionPolicyCancel, preferences);
        return;
    }
    if ([scheme isEqualToString:@"command"]) {
        if (self.onCommandLink) {
            self.onCommandLink(url.absoluteString);
        }
    } else if ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"] || [scheme isEqualToString:@"mailto"]) {
        [NSWorkspace.sharedWorkspace openURL:url];
    } else if (url.fragment != nil) {
        // A link to a spot in the same page stays; a link to another page does not.
        NSString *current = [webView.URL.absoluteString componentsSeparatedByString:@"#"].firstObject;
        NSString *target = [url.absoluteString componentsSeparatedByString:@"#"].firstObject;
        if ([current isEqualToString:target]) {
            decisionHandler(WKNavigationActionPolicyAllow, preferences);
            return;
        }
    }
    decisionHandler(WKNavigationActionPolicyCancel, preferences);
}

@end
