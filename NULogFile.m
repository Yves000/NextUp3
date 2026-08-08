// Dev-only file sink for NULog (DEBUG builds only — see NUShared.h).
//
// Why this exists: on the iOS 18 and iOS 26 test targets
// `oslog` on-device cannot decode our os_log format strings — every
// NULog comes out as `<compose failure [corrupt log]>`, which makes the display
// side effectively un-debuggable. The tweak spans six processes, so "attach a
// debugger" is not a practical substitute either.
//
// So every NULog also appends a plain line to a per-process file. The sink is
// chosen at first use from a candidate list, because the six injected processes
// do NOT share a writable directory: SpringBoard / MediaRemoteUI can write under
// /var/mobile, the App Store apps (Spotify, YouTube Music, …) are container-
// redirected and can only write inside their own sandbox. NSTemporaryDirectory()
// is the always-works fallback.
//
// Release (FINALPACKAGE) builds compile this to nothing.
#import "NUShared.h"

#ifdef DEBUG

#import <pthread.h>

static NSString *gNULogPath = nil;
static pthread_mutex_t gNULogLock = PTHREAD_MUTEX_INITIALIZER;

// First writable candidate wins, and we remember it for the process lifetime.
// The shared /var/mobile/nu directory is preferred so the display-side logs
// (SpringBoard + MediaRemoteUI, the two that matter most for the UI work) land
// together in one place.
static NSString *NULogResolvePath(void) {
    NSString *proc = NSProcessInfo.processInfo.processName ?: @"unknown";
    proc = [proc stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    NSFileManager *fm = NSFileManager.defaultManager;

    NSString *shared = @"/var/mobile/nu";
    [fm createDirectoryAtPath:shared withIntermediateDirectories:YES attributes:nil error:NULL];
    for (NSString *dir in @[ shared, NSTemporaryDirectory() ?: @"/tmp" ]) {
        if (![fm isWritableFileAtPath:dir]) continue;
        NSString *p = [dir stringByAppendingPathComponent:
                       [NSString stringWithFormat:@"nextup3-%@.log", proc]];
        // isWritableFileAtPath on a directory is necessary but not sufficient
        // under the app sandboxes — prove it by actually creating the file.
        if ([fm fileExistsAtPath:p] || [fm createFileAtPath:p contents:nil attributes:nil]) return p;
    }
    return nil;
}

void NULogWritev(const char *cfmt, va_list ap) {
    if (!cfmt) return;
    @autoreleasepool {
        // os_log's annotations have no NSString equivalent; strip them so the
        // same literal format string works for both sinks.
        NSMutableString *fmt = [NSMutableString stringWithUTF8String:cfmt];
        for (NSString *ann in @[ @"%{public}", @"%{private}" ])
            [fmt replaceOccurrencesOfString:ann withString:@"%"
                                    options:0 range:NSMakeRange(0, fmt.length)];

        NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];

        pthread_mutex_lock(&gNULogLock);
        if (!gNULogPath) gNULogPath = NULogResolvePath();
        NSString *path = gNULogPath;
        pthread_mutex_unlock(&gNULogLock);
        if (!path) return;

        static NSDateFormatter *df = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            df = [NSDateFormatter new];
            df.dateFormat = @"HH:mm:ss.SSS";
        });
        NSString *stamped = [NSString stringWithFormat:@"%@ [%d] %@\n",
                             [df stringFromDate:NSDate.date], getpid(), line];

        // Recreate the file if it vanished. The resolved path is cached for the
        // process lifetime, and a deploy cycle that clears /var/mobile/nu would
        // otherwise silence this process's logging until it restarts — which is
        // exactly when the log matters most (SpringBoard survives many deploys).
        NSFileManager *fm = NSFileManager.defaultManager;
        if (![fm fileExistsAtPath:path]) [fm createFileAtPath:path contents:nil attributes:nil];

        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) return;
        @try {
            [fh seekToEndOfFile];
            [fh writeData:[stamped dataUsingEncoding:NSUTF8StringEncoding]];
        } @catch (__unused NSException *e) {
        } @finally {
            [fh closeFile];
        }
    }
}

#endif  // DEBUG
