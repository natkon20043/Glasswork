#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// SF Symbol and tint by file name/extension, so sidebar, tabs and status bar agree.
NSString *GWSymbolForFile(NSString *filename);
NSColor *GWColorForFile(NSString *filename);

/// From the chosen file icon theme, else the tinted built-in symbol. Never nil. `size` is height in points.
NSImage *GWFileIconImage(NSString *filename, BOOL directory, BOOL expanded, CGFloat size);

/// Symbol image for attributed strings (status bar, breadcrumbs).
NSAttributedString *GWSymbolString(NSString *symbol, NSColor *color, CGFloat pointSize);

NS_ASSUME_NONNULL_END
