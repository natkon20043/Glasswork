#import "ExtensionHostService.h"

#import "Services.h"

#include "ExtensionHost.hpp"
#include "Fuzzy.hpp"
#include "Jsonc.hpp"
#include "SettingsLookup.hpp"

#include <fstream>
#include <map>
#include <set>
#include <sstream>

using Json = gw::lsp::Json;

@implementation GWExtensionStatusItem
@end

namespace {

/// What an installed extension tells us before its code has run.
struct ExtensionIndexEntry {
    std::string identifier;
    std::set<std::string> activationEvents;  // as declared, plus the implicit ones
    std::set<std::string> languages;         // languages it contributes
    bool runsAtStartup = false;              // "*", onStartupFinished or workspaceContains
};

struct ContributedCommand {
    std::string identifier;
    std::string title;
    bool hiddenFromPalette = false;
};

/// A host process started this many times in a row without lasting is not started again.
constexpr int kMostRestarts = 3;

NSString *StringFromJson(const Json &value) {
    if (value.is_string()) {
        return @(value.get<std::string>().c_str());
    }
    return nil;
}

id FoundationFromJson(const Json &value) {
    std::string text = value.dump();
    NSData *data = [NSData dataWithBytes:text.data() length:text.size()];
    return [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:nil];
}

Json JsonFromFoundation(id object) {
    if (object == nil || object == NSNull.null) {
        return Json();
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingFragmentsAllowed error:nil];
    if (data == nil) {
        return Json();
    }
    std::string text(static_cast<const char *>(data.bytes), data.length);
    return Json::parse(text, nullptr, false);
}

/// "$(sync~spin) Building" → "Building": icons in extension status text are VS Code's own set.
NSString *WithoutIconMarkup(NSString *text) {
    NSRegularExpression *icons = [NSRegularExpression regularExpressionWithPattern:@"\\$\\([^)]*\\)\\s*" options:0 error:nil];
    return [icons stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:@""];
}

std::string PathFromURI(const std::string &uri) {
    return gw::lsp::pathFromURI(uri);
}

}  // namespace

@implementation GWExtensionHostService {
    std::unique_ptr<gw::ExtensionHost> _host;
    BOOL _initializing;
    BOOL _initialized;
    BOOL _stopping;
    int _restarts;
    NSMutableArray<void (^)(BOOL)> *_waiting;
    std::set<std::string> _providerLanguages;
    BOOL _providersForAnyLanguage;
    std::set<std::string> _activatedLanguages;
    std::vector<ExtensionIndexEntry> _index;
    std::vector<ContributedCommand> _contributedCommands;
    NSMutableDictionary<NSString *, NSString *> *_registeredCommands;  // id → title ("" when it has none)
    NSMutableDictionary<NSString *, GWExtensionStatusItem *> *_statusItemsByID;
    NSMutableDictionary<NSString *, NSString *> *_extensionStates;
    dispatch_queue_t _logQueue;
    NSMutableSet<NSString *> *_openedChannels;
    NSMutableSet<NSString *> *_knownChannels;
    BOOL _indexBuilt;
    std::string _lastEditorState;  // what the host was last told, to send only changes
}

- (instancetype)init {
    if ((self = [super init])) {
        _waiting = [NSMutableArray array];
        _registeredCommands = [NSMutableDictionary dictionary];
        _statusItemsByID = [NSMutableDictionary dictionary];
        _extensionStates = [NSMutableDictionary dictionary];
        _openedChannels = [NSMutableSet set];
        _knownChannels = [NSMutableSet set];
        _logQueue = dispatch_queue_create("glasswork.extension-logs", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc {
    if (_host != nullptr) {
        _host->stop();
    }
}

// ---------------------------------------------------------------------------
// MARK: What is installed

- (NSURL *)supportFolder {
    return [GWServices.shared.settingsURL URLByDeletingLastPathComponent];
}

/// Reads each installed extension's manifest once to learn what could wake it.
- (void)buildIndexIfNeeded {
    if (_indexBuilt) {
        return;
    }
    _indexBuilt = YES;
    _index.clear();
    _contributedCommands.clear();
    for (const gw::Extension &extension : GWServices.shared.extensions.extensions()) {
        if (!extension.hasCode || extension.id.rfind("vscode.", 0) == 0) {
            continue;  // declarative only, or one of VS Code's own built-ins (themes, grammars)
        }
        Json manifest = Json::parse(extension.manifestJson, nullptr, false);
        if (!manifest.is_object()) {
            continue;
        }
        ExtensionIndexEntry entry;
        entry.identifier = extension.id;
        for (const Json &event : manifest.value("activationEvents", Json::array())) {
            if (event.is_string()) {
                entry.activationEvents.insert(event.get<std::string>());
            }
        }
        const Json contributes = manifest.value("contributes", Json::object());
        for (const Json &language : contributes.value("languages", Json::array())) {
            if (language.is_object() && language.contains("id") && language["id"].is_string()) {
                entry.languages.insert(language["id"].get<std::string>());
            }
        }
        for (const std::string &event : entry.activationEvents) {
            bool startup = event == "*" || event == "onStartupFinished" || event.rfind("workspaceContains:", 0) == 0;
            entry.runsAtStartup = entry.runsAtStartup || startup;
        }

        // Commands in the palette: those the manifest contributes, minus ones it hides there.
        std::set<std::string> hidden;
        const Json menus = contributes.value("menus", Json::object());
        for (const Json &item : menus.value("commandPalette", Json::array())) {
            if (item.is_object() && item.value("when", "") == "false") {
                hidden.insert(item.value("command", ""));
            }
        }
        for (const Json &command : contributes.value("commands", Json::array())) {
            if (!command.is_object() || !command.contains("command") || !command["command"].is_string()) {
                continue;
            }
            ContributedCommand contributed;
            contributed.identifier = command["command"].get<std::string>();
            std::string title = command.value("title", "");
            std::string category = command.value("category", "");
            contributed.title = category.empty() ? title : category + ": " + title;
            contributed.hiddenFromPalette = hidden.count(contributed.identifier) > 0 || title.empty();
            _contributedCommands.push_back(std::move(contributed));
        }
        _index.push_back(std::move(entry));
    }
}

- (BOOL)hasRunnableExtensions {
    [self buildIndexIfNeeded];
    return !_index.empty();
}

- (void)extensionsDidChange {
    _indexBuilt = NO;
}

// ---------------------------------------------------------------------------
// MARK: Starting the host

- (NSString *)hostScriptPath {
    const char *override = getenv("GLASSWORK_HOST_DIR");
    if (override != nullptr) {
        return [@(override) stringByAppendingPathComponent:@"main.js"];
    }
    NSString *bundled = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"ExtensionHost/main.js"];
    if ([NSFileManager.defaultManager fileExistsAtPath:bundled]) {
        return bundled;
    }
#ifdef GLASSWORK_SOURCE_DIR
    return [@GLASSWORK_SOURCE_DIR stringByAppendingPathComponent:@"host/main.js"];
#else
    return bundled;
#endif
}

- (Json)extensionDescriptions {
    Json list = Json::array();
    for (const gw::Extension &extension : GWServices.shared.extensions.extensions()) {
        if (!extension.hasCode || extension.id.rfind("vscode.", 0) == 0) {
            continue;
        }
        Json manifest = Json::parse(extension.manifestJson, nullptr, false);
        if (!manifest.is_object()) {
            continue;
        }
        list.push_back({{"id", extension.id}, {"path", extension.root.string()}, {"manifest", manifest}});
    }
    return list;
}

/// settings.json, with settings that extensions saved through their own API on top.
- (Json)configuration {
    Json merged = Json::object();
    NSArray<NSURL *> *files = @[GWServices.shared.settingsURL,
                                [[self supportFolder] URLByAppendingPathComponent:@"extension-settings.json"]];
    for (NSURL *file in files) {
        std::ifstream input(file.path.UTF8String);
        if (!input) {
            continue;
        }
        std::stringstream text;
        text << input.rdbuf();
        Json parsed = gw::parseJsonc(text.str());
        if (!parsed.is_object()) {
            continue;
        }
        for (const auto &[key, value] : parsed.items()) {
            merged[key] = value;
        }
    }
    return merged;
}

- (Json)allSettings {
    return [self configuration];
}

- (Json)configurationValueForSection:(NSString *)section {
    return gw::settingsSection([self configuration], section.UTF8String);
}

- (Json)languageByExtension {
    Json map = Json::object();
    for (const gw::Extension &extension : GWServices.shared.extensions.extensions()) {
        for (const gw::LanguageInfo &language : extension.languages) {
            for (const std::string &suffix : language.extensions) {
                map[suffix] = language.id;
            }
        }
    }
    return map;
}

/// Starts the host (if it isn't running) and calls `done` once it has been told about the
/// extensions and is ready for work. Callers that arrive while it is starting wait for the same start.
- (void)ensureHost:(void (^)(BOOL ok))done {
    if (_initialized && _host != nullptr && _host->isRunning()) {
        done(YES);
        return;
    }
    [self buildIndexIfNeeded];
    if (_index.empty() || _restarts >= kMostRestarts) {
        done(NO);
        return;
    }
    [_waiting addObject:[done copy]];
    if (_initializing) {
        return;
    }
    _initializing = YES;
    _stopping = NO;

    auto host = std::make_unique<gw::ExtensionHost>();
    gw::ExtensionHost *rawHost = host.get();
    __weak GWExtensionHostService *weakSelf = self;

    // Everything the blocks use is copied first: the arguments are references that are gone by
    // the time the main thread runs the block.
    host->onNotification = [weakSelf, rawHost](const std::string &method, const Json &params) {
        auto sharedMethod = std::make_shared<std::string>(method);
        auto sharedParams = std::make_shared<Json>(params);
        dispatch_async(dispatch_get_main_queue(), ^{
            GWExtensionHostService *strongSelf = weakSelf;
            if (strongSelf != nil && strongSelf->_host.get() == rawHost) {
                [strongSelf handleNotification:*sharedMethod params:*sharedParams];
            }
        });
    };
    host->onRequest = [weakSelf, rawHost](const std::string &method, const Json &params, gw::ExtensionHost::Reply reply) {
        auto sharedMethod = std::make_shared<std::string>(method);
        auto sharedParams = std::make_shared<Json>(params);
        dispatch_async(dispatch_get_main_queue(), ^{
            GWExtensionHostService *strongSelf = weakSelf;
            if (strongSelf == nil || strongSelf->_host.get() != rawHost) {
                reply(Json(), "The extension host was restarted");
                return;
            }
            [strongSelf handleRequest:*sharedMethod params:*sharedParams reply:reply];
        });
    };
    host->onStderr = [weakSelf](std::string_view bytes) {
        NSString *text = [[NSString alloc] initWithBytes:bytes.data() length:bytes.size() encoding:NSUTF8StringEncoding];
        if (text != nil) {
            [weakSelf appendLog:text toChannel:@"Extension Host"];
        }
    };
    host->onExit = [weakSelf, rawHost](int code) {
        dispatch_async(dispatch_get_main_queue(), ^{
            GWExtensionHostService *strongSelf = weakSelf;
            if (strongSelf != nil && strongSelf->_host.get() == rawHost) {
                [strongSelf hostExited:code];
            }
        });
    };

    gw::ExtensionHost::Settings settings;
    // A Node.js shipped inside the app wins over whatever is installed on the Mac.
    NSString *bundledNode = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"node"];
    if ([NSFileManager.defaultManager isExecutableFileAtPath:bundledNode]) {
        settings.nodeProgram = bundledNode.UTF8String;
    }
    settings.hostScript = [self hostScriptPath].UTF8String;
    settings.workingDirectory = (self.rootFolder ?: NSHomeDirectory()).UTF8String;
    std::string error;
    if (!host->start(settings, &error)) {
        _initializing = NO;
        [self finishWaiting:NO];
        [self.delegate hostShowStatusMessage:@(error.c_str()) seconds:8];
        return;
    }
    _host = std::move(host);

    NSURL *storage = [[self supportFolder] URLByAppendingPathComponent:@"extension-state" isDirectory:YES];
    NSString *root = self.rootFolder ?: NSHomeDirectory();
    Json parameters = {
        {"extensions", [self extensionDescriptions]},
        {"workspaceFolders", Json::array({gw::lsp::fileURI(root.UTF8String)})},
        {"configuration", [self configuration]},
        {"storageRoot", storage.path.UTF8String},
        {"appRoot", (NSBundle.mainBundle.resourcePath ?: @"").UTF8String},
        {"languageIds", Json::array()},
        {"languageForPath", [self languageByExtension]},
    };
    _host->request("initialize", parameters, [weakSelf, rawHost](const Json &, const std::string &problem) {
        std::string failure = problem;
        dispatch_async(dispatch_get_main_queue(), ^{
            GWExtensionHostService *strongSelf = weakSelf;
            if (strongSelf == nil || strongSelf->_host.get() != rawHost) {
                return;
            }
            strongSelf->_initializing = NO;
            strongSelf->_initialized = failure.empty();
            [strongSelf finishWaiting:failure.empty()];
            if (failure.empty()) {
                // The host follows every open file once it runs, so files opened before it
                // started (and which nothing else prompted a second look at) join it now.
                [strongSelf.delegate hostProvidersChanged];
            }
        });
    });
}

- (void)finishWaiting:(BOOL)ok {
    NSArray<void (^)(BOOL)> *waiting = [_waiting copy];
    [_waiting removeAllObjects];
    for (void (^done)(BOOL) in waiting) {
        done(ok);
    }
}

- (void)hostExited:(int)code {
    BOOL wasStopping = _stopping;
    _host.reset();
    _initialized = NO;
    _initializing = NO;
    _activatedLanguages.clear();
    _lastEditorState.clear();
    _providerLanguages.clear();
    _providersForAnyLanguage = NO;
    [_registeredCommands removeAllObjects];
    [_statusItemsByID removeAllObjects];
    [self finishWaiting:NO];
    [self.delegate hostStatusItemsChanged];
    if (wasStopping) {
        return;
    }
    ++_restarts;
    [self appendLog:[NSString stringWithFormat:@"The extension host stopped (exit code %d).\n", code] toChannel:@"Extension Host"];
    if (_restarts < kMostRestarts) {
        [self.delegate hostShowStatusMessage:@"The extension host stopped; restarting…" seconds:4];
        [self.delegate hostProvidersChanged];  // open files ask for a new host
    } else {
        [self.delegate hostShowStatusMessage:@"The extension host keeps stopping; extensions are off for this window. See the Extension Host log." seconds:10];
    }
}

- (void)startIfExtensionsWantToRun {
    [self buildIndexIfNeeded];
    BOOL wanted = NO;
    for (const ExtensionIndexEntry &entry : _index) {
        wanted = wanted || entry.runsAtStartup;
    }
    if (!wanted) {
        return;
    }
    __weak GWExtensionHostService *weakSelf = self;
    [self ensureHost:^(BOOL ok) {
        GWExtensionHostService *strongSelf = weakSelf;
        if (!ok || strongSelf == nil || strongSelf->_host == nullptr) {
            return;
        }
        strongSelf->_host->request("host/event", Json{{"name", "onStartupFinished"}}, [](const Json &, const std::string &) {});
    }];
}

- (void)shutdown {
    _stopping = YES;
    if (_host != nullptr) {
        _host->stop();
    }
    _host.reset();
    _initialized = NO;
    _initializing = NO;
    _activatedLanguages.clear();
    [self finishWaiting:NO];
}

- (void)setEditorState:(const Json &)state {
    std::string text = state.dump();
    if (!_initialized || _host == nullptr || text == _lastEditorState) {
        return;
    }
    _lastEditorState = text;
    _host->notify("editor/state", state);
}

- (void)filesDidChange:(NSArray<NSString *> *)paths {
    if (!_initialized || _host == nullptr) {
        return;
    }
    Json events = Json::array();
    NSFileManager *files = NSFileManager.defaultManager;
    for (NSString *path in paths) {
        if ([path containsString:@"/.git/"] || events.size() >= 5000) {
            continue;
        }
        int type = [files fileExistsAtPath:path] ? 2 : 3;
        events.push_back({{"uri", gw::lsp::fileURI(path.UTF8String)}, {"type", type}});
    }
    if (!events.empty()) {
        _host->notify("workspace/fileEvents", Json{{"events", events}});
    }
}

- (void)settingsDidChange {
    if (_initialized && _host != nullptr) {
        _host->notify("workspace/didChangeConfiguration", Json{{"configuration", [self configuration]}});
    }
}

// ---------------------------------------------------------------------------
// MARK: Language features

- (BOOL)extensionsMayServeLanguage:(NSString *)languageId {
    [self buildIndexIfNeeded];
    std::string language = languageId.UTF8String;
    // Once the host is running it follows every open file, so `window.activeTextEditor` and the
    // document events work for any language, not only ones with providers.
    if (_initialized || _providersForAnyLanguage || _providerLanguages.count(language) > 0) {
        return YES;
    }
    for (const ExtensionIndexEntry &entry : _index) {
        if (entry.languages.count(language) > 0 || entry.activationEvents.count("onLanguage:" + language) > 0) {
            return YES;
        }
    }
    return NO;
}

- (void)prepareLanguage:(NSString *)languageId completion:(void (^)(BOOL))done {
    std::string language = languageId.UTF8String;
    __weak GWExtensionHostService *weakSelf = self;
    [self ensureHost:^(BOOL ok) {
        GWExtensionHostService *strongSelf = weakSelf;
        if (!ok || strongSelf == nil || strongSelf->_host == nullptr) {
            done(NO);
            return;
        }
        if (strongSelf->_activatedLanguages.count(language) > 0) {
            done(YES);
            return;
        }
        gw::ExtensionHost *rawHost = strongSelf->_host.get();
        // Runs the extensions that wait for this language and answers once they have registered.
        strongSelf->_host->request("host/event", Json{{"name", "onLanguage:" + language}},
                                   [weakSelf, rawHost, language, done](const Json &, const std::string &) {
            dispatch_async(dispatch_get_main_queue(), ^{
                GWExtensionHostService *inner = weakSelf;
                if (inner == nil || inner->_host.get() != rawHost) {
                    done(NO);
                    return;
                }
                inner->_activatedLanguages.insert(language);
                done(YES);
            });
        });
    }];
}

- (std::unique_ptr<gw::lsp::ServerTransport>)newTransportForLanguage:(NSString *)languageId rootURI:(NSString *)rootURI {
    if (!_initialized || _host == nullptr || !_host->isRunning()) {
        // Bring the host back; files are attached again when it is up.
        __weak GWExtensionHostService *weakSelf = self;
        [self ensureHost:^(BOOL ok) {
            if (ok) {
                [weakSelf.delegate hostProvidersChanged];
            }
        }];
        return nullptr;
    }
    return _host->makeServerTransport(languageId.UTF8String, rootURI.UTF8String);
}

// ---------------------------------------------------------------------------
// MARK: Commands

- (NSArray<GWPaletteItem *> *)commandItemsForQuery:(NSString *)query {
    [self buildIndexIfNeeded];
    std::string wanted = query.UTF8String;
    std::map<std::string, std::string> titles;
    for (const ContributedCommand &command : _contributedCommands) {
        if (!command.hiddenFromPalette) {
            titles[command.identifier] = command.title;
        }
    }
    for (NSString *identifier in _registeredCommands) {
        NSString *title = _registeredCommands[identifier];
        if (title.length > 0 && titles.count(identifier.UTF8String) == 0) {
            titles[identifier.UTF8String] = title.UTF8String;
        }
    }

    NSMutableArray<GWPaletteItem *> *items = [NSMutableArray array];
    __weak GWExtensionHostService *weakSelf = self;
    for (const auto &[identifier, title] : titles) {
        std::optional<gw::FuzzyMatch> match = gw::fuzzyMatch(wanted, title);
        if (!match) {
            continue;
        }
        GWPaletteItem *item = [GWPaletteItem new];
        item.title = @(title.c_str());
        item.subtitle = @"Extension";
        item.symbol = @"puzzlepiece.extension";
        item.symbolColor = NSColor.systemPurpleColor;
        NSMutableIndexSet *indexes = [NSMutableIndexSet indexSet];
        for (uint32_t position : match->positions) {
            [indexes addIndex:position];
        }
        item.matchedIndexes = indexes;
        NSString *commandIdentifier = @(identifier.c_str());
        item.run = ^{
            [weakSelf executeCommand:commandIdentifier arguments:nil];
        };
        [items addObject:item];
    }
    return items;
}

- (void)executeCommand:(NSString *)identifier arguments:(NSArray *)arguments {
    __weak GWExtensionHostService *weakSelf = self;
    [self ensureHost:^(BOOL ok) {
        GWExtensionHostService *strongSelf = weakSelf;
        if (!ok || strongSelf == nil || strongSelf->_host == nullptr) {
            [weakSelf.delegate hostShowStatusMessage:@"Extensions aren't running." seconds:4];
            return;
        }
        Json parameters = {{"id", identifier.UTF8String}, {"args", arguments ? JsonFromFoundation(arguments) : Json::array()}};
        strongSelf->_host->request("commands/execute", parameters, [weakSelf, identifier](const Json &, const std::string &problem) {
            if (problem.empty()) {
                return;
            }
            std::string failure = problem;
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf.delegate hostShowStatusMessage:[NSString stringWithFormat:@"%@ failed: %s", identifier, failure.c_str()] seconds:8];
            });
        });
    }];
}

// ---------------------------------------------------------------------------
// MARK: Status

- (NSArray<GWExtensionStatusItem *> *)statusItems {
    NSArray<GWExtensionStatusItem *> *all = _statusItemsByID.allValues;
    return [all sortedArrayUsingComparator:^NSComparisonResult(GWExtensionStatusItem *a, GWExtensionStatusItem *b) {
        if (a.priority != b.priority) {
            return a.priority > b.priority ? NSOrderedAscending : NSOrderedDescending;
        }
        return [a.identifier compare:b.identifier];
    }];
}

- (NSString *)summary {
    NSUInteger running = 0;
    for (NSString *state in _extensionStates.allValues) {
        if ([state isEqualToString:@"active"]) {
            ++running;
        }
    }
    return running == 0 ? @"" : [NSString stringWithFormat:@"%lu extension%@ running", (unsigned long)running, running == 1 ? @"" : @"s"];
}

// ---------------------------------------------------------------------------
// MARK: Logs

- (NSURL *)logFolder {
    NSURL *folder = [[self supportFolder] URLByAppendingPathComponent:@"extension-logs" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
    return folder;
}

- (NSURL *)logURLForChannel:(NSString *)channel {
    NSMutableCharacterSet *allowed = [NSMutableCharacterSet alphanumericCharacterSet];
    [allowed addCharactersInString:@" -_."];
    NSString *safe = [[channel componentsSeparatedByCharactersInSet:allowed.invertedSet] componentsJoinedByString:@"_"];
    return [[self logFolder] URLByAppendingPathComponent:[safe stringByAppendingString:@".log"]];
}

- (NSArray<NSString *> *)logChannels {
    return [_knownChannels.allObjects sortedArrayUsingSelector:@selector(compare:)];
}

/// Output channels are plain text files, so they can be opened, searched and followed like any other file.
- (void)appendLog:(NSString *)text toChannel:(NSString *)channel {
    [_knownChannels addObject:channel];
    BOOL firstWrite = ![_openedChannels containsObject:channel];
    if (firstWrite) {
        [_openedChannels addObject:channel];
    }
    NSURL *url = [self logURLForChannel:channel];
    dispatch_async(_logQueue, ^{
        NSFileManager *files = NSFileManager.defaultManager;
        if (firstWrite || ![files fileExistsAtPath:url.path]) {
            [@"" writeToURL:url atomically:NO encoding:NSUTF8StringEncoding error:nil];  // each session starts fresh
        }
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingToURL:url error:nil];
        [handle seekToEndOfFile];
        [handle writeData:[text dataUsingEncoding:NSUTF8StringEncoding]];
        [handle closeFile];
    });
}

// ---------------------------------------------------------------------------
// MARK: Messages from the host

- (void)handleNotification:(const std::string &)method params:(const Json &)params {
    if (method == "ui/log") {
        [self appendLog:StringFromJson(params["text"]) ?: @"" toChannel:StringFromJson(params["channel"]) ?: @"Extension Host"];
    } else if (method == "ui/logClear") {
        NSString *channel = StringFromJson(params["channel"]) ?: @"Extension Host";
        [@"" writeToURL:[self logURLForChannel:channel] atomically:NO encoding:NSUTF8StringEncoding error:nil];
    } else if (method == "ui/logShow") {
        NSString *channel = StringFromJson(params["channel"]) ?: @"Extension Host";
        [self.delegate hostOpenFileAtPath:[self logURLForChannel:channel].path line:-1 character:0];
    } else if (method == "ui/statusBar") {
        NSString *identifier = StringFromJson(params["id"]);
        if (identifier == nil) {
            return;
        }
        if (!params.value("visible", false)) {
            [_statusItemsByID removeObjectForKey:identifier];
        } else {
            GWExtensionStatusItem *item = _statusItemsByID[identifier] ?: [GWExtensionStatusItem new];
            item.identifier = identifier;
            item.text = WithoutIconMarkup(StringFromJson(params["text"]) ?: @"");
            item.tooltip = StringFromJson(params["tooltip"]);
            item.command = StringFromJson(params["command"]);
            item.alignment = params.value("alignment", 1);
            item.priority = params.value("priority", 0.0);
            _statusItemsByID[identifier] = item;
        }
        [self.delegate hostStatusItemsChanged];
    } else if (method == "ui/statusMessage") {
        NSString *text = StringFromJson(params["text"]) ?: @"";
        [self.delegate hostShowStatusMessage:WithoutIconMarkup(text) seconds:params.value("timeout", 0) / 1000.0];
    } else if (method == "commands/registered") {
        NSString *identifier = StringFromJson(params["id"]);
        if (identifier != nil) {
            _registeredCommands[identifier] = StringFromJson(params["title"]) ?: @"";
        }
    } else if (method == "commands/unregistered") {
        NSString *identifier = StringFromJson(params["id"]);
        if (identifier != nil) {
            [_registeredCommands removeObjectForKey:identifier];
        }
    } else if (method == "host/extensionState") {
        NSString *identifier = StringFromJson(params["id"]);
        NSString *state = StringFromJson(params["state"]);
        if (identifier != nil && state != nil) {
            _extensionStates[identifier] = state;
        }
        if ([state isEqualToString:@"failed"]) {
            [self.delegate hostShowStatusMessage:[NSString stringWithFormat:@"%@ couldn't start. See the Extension Host log.", identifier] seconds:8];
        }
    } else if (method == "commands/setContext") {
        NSString *key = StringFromJson(params["key"]);
        const Json &value = params.contains("value") ? params["value"] : Json();
        NSString *text = value.is_string() ? StringFromJson(value) : @(value.is_null() ? "" : value.dump().c_str());
        if (key != nil) {
            [self.delegate hostSetContextKey:key value:text];
        }
    } else if (method == "editor/setSelections") {
        [self.delegate hostSetSelections:params.value("selections", Json::array())
                                 forPath:@(PathFromURI(params.value("uri", "")).c_str())];
    } else if (method == "editor/reveal") {
        [self.delegate hostRevealRange:params.value("range", Json::object())
                               forPath:@(PathFromURI(params.value("uri", "")).c_str())];
    } else if (method == "editor/decorations") {
        [self.delegate hostSetDecorationsForPath:@(PathFromURI(params.value("uri", "")).c_str())
                                             key:StringFromJson(params["key"]) ?: @""
                                         options:params.value("options", Json::object())
                                          ranges:params.value("ranges", Json::array())];
    } else if (method == "providers/changed") {
        _providerLanguages.clear();
        for (const Json &language : params.value("languages", Json::array())) {
            if (language.is_string()) {
                _providerLanguages.insert(language.get<std::string>());
            }
        }
        _providersForAnyLanguage = params.value("any", false);
        [self.delegate hostProvidersChanged];
    }
}

- (void)handleRequest:(const std::string &)method params:(const Json &)params reply:(gw::ExtensionHost::Reply)reply {
    if (method == "ui/showMessage") {
        [self showMessage:params reply:reply];
    } else if (method == "ui/quickPick") {
        [self showQuickPick:params reply:reply];
    } else if (method == "ui/inputBox") {
        [self showInputBox:params reply:reply];
    } else if (method == "workspace/applyEdit") {
        BOOL applied = [self.delegate hostApplyWorkspaceEdit:params.value("edit", Json::object())];
        reply(Json{{"applied", applied == YES}}, "");
    } else if (method == "workspace/saveDocument") {
        BOOL saved = [self.delegate hostSaveFileAtPath:@(PathFromURI(params.value("uri", "")).c_str())];
        reply(Json(saved == YES), "");
    } else if (method == "workspace/saveAll") {
        [self.delegate hostSaveAll];
        reply(Json(true), "");
    } else if (method == "workspace/updateConfiguration") {
        [self storeSetting:params];
        reply(Json(), "");
    } else if (method == "editor/insertSnippet") {
        BOOL inserted = [self.delegate hostInsertSnippet:StringFromJson(params["snippet"]) ?: @""
                                                atRanges:params.value("ranges", Json::array())
                                                 forPath:@(PathFromURI(params.value("uri", "")).c_str())];
        reply(Json(inserted == YES), "");
    } else if (method == "ui/openDocument") {
        std::string path = PathFromURI(params.value("uri", ""));
        NSInteger line = params.contains("line") && params["line"].is_number() ? params["line"].get<NSInteger>() : -1;
        NSInteger character = params.contains("character") && params["character"].is_number() ? params["character"].get<NSInteger>() : 0;
        [self.delegate hostOpenFileAtPath:@(path.c_str()) line:line character:character];
        reply(Json(), "");
    } else if (method == "env/openExternal") {
        NSURL *url = [NSURL URLWithString:StringFromJson(params["uri"]) ?: @""];
        BOOL opened = url != nil && [NSWorkspace.sharedWorkspace openURL:url];
        reply(Json(opened == YES), "");
    } else if (method == "env/clipboardRead") {
        NSString *text = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
        reply(Json(std::string(text.UTF8String ?: "")), "");
    } else if (method == "env/clipboardWrite") {
        [NSPasteboard.generalPasteboard clearContents];
        [NSPasteboard.generalPasteboard setString:StringFromJson(params["text"]) ?: @"" forType:NSPasteboardTypeString];
        reply(Json(), "");
    } else if (method == "commands/executeBuiltin") {
        NSArray *arguments = FoundationFromJson(params.value("args", Json::array()));
        BOOL handled = [self.delegate hostRunBuiltinCommand:StringFromJson(params["id"]) ?: @"" arguments:arguments ?: @[]];
        reply(Json(), handled ? "" : "Unknown command");
    } else {
        reply(Json(), "Not supported: " + method);
    }
}

/// Saves a setting an extension changed (`config.update`) next to settings.json instead of
/// editing the user's file, which would lose its comments.
- (void)storeSetting:(const Json &)params {
    NSURL *file = [[self supportFolder] URLByAppendingPathComponent:@"extension-settings.json"];
    Json settings = Json::object();
    std::ifstream input(file.path.UTF8String);
    if (input) {
        std::stringstream text;
        text << input.rdbuf();
        Json parsed = gw::parseJsonc(text.str());
        if (parsed.is_object()) {
            settings = parsed;
        }
    }
    std::string key = params.value("key", "");
    if (params.contains("value") && !params["value"].is_null()) {
        settings[key] = params["value"];
    } else {
        settings.erase(key);
    }
    std::ofstream output(file.path.UTF8String);
    output << settings.dump(2) << "\n";
    output.close();
    [self settingsDidChange];
}

// ---------------------------------------------------------------------------
// MARK: Messages, pickers and prompts

- (void)showMessage:(const Json &)params reply:(gw::ExtensionHost::Reply)reply {
    std::string severity = params.value("severity", "info");
    NSString *message = StringFromJson(params["message"]) ?: @"";
    NSMutableArray<NSString *> *items = [NSMutableArray array];
    for (const Json &item : params.value("items", Json::array())) {
        if (item.is_string()) {
            [items addObject:@(item.get<std::string>().c_str())];
        }
    }
    BOOL modal = params.value("modal", false);

    // A plain notice with nothing to choose from goes to the status bar instead of in the way.
    if (items.count == 0 && !modal && severity == "info") {
        [self.delegate hostShowStatusMessage:message seconds:6];
        reply(Json(), "");
        return;
    }

    NSAlert *alert = [NSAlert new];
    alert.messageText = message;
    if (params.contains("detail") && params["detail"].is_string()) {
        alert.informativeText = StringFromJson(params["detail"]);
    }
    alert.alertStyle = severity == "error" ? NSAlertStyleCritical : (severity == "warning" ? NSAlertStyleWarning : NSAlertStyleInformational);
    for (NSString *title in items) {
        [alert addButtonWithTitle:title];
    }
    [alert addButtonWithTitle:items.count > 0 ? @"Dismiss" : @"OK"];

    void (^finish)(NSModalResponse) = ^(NSModalResponse response) {
        NSInteger index = response - NSAlertFirstButtonReturn;
        if (index >= 0 && index < static_cast<NSInteger>(items.count)) {
            reply(Json(std::string(items[static_cast<NSUInteger>(index)].UTF8String)), "");
        } else {
            reply(Json(), "");
        }
    };
    NSWindow *window = self.delegate.hostWindow;
    if (window != nil) {
        [alert beginSheetModalForWindow:window completionHandler:finish];
    } else {
        finish([alert runModal]);
    }
}

- (void)showQuickPick:(const Json &)params reply:(gw::ExtensionHost::Reply)reply {
    NSMutableArray<GWPaletteItem *> *items = [NSMutableArray array];
    __block BOOL answered = NO;
    for (const Json &entry : params.value("items", Json::array())) {
        if (entry.value("kind", 0) == -1) {
            continue;  // a separator
        }
        GWPaletteItem *item = [GWPaletteItem new];
        item.title = StringFromJson(entry["label"]) ?: @"";
        NSString *description = StringFromJson(entry["description"]);
        NSString *detail = StringFromJson(entry["detail"]);
        item.subtitle = description.length > 0 ? description : detail;
        item.symbol = @"circle.fill";
        item.symbolColor = NSColor.tertiaryLabelColor;
        int index = entry.value("index", 0);
        item.run = ^{
            answered = YES;
            reply(Json(index), "");
        };
        [items addObject:item];
    }
    NSString *placeholder = StringFromJson(params["placeHolder"]) ?: StringFromJson(params["title"]) ?: @"Select an item…";
    NSWindow *window = self.delegate.hostWindow;
    if (window == nil || items.count == 0) {
        reply(Json(), "");
        return;
    }
    [GWPalette.shared showOverWindow:window placeholder:placeholder
                            provider:^NSArray<GWPaletteItem *> *(NSString *query) {
        std::string wanted = query.UTF8String;
        if (wanted.empty()) {
            return items;
        }
        NSMutableArray<GWPaletteItem *> *matching = [NSMutableArray array];
        for (GWPaletteItem *item in items) {
            if (gw::fuzzyScore(wanted, item.title.UTF8String)) {
                [matching addObject:item];
            }
        }
        return matching;
    } onDismiss:^{
        if (!answered) {
            answered = YES;
            reply(Json(), "");
        }
    }];
}

- (void)showInputBox:(const Json &)params reply:(gw::ExtensionHost::Reply)reply {
    NSAlert *alert = [NSAlert new];
    alert.messageText = StringFromJson(params["prompt"]) ?: StringFromJson(params["title"]) ?: @"Enter a value";
    [alert addButtonWithTitle:@"OK"];
    [alert addButtonWithTitle:@"Cancel"];
    BOOL password = params.value("password", false);
    NSTextField *field = password ? [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 320, 24)]
                                  : [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 320, 24)];
    field.stringValue = StringFromJson(params["value"]) ?: @"";
    field.placeholderString = StringFromJson(params["placeHolder"]);
    alert.accessoryView = field;
    alert.window.initialFirstResponder = field;

    void (^finish)(NSModalResponse) = ^(NSModalResponse response) {
        if (response == NSAlertFirstButtonReturn) {
            reply(Json(std::string(field.stringValue.UTF8String ?: "")), "");
        } else {
            reply(Json(), "");
        }
    };
    NSWindow *window = self.delegate.hostWindow;
    if (window != nil) {
        [alert beginSheetModalForWindow:window completionHandler:finish];
    } else {
        finish([alert runModal]);
    }
}

@end
