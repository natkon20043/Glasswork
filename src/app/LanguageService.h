#pragma once

#import <AppKit/AppKit.h>

#include "Document.hpp"
#include "LspServer.hpp"
#include "SemanticTokens.hpp"

#include <memory>
#include <string>
#include <vector>

NS_ASSUME_NONNULL_BEGIN

/// How VS Code extensions take part in language features: per language, whether extensions have
/// anything to say, and a transport for a virtual server answering from their providers.
@protocol GWExtensionLanguageProvider <NSObject>

/// May answer yes before the extension has run (extensions load on demand).
- (BOOL)extensionsMayServeLanguage:(NSString *)languageId;
/// Starts the host if needed and activates extensions waiting for this language. `done` runs on main
/// with whether there is a host to ask.
- (void)prepareLanguage:(NSString *)languageId completion:(void (^)(BOOL ok))done;
/// Null if the host isn't running.
- (std::unique_ptr<gw::lsp::ServerTransport>)newTransportForLanguage:(NSString *)languageId rootURI:(NSString *)rootURI;

@end

/// An inline hint (parameter name before an argument, inferred type after a name). Positions use the
/// document's units (UTF-8 bytes).
struct GWInlayHint {
    gw::Position position;
    std::string label;
    /// False: a parameter name.
    bool isType = false;
    bool padLeft = false;
    bool padRight = false;
};

/// A problem in a file, in the document's units (UTF-8 bytes).
struct GWDiagnostic {
    gw::Range range;
    /// 1 error, 2 warning, 3 information, 4 hint.
    int severity = 1;
    std::string message;
    std::string source;
    /// The server's own form, sent back with code-action requests.
    std::shared_ptr<gw::lsp::Json> raw;
};

/// Runs language servers (clangd, sourcekit-lsp, pyright...) for open files, keeps them in step with
/// the editor and collects diagnostics. A server starts when a file of its language first opens and
/// shuts down with the window. Called on the main thread; completions run there too.
@interface GWLanguageService : NSObject

// ---- Lifecycle
/// Stops every server.
- (void)shutdown;
/// Servers that asked to hear about files like these are told, so new sources or changed build files
/// take effect. Paths are absolute, as the folder watcher reports them.
- (void)filesDidChange:(NSArray<NSString *> *)paths;
/// The user's settings as servers see them (`workspace/configuration`). Call at startup and on change:
/// running servers are told and later answers use the new values.
- (void)settingsDidChange:(const gw::lsp::Json &)settings;

// ---- Document tracking
/// Opens the file on its language's server. Safe to repeat after a language change. Unsaved and very
/// large files are skipped.
- (void)trackDocument:(gw::Document *)document;
/// The server hears about it a moment later.
- (void)documentDidChange:(gw::Document *)document;
- (void)documentDidSave:(gw::Document *)document;
- (void)untrackDocument:(gw::Document *)document;
/// Closes under the old path and opens under the new.
- (void)documentDidMove:(gw::Document *)document fromPath:(NSString *)oldPath;

// ---- Requests
/// Pending text changes are sent first. The block runs on main with the result or an error message. With
/// `requireSameVersion` it is skipped if the document was edited meanwhile (stale answer).
- (void)request:(NSString *)method
         params:(gw::lsp::Json)params
       document:(gw::Document *)document
requireSameVersion:(BOOL)requireSameVersion
     completion:(void (^)(const gw::lsp::Json &result, NSString *_Nullable error))completion;
/// `{textDocument: {uri}, position}`
- (gw::lsp::Json)positionParamsForDocument:(gw::Document *)document position:(gw::Position)position;

// ---- Results
- (const std::vector<GWInlayHint> &)inlayHintsForDocument:(gw::Document *)document;
- (const std::vector<GWDiagnostic> &)diagnosticsForDocument:(gw::Document *)document;
/// Null if none.
- (std::shared_ptr<const gw::SemanticTokenSet>)semanticTokensForDocument:(gw::Document *)document;
/// Totals over every followed file.
- (NSUInteger)errorCount;
- (NSUInteger)warningCount;

// ---- Server info
/// Whether some server handles this language, installed or not.
- (BOOL)hasServerForLanguage:(NSString *)languageId;
/// The document's server is running and knows the capability (such as "renameProvider").
- (BOOL)serverSupports:(NSString *)capability forDocument:(gw::Document *)document;
/// Characters that open the completion list right away (".", "::"), as one string.
- (NSString *)completionTriggerCharactersForDocument:(gw::Document *)document;
/// E.g. "clangd" or "pyright isn't installed"; empty when no server applies.
- (NSString *)statusTextForLanguage:(nullable NSString *)languageId;
- (nullable NSString *)installHintForLanguage:(NSString *)languageId;

// ---- Properties
@property (nonatomic, copy, nullable) NSString *rootFolder;
@property (nonatomic, weak, nullable) id<GWExtensionLanguageProvider> extensionProvider;
/// Off with "lsp.enabled": false in settings.
@property (nonatomic) BOOL enabled;

// ---- Callbacks
@property (nonatomic, copy, nullable) void (^onDiagnosticsChanged)(gw::Document *document);
@property (nonatomic, copy, nullable) void (^onSemanticTokensChanged)(gw::Document *document);
@property (nonatomic, copy, nullable) void (^onInlayHintsChanged)(gw::Document *document);
/// `window/showMessage`: type 1 error, 2 warning, 3 info.
@property (nonatomic, copy, nullable) void (^onServerMessage)(NSString *serverName, int type, NSString *message);
/// `window/logMessage`.
@property (nonatomic, copy, nullable) void (^onServerLog)(NSString *serverName, NSString *message);
/// `kind` is begin, report or end; percentage is -1 when unknown.
@property (nonatomic, copy, nullable) void (^onServerProgress)(NSString *serverName, NSString *token, NSString *kind,
                                                               NSString *title, NSString *message, int percentage);
/// Call `reply` with the chosen title, or "" if dismissed.
@property (nonatomic, copy, nullable) void (^onServerQuestion)(NSString *serverName, NSString *message, NSArray<NSString *> *actions,
                                                               void (^reply)(NSString *chosen));
/// A server asks for files to change (e.g. a refactoring). Call `reply` with whether it worked; refused when unset.
@property (nonatomic, copy, nullable) void (^onApplyEdit)(const gw::lsp::Json &edit, void (^reply)(BOOL applied));
/// A server's state changed (starting, ready, missing, stopped); read `statusText`.
@property (nonatomic, copy, nullable) void (^onStatusChanged)(void);

@end

NS_ASSUME_NONNULL_END
