#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// SF Symbol and tint for a file, by name and extension, so the sidebar, tabs and status bar
/// all show a file the same way.
NSString *GWSymbolForFile(NSString *filename);
NSColor *GWColorForFile(NSString *filename);

/// The image for a file or folder: from the file icon theme when one is chosen, else the built-in
/// symbol tinted for its type. Always returns something. `size` is the image's height in points.
NSImage *GWFileIconImage(NSString *filename, BOOL directory, BOOL expanded, CGFloat size);

/// A symbol image for inline use in attributed strings (status bar, breadcrumbs).
NSAttributedString *GWSymbolString(NSString *symbol, NSColor *color, CGFloat pointSize);

NS_ASSUME_NONNULL_END
