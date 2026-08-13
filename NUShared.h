// Shared constants for the NextUp 3 Music-provider <-> MediaRemoteUI-display IPC.
#import <Foundation/Foundation.h>
#import <os/log.h>
#import <dlfcn.h>
#import <notify.h>

#ifdef DEBUG
// Two sinks on purpose: os_log for a normal `log stream` on a device where that
// works, and a plain per-process file (NULogFile.m) for the ones where it does
// not — on the iOS 18 and iOS 26 test targets on-device `oslog` renders every
// one of our lines as `<compose failure [corrupt log]>`.
// Both take the SAME literal format string; NULogWritev strips the
// os_log-only `%{public}` / `%{private}` annotations before formatting.
#import <stdarg.h>
void NULogWritev(const char *fmt, va_list ap);
// No format attribute: the string mixes printf specifiers with ObjC `%@`, which
// neither `format(printf)` nor `format(NSString)` describes. os_log in the same
// macro still gets the compiler's format checking.
static inline void NULogWrite(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt); NULogWritev(fmt, ap); va_end(ap);
}
#define NULog(fmt, ...) do { \
    os_log(OS_LOG_DEFAULT, "[NextUp3] " fmt, ##__VA_ARGS__); \
    NULogWrite(fmt, ##__VA_ARGS__); \
} while (0)
#else
// Compile logging out of release (FINALPACKAGE) builds, but keep the arguments
// referenced in a dead branch so variables used only for logging don't trip
// -Werror=unused-variable.
#define NULog(fmt, ...) do { if (0) os_log(OS_LOG_DEFAULT, "[NextUp3] " fmt, ##__VA_ARGS__); } while (0)
#endif

// IPC: each provider registers a LightMessaging mach service (via a libSandy
// mach extension — app sandboxes can't register bootstrap services on their
// own) and serves the current next-up as a property list on request; the
// display side looks the service up and queries it. Darwin notifications
// (no payload, no privilege, cross sandboxes freely) signal "changed"
// (provider→display) and skip/prev/jump (display→provider).
// ---- Per-source provider IPC (one provider per media app) ----
// Each supported media app (Music, Podcasts, …) runs its own provider and can be
// alive at the same time, so IPC names are namespaced per source — a shared name
// would collide on registration. Convention for adding a new app: pick a short
// source key, add its bundle-id → key mapping + connection in NUNextUpManager, and
// name its service/skip the same way. The display picks which provider to talk to
// by the current now-playing app.
#define kNUServiceNameMusic        "com.yves.nextup3.svc.music"
#define kNUServiceNamePodcasts     "com.yves.nextup3.svc.podcasts"
#define kNUServiceNameYouTubeMusic "com.yves.nextup3.svc.youtubemusic"
#define kNUServiceNameSpotify      "com.yves.nextup3.svc.spotify"

// Darwin notifications (no payload; just signals).
// "changed" is SHARED by all providers → display: whichever provider's next-up
// changed, the display re-queries the current source. One signal scales to any
// number of apps. "skip" is per-source: display → that app's provider.
#define kNUChangedNotification "com.yves.nextup3.changed"
#define kNUSkipNotificationMusic        "com.yves.nextup3.skip.music"    // display → Music provider: remove next track
#define kNUSkipNotificationPodcasts     "com.yves.nextup3.skip.podcasts" // display → Podcasts provider: remove next episode
#define kNUSkipNotificationYouTubeMusic "com.yves.nextup3.skip.youtubemusic" // display → YTM provider: remove next track
#define kNUSkipNotificationSpotify      "com.yves.nextup3.skip.spotify"      // display → Spotify provider: remove next track
// Play-previous: Music does the enqueue display-side (public MPMusicPlayer API), so it
// needs no notification. Podcasts' enqueue API (MTUpNextController) is in-process, so the
// display signals the Podcasts provider to re-queue the previous episode itself.
#define kNUPrevNotificationPodcasts "com.yves.nextup3.prev.podcasts" // display → Podcasts provider: re-queue previous episode
// YouTube Music enqueues 'previous' provider-side too (its queue mutation API is in-process), so the
// display signals the YTM provider to re-queue the previous track as the immediate next itself.
#define kNUPrevNotificationYouTubeMusic "com.yves.nextup3.prev.youtubemusic" // display → YTM provider: re-queue previous track
// Spotify's queue API is in-process too (-[SPTPlayer playAsNextInQueue:options:loggingParams:] is
// exactly the "Play Next" semantic), so it takes the provider-side path as well. Registering this
// name is also what flips -[NUNextUpManager canActionPrevious] off the adamID requirement.
#define kNUPrevNotificationSpotify "com.yves.nextup3.prev.spotify" // display → Spotify provider: re-queue previous track
// Tap the next-up cover to play it now. Music maps the MediaRemote NextTrack command to
// "advance to the next queued item" — but iOS 18 Podcasts maps it to a 30s skip, so the
// display signals the Podcasts (MPC) provider to jump the queue to the next episode instead.
#define kNUJumpNotificationPodcasts "com.yves.nextup3.jump.podcasts" // display → Podcasts provider: play the next episode now
// YTM maps the MediaRemote NextTrack command through its own player; jump the queue to the next
// item's index directly (-playItemAtIndex:) instead, so the cover tap always plays the shown track.
#define kNUJumpNotificationYouTubeMusic "com.yves.nextup3.jump.youtubemusic" // display → YTM provider: play the next track now

// User preferences live in NUPrefs.h (domain + notify-state token). Kept out of this IPC
// header so the Settings bundle can include NUPrefs.h without pulling in the mach stack.

// Cross-process touch flag: our row (MediaRemoteUI) is being touched/swiped. Read
// synchronously by SpringBoard's Dynamic Island gesture block via notify_get_state,
// so it can fail the island's own resize/dismiss gesture while our swipe is active —
// the aperture content is scaled/transformed, making geometry-based hit-testing
// unreliable, so we signal the exact touch state instead.
#define kNUDITouchNotify "com.yves.nextup3.ditouch"

// The "on" state carries the touch-down wall-clock second, not a bare 1: notify
// state lives in notifyd and survives the setter process. If the row's process
// dies mid-touch (jetsam, killall) nothing ever clears the flag, and a bare 1
// would fail the island's resize/dismiss gestures until reboot. With the
// timestamp, the reader simply ignores a flag older than any plausible touch.
// The display-side %ctor additionally clears it on relaunch.
#define kNUDITouchMaxAge 30 // s

static inline void NUDITouchSet(uint64_t on) {
    static int token = -1;
    if (token == -1 && notify_register_check(kNUDITouchNotify, &token) != NOTIFY_STATUS_OK) { token = -1; return; }
    notify_set_state(token, on ? (uint64_t)time(NULL) : 0);
    notify_post(kNUDITouchNotify);
}

static inline uint64_t NUDITouchGet(void) {
    static int token = -1;
    if (token == -1 && notify_register_check(kNUDITouchNotify, &token) != NOTIFY_STATUS_OK) { token = -1; return 0; }
    uint64_t v = 0;
    notify_get_state(token, &v);
    if (v == 0) return 0;
    time_t now = time(NULL);
    if (now < (time_t)v || now - (time_t)v > kNUDITouchMaxAge) return 0; // stale — setter died mid-touch
    return 1;
}

// Cross-process media-suggestions flag — iOS 18 lock screen ONLY. Every other surface
// reads the player view's own -showSuggestionsView directly (see NUViewShowsSuggestions in
// NUHooksShared.h); this exists because on iOS 18 the lock-screen player is a remote
// MediaRemoteUI scene (MRULockscreenView) while our row is drawn SpringBoard-side
// (NUHooksLockScreen18), so SpringBoard has no player view to ask. The MediaRemoteUI side
// publishes the state from -[MRULockscreenView setShowSuggestionsView:]; SpringBoard's
// height lever + layout read it back.
#define kNUSuggestNotify "com.yves.nextup3.suggesting"

static inline void NUSuggestingSet(uint64_t on) {
    static int token = -1;
    if (token == -1 && notify_register_check(kNUSuggestNotify, &token) != NOTIFY_STATUS_OK) { token = -1; return; }
    notify_set_state(token, on);
    notify_post(kNUSuggestNotify);
}

static inline uint64_t NUSuggestingGet(void) {
    static int token = -1;
    if (token == -1 && notify_register_check(kNUSuggestNotify, &token) != NOTIFY_STATUS_OK) { token = -1; return 0; }
    uint64_t v = 0;
    notify_get_state(token, &v);
    return v;
}

// libSandy profile granting the mach-register / mach-lookup extensions for the
// per-source service names above. Applied in each process's %ctor before any
// LM call. Loaded via dlopen so we don't need a link-time tbd.
#define kNUSandyProfile "com.yves.nextup3"

// Returns whether the profile is in effect for this process. The RESULT is cached,
// not the attempt: at boot SpringBoard starts before libSandy's service, so the
// %ctor-time apply fails — remembered as "done", that would leave every mach lookup
// denied for the life of the process (row dead on every surface until a respring).
// A failed apply stays retryable; NUNextUpManager retries from its query path once
// a lookup is refused.
static inline BOOL NUApplySandbox(void) {
    static BOOL applied = NO;
    static BOOL announced = NO;
    if (applied) return YES;

    if (!announced) {
        announced = YES;
        // First line every injected process writes — the "are we loaded at all,
        // and into what" marker for a new iOS version / new jailbreak.
        NULog("ctor: proc=%{public}@ os=%{public}@",
              NSProcessInfo.processInfo.processName,
              NSProcessInfo.processInfo.operatingSystemVersionString);
    }

    void *h = dlopen("libsandy.dylib", RTLD_LAZY);
    // roothide's jbroot is randomised; resolve libsandy relative to our own
    // dylib path (…/<jbroot>/usr/lib/TweakInject/NextUp3.dylib).
    if (!h) {
        Dl_info info; memset(&info, 0, sizeof(info));
        if (dladdr((const void *)&NUApplySandbox, &info) && info.dli_fname) {
            NSString *self = @(info.dli_fname);
            NSRange r = [self rangeOfString:@"/usr/lib/" options:NSBackwardsSearch];
            if (r.location != NSNotFound) {
                NSString *lib = [[self substringToIndex:NSMaxRange(r)] stringByAppendingString:@"libsandy.dylib"];
                h = dlopen(lib.fileSystemRepresentation, RTLD_LAZY);
                NULog("libSandy dlopen(%{public}@) = %p", lib, h);
            }
        }
    }
    int (*applyProfile)(const char *) = h ? (int (*)(const char *))dlsym(h, "libSandy_applyProfile") : NULL;
    if (applyProfile) {
        int r = applyProfile(kNUSandyProfile);
        NULog("libSandy applyProfile(%s) = %d (0=ok)", kNUSandyProfile, r);
        applied = (r == 0);
    } else {
        NULog("libSandy not available (h=%p)", h);
    }
    return applied;
}

// Keys in the archived next-up dictionary.
static NSString *const kNUKeyActive   = @"active";   // NSNumber(BOOL): is there a valid next track
static NSString *const kNUKeyTitle    = @"title";    // NSString
static NSString *const kNUKeySubtitle = @"subtitle"; // NSString (artist)
static NSString *const kNUKeyArtwork  = @"artwork";  // NSData (PNG) or absent
static NSString *const kNUKeyCanSkip  = @"canSkip";  // NSNumber(BOOL)
static NSString *const kNUKeyCanPrev  = @"canPrev";  // NSNumber(BOOL): a previous track exists (history)

// Neighbour previews for the swipe carousel. "Fwd" = the item that becomes
// up-next after a skip (queue offset +2), shown sliding in on a left swipe.
// "Back" = the PREVIOUS track (recorded play history, depth 1), which "previous"
// navigates to, shown sliding in on a right swipe.
static NSString *const kNUKeyFwdTitle    = @"fwdTitle";
static NSString *const kNUKeyFwdSubtitle = @"fwdSubtitle";
static NSString *const kNUKeyFwdArtwork  = @"fwdArtwork";   // NSData(PNG) or absent
static NSString *const kNUKeyBackTitle    = @"backTitle";
static NSString *const kNUKeyBackSubtitle = @"backSubtitle";
static NSString *const kNUKeyBackArtwork  = @"backArtwork"; // NSData(PNG) or absent
static NSString *const kNUKeyBackAdamID   = @"backAdamID";  // NSString store id, for Play-Next enqueue
