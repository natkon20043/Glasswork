#pragma once

#import <AppKit/AppKit.h>

#include "ClaudeProtocol.hpp"

NS_ASSUME_NONNULL_BEGIN

// User's answer on a permission prompt -> what Claude is told (AllowAllEdits also switches to "accept edits").
typedef NS_ENUM(NSInteger, GWPermissionChoice) {
    GWPermissionChoiceDeny,
    GWPermissionChoiceAllow,
    GWPermissionChoiceAllowAllEdits,
};

/// What the user typed, in a rounded bubble on the right.
@interface GWChatUserView : NSView
- (void)setText:(NSString *)text;
@end

/// Quiet line between messages: errors, "session ended".
@interface GWChatNoticeView : NSView
- (void)setText:(NSString *)text isError:(BOOL)isError;
@end

/// One Claude reply: text, thinking and tools used, in order.
@interface GWChatAssistantView : NSView

// ---- Updating
/// Cheap to call as the message grows.
- (void)updateWithMessage:(const gw::claude::Message &)message turnIsRunning:(BOOL)running;

// ---- Properties
@property (nonatomic, copy, nullable) NSString *projectRoot;

// ---- Callbacks
@property (nonatomic, copy, nullable) void (^onOpenPath)(NSString *path, NSInteger line);
@property (nonatomic, copy, nullable) void (^onInsertCode)(NSString *code);
/// `message` is what Claude is told on a denial.
@property (nonatomic, copy, nullable) void (^onPermission)(NSString *requestId, GWPermissionChoice choice, NSString *_Nullable message);

@end

/// "Claude is working..." with the current tool, shown while a turn runs.
@interface GWChatWorkingView : NSView
- (void)setText:(NSString *)text;
- (void)startAnimating;
- (void)stopAnimating;
@end

NS_ASSUME_NONNULL_END
