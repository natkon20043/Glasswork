#pragma once

#import <AppKit/AppKit.h>

#include "ClaudeProtocol.hpp"

NS_ASSUME_NONNULL_BEGIN

/// What the user chose for a tool that asked permission.
typedef NS_ENUM(NSInteger, GWPermissionChoice) {
    GWPermissionChoiceDeny,
    GWPermissionChoiceAllow,
    /// Allow this and switch to "accept edits" so file changes stop asking.
    GWPermissionChoiceAllowAllEdits,
};

/// What the user typed, in a rounded bubble on the right.
@interface GWChatUserView : NSView
- (void)setText:(NSString *)text;
@end

/// A quiet line between messages: errors, "session ended", and so on.
@interface GWChatNoticeView : NSView
- (void)setText:(NSString *)text isError:(BOOL)isError;
@end

/// One reply from Claude: text, thinking, and the tools it used, in order.
@interface GWChatAssistantView : NSView

@property (nonatomic, copy, nullable) NSString *projectRoot;
@property (nonatomic, copy, nullable) void (^onOpenPath)(NSString *path, NSInteger line);
@property (nonatomic, copy, nullable) void (^onInsertCode)(NSString *code);
/// The user answered a permission question. `message` is what Claude is told on a denial.
@property (nonatomic, copy, nullable) void (^onPermission)(NSString *requestId, GWPermissionChoice choice, NSString *_Nullable message);

/// Shows the message's current content. Cheap to call as it grows.
- (void)updateWithMessage:(const gw::claude::Message &)message turnIsRunning:(BOOL)running;

@end

/// "Claude is working…" with the tool it is on, shown while a turn runs.
@interface GWChatWorkingView : NSView
- (void)setText:(NSString *)text;
- (void)startAnimating;
- (void)stopAnimating;
@end

NS_ASSUME_NONNULL_END
