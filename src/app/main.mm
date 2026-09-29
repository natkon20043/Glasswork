#import <AppKit/AppKit.h>

#import "AppDelegate.h"
#import "StartupTiming.h"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        GWStartupMark(@"main() entered");
        NSApplication *application = NSApplication.sharedApplication;
        GWAppDelegate *delegate = [GWAppDelegate new];
        application.delegate = delegate;
        application.activationPolicy = NSApplicationActivationPolicyRegular;
        [application run];
    }
    return 0;
}
