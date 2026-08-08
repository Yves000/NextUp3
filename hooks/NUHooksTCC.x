// iOS 16 TCC bypass for the Play-Next enqueue (display side). Provides the missing
// NSAppleMusicUsageDescription and forces media-library authorization so the enqueue
// that works on iOS 17 also succeeds on iOS 16.
#import "NUHooksShared.h"
#import "NULocalization.h"

// The MPMusicPlayerController "Play Next" enqueue (playPreviousTrack) works on iOS
// 17 from the display process, but on iOS 16 MediaRemoteUI's Info.plist lacks
// NSAppleMusicUsageDescription, so the media-library access is TCC-killed (SIGABRT).
// Provide the missing purpose string (the only thing the crash complains about) and
// force the media-library authorization to "authorized", so the same enqueue that
// works on iOS 17 succeeds here. Scoped strictly to that one key.
@interface MPMediaLibrary : NSObject @end

// Statically retained: the CFBundle hook below hands this out under the CF Get
// rule (caller borrows the reference), so it must live for the process lifetime
// — never a per-call autoreleased object.
static NSString *NUUsageDescription(void) {
    static NSString *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = NULocalizedString(@"MUSIC_USAGE_DESCRIPTION",
                              @"NextUp 3 manages the Apple Music Up Next queue.");
    });
    return s;
}

// --- Group 1: the missing Info.plist purpose string ---------------------------
// Narrow and safe: one key, only when %orig is nil. This is what the TCC kill
// actually complains about, so it is what iOS 14/15 (untested but harmless: no
// behaviour is reshaped, only a missing string supplied) and 16 both get.
%group NUMediaUsageDescription

%hook NSBundle
- (id)objectForInfoDictionaryKey:(NSString *)key {
    id r = %orig;
    if (!r && [key isEqualToString:@"NSAppleMusicUsageDescription"])
        return NUUsageDescription();
    return r;
}
%end

%hookf(CFTypeRef, CFBundleGetValueForInfoDictionaryKey, CFBundleRef bundle, CFStringRef key) {
    CFTypeRef r = %orig;
    if (!r && key && CFStringCompare(key, CFSTR("NSAppleMusicUsageDescription"), 0) == kCFCompareEqualTo)
        return (__bridge CFTypeRef)NUUsageDescription();
    return r;
}

%end // NUMediaUsageDescription

// --- Group 2: reshaping MPMediaLibrary itself ---------------------------------
// iOS 16 ONLY. These three change MPMediaLibrary behaviour for EVERY caller in the
// host process — and on iOS 14.2 the host is SpringBoard, which runs the whole
// now-playing / media-controls stack in-process. Installing them there correlates
// exactly with mediaserverd being wedged and RPC-timeout-killed (playback stops):
// five stackshots show the same wedge, it survives the master toggle being off
// (this %ctor never consulted prefs), it disappears when the tweak is uninstalled,
// and iOS 17/18 — where this group is not installed at all — are unaffected.
// They were only ever *needed* for the iOS 16 enqueue-response decode.
%group NUMediaLibraryShim

%hook MPMediaLibrary
+ (long long)authorizationStatus { return 3; /* Authorized */ }
+ (void)requestAuthorization:(void (^)(long long))handler { if (handler) handler(3); }
// The Play-Next response decoded in MediaRemoteUI references an MPMediaLibrary.
// Decoding it runs +deviceMediaLibrary, which throws (unlike iOS 17, MediaRemoteUI
// can't open the media-library DB). That throw happens inside a dispatch_once
// callout — NOT exception-safe — so it std::terminate()s the process before any
// @catch up the stack can see it (the enqueue itself already succeeded first). So
// don't let the throwing chain run at all: decode the library reference as nil.
// MediaRemoteUI can't use a real one here anyway, so nil is equivalent-and-safe.
// (Known, accepted micro-leak: returning nil without releasing the +alloc'd self
// leaks one tiny object per decode — a Logos hook isn't an ARC init method, so
// nothing balances the alloc. A manual release here risks an over-release crash,
// which would be strictly worse; this path is rare and iOS ≤ 16 only.)
- (id)initWithCoder:(id)coder {
    NULog("MPMediaLibrary initWithCoder — decoding as nil (avoids deviceMediaLibrary abort)");
    return nil;
}
%end

%end // NUMediaLibraryShim

%ctor {
    @autoreleasepool {
        NUApplySandbox();
        if (!NUIsDisplaySide()) return;
        // Nothing here is needed from iOS 17 on: the Play-Next enqueue runs natively
        // on 17 (MediaRemoteUI-side, verified live) AND on 18 (SpringBoard-side,
        // where the LS row is drawn — verified on iPad7,11 @ 18.7.5: repeated
        // previous-swipes enqueue cleanly, no SpringBoard SIGABRT / player-UI
        // restart, which is the signature of the TCC media-library kill).
        if (NUIOSMajor() >= 17) return;
        // The purpose string is the narrow part — safe on 14/15/16.
        %init(NUMediaUsageDescription);
        // The MPMediaLibrary reshaping is iOS 16 only. Verified on-device on
        // iPhone9,3 @ 14.2 that the back-swipe "play previous" (Apple Music) still
        // works WITHOUT it — so 14/15 never needed it; they only inherited it
        // untested. Don't widen this again: it changes MPMediaLibrary for every
        // caller in the host process, and on 14/15 that host is SpringBoard.
        if (NUIOSMajor() == 16) %init(NUMediaLibraryShim);
    }
}
