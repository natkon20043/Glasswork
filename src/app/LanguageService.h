#pragma once

#import <AppKit/AppKit.h>

#include "Document.hpp"
#include "LspServer.hpp"
#include "SemanticTokens.hpp"

#include <memory>
#include <string>
#include <vector>

NS_ASSUME_NONNULL_BEGIN

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
/// Turned off by "lsp.enabled": false in settings.
@property (nonatomic) BOOL enabled;

/// A file's diagnostics changed.
@property (nonatomic, copy, nullable) void (^onDiagnosticsChanged)(gw::Document *document);
/// Semantic highlighting for a file arrived (or changed).
@property (nonatomic, copy, nullable) void (^onSemanticTokensChanged)(gw::Document *document);
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
