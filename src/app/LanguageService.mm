#import "LanguageService.h"

#import "Services.h"

#include <map>
#include <memory>
#include <set>
#include <unordered_map>

namespace {

/// Files larger than this are not sent to language servers (each keystroke would resend them).
constexpr size_t kLargestTrackedFile = 4 * 1024 * 1024;
/// How long after the last keystroke the server hears about the edit.
constexpr NSTimeInterval kSyncDelay = 0.25;

struct Tracked {
    std::string uri;
    std::string languageId;
    std::string serverName;
    uint64_t sentVersion = 0;
    std::vector<GWDiagnostic> diagnostics;
    bool pendingChange = false;
    std::shared_ptr<const gw::SemanticTokenSet> semantic;
    uint64_t semanticRequestedVersion = 0;
};

struct ServerEntry {
    std::unique_ptr<gw::lsp::LanguageServer> server;
    bool failedToStart = false;
    std::string failureMessage;
    std::set<std::string> openUris;
};

}  // namespace

@implementation GWLanguageService {
    std::vector<gw::lsp::ServerSpec> _specs;
    std::map<std::string, ServerEntry> _servers;             // by server name
    std::unordered_map<gw::Document *, Tracked> _tracked;
    std::vector<GWDiagnostic> _noDiagnostics;
}

- (instancetype)init {
    if ((self = [super init])) {
        _specs = gw::lsp::defaultServerSpecs();
        _enabled = YES;
    }
    return self;
}

- (void)dealloc {
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
}

// ---------------------------------------------------------------------------
// MARK: Servers

- (const gw::lsp::ServerSpec *)specForLanguage:(NSString *)languageId {
    return gw::lsp::serverForLanguage(_specs, languageId.UTF8String);
}

- (BOOL)hasServerForLanguage:(NSString *)languageId {
    return [self specForLanguage:languageId] != nullptr;
}

/// The running server for a spec, starting it if this is the first file that needs it.
- (gw::lsp::LanguageServer *)serverForSpec:(const gw::lsp::ServerSpec &)spec {
    ServerEntry &entry = _servers[spec.name];
    if (entry.server != nullptr && entry.server->isRunning()) {
        return entry.server.get();
    }
    if (entry.failedToStart) {
        return nullptr;
    }
    NSString *root = self.rootFolder;
    if (root.length == 0) {
        root = NSHomeDirectory();
    }
    entry.openUris.clear();
    entry.server = std::make_unique<gw::lsp::LanguageServer>(spec, root.UTF8String);

    __weak GWLanguageService *weakSelf = self;
    std::string serverName = spec.name;
    gw::lsp::LanguageServer *rawServer = entry.server.get();
    entry.server->onDiagnostics = [weakSelf, serverName](const std::string &uri, long version, std::vector<gw::lsp::Diagnostic> diagnostics) {
        auto shared = std::make_shared<std::vector<gw::lsp::Diagnostic>>(std::move(diagnostics));
        // Copies: a block would only hold a reference to `uri`, which is gone by the time it runs.
        auto sharedUri = std::make_shared<std::string>(uri);
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf receivedDiagnostics:*shared forUri:*sharedUri version:version fromServer:serverName];
        });
    };
    entry.server->onReady = [weakSelf]() {
        dispatch_async(dispatch_get_main_queue(), ^{
            GWLanguageService *strongSelf = weakSelf;
            if (strongSelf.onStatusChanged) strongSelf.onStatusChanged();
        });
    };
    entry.server->onExit = [weakSelf, serverName, rawServer](int) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf serverEnded:serverName instance:rawServer];
        });
    };
    std::string error;
    if (!entry.server->start(&error)) {
        entry.failedToStart = true;
        entry.failureMessage = error;
        entry.server.reset();
        if (self.onStatusChanged) self.onStatusChanged();
        return nullptr;
    }
    if (self.onStatusChanged) self.onStatusChanged();
    return entry.server.get();
}

/// A server stopped by itself (crashed). Files reopen on a fresh server the next time they change.
- (void)serverEnded:(const std::string &)name instance:(gw::lsp::LanguageServer *)instance {
    auto found = _servers.find(name);
    if (found == _servers.end() || found->second.server.get() != instance) {
        return;  // already replaced
    }
    found->second.openUris.clear();
    for (auto &[document, tracked] : _tracked) {
        if (tracked.serverName == name) {
            tracked.sentVersion = 0;
        }
    }
    if (self.onStatusChanged) self.onStatusChanged();
}

- (void)shutdown {
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    for (auto &[name, entry] : _servers) {
        if (entry.server != nullptr) {
            entry.server->stop();
        }
    }
    _servers.clear();
    _tracked.clear();
}

// ---------------------------------------------------------------------------
// MARK: Following documents

- (void)trackDocument:(gw::Document *)document {
    if (!self.enabled || document == nullptr || !document->path() || document->readOnly) {
        return;
    }
    NSString *languageId = @(document->languageId.c_str());
    const gw::lsp::ServerSpec *spec = [self specForLanguage:languageId];
    std::string uri = gw::lsp::fileURI(document->path()->string());

    auto existing = _tracked.find(document);
    if (existing != _tracked.end()) {
        bool sameServer = spec != nullptr && existing->second.serverName == spec->name;
        if (sameServer && existing->second.languageId == document->languageId && existing->second.uri == uri) {
            return;
        }
        [self untrackDocument:document];  // the language or the file name changed
    }
    if (spec == nullptr) {
        return;
    }
    gw::lsp::LanguageServer *server = [self serverForSpec:*spec];
    if (server == nullptr) {
        return;
    }
    std::string text = document->buffer().text();
    if (text.size() > kLargestTrackedFile) {
        return;
    }
    Tracked tracked;
    tracked.uri = uri;
    tracked.languageId = document->languageId;
    tracked.serverName = spec->name;
    tracked.sentVersion = document->version();
    server->didOpen(uri, document->languageId, document->version(), text);
    _servers[spec->name].openUris.insert(uri);
    _tracked[document] = std::move(tracked);
}

- (void)documentDidChange:(gw::Document *)document {
    auto found = _tracked.find(document);
    if (found == _tracked.end()) {
        return;
    }
    found->second.pendingChange = true;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(flushAllPending) object:nil];
    [self performSelector:@selector(flushAllPending) withObject:nil afterDelay:kSyncDelay];
}

- (void)flushAllPending {
    for (auto &[document, tracked] : _tracked) {
        if (tracked.pendingChange) {
            [self flushDocument:document];
        }
    }
}

/// Sends the document's current text if the server has an older version.
- (void)flushDocument:(gw::Document *)document {
    auto found = _tracked.find(document);
    if (found == _tracked.end()) {
        return;
    }
    Tracked &tracked = found->second;
    tracked.pendingChange = false;
    if (tracked.sentVersion == document->version()) {
        return;
    }
    ServerEntry &entry = _servers[tracked.serverName];
    if (entry.server == nullptr || !entry.server->isRunning()) {
        // The server died: start a fresh one and open the file again.
        const gw::lsp::ServerSpec *spec = gw::lsp::serverForLanguage(_specs, tracked.languageId);
        gw::lsp::LanguageServer *server = spec ? [self serverForSpec:*spec] : nullptr;
        if (server == nullptr) {
            return;
        }
        std::string text = document->buffer().text();
        server->didOpen(tracked.uri, tracked.languageId, document->version(), text);
        _servers[tracked.serverName].openUris.insert(tracked.uri);
        tracked.sentVersion = document->version();
        return;
    }
    if (entry.openUris.count(tracked.uri) == 0) {
        entry.server->didOpen(tracked.uri, tracked.languageId, document->version(), document->buffer().text());
        entry.openUris.insert(tracked.uri);
    } else {
        entry.server->didChange(tracked.uri, document->version(), document->buffer().text());
    }
    tracked.sentVersion = document->version();
}

- (void)documentDidSave:(gw::Document *)document {
    auto found = _tracked.find(document);
    if (found == _tracked.end()) {
        return;
    }
    [self flushDocument:document];
    ServerEntry &entry = _servers[found->second.serverName];
    if (entry.server != nullptr && entry.server->isRunning()) {
        entry.server->didSave(found->second.uri);
    }
}

- (void)untrackDocument:(gw::Document *)document {
    auto found = _tracked.find(document);
    if (found == _tracked.end()) {
        return;
    }
    ServerEntry &entry = _servers[found->second.serverName];
    if (entry.server != nullptr && entry.server->isRunning() && entry.openUris.count(found->second.uri) > 0) {
        entry.server->didClose(found->second.uri);
    }
    entry.openUris.erase(found->second.uri);
    _tracked.erase(found);
    if (self.onDiagnosticsChanged) self.onDiagnosticsChanged(document);
}

- (void)documentDidMove:(gw::Document *)document fromPath:(NSString *)oldPath {
    // Close under the old uri, then let trackDocument open the new one.
    auto found = _tracked.find(document);
    if (found != _tracked.end()) {
        ServerEntry &entry = _servers[found->second.serverName];
        if (entry.server != nullptr && entry.server->isRunning()) {
            entry.server->didClose(found->second.uri);
        }
        entry.openUris.erase(found->second.uri);
        _tracked.erase(found);
    }
    [self trackDocument:document];
}

// ---------------------------------------------------------------------------
// MARK: Diagnostics

- (void)receivedDiagnostics:(const std::vector<gw::lsp::Diagnostic> &)diagnostics
                     forUri:(const std::string &)uri
                    version:(long)version
                 fromServer:(const std::string &)serverName {
    if (getenv("GLASSWORK_LSP_TRACE") != nullptr) {
        fprintf(stderr, "[lsp diagnostics] %s (%zu items) for %zu followed files\n", uri.c_str(), diagnostics.size(), _tracked.size());
        for (auto &[document, tracked] : _tracked) {
            fprintf(stderr, "[lsp followed] %s on %s\n", tracked.uri.c_str(), tracked.serverName.c_str());
        }
    }
    for (auto &[document, tracked] : _tracked) {
        if (tracked.uri != uri || tracked.serverName != serverName) {
            continue;
        }
        const gw::TextBuffer &buffer = document->buffer();
        std::vector<GWDiagnostic> converted;
        for (const gw::lsp::Diagnostic &diagnostic : diagnostics) {
            try {
                GWDiagnostic item;
                item.range.start = gw::lsp::position(buffer, diagnostic.range.at("start"));
                item.range.end = gw::lsp::position(buffer, diagnostic.range.at("end"));
                item.severity = diagnostic.severity;
                item.message = diagnostic.message;
                item.source = diagnostic.source;
                item.raw = std::make_shared<gw::lsp::Json>(diagnostic.toJson());
                converted.push_back(std::move(item));
            } catch (const std::exception &) {
                // A malformed range from the server: skip that one problem.
            }
        }
        tracked.diagnostics = std::move(converted);
        if (self.onDiagnosticsChanged) self.onDiagnosticsChanged(document);
        // The server has just looked at the file, so its token colours are fresh too.
        [self requestSemanticTokensForDocument:document];
        return;
    }
}

- (void)requestSemanticTokensForDocument:(gw::Document *)document {
    auto found = _tracked.find(document);
    if (found == _tracked.end() || !GWServices.shared.settings.semanticHighlighting) {
        return;
    }
    Tracked &tracked = found->second;
    uint64_t version = document->version();
    if (tracked.semanticRequestedVersion == version) {
        return;
    }
    ServerEntry &entry = _servers[tracked.serverName];
    if (entry.server == nullptr || !entry.server->isReady() || !entry.server->supports("semanticTokensProvider")) {
        return;
    }
    gw::lsp::Json capabilities = entry.server->capabilities();
    const gw::lsp::Json &provider = capabilities["semanticTokensProvider"];
    if (!provider.is_object() || !provider.contains("legend")) {
        return;
    }
    bool wantsFull = provider.contains("full") && (provider["full"].is_object() || provider["full"] == true);
    if (!wantsFull) {
        return;
    }
    tracked.semanticRequestedVersion = version;
    auto typeNames = std::make_shared<std::vector<std::string>>();
    auto modifierNames = std::make_shared<std::vector<std::string>>();
    for (const gw::lsp::Json &name : provider["legend"].value("tokenTypes", gw::lsp::Json::array())) {
        typeNames->push_back(name.is_string() ? name.get<std::string>() : std::string());
    }
    for (const gw::lsp::Json &name : provider["legend"].value("tokenModifiers", gw::lsp::Json::array())) {
        modifierNames->push_back(name.is_string() ? name.get<std::string>() : std::string());
    }
    __weak GWLanguageService *weakSelf = self;
    entry.server->request("textDocument/semanticTokens/full", {{"textDocument", {{"uri", tracked.uri}}}},
                          [weakSelf, document, version, typeNames, modifierNames](const gw::lsp::Json &result, const std::string &error) {
        if (!error.empty() || !result.is_object() || !result["data"].is_array()) {
            return;
        }
        auto numbers = std::make_shared<std::vector<uint32_t>>();
        numbers->reserve(result["data"].size());
        for (const gw::lsp::Json &number : result["data"]) {
            numbers->push_back(number.is_number_unsigned() ? number.get<uint32_t>() : 0);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            GWLanguageService *strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            auto tracked = strongSelf->_tracked.find(document);
            if (tracked == strongSelf->_tracked.end() || document->version() != version) {
                return;  // closed, or edited since: newer tokens are on their way
            }
            auto set = std::make_shared<gw::SemanticTokenSet>();
            set->tokens = gw::decodeSemanticTokens(*numbers);
            set->typeNames = *typeNames;
            set->modifierNames = *modifierNames;
            tracked->second.semantic = set;
            if (strongSelf.onSemanticTokensChanged) strongSelf.onSemanticTokensChanged(document);
        });
    });
}

- (std::shared_ptr<const gw::SemanticTokenSet>)semanticTokensForDocument:(gw::Document *)document {
    auto found = _tracked.find(document);
    if (found == _tracked.end()) {
        return nullptr;
    }
    return found->second.semantic;
}

- (const std::vector<GWDiagnostic> &)diagnosticsForDocument:(gw::Document *)document {
    auto found = _tracked.find(document);
    if (found == _tracked.end()) {
        return _noDiagnostics;
    }
    return found->second.diagnostics;
}

- (NSUInteger)countWithSeverity:(int)severity {
    NSUInteger total = 0;
    for (const auto &[document, tracked] : _tracked) {
        for (const GWDiagnostic &diagnostic : tracked.diagnostics) {
            if (diagnostic.severity == severity) {
                ++total;
            }
        }
    }
    return total;
}

- (NSUInteger)errorCount { return [self countWithSeverity:1]; }
- (NSUInteger)warningCount { return [self countWithSeverity:2]; }

// ---------------------------------------------------------------------------
// MARK: Status

- (NSString *)statusTextForLanguage:(NSString *)languageId {
    if (languageId.length == 0 || !self.enabled) {
        return @"";
    }
    const gw::lsp::ServerSpec *spec = [self specForLanguage:languageId];
    if (spec == nullptr) {
        return @"";
    }
    auto found = _servers.find(spec->name);
    NSString *name = @(spec->name.c_str());
    if (found == _servers.end()) {
        return name;
    }
    const ServerEntry &entry = found->second;
    if (entry.failedToStart) {
        return [name stringByAppendingString:@" isn't installed"];
    }
    if (entry.server == nullptr || !entry.server->isRunning()) {
        return [name stringByAppendingString:@" stopped"];
    }
    if (!entry.server->isReady()) {
        return [name stringByAppendingString:@" starting…"];
    }
    return name;
}

- (NSString *)completionTriggerCharactersForDocument:(gw::Document *)document {
    auto found = _tracked.find(document);
    if (found == _tracked.end()) {
        return @"";
    }
    ServerEntry &entry = _servers[found->second.serverName];
    if (entry.server == nullptr || !entry.server->isReady()) {
        return @"";
    }
    gw::lsp::Json capabilities = entry.server->capabilities();
    NSMutableString *result = [NSMutableString string];
    if (capabilities.contains("completionProvider") && capabilities["completionProvider"].contains("triggerCharacters")) {
        for (const gw::lsp::Json &trigger : capabilities["completionProvider"]["triggerCharacters"]) {
            if (trigger.is_string()) {
                [result appendString:@(trigger.get<std::string>().c_str())];
            }
        }
    }
    return result;
}

- (NSString *)installHintForLanguage:(NSString *)languageId {
    const gw::lsp::ServerSpec *spec = [self specForLanguage:languageId];
    if (spec == nullptr) {
        return nil;
    }
    auto found = _servers.find(spec->name);
    if (found == _servers.end() || !found->second.failedToStart) {
        return nil;
    }
    return @(found->second.failureMessage.c_str());
}

- (BOOL)serverSupports:(NSString *)capability forDocument:(gw::Document *)document {
    auto found = _tracked.find(document);
    if (found == _tracked.end()) {
        return NO;
    }
    ServerEntry &entry = _servers[found->second.serverName];
    return entry.server != nullptr && entry.server->isReady() && entry.server->supports(capability.UTF8String);
}

// ---------------------------------------------------------------------------
// MARK: Requests

- (gw::lsp::Json)positionParamsForDocument:(gw::Document *)document position:(gw::Position)position {
    auto found = _tracked.find(document);
    std::string uri = found != _tracked.end() ? found->second.uri : gw::lsp::fileURI(document->path()->string());
    return {{"textDocument", {{"uri", uri}}}, {"position", gw::lsp::position(document->buffer(), position)}};
}

- (void)request:(NSString *)method
         params:(gw::lsp::Json)params
       document:(gw::Document *)document
requireSameVersion:(BOOL)requireSameVersion
     completion:(void (^)(const gw::lsp::Json &, NSString *))completion {
    auto found = _tracked.find(document);
    if (found == _tracked.end()) {
        completion(gw::lsp::Json(), @"No language server is following this file.");
        return;
    }
    [self flushDocument:document];
    ServerEntry &entry = _servers[found->second.serverName];
    if (entry.server == nullptr || !entry.server->isRunning()) {
        completion(gw::lsp::Json(), @"The language server isn't running.");
        return;
    }
    uint64_t versionAtRequest = document->version();
    __weak GWLanguageService *weakSelf = self;
    void (^copiedCompletion)(const gw::lsp::Json &, NSString *) = [completion copy];
    entry.server->request(method.UTF8String, std::move(params),
                          [weakSelf, document, versionAtRequest, requireSameVersion, copiedCompletion](const gw::lsp::Json &result, const std::string &error) {
        auto sharedResult = std::make_shared<gw::lsp::Json>(result);
        std::string errorCopy = error;
        dispatch_async(dispatch_get_main_queue(), ^{
            GWLanguageService *strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            // The document may have been closed (its pointer is then not followed any more).
            if (strongSelf->_tracked.find(document) == strongSelf->_tracked.end()) {
                return;
            }
            if (requireSameVersion && document->version() != versionAtRequest) {
                return;
            }
            NSString *message = errorCopy.empty() ? nil : @(errorCopy.c_str());
            copiedCompletion(*sharedResult, message);
        });
    });
}

@end
