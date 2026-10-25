#import "RemoteSupport.h"
#import "Strings.h"

#include "RemoteHost.hpp"
#include "Tasks.hpp"

@implementation GWRemoteItem
@end

NSURL *GWRemoteURL(NSString *destination, NSString *path) {
    NSURLComponents *components = [NSURLComponents new];
    components.scheme = @"ssh";
    NSRange at = [destination rangeOfString:@"@"];
    if (at.location != NSNotFound) {
        components.user = [destination substringToIndex:at.location];
        components.host = [destination substringFromIndex:at.location + 1];
    } else {
        components.host = destination;
    }
    components.path = path;
    return components.URL;
}

BOOL GWIsRemoteURL(NSURL *url) {
    return url != nil && [url.scheme isEqualToString:@"ssh"];
}

NSString *GWRemoteDestination(NSURL *url) {
    if (url.user.length > 0) {
        return [NSString stringWithFormat:@"%@@%@", url.user, url.host];
    }
    return url.host ?: @"";
}

NSString *GWLocalCopyPathForRemoteURL(NSURL *url) {
    NSURL *caches = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    NSString *base = [caches.path stringByAppendingPathComponent:@"Glasswork/Remote"];
    NSString *machine = [base stringByAppendingPathComponent:GWRemoteDestination(url)];
    return [machine stringByAppendingPathComponent:url.path];
}

static gw::RemoteHost HostFor(NSURL *url) {
    return gw::RemoteHost(GWRemoteDestination(url).UTF8String);
}

NSArray<GWRemoteItem *> *GWListRemoteFolder(NSURL *folder, NSString **error) {
    gw::RemoteHost host = HostFor(folder);
    std::vector<gw::RemoteEntry> entries;
    std::string message;
    if (!host.listDirectory(folder.path.UTF8String, &entries, &message)) {
        if (error) {
            *error = StringFromUTF8(message);
        }
        return nil;
    }
    NSMutableArray<GWRemoteItem *> *items = [NSMutableArray array];
    for (const gw::RemoteEntry &entry : entries) {
        NSString *name = StringFromUTF8(entry.name);
        GWRemoteItem *item = [GWRemoteItem new];
        item.url = [folder URLByAppendingPathComponent:name isDirectory:entry.isDirectory];
        item.isDirectory = entry.isDirectory;
        [items addObject:item];
    }
    return items;
}

NSData *GWReadRemoteFile(NSURL *file, NSString **error) {
    gw::RemoteHost host = HostFor(file);
    std::string contents;
    std::string message;
    if (!host.readFile(file.path.UTF8String, &contents, &message)) {
        if (error) {
            *error = StringFromUTF8(message);
        }
        return nil;
    }
    return [NSData dataWithBytes:contents.data() length:contents.size()];
}

BOOL GWWriteRemoteFile(NSURL *file, NSData *contents, NSString **error) {
    gw::RemoteHost host = HostFor(file);
    std::string text;
    if (contents.length > 0) {
        text.assign(static_cast<const char *>(contents.bytes), contents.length);
    }
    std::string message;
    if (!host.writeFile(file.path.UTF8String, text, &message)) {
        if (error) {
            *error = StringFromUTF8(message);
        }
        return NO;
    }
    return YES;
}

NSString *GWResolveRemotePath(NSString *destination, NSString *path, NSString **error) {
    gw::RemoteHost host(destination.UTF8String);
    std::string message;
    std::optional<std::string> resolved = host.resolvePath(path.UTF8String, &message);
    if (!resolved) {
        if (error) {
            *error = StringFromUTF8(message);
        }
        return nil;
    }
    return StringFromUTF8(*resolved);
}

NSString *GWRemoteShellCommand(NSURL *folder) {
    gw::RemoteHost host = HostFor(folder);
    std::vector<std::string> arguments = host.shellCommand(folder.path.UTF8String);
    // The terminal runs this line through a shell, so each word is quoted.
    NSMutableArray<NSString *> *words = [NSMutableArray array];
    for (const std::string &argument : arguments) {
        [words addObject:StringFromUTF8(gw::shellQuote(argument))];
    }
    return [words componentsJoinedByString:@" "];
}
