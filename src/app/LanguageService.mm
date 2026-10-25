#import "LanguageService.h"

#import "Services.h"

#include "SettingsLookup.hpp"

#include <map>
#include <memory>
#include <set>
#include <unordered_map>

namespace {

/// Files larger than this are not sent to language servers (each keystroke would resend them).
constexpr size_t kLargestTrackedFile = 4 * 1024 * 1024;
/// How long after the last keystroke the server hears about the edit.
constexpr NSTimeInterval kSyncDelay = 0.25;

/// One server following one document. A document has the native server for its language (if any)
/// and, when VS Code extensions have providers for the language, the extension host's server too.
struct Attachment {
    std::string serverName;
    bool fromExtensions = false;
    uint64_t sentVersion = 0;
    std::vector<GWDiagnostic> diagnostics;
};

struct Tracked {
    std::string uri;
    std::string languageId;
    std::vector<Attachment> attachments;  // native first, then extensions
    std::vector<GWDiagnostic> diagnostics;  // every attachment's, merged: what the editor shows
    bool pendingChange = false;
    bool extensionsRequested = false;  // the host is being prepared for this document's language
    std::shared_ptr<const gw::SemanticTokenSet> semantic;
    // The text version each kind of answer was last asked for. A new file is at version 0, so
    // "never asked" must be something else than 0.
    static constexpr uint64_t kNeverAsked = UINT64_MAX;
    uint64_t semanticRequestedVersion = kNeverAsked;
    std::vector<GWInlayHint> inlayHints;
    uint64_t inlayRequestedVersion = kNeverAsked;
};

/// The user's settings, shared with the servers' reader threads.
struct SettingsSnapshot {
    std::mutex mutex;
    gw::lsp::Json values = gw::lsp::Json::object();
};

struct ServerEntry {
    std::unique_ptr<gw::lsp::LanguageServer> server;
    bool failedToStart = false;
    std::string failureMessage;
    std::set<std::string> openUris;
    bool fromExtensions = false;
};

/// Requests where every server's answer is wanted (VS Code merges them too); the rest go to the
/// one server that is best placed to answer.
bool isMergedMethod(const std::string &method) {
    static const std::set<std::string> merged = {
        "textDocument/completion", "textDocument/hover", "textDocument/codeAction",
        "textDocument/definition", "textDocument/declaration", "textDocument/typeDefinition",
        "textDocument/implementation", "textDocument/references", "textDocument/documentHighlight",
        "textDocument/codeLens", "textDocument/documentLink", "textDocument/inlayHint",
        "textDocument/foldingRange", "textDocument/documentSymbol", "workspace/symbol",
    };
    return merged.count(method) > 0;
}

/// Formatting is the one thing an extension is installed to take over (Prettier, say), so for
/// it the extension's provider is asked first.
bool prefersExtensions(const std::string &method) {
    return method == "textDocument/formatting" || method == "textDocument/rangeFormatting" ||
           method == "textDocument/onTypeFormatting";
}

/// An LSP hover's contents as a list of markdown pieces (string, MarkedString, MarkupContent, or an array of them).
void collectHoverText(const gw::lsp::Json &contents, std::vector<std::string> &into) {
    using Json = gw::lsp::Json;
    if (contents.is_string()) {
        into.push_back(contents.get<std::string>());
    } else if (contents.is_array()) {
        for (const Json &piece : contents) {
            collectHoverText(piece, into);
        }
    } else if (contents.is_object() && contents.contains("language") && contents.contains("value")) {
        into.push_back("```" + contents.value("language", "") + "\n" + contents.value("value", "") + "\n```");
    } else if (contents.is_object() && contents.contains("value") && contents["value"].is_string()) {
        into.push_back(contents["value"].get<std::string>());
    }
}

/// Combines the answers of several servers to the same request into one.
gw::lsp::Json mergeAnswers(const std::string &method, const std::vector<gw::lsp::Json> &answers) {
    using Json = gw::lsp::Json;
    if (method == "textDocument/completion") {
        Json items = Json::array();
        bool incomplete = false;
        for (const Json &answer : answers) {
            if (answer.is_array()) {
                for (const Json &item : answer) items.push_back(item);
            } else if (answer.is_object()) {
                incomplete = incomplete || answer.value("isIncomplete", false);
                for (const Json &item : answer.value("items", Json::array())) items.push_back(item);
            }
        }
        return {{"isIncomplete", incomplete}, {"items", items}};
    }
    if (method == "textDocument/hover") {
        std::vector<std::string> pieces;
        Json range;
        for (const Json &answer : answers) {
            if (!answer.is_object() || !answer.contains("contents")) continue;
            collectHoverText(answer["contents"], pieces);
            if (range.is_null() && answer.contains("range")) range = answer["range"];
        }
        if (pieces.empty()) return Json();
        std::string joined;
        for (size_t index = 0; index < pieces.size(); ++index) {
            if (index > 0) joined += "\n\n---\n\n";
            joined += pieces[index];
        }
        Json result = {{"contents", {{"kind", "markdown"}, {"value", joined}}}};
        if (!range.is_null()) result["range"] = range;
        return result;
    }
    // Everything else is a list (or a single location): concatenate.
    Json list = Json::array();
    for (const Json &answer : answers) {
        if (answer.is_array()) {
            for (const Json &item : answer) list.push_back(item);
        } else if (answer.is_object()) {
            list.push_back(answer);
        }
    }
    return list;
}

/// Marks each item of a completion/code-action/code-lens answer with the server that made it,
/// so a later resolve (or command) goes back to the same server.
void tagAnswer(const std::string &method, gw::lsp::Json &answer, const std::string &serverName) {
    using Json = gw::lsp::Json;
    Json *items = nullptr;
    if (answer.is_array()) {
        items = &answer;
    } else if (answer.is_object() && answer.contains("items") && answer["items"].is_array()) {
        items = &answer["items"];
    }
    bool wantsTag = method == "textDocument/completion" || method == "textDocument/codeAction" || method == "textDocument/codeLens";
    if (items == nullptr || !wantsTag) return;
    for (Json &item : *items) {
        if (item.is_object()) item["__gwServer"] = serverName;
    }
}

}  // namespace

@implementation GWLanguageService {
    std::vector<gw::lsp::ServerSpec> _specs;
    std::map<std::string, ServerEntry> _servers;             // by server name
    std::unordered_map<gw::Document *, Tracked> _tracked;
    std::vector<GWDiagnostic> _noDiagnostics;
    std::vector<GWInlayHint> _noInlayHints;
    std::shared_ptr<SettingsSnapshot> _settings;
}

- (instancetype)init {
    if ((self = [super init])) {
        _settings = std::make_shared<SettingsSnapshot>();
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

- (BOOL)extensionsServeLanguage:(NSString *)languageId {
    id<GWExtensionLanguageProvider> provider = self.extensionProvider;
    return provider != nil && [provider extensionsMayServeLanguage:languageId];
}

- (BOOL)hasServerForLanguage:(NSString *)languageId {
    return [self specForLanguage:languageId] != nullptr || [self extensionsServeLanguage:languageId];
}

/// Connects the callbacks every server needs (problems, edits the server wants made, status).
- (void)wireServer:(gw::lsp::LanguageServer *)server name:(const std::string &)serverName {
    __weak GWLanguageService *weakSelf = self;
    server->onDiagnostics = [weakSelf, serverName](const std::string &uri, long version, std::vector<gw::lsp::Diagnostic> diagnostics) {
        auto shared = std::make_shared<std::vector<gw::lsp::Diagnostic>>(std::move(diagnostics));
        // Copies: a block would only hold a reference to `uri`, which is gone by the time it runs.
        auto sharedUri = std::make_shared<std::string>(uri);
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf receivedDiagnostics:*shared forUri:*sharedUri version:version fromServer:serverName];
        });
    };
    server->onApplyEdit = [weakSelf](const gw::lsp::Json &edit, std::function<void(bool)> reply) {
        auto sharedEdit = std::make_shared<gw::lsp::Json>(edit);
        dispatch_async(dispatch_get_main_queue(), ^{
            GWLanguageService *strongSelf = weakSelf;
            if (strongSelf == nil || strongSelf.onApplyEdit == nil) {
                reply(false);
                return;
            }
            strongSelf.onApplyEdit(*sharedEdit, ^(BOOL applied) {
                reply(applied == YES);
            });
        });
    };
    // Things the server says on its own. The strings are copied: they are references that are
    // gone by the time the main thread runs the block.
    server->onShowMessage = [weakSelf, serverName](int type, const std::string &message) {
        NSString *text = @(message.c_str());
        dispatch_async(dispatch_get_main_queue(), ^{
            GWLanguageService *strongSelf = weakSelf;
            if (strongSelf.onServerMessage) strongSelf.onServerMessage(@(serverName.c_str()), type, text);
        });
    };
    server->onLogMessage = [weakSelf, serverName](int, const std::string &message) {
        NSString *text = @(message.c_str());
        dispatch_async(dispatch_get_main_queue(), ^{
            GWLanguageService *strongSelf = weakSelf;
            if (strongSelf.onServerLog) strongSelf.onServerLog(@(serverName.c_str()), text);
        });
    };
    server->onProgress = [weakSelf, serverName](const std::string &token, const std::string &kind, const std::string &title,
                                                const std::string &message, int percentage) {
        NSString *tokenText = @(token.c_str());
        NSString *kindText = @(kind.c_str());
        NSString *titleText = @(title.c_str());
        NSString *messageText = @(message.c_str());
        dispatch_async(dispatch_get_main_queue(), ^{
            GWLanguageService *strongSelf = weakSelf;
            if (strongSelf.onServerProgress) {
                strongSelf.onServerProgress(@(serverName.c_str()), tokenText, kindText, titleText, messageText, percentage);
            }
        });
    };
    server->onShowMessageRequest = [weakSelf, serverName](int, const std::string &message, const std::vector<std::string> &actions,
                                                          std::function<void(const std::string &)> reply) {
        NSString *text = @(message.c_str());
        NSMutableArray<NSString *> *titles = [NSMutableArray array];
        for (const std::string &action : actions) {
            [titles addObject:@(action.c_str())];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            GWLanguageService *strongSelf = weakSelf;
            if (strongSelf == nil || strongSelf.onServerQuestion == nil) {
                reply("");
                return;
            }
            strongSelf.onServerQuestion(@(serverName.c_str()), text, titles, ^(NSString *chosen) {
                reply(chosen.UTF8String ?: "");
            });
        });
    };
    // A server asks for settings on its own thread; answer from a snapshot kept up to date on the
    // main thread, so neither thread ever waits for the other.
    std::shared_ptr<SettingsSnapshot> snapshot = _settings;
    server->onConfiguration = [snapshot](const std::string &section, const std::string &) -> gw::lsp::Json {
        std::lock_guard<std::mutex> lock(snapshot->mutex);
        return gw::settingsSection(snapshot->values, section);
    };
    server->onReady = [weakSelf]() {
        dispatch_async(dispatch_get_main_queue(), ^{
            GWLanguageService *strongSelf = weakSelf;
            if (strongSelf.onStatusChanged) strongSelf.onStatusChanged();
        });
    };
    gw::lsp::LanguageServer *rawServer = server;
    server->onExit = [weakSelf, serverName, rawServer](int) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf serverEnded:serverName instance:rawServer];
        });
    };
}

- (NSString *)rootFolderOrHome {
    NSString *root = self.rootFolder;
    return root.length == 0 ? NSHomeDirectory() : root;
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
    entry.openUris.clear();
    entry.server = std::make_unique<gw::lsp::LanguageServer>(spec, [self rootFolderOrHome].UTF8String);
    [self wireServer:entry.server.get() name:spec.name];
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

static std::string extensionServerName(NSString *languageId) {
    return std::string("extensions:") + languageId.UTF8String;
}

/// The virtual server through which VS Code extensions answer for a language. Unlike a missing
/// program, a host that isn't running right now isn't a permanent failure: ask again next time.
- (gw::lsp::LanguageServer *)extensionServerForLanguage:(NSString *)languageId {
    std::string name = extensionServerName(languageId);
    ServerEntry &entry = _servers[name];
    if (entry.server != nullptr && entry.server->isRunning()) {
        return entry.server.get();
    }
    id<GWExtensionLanguageProvider> provider = self.extensionProvider;
    NSString *root = [self rootFolderOrHome];
    NSString *rootURI = @(gw::lsp::fileURI(root.UTF8String).c_str());
    std::unique_ptr<gw::lsp::ServerTransport> transport = [provider newTransportForLanguage:languageId rootURI:rootURI];
    if (transport == nullptr) {
        return nullptr;
    }
    gw::lsp::ServerSpec spec;
    spec.name = name;
    entry.openUris.clear();
    entry.fromExtensions = true;
    entry.server = std::make_unique<gw::lsp::LanguageServer>(spec, root.UTF8String, std::move(transport));
    [self wireServer:entry.server.get() name:name];
    std::string error;
    if (!entry.server->start(&error)) {
        entry.server.reset();
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
        for (Attachment &attachment : tracked.attachments) {
            if (attachment.serverName == name) {
                attachment.sentVersion = 0;
            }
        }
    }
    if (self.onStatusChanged) self.onStatusChanged();
}

- (void)filesDidChange:(NSArray<NSString *> *)paths {
    std::vector<gw::lsp::LanguageServer::FileEvent> events;
    NSFileManager *files = NSFileManager.defaultManager;
    for (NSString *path in paths) {
        if ([path containsString:@"/.git/"] || events.size() >= 5000) {
            continue;  // repository internals aren't source, and a huge batch (a checkout) is capped
        }
        gw::lsp::LanguageServer::FileEvent event;
        event.path = path.UTF8String;
        event.type = [files fileExistsAtPath:path] ? 2 : 3;  // present: changed (or created); gone: deleted
        events.push_back(std::move(event));
    }
    if (events.empty()) {
        return;
    }
    for (auto &[name, entry] : _servers) {
        if (entry.server != nullptr && entry.server->isReady() && !entry.fromExtensions && entry.server->watchesFiles()) {
            entry.server->didChangeWatchedFiles(events);
        }
    }
}

- (void)settingsDidChange:(const gw::lsp::Json &)settings {
    {
        std::lock_guard<std::mutex> lock(_settings->mutex);
        _settings->values = settings;
    }
    for (auto &[name, entry] : _servers) {
        if (entry.server != nullptr && entry.server->isReady() && !entry.fromExtensions) {
            entry.server->didChangeConfiguration(settings);
        }
    }
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

static Attachment *attachmentNamed(Tracked &tracked, const std::string &name) {
    for (Attachment &attachment : tracked.attachments) {
        if (attachment.serverName == name) {
            return &attachment;
        }
    }
    return nullptr;
}

static bool hasExtensionAttachment(const Tracked &tracked) {
    for (const Attachment &attachment : tracked.attachments) {
        if (attachment.fromExtensions) {
            return true;
        }
    }
    return false;
}

- (void)trackDocument:(gw::Document *)document {
    if (!self.enabled || document == nullptr || !document->path() || document->readOnly) {
        return;
    }
    NSString *languageId = @(document->languageId.c_str());
    const gw::lsp::ServerSpec *spec = [self specForLanguage:languageId];
    BOOL extensionsWanted = [self extensionsServeLanguage:languageId];
    std::string uri = gw::lsp::fileURI(document->path()->string());

    auto existing = _tracked.find(document);
    if (existing != _tracked.end()) {
        Tracked &current = existing->second;
        bool hasNative = !current.attachments.empty() && !current.attachments.front().fromExtensions;
        bool sameNative = spec != nullptr ? (hasNative && current.attachments.front().serverName == spec->name) : !hasNative;
        if (sameNative && current.languageId == document->languageId && current.uri == uri) {
            if (extensionsWanted) {
                [self attachExtensionsToDocument:document];
            }
            return;
        }
        [self untrackDocument:document];  // the language or the file name changed
    }
    if (spec == nullptr && !extensionsWanted) {
        return;
    }
    // Look at the size first: copying a huge file's text just to find out it is too big would
    // cost as much memory as the file itself.
    if (document->buffer().byteSize() > kLargestTrackedFile) {
        return;
    }

    Tracked tracked;
    tracked.uri = uri;
    tracked.languageId = document->languageId;
    document->recordSyncEdits(true);  // from now on, changes can be sent as small edits

    if (spec != nullptr) {
        gw::lsp::LanguageServer *server = [self serverForSpec:*spec];
        if (server != nullptr) {
            server->didOpen(uri, document->languageId, document->version(), document->buffer().text());
            _servers[spec->name].openUris.insert(uri);
            Attachment attachment;
            attachment.serverName = spec->name;
            attachment.sentVersion = document->version();
            tracked.attachments.push_back(attachment);
        }
    }
    if (tracked.attachments.empty() && !extensionsWanted) {
        document->recordSyncEdits(false);
        return;
    }
    _tracked[document] = std::move(tracked);
    if (extensionsWanted) {
        [self attachExtensionsToDocument:document];
    }
}

/// Asks the extension host to get ready for this document's language (starting it, and running
/// the extensions that wait for the language), then adds the host's virtual server to the
/// document alongside any native server.
- (void)attachExtensionsToDocument:(gw::Document *)document {
    auto found = _tracked.find(document);
    if (found == _tracked.end()) {
        return;
    }
    Tracked &tracked = found->second;
    if (tracked.extensionsRequested) {
        return;
    }
    NSString *languageId = @(tracked.languageId.c_str());
    if (hasExtensionAttachment(tracked)) {
        // Already attached: just make sure its server is still alive.
        Attachment *attachment = attachmentNamed(tracked, extensionServerName(languageId));
        ServerEntry &entry = _servers[extensionServerName(languageId)];
        if (attachment != nullptr && entry.server != nullptr && entry.server->isRunning()) {
            return;
        }
    }
    tracked.extensionsRequested = YES;
    std::string uriAtRequest = tracked.uri;
    id<GWExtensionLanguageProvider> provider = self.extensionProvider;
    __weak GWLanguageService *weakSelf = self;
    [provider prepareLanguage:languageId completion:^(BOOL ok) {
        GWLanguageService *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        auto stillTracked = strongSelf->_tracked.find(document);
        if (stillTracked == strongSelf->_tracked.end() || stillTracked->second.uri != uriAtRequest) {
            return;  // closed while the host was starting
        }
        stillTracked->second.extensionsRequested = NO;
        if (!ok) {
            return;
        }
        [strongSelf attachExtensionServerForLanguage:languageId toDocument:document];
    }];
}

- (void)attachExtensionServerForLanguage:(NSString *)languageId toDocument:(gw::Document *)document {
    auto found = _tracked.find(document);
    if (found == _tracked.end()) {
        return;
    }
    gw::lsp::LanguageServer *server = [self extensionServerForLanguage:languageId];
    if (server == nullptr) {
        return;
    }
    // Bring the other servers up to date first, so the edit journal starts from this version.
    [self flushDocument:document];
    found = _tracked.find(document);
    Tracked &tracked = found->second;
    std::string name = extensionServerName(languageId);
    ServerEntry &entry = _servers[name];

    server->didOpen(tracked.uri, tracked.languageId, document->version(), document->buffer().text());
    entry.openUris.insert(tracked.uri);
    Attachment *attachment = attachmentNamed(tracked, name);
    if (attachment == nullptr) {
        Attachment fresh;
        fresh.serverName = name;
        fresh.fromExtensions = true;
        tracked.attachments.push_back(fresh);
        attachment = &tracked.attachments.back();
    }
    attachment->sentVersion = document->version();
    if (self.onStatusChanged) self.onStatusChanged();
    [self requestInlayHintsForDocument:document];
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

/// Sends every server the document's changes since it last heard.
- (void)flushDocument:(gw::Document *)document {
    auto found = _tracked.find(document);
    if (found == _tracked.end()) {
        return;
    }
    Tracked &tracked = found->second;
    tracked.pendingChange = false;
    uint64_t version = document->version();
    bool anyBehind = false;
    for (const Attachment &attachment : tracked.attachments) {
        if (attachment.sentVersion != version) {
            anyBehind = true;
        }
    }
    if (!anyBehind) {
        return;
    }

    // The journal holds everything since the last flush. Take it once; each server that is up
    // to date with the previous version gets the same small edits.
    std::optional<std::vector<gw::SyncEdit>> edits = document->takeSyncEdits();
    std::string fullText;
    bool haveFullText = false;
    auto text = [&]() -> const std::string & {
        if (!haveFullText) {
            fullText = document->buffer().text();
            haveFullText = true;
        }
        return fullText;
    };

    for (Attachment &attachment : tracked.attachments) {
        if (attachment.sentVersion == version) {
            continue;
        }
        ServerEntry &entry = _servers[attachment.serverName];
        if (entry.server == nullptr || !entry.server->isRunning()) {
            // The server died: start a fresh one and open the file again.
            gw::lsp::LanguageServer *server = nullptr;
            if (attachment.fromExtensions) {
                server = [self extensionServerForLanguage:@(tracked.languageId.c_str())];
            } else {
                const gw::lsp::ServerSpec *spec = gw::lsp::serverForLanguage(_specs, tracked.languageId);
                server = spec ? [self serverForSpec:*spec] : nullptr;
            }
            if (server == nullptr) {
                continue;
            }
            server->didOpen(tracked.uri, tracked.languageId, version, text());
            _servers[attachment.serverName].openUris.insert(tracked.uri);
            attachment.sentVersion = version;
            continue;
        }
        if (entry.openUris.count(tracked.uri) == 0) {
            entry.server->didOpen(tracked.uri, tracked.languageId, version, text());
            entry.openUris.insert(tracked.uri);
        } else {
            // Send just what changed when the server accepts that and the list of edits is complete;
            // otherwise (or if too much changed to be worth replaying) send the whole text.
            bool canSendEdits = entry.server->wantsIncrementalSync() && edits.has_value() && !edits->empty();
            if (canSendEdits) {
                entry.server->didChangeIncremental(tracked.uri, version, *edits);
            } else {
                entry.server->didChange(tracked.uri, version, text());
            }
        }
        attachment.sentVersion = version;
    }
    // Hints follow the text: ask again shortly after the servers have heard about the edit.
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(refreshInlayHintsSoon:) object:nil];
    NSValue *key = [NSValue valueWithPointer:document];
    [self performSelector:@selector(refreshInlayHintsSoon:) withObject:key afterDelay:0.6];
}

- (void)refreshInlayHintsSoon:(NSValue *)key {
    gw::Document *document = static_cast<gw::Document *>(key.pointerValue);
    if (_tracked.find(document) != _tracked.end()) {
        [self requestInlayHintsForDocument:document];
    }
}

- (void)documentDidSave:(gw::Document *)document {
    auto found = _tracked.find(document);
    if (found == _tracked.end()) {
        return;
    }
    [self flushDocument:document];
    for (const Attachment &attachment : found->second.attachments) {
        ServerEntry &entry = _servers[attachment.serverName];
        if (entry.server != nullptr && entry.server->isRunning()) {
            entry.server->didSave(found->second.uri);
        }
    }
}

/// Tells every server the file is closed.
- (void)closeDocumentOnServers:(const Tracked &)tracked {
    for (const Attachment &attachment : tracked.attachments) {
        ServerEntry &entry = _servers[attachment.serverName];
        if (entry.server != nullptr && entry.server->isRunning() && entry.openUris.count(tracked.uri) > 0) {
            entry.server->didClose(tracked.uri);
        }
        entry.openUris.erase(tracked.uri);
    }
}

- (void)untrackDocument:(gw::Document *)document {
    auto found = _tracked.find(document);
    if (found == _tracked.end()) {
        return;
    }
    [self closeDocumentOnServers:found->second];
    _tracked.erase(found);
    document->recordSyncEdits(false);
    if (self.onDiagnosticsChanged) self.onDiagnosticsChanged(document);
}

- (void)documentDidMove:(gw::Document *)document fromPath:(NSString *)oldPath {
    // Close under the old uri, then let trackDocument open the new one.
    auto found = _tracked.find(document);
    if (found != _tracked.end()) {
        [self closeDocumentOnServers:found->second];
        _tracked.erase(found);
        document->recordSyncEdits(false);
    }
    [self trackDocument:document];
}

// ---------------------------------------------------------------------------
// MARK: Diagnostics

/// Rebuilds the list the editor shows: every server's problems for the file, together.
static void mergeDiagnostics(Tracked &tracked) {
    tracked.diagnostics.clear();
    for (const Attachment &attachment : tracked.attachments) {
        tracked.diagnostics.insert(tracked.diagnostics.end(), attachment.diagnostics.begin(), attachment.diagnostics.end());
    }
}

- (void)receivedDiagnostics:(const std::vector<gw::lsp::Diagnostic> &)diagnostics
                     forUri:(const std::string &)uri
                    version:(long)version
                 fromServer:(const std::string &)serverName {
    if (getenv("GLASSWORK_LSP_TRACE") != nullptr) {
        fprintf(stderr, "[lsp diagnostics] %s (%zu items) from %s for %zu followed "
                        "files\n", uri.c_str(), diagnostics.size(), serverName.c_str(), _tracked.size());
    }
    for (auto &[document, tracked] : _tracked) {
        Attachment *attachment = tracked.uri == uri ? attachmentNamed(tracked, serverName) : nullptr;
        if (attachment == nullptr) {
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
                // Remember who reported it, so code actions for it go to the same server.
                (*item.raw)["__gwServer"] = serverName;
                converted.push_back(std::move(item));
            } catch (const std::exception &) {
                // A malformed range from the server: skip that one problem.
            }
        }
        attachment->diagnostics = std::move(converted);
        mergeDiagnostics(tracked);
        if (self.onDiagnosticsChanged) self.onDiagnosticsChanged(document);
        // The server has just looked at the file, so its token colors and hints are fresh too.
        [self requestSemanticTokensForDocument:document];
        [self requestInlayHintsForDocument:document];
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
    // The first server that can color code (a native server's, normally).
    gw::lsp::LanguageServer *server = nullptr;
    for (const Attachment &attachment : tracked.attachments) {
        ServerEntry &candidate = _servers[attachment.serverName];
        if (candidate.server != nullptr && candidate.server->isReady() && candidate.server->supports("semanticTokensProvider")) {
            server = candidate.server.get();
            break;
        }
    }
    if (server == nullptr) {
        return;
    }
    gw::lsp::Json capabilities = server->capabilities();
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
    server->request("textDocument/semanticTokens/full", {{"textDocument", {{"uri", tracked.uri}}}},
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
            auto trackedEntry = strongSelf->_tracked.find(document);
            if (trackedEntry == strongSelf->_tracked.end() || document->version() != version) {
                return;  // closed, or edited since: newer tokens are on their way
            }
            auto set = std::make_shared<gw::SemanticTokenSet>();
            set->tokens = gw::decodeSemanticTokens(*numbers);
            set->typeNames = *typeNames;
            set->modifierNames = *modifierNames;
            trackedEntry->second.semantic = set;
            if (strongSelf.onSemanticTokensChanged) strongSelf.onSemanticTokensChanged(document);
        });
    });
}

/// Asks the servers for the document's inlay hints, once per version of the text.
- (void)requestInlayHintsForDocument:(gw::Document *)document {
    auto found = _tracked.find(document);
    if (found == _tracked.end()) {
        return;
    }
    Tracked &tracked = found->second;
    if (!GWServices.shared.settings.inlayHints) {
        if (!tracked.inlayHints.empty()) {
            tracked.inlayHints.clear();
            if (self.onInlayHintsChanged) self.onInlayHintsChanged(document);
        }
        return;
    }
    uint64_t version = document->version();
    if (tracked.inlayRequestedVersion == version || ![self serverSupports:@"inlayHintProvider" forDocument:document]) {
        return;
    }
    tracked.inlayRequestedVersion = version;
    const gw::TextBuffer &buffer = document->buffer();
    gw::lsp::Json params = {
        {"textDocument", {{"uri", tracked.uri}}},
        {"range", {{"start", {{"line", 0}, {"character", 0}}}, {"end", gw::lsp::position(buffer, buffer.end())}}},
    };
    __weak GWLanguageService *weakSelf = self;
    [self request:@"textDocument/inlayHint" params:params document:document requireSameVersion:YES
       completion:^(const gw::lsp::Json &result, NSString *error) {
        GWLanguageService *strongSelf = weakSelf;
        auto stillTracked = strongSelf->_tracked.find(document);
        if (strongSelf == nil || error != nil || !result.is_array() || stillTracked == strongSelf->_tracked.end()) {
            return;
        }
        std::vector<GWInlayHint> hints;
        const gw::TextBuffer &current = document->buffer();
        for (const gw::lsp::Json &item : result) {
            if (!item.is_object() || !item.contains("position") || !item.contains("label")) continue;
            GWInlayHint hint;
            try {
                hint.position = gw::lsp::position(current, item["position"]);
            } catch (const std::exception &) {
                continue;
            }
            // A label is a string, or a list of parts whose values join up.
            if (item["label"].is_string()) {
                hint.label = item["label"].get<std::string>();
            } else if (item["label"].is_array()) {
                for (const gw::lsp::Json &part : item["label"]) {
                    hint.label += part.value("value", "");
                }
            }
            if (hint.label.empty()) continue;
            hint.isType = item.value("kind", 0) == 1;
            hint.padLeft = item.value("paddingLeft", false);
            hint.padRight = item.value("paddingRight", false);
            hints.push_back(std::move(hint));
            if (hints.size() >= 5000) break;
        }
        std::stable_sort(hints.begin(), hints.end(), [](const GWInlayHint &a, const GWInlayHint &b) { return a.position < b.position; });
        stillTracked->second.inlayHints = std::move(hints);
        if (strongSelf.onInlayHintsChanged) strongSelf.onInlayHintsChanged(document);
    }];
}

- (const std::vector<GWInlayHint> &)inlayHintsForDocument:(gw::Document *)document {
    auto found = _tracked.find(document);
    return found == _tracked.end() ? _noInlayHints : found->second.inlayHints;
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
    NSString *text = @"";
    const gw::lsp::ServerSpec *spec = [self specForLanguage:languageId];
    if (spec != nullptr) {
        auto found = _servers.find(spec->name);
        NSString *name = @(spec->name.c_str());
        text = name;
        if (found != _servers.end()) {
            const ServerEntry &entry = found->second;
            if (entry.failedToStart) {
                text = [name stringByAppendingString:@" isn't installed"];
            } else if (entry.server == nullptr || !entry.server->isRunning()) {
                text = [name stringByAppendingString:@" stopped"];
            } else if (!entry.server->isReady()) {
                text = [name stringByAppendingString:@" starting…"];
            }
        }
    }
    if ([self extensionsServeLanguage:languageId]) {
        auto found = _servers.find(extensionServerName(languageId));
        bool running = found != _servers.end() && found->second.server != nullptr && found->second.server->isRunning();
        NSString *extra = running ? @"extensions" : @"extensions starting…";
        text = text.length > 0 ? [NSString stringWithFormat:@"%@ + %@", text, extra] : extra;
    }
    return text;
}

- (NSString *)completionTriggerCharactersForDocument:(gw::Document *)document {
    auto found = _tracked.find(document);
    if (found == _tracked.end()) {
        return @"";
    }
    NSMutableString *result = [NSMutableString string];
    for (const Attachment &attachment : found->second.attachments) {
        ServerEntry &entry = _servers[attachment.serverName];
        if (entry.server == nullptr || !entry.server->isReady()) {
            continue;
        }
        gw::lsp::Json capabilities = entry.server->capabilities();
        if (capabilities.contains("completionProvider") && capabilities["completionProvider"].contains("triggerCharacters")) {
            for (const gw::lsp::Json &trigger : capabilities["completionProvider"]["triggerCharacters"]) {
                if (trigger.is_string()) {
                    NSString *characters = @(trigger.get<std::string>().c_str());
                    if (![result containsString:characters]) {
                        [result appendString:characters];
                    }
                }
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
    for (const Attachment &attachment : found->second.attachments) {
        ServerEntry &entry = _servers[attachment.serverName];
        if (entry.server != nullptr && entry.server->isReady() && entry.server->supports(capability.UTF8String)) {
            return YES;
        }
    }
    return NO;
}

// ---------------------------------------------------------------------------
// MARK: Requests

- (gw::lsp::Json)positionParamsForDocument:(gw::Document *)document position:(gw::Position)position {
    auto found = _tracked.find(document);
    std::string uri = found != _tracked.end() ? found->second.uri : gw::lsp::fileURI(document->path()->string());
    return {{"textDocument", {{"uri", uri}}}, {"position", gw::lsp::position(document->buffer(), position)}};
}

/// The servers that should hear a request, in the order they should be tried.
- (std::vector<std::string>)serversForMethod:(const std::string &)method
                                      params:(const gw::lsp::Json &)params
                                     tracked:(Tracked &)tracked {
    // An item from an earlier answer says which server made it (resolve, commands).
    if (params.is_object() && params.contains("__gwServer") && params["__gwServer"].is_string()) {
        std::string hint = params["__gwServer"].get<std::string>();
        if (attachmentNamed(tracked, hint) != nullptr) {
            return {hint};
        }
    }

    std::string key = gw::lsp::capabilityKeyForMethod(method);
    if (method == "completionItem/resolve") {
        key = "completionProvider.resolveProvider";
    } else if (method == "codeAction/resolve") {
        key = "codeActionProvider.resolveProvider";
    } else if (method == "codeLens/resolve") {
        key = "codeLensProvider.resolveProvider";
    } else if (method == "textDocument/prepareRename") {
        key = "renameProvider";
    }

    std::vector<std::string> ordered;
    for (const Attachment &attachment : tracked.attachments) {
        ordered.push_back(attachment.serverName);
    }
    if (prefersExtensions(method)) {
        std::stable_partition(ordered.begin(), ordered.end(), [&](const std::string &name) {
            Attachment *attachment = attachmentNamed(tracked, name);
            return attachment != nullptr && attachment->fromExtensions;
        });
    }

    std::vector<std::string> capable;
    for (const std::string &name : ordered) {
        ServerEntry &entry = _servers[name];
        if (entry.server == nullptr || !entry.server->isRunning()) {
            continue;
        }
        if (key.empty() || entry.server->supports(key)) {
            capable.push_back(name);
        }
    }
    if (capable.empty() && !ordered.empty()) {
        // Nobody claims to support it: let the first server say so itself.
        capable.push_back(ordered.front());
    }
    if (!isMergedMethod(method) && capable.size() > 1) {
        capable.resize(1);
    }
    return capable;
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
    found = _tracked.find(document);
    std::string methodName = method.UTF8String;
    std::vector<std::string> targets = [self serversForMethod:methodName params:params tracked:found->second];
    bool tagResults = targets.size() > 1 || (found->second.attachments.size() > 1 &&
                                             (methodName == "textDocument/completion" || methodName == "textDocument/codeAction" ||
                                              methodName == "textDocument/codeLens"));
    if (params.is_object()) {
        params.erase("__gwServer");
    }

    std::vector<gw::lsp::LanguageServer *> servers;
    std::vector<std::string> serverNames;
    for (const std::string &name : targets) {
        ServerEntry &entry = _servers[name];
        if (entry.server != nullptr && entry.server->isRunning()) {
            servers.push_back(entry.server.get());
            serverNames.push_back(name);
        }
    }
    if (servers.empty()) {
        completion(gw::lsp::Json(), @"The language server isn't running.");
        return;
    }

    uint64_t versionAtRequest = document->version();
    __weak GWLanguageService *weakSelf = self;
    void (^copiedCompletion)(const gw::lsp::Json &, NSString *) = [completion copy];

    // Collects the servers' answers (they arrive on background threads, in any order) and
    // finishes on the main thread once every one has come back.
    struct Gathered {
        std::mutex mutex;
        size_t remaining = 0;
        std::vector<gw::lsp::Json> answers;
        std::vector<std::string> errors;
    };
    auto gathered = std::make_shared<Gathered>();
    gathered->remaining = servers.size();
    gathered->answers.resize(servers.size());

    for (size_t index = 0; index < servers.size(); ++index) {
        std::string serverName = serverNames[index];
        servers[index]->request(methodName, params,
                                [=](const gw::lsp::Json &result, const std::string &error) {
            bool last = false;
            {
                std::lock_guard<std::mutex> lock(gathered->mutex);
                if (error.empty()) {
                    gw::lsp::Json answer = result;
                    if (tagResults) {
                        tagAnswer(methodName, answer, serverName);
                    }
                    gathered->answers[index] = std::move(answer);
                } else {
                    gathered->errors.push_back(error);
                }
                last = --gathered->remaining == 0;
            }
            if (!last) {
                return;
            }
            gw::lsp::Json combined;
            std::string firstError;
            {
                std::lock_guard<std::mutex> lock(gathered->mutex);
                bool anySucceeded = gathered->errors.size() < gathered->answers.size();
                if (!anySucceeded) {
                    firstError = gathered->errors.empty() ? "Request failed" : gathered->errors.front();
                } else if (gathered->answers.size() == 1) {
                    combined = gathered->answers[0];
                } else {
                    combined = mergeAnswers(methodName, gathered->answers);
                }
            }
            auto sharedResult = std::make_shared<gw::lsp::Json>(std::move(combined));
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
                NSString *message = firstError.empty() ? nil : @(firstError.c_str());
                copiedCompletion(*sharedResult, message);
            });
        });
    }
}

@end
