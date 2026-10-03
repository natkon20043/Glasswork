#pragma once

#import <AppKit/AppKit.h>

#include "Document.hpp"
#include "LspServer.hpp"
#include "SemanticTokens.hpp"

#include <memory>
#include <string>
#include <vector>

NS_ASSUME_NONNULL_BEGIN

/// How the extension host (VS Code extensions) takes part in language features. The language
/// service asks it, per language, whether extensions have anything to say, and gets a transport
/// for a virtual server that answers with the providers extensions registered.
@protocol GWExtensionLanguageProvider <NSObject>
/// Whether an installed extension might provide features for this language (it can say yes
/// before the extension has run: extensions are loaded on demand).
- (BOOL)extensionsMayServeLanguage:(NSString *)languageId;
/// Starts the host if needed and activates the extensions that wait for this language. `done` runs
/// on the main thread, with whether there is a host to ask.
- (void)prepareLanguage:(NSString *)languageId completion:(void (^)(BOOL ok))done;
/// A transport for the language's virtual server, or null if the host isn't running.
- (std::unique_ptr<gw::lsp::ServerTransport>)newTransportForLanguage:(NSString *)languageId rootURI:(NSString *)rootURI;
@end

/// A hint a language server wants shown inline: a parameter's name before an argument, or a variable's
/// inferred type after its name. The position is where the hint is drawn.
struct GWInlayHint {
    gw::Position position;  // the document's units (UTF-8 bytes)
    std::string label;
    bool isType = false;    // false: a parameter name
    bool padLeft = false;
    bool padRight = false;
};

/// One problem in a file, with its position in the document's own units (UTF-8 bytes).
struct GWDiagnostic {
    gw::Range range;
    int severity = 1;  // 1 error, 2 warning, 3 information, 4 hint
    std::string message;
    std::string source;
    /// The server's own form of the problem, sent back with code-action requests.
    std::shared_ptr<gw::lsp::Json> raw;
};

/// Runs the language servers for the open files (clangd, sourcekit-lsp, pyright and so on),
/// keeps them in step with the editor, and collects their diagnostics. Servers start the first
/// time a file of their language is opened and are shut down with the window.
///
/// Everything here is called on the main thread, and completion blocks run on it too.
@interface GWLanguageService : NSObject

/// The project folder the servers are rooted in.
@property (nonatomic, copy, nullable) NSString *rootFolder;
/// Lets VS Code extensions provide language features alongside the language servers.
@property (nonatomic, weak, nullable) id<GWExtensionLanguageProvider> extensionProvider;
/// Turned off by "lsp.enabled": false in settings.
@property (nonatomic) BOOL enabled;

/// A file's diagnostics changed.
@property (nonatomic, copy, nullable) void (^onDiagnosticsChanged)(gw::Document *document);
/// Semantic highlighting for a file arrived (or changed).
@property (nonatomic, copy, nullable) void (^onSemanticTokensChanged)(gw::Document *document);
/// A language server said something for the user (`window/showMessage`): type 1 error, 2 warning, 3 info.
@property (nonatomic, copy, nullable) void (^onServerMessage)(NSString *serverName, int type, NSString *message);
/// A server's log output (`window/logMessage`).
@property (nonatomic, copy, nullable) void (^onServerLog)(NSString *serverName, NSString *message);
/// Work a server reports (indexing…): `kind` is begin, report or end; percentage is -1 when unknown.
@property (nonatomic, copy, nullable) void (^onServerProgress)(NSString *serverName, NSString *token, NSString *kind,
                                                               NSString *title, NSString *message, int percentage);
/// A server asks a question with buttons; call `reply` with the chosen title ("" if dismissed).
@property (nonatomic, copy, nullable) void (^onServerQuestion)(NSString *serverName, NSString *message, NSArray<NSString *> *actions,
                                                               void (^reply)(NSString *chosen));
/// Files changed on disk (absolute paths, as the folder watcher reports them). Servers that asked to
/// hear about files like these are told, so a new source file or a changed build file takes effect.
- (void)filesDidChange:(NSArray<NSString *> *)paths;
/// Tells every running server the settings changed.
/// The user's settings, as servers see them (`workspace/configuration`). Call it at startup and
/// whenever settings change: servers running now are told, and later answers use the new values.
- (void)settingsDidChange:(const gw::lsp::Json &)settings;

/// A server asks for files to be changed (while running a refactoring command, say). Make the
/// changes and call `reply` with whether it worked. Without this the request is refused.
@property (nonatomic, copy, nullable) void (^onApplyEdit)(const gw::lsp::Json &edit, void (^reply)(BOOL applied));
/// The state of a server changed (starting, ready, missing, stopped). Read `statusText`.
@property (nonatomic, copy, nullable) void (^onStatusChanged)(void);

/// Whether some server handles this language (whether or not it is installed).
- (BOOL)hasServerForLanguage:(NSString *)languageId;

/// Starts following a file: opens it on the server for its language. Safe to call again after
/// the language changed. Files that aren't saved yet or are very large are left alone.
- (void)trackDocument:(gw::Document *)document;
/// The document's text changed; the server hears about it a moment later.
- (void)documentDidChange:(gw::Document *)document;
- (void)documentDidSave:(gw::Document *)document;
- (void)untrackDocument:(gw::Document *)document;
/// The file was renamed or moved: close it under the old path and open it under the new.
- (void)documentDidMove:(gw::Document *)document fromPath:(NSString *)oldPath;

/// Inlay hints the servers gave for a document (empty if none).
- (const std::vector<GWInlayHint> &)inlayHintsForDocument:(gw::Document *)document;
/// Inlay hints for a document arrived (or were cleared).
@property (nonatomic, copy, nullable) void (^onInlayHintsChanged)(gw::Document *document);

/// Problems the server reported for a document.
- (const std::vector<GWDiagnostic> &)diagnosticsForDocument:(gw::Document *)document;
/// The semantic tokens last received for a document (null if none).
- (std::shared_ptr<const gw::SemanticTokenSet>)semanticTokensForDocument:(gw::Document *)document;
/// Totals over every followed file.
- (NSUInteger)errorCount;
- (NSUInteger)warningCount;

/// Characters that should open the completion list right away (".", "::" and so on), as one string.
- (NSString *)completionTriggerCharactersForDocument:(gw::Document *)document;

/// A short description of the server for the current language, e.g. "clangd", "pyright isn't
/// installed"; empty when no server applies.
- (NSString *)statusTextForLanguage:(nullable NSString *)languageId;
/// The install instructions for a missing server, or nil.
- (nullable NSString *)installHintForLanguage:(NSString *)languageId;

/// True if the server for this document is running and knows the capability (for example
/// "renameProvider").
- (BOOL)serverSupports:(NSString *)capability forDocument:(gw::Document *)document;

/// Sends a request for a document. Pending text changes are sent first. The block runs on the
/// main thread with the result, or an error message. With `requireSameVersion`, the block is
/// skipped if the document was edited while the server was thinking (the answer is stale).
- (void)request:(NSString *)method
         params:(gw::lsp::Json)params
       document:(gw::Document *)document
requireSameVersion:(BOOL)requireSameVersion
     completion:(void (^)(const gw::lsp::Json &result, NSString *_Nullable error))completion;

/// `{textDocument: {uri}, position}` for a position in a document.
- (gw::lsp::Json)positionParamsForDocument:(gw::Document *)document position:(gw::Position)position;

/// Stops every server.
- (void)shutdown;

@end

NS_ASSUME_NONNULL_END
