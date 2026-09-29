#import "StartupTiming.h"

#include <sys/sysctl.h>
#include <sys/time.h>
#include <unistd.h>

/// When this process was started, in seconds since 1970.
static double processStartTime() {
    struct kinfo_proc info;
    size_t size = sizeof info;
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    if (sysctl(mib, 4, &info, &size, nullptr, 0) != 0) {
        return 0;
    }
    struct timeval start = info.kp_proc.p_un.__p_starttime;
    return (double)start.tv_sec + (double)start.tv_usec / 1e6;
}

void GWStartupMark(NSString *label) {
    static BOOL enabled = getenv("GLASSWORK_TIMING") != nullptr;
    if (!enabled) {
        return;
    }
    static double started = processStartTime();
    double elapsed = ([NSDate date].timeIntervalSince1970 - started) * 1000;
    fprintf(stderr, "[startup] %7.1f ms  %s\n", elapsed, label.UTF8String);
}
