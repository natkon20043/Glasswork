// Measures how quickly an app starts, the same way for any editor:
//
//   launch_bench <App.app> <file-to-open> <window-owner-name> [runs]
//
// For each run it makes sure the app is not running, opens the file with it, and reports:
//   window  – ms until a window of the app is on screen
//   idle    – ms until the app has stopped using the CPU (it has finished starting up)
//   memory  – resident memory once idle
// The app is quit after each run.

#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#include <libproc.h>
#include <mach/mach_time.h>

static double nowMs(void) {
    static mach_timebase_info_data_t info;
    if (info.denom == 0) mach_timebase_info(&info);
    return (double)mach_absolute_time() * info.numer / info.denom / 1e6;
}

static NSRunningApplication *findApp(NSString *bundleId) {
    NSArray *apps = [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleId];
    return apps.firstObject;
}

static BOOL hasWindow(NSString *owner, pid_t pid) {
    NSArray *list = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID));
    for (NSDictionary *w in list) {
        if ([w[(id)kCGWindowOwnerPID] intValue] != pid) continue;
        if ([w[(id)kCGWindowLayer] intValue] != 0) continue;
        NSDictionary *b = w[(id)kCGWindowBounds];
        if ([b[@"Width"] doubleValue] > 300 && [b[@"Height"] doubleValue] > 200) return YES;
    }
    return NO;
}

static uint64_t cpuNanoseconds(pid_t pid) {
    struct proc_taskinfo info;
    if (proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, sizeof info) != sizeof info) return 0;
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);
    return (info.pti_total_user + info.pti_total_system) * tb.numer / tb.denom;
}

static uint64_t residentBytes(pid_t pid) {
    struct proc_taskinfo info;
    if (proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, sizeof info) != sizeof info) return 0;
    return info.pti_resident_size;
}

static int compare(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : (x > y);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 4) { fprintf(stderr, "usage: launch_bench App.app file owner [runs]\n"); return 2; }
        NSString *appPath = @(argv[1]);
        NSString *file = @(argv[2]);
        NSString *owner = @(argv[3]);
        int runs = argc > 4 ? atoi(argv[4]) : 5;
        NSString *bundleId = [NSBundle bundleWithPath:appPath].bundleIdentifier;
        double windows[64], idles[64], memory[64];
        int count = 0;

        for (int run = 0; run < runs && run < 64; ++run) {
            // Make sure it is not running, and give the machine a moment to settle.
            NSRunningApplication *existing = findApp(bundleId);
            if (existing) { [existing forceTerminate]; [NSThread sleepForTimeInterval:1.0]; }
            [NSThread sleepForTimeInterval:1.5];

            double start = nowMs();
            NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
            configuration.activates = YES;

            [NSWorkspace.sharedWorkspace openURLs:@[[NSURL fileURLWithPath:file]]
                             withApplicationAtURL:[NSURL fileURLWithPath:appPath]
                                    configuration:configuration
                                completionHandler:^(NSRunningApplication *app, NSError *error) { }];

            pid_t pid = 0;
            double windowTime = -1;
            while (nowMs() - start < 20000) {
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.002]];
                if (pid == 0) {
                    NSRunningApplication *app = findApp(bundleId);
                    if (app) pid = app.processIdentifier;
                }
                if (pid != 0 && windowTime < 0 && hasWindow(owner, pid)) { windowTime = nowMs() - start; break; }
            }
            if (windowTime < 0) { printf("run %d: no window appeared\n", run + 1); continue; }

            // Idle: less than 3% of a core over a 250 ms stretch.
            double idleTime = -1;
            uint64_t cpuBefore = cpuNanoseconds(pid);
            double stretchStart = nowMs();
            while (nowMs() - start < 30000) {
                [NSThread sleepForTimeInterval:0.01];
                double elapsed = nowMs() - stretchStart;
                if (elapsed >= 250) {
                    uint64_t cpuNow = cpuNanoseconds(pid);
                    double used = (double)(cpuNow - cpuBefore) / 1e6;
                    if (used / elapsed < 0.03) { idleTime = stretchStart - start; break; }
                    cpuBefore = cpuNow;
                    stretchStart = nowMs();
                }
            }
            double megabytes = (double)residentBytes(pid) / 1048576.0;
            printf("run %d: window %6.0f ms   idle %6.0f ms   memory %5.0f MB\n", run + 1, windowTime, idleTime, megabytes);
            windows[count] = windowTime; idles[count] = idleTime; memory[count] = megabytes; ++count;

            NSRunningApplication *app = findApp(bundleId);
            if (app) [app forceTerminate];
        }
        if (count > 0) {
            qsort(windows, count, sizeof(double), compare);
            qsort(idles, count, sizeof(double), compare);
            qsort(memory, count, sizeof(double), compare);
            printf("median: window %6.0f ms   idle %6.0f ms   memory %5.0f MB   (best window %0.0f ms)\n",
                   windows[count / 2], idles[count / 2], memory[count / 2], windows[0]);
        }
    }
    return 0;
}
