#import "GitRepository.h"

#include <unordered_map>

NSNotificationName const GWGitStatusDidChangeNotification = @"GWGitStatusDidChangeNotification";

namespace {

/// A short text that changes whenever anything the interface shows about the repository
/// changes, so we can tell "same as before" without comparing every field by hand.
std::string signatureOf(const gw::git::Status &status, const std::vector<gw::git::LogEntry> &log) {
    std::string signature;
    signature += status.isRepository ? "R" : "-";
    signature += "|" + status.root + "|" + status.branch + "|" + status.headCommit + "|" + status.upstream;
    signature += "|" + std::to_string(status.ahead) + "|" + std::to_string(status.behind);
    signature += status.hasRemote ? "|remote" : "|local";
    signature += "|" + status.error;
    for (const gw::git::FileChange &change : status.changes) {
        signature += "\n" + change.path + "\t" + std::to_string(static_cast<int>(change.staged)) + "\t" +
                     std::to_string(static_cast<int>(change.unstaged));
    }
    signature += "\n#" + std::to_string(log.size());
    if (!log.empty()) {
        signature += log.front().hash;
    }
    return signature;
}

}  // namespace

@implementation GWGitRepository {
    dispatch_queue_t _queue;
    NSString *_folder;
    NSString *_root;
    gw::git::Status _status;
    gw::git::GitHubState _github;
    std::vector<gw::git::LogEntry> _log;
    std::string _signature;

    // Bumped when a different folder is opened, so late results from the old one are ignored.
    NSUInteger _generation;
    BOOL _refreshRunning;
    BOOL _refreshQueued;
    NSInteger _busyCount;
    NSString *_busyTitle;

    std::unordered_map<std::string, std::shared_ptr<const std::string>> _headCache;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
        _queue = dispatch_queue_create("Glasswork.git", attributes);
    }
    return self;
}

- (NSString *)folder { return _folder; }
- (NSString *)root { return _root; }
- (BOOL)isRepository { return _status.isRepository; }
- (BOOL)isBusy { return _busyCount > 0; }
- (NSString *)busyTitle { return _busyTitle; }
- (const gw::git::Status &)status { return _status; }
- (const gw::git::GitHubState &)github { return _github; }
- (const std::vector<gw::git::LogEntry> &)log { return _log; }

- (void)postChange {
    [NSNotificationCenter.defaultCenter postNotificationName:GWGitStatusDidChangeNotification object:self];
}

// MARK: Opening

- (void)openFolder:(NSString *)folder {
    ++_generation;
    _folder = [folder copy];
    _root = nil;
    _status = gw::git::Status();
    _log.clear();
    _signature.clear();
    _headCache.clear();
    _refreshRunning = NO;
    _refreshQueued = NO;
    [self postChange];
    if (folder == nil) {
        return;
    }
    [self refresh];
    [self refreshGitHubState];
}

- (void)refreshGitHubState {
    NSUInteger generation = _generation;
    dispatch_async(_queue, ^{
        gw::git::GitHubState state = gw::git::readGitHubState();
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self->_generation) {
                return;
            }
            self->_github = state;
            [self postChange];
        });
    });
}

// MARK: Refreshing

- (void)refresh {
    if (_folder == nil) {
        return;
    }
    if (_refreshRunning) {
        _refreshQueued = YES;
        return;
    }
    _refreshRunning = YES;
    NSUInteger generation = _generation;
    std::string folder = _folder.UTF8String;

    dispatch_async(_queue, ^{
        gw::git::Status status = gw::git::readStatus(folder);
        std::vector<gw::git::LogEntry> log;
        if (status.isRepository && status.hasCommits()) {
            log = gw::git::readLog(status.root, 30);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self->_generation) {
                return;
            }
            [self finishRefreshWithStatus:std::move(status) log:std::move(log)];
        });
    });
}

- (void)finishRefreshWithStatus:(gw::git::Status)status log:(std::vector<gw::git::LogEntry>)log {
    _refreshRunning = NO;

    // Content at HEAD is only valid for one commit.
    if (status.headCommit != _status.headCommit) {
        _headCache.clear();
    }
    std::string signature = signatureOf(status, log);
    bool changed = signature != _signature;

    _signature = std::move(signature);
    _status = std::move(status);
    _log = std::move(log);
    _root = _status.isRepository ? @(_status.root.c_str()) : nil;

    if (changed) {
        [self postChange];
    }
    if (_refreshQueued) {
        _refreshQueued = NO;
        [self refresh];
    }
}

// MARK: Changing things

- (void)perform:(NSString *)title
      operation:(gw::git::CommandResult (^)(NSString *))operation
     completion:(void (^)(gw::git::CommandResult))completion {
    NSString *root = _root ?: _folder;
    if (root == nil) {
        if (completion) {
            gw::git::CommandResult none;
            none.error = "No folder is open.";
            completion(none);
        }
        return;
    }
    ++_busyCount;
    _busyTitle = [title copy];
    [self postChange];

    dispatch_async(_queue, ^{
        gw::git::CommandResult result = operation(root);
        dispatch_async(dispatch_get_main_queue(), ^{
            --self->_busyCount;
            if (self->_busyCount == 0) {
                self->_busyTitle = nil;
            }
            [self postChange];
            if (completion) {
                completion(result);
            }
            [self refresh];
        });
    });
}

- (void)read:(id (^)(NSString *))work completion:(void (^)(id))completion {
    NSString *root = _root ?: _folder;
    NSUInteger generation = _generation;
    dispatch_async(_queue, ^{
        id result = root ? work(root) : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self->_generation) {
                return;
            }
            completion(result);
        });
    });
}

// MARK: HEAD content

- (NSString *)relativePathForAbsolute:(NSString *)path {
    if (_root == nil) {
        return nil;
    }
    NSString *prefix = [_root stringByAppendingString:@"/"];
    if ([path hasPrefix:prefix]) {
        return [path substringFromIndex:prefix.length];
    }
    // The path may go through a symbolic link (/tmp, /var…); compare real locations.
    NSString *resolved = [path stringByResolvingSymlinksInPath];
    if ([resolved hasPrefix:prefix]) {
        return [resolved substringFromIndex:prefix.length];
    }
    return nil;
}

- (NSString *)absolutePathForRelative:(NSString *)path {
    return _root ? [_root stringByAppendingPathComponent:path] : nil;
}

- (void)headTextForPath:(NSString *)absolutePath completion:(void (^)(std::shared_ptr<const std::string>))completion {
    NSString *relative = [self relativePathForAbsolute:absolutePath];
    if (relative == nil || !_status.hasCommits()) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nullptr);
        });
        return;
    }

    std::string key = relative.UTF8String;
    auto cached = _headCache.find(key);
    if (cached != _headCache.end()) {
        std::shared_ptr<const std::string> text = cached->second;
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(text);
        });
        return;
    }

    NSUInteger generation = _generation;
    std::string commit = _status.headCommit;
    std::string root = _root.UTF8String;
    dispatch_async(_queue, ^{
        std::optional<std::string> content = gw::git::readHeadFile(root, key);
        std::shared_ptr<const std::string> text;
        if (content) {
            text = std::make_shared<const std::string>(std::move(*content));
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation == self->_generation && self->_status.headCommit == commit) {
                self->_headCache[key] = text;
            }
            completion(text);
        });
    });
}

@end
