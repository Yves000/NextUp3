#import "NUNextUpManager.h"
#import "NUShared.h"
#import "NUPrefs.h"
#import "LightMessaging.h"
#import <QuartzCore/QuartzCore.h> // CACurrentMediaTime (monotonic query-throttle stamp)
#import <notify.h>
#import <objc/runtime.h>

// Public MediaPlayer queue API — enqueue a track to play next by its store adam id.
// Runs from the display (a media client, cross-process to Music, so no deadlock),
// exactly as on iOS 17. The iOS-16 TCC kill (missing NSAppleMusicUsageDescription)
// is worked around by the usage-description injection in hooks/NUHooksTCC.x (%group NUMediaTCC).
// The `2` suffix keeps these shadow interfaces from colliding with the real private
// interfaces at runtime/SDK (same convention as NUMusicProvider.m).
@interface MPMusicPlayerStoreQueueDescriptor2 : NSObject
- (instancetype)initWithStoreIDs:(NSArray<NSString *> *)storeIDs;
@end
@interface MPMusicPlayerController2 : NSObject
+ (id)systemMusicPlayer;
- (void)prependQueueDescriptor:(id)descriptor;
@end

NSString *const NUNextUpDidChangeNotification = @"NUNextUpDidChangeNotification";

// Same track slot across two snapshots (nil-safe; nil never matches).
static BOOL NUSameTitle(NSString *a, NSString *b) {
    return a != nil && b != nil && [a isEqualToString:b];
}
// Track identity for the artwork-retention check: title alone is ambiguous (two
// consecutive "Intro"s, covers of the same song), and keeping the old artwork
// across such a boundary pins the WRONG cover. Subtitles may legitimately both be
// empty (@""), so equal-or-both-nil is fine there once the titles match.
static BOOL NUSameTrack(NSString *t1, NSString *s1, NSString *t2, NSString *s2) {
    if (!NUSameTitle(t1, t2)) return NO;
    return s1 == s2 || (s1 != nil && s2 != nil && [s1 isEqualToString:s2]);
}

// Which media app currently owns the now-playing UI (and thus which provider the
// display talks to).
// Adding a new source? Follow the checklist in README.md "Adding support for another app" (enum here, prefs bit in NUPrefs.h, service name in NUShared.h).
typedef NS_ENUM(NSInteger, NUSource) {
    NUSourceNone = 0,
    NUSourceMusic,
    NUSourcePodcasts,
    NUSourceYouTubeMusic,
    NUSourceSpotify,
};

// One LightMessaging connection per source (see NUShared.h).
static LMConnection gConnMusic         = { MACH_PORT_NULL, kNUServiceNameMusic };
static LMConnection gConnPodcasts      = { MACH_PORT_NULL, kNUServiceNamePodcasts };
static LMConnection gConnYouTubeMusic  = { MACH_PORT_NULL, kNUServiceNameYouTubeMusic };
static LMConnection gConnSpotify       = { MACH_PORT_NULL, kNUServiceNameSpotify };

static LMConnection *NUConnectionForSource(NUSource s) {
    switch (s) {
        case NUSourceMusic:         return &gConnMusic;
        case NUSourcePodcasts:      return &gConnPodcasts;
        case NUSourceYouTubeMusic:  return &gConnYouTubeMusic;
        case NUSourceSpotify:       return &gConnSpotify;
        default:                    return NULL;
    }
}
static NUSource NUSourceForBundleID(NSString *bid) {
    if ([bid isEqualToString:@"com.apple.Music"])              return NUSourceMusic;
    if ([bid isEqualToString:@"com.apple.podcasts"])           return NUSourcePodcasts;
    if ([bid isEqualToString:@"com.google.ios.youtubemusic"])  return NUSourceYouTubeMusic;
    if ([bid isEqualToString:@"com.spotify.client"])           return NUSourceSpotify;
    return NUSourceNone;
}

// Per-source Settings key for the "show the row for this app" toggle. This is the single
// place the per-app preference is wired — the NUSource → key map. A source with no key
// (NUSourceNone / a future app before its switch is added) is treated as enabled.
static NSString *NUAppPrefKeyForSource(NUSource s) {
    switch (s) {
        case NUSourceMusic:         return @"enabledMusic";
        case NUSourcePodcasts:      return @"enabledPodcasts";
        case NUSourceYouTubeMusic:  return @"enabledYouTubeMusic";
        case NUSourceSpotify:       return @"enabledSpotify";
        default:                    return nil;
    }
}
static BOOL NUAppEnabled(NUSource s) {
    NSString *key = NUAppPrefKeyForSource(s);
    return key ? NUPrefBool(key, YES) : YES;
}

// Per-source display→provider Darwin notifications. NULL = not applicable (e.g. Music
// enqueues 'previous' display-side); no Music default, so an unhandled source is a
// no-op, never a wrong-provider signal.
static const char *NUSkipNotificationForSource(NUSource s) {
    switch (s) {
        case NUSourceMusic:         return kNUSkipNotificationMusic;
        case NUSourcePodcasts:      return kNUSkipNotificationPodcasts;
        case NUSourceYouTubeMusic:  return kNUSkipNotificationYouTubeMusic;
        case NUSourceSpotify:       return kNUSkipNotificationSpotify;
        default:                    return NULL;
    }
}
static const char *NUPrevNotificationForSource(NUSource s) {
    switch (s) {
        case NUSourcePodcasts:      return kNUPrevNotificationPodcasts;
        case NUSourceYouTubeMusic:  return kNUPrevNotificationYouTubeMusic;
        case NUSourceSpotify:       return kNUPrevNotificationSpotify;
        default:                    return NULL; // Music (and any display-side-enqueue source)
    }
}

@interface NUNextUpManager ()
@property (nonatomic, copy, readwrite) NSString *nextTitle;
@property (nonatomic, copy, readwrite) NSString *nextSubtitle;
@property (nonatomic, strong, readwrite) UIImage *nextArtwork;
@property (nonatomic, readwrite) BOOL canSkip;
@property (nonatomic, readwrite) BOOL canPrevious;
@property (nonatomic, copy, readwrite) NSString *fwdTitle;
@property (nonatomic, copy, readwrite) NSString *fwdSubtitle;
@property (nonatomic, strong, readwrite) UIImage *fwdArtwork;
@property (nonatomic, copy, readwrite) NSString *backTitle;
@property (nonatomic, copy, readwrite) NSString *backSubtitle;
@property (nonatomic, strong, readwrite) UIImage *backArtwork;
@property (nonatomic, copy) NSString *backAdamID; // store id of the previous track, for Play-Next
// `active` (isActive) is computed: the current source's provider says it has a next
// item AND a supported media app (Music/Podcasts) currently owns the now-playing UI.
// The second gate stops our row from overlaying another app's player (e.g. a WhatsApp
// voice note).
@property (nonatomic) BOOL providerActive; // provider snapshot: current source has a real next item
@property (nonatomic) NUSource source;     // media app that owns the now-playing UI
// Bytes behind the last decode per artwork slot: every provider notification makes
// BOTH display processes re-query and re-receive the same PNGs, so compare (memcmp,
// orders of magnitude cheaper than a decode) and skip the decode when unchanged.
@property (nonatomic, strong) NSData *lastNextArtworkData;
@property (nonatomic, strong) NSData *lastFwdArtworkData;
@property (nonatomic, strong) NSData *lastBackArtworkData;
// Last successful LM roundtrip (monotonic clock + source), for -start's throttle.
@property (nonatomic) BOOL nowPlayingTrackingActive; // MediaRemote registration done
@property (nonatomic) CFTimeInterval lastQueryStamp;
@property (nonatomic) NUSource lastQuerySource;
@end

@implementation NUNextUpManager

+ (instancetype)sharedManager {
    static NUNextUpManager *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [NUNextUpManager new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        // Fail open to Music until the now-playing app is resolved, so the row isn't
        // withheld for a frame when Music genuinely is the source.
        _source = NUSourceMusic;
    }
    return self;
}

- (BOOL)isActive {
    // Every show/grow path flows through `active`, so this one gate suppresses the row
    // on every surface; per-interface toggles are applied host-side (NUInterfaceEnabled).
    if (!NUMasterEnabled() || !NUAppEnabled(self.source)) return NO;
    return self.providerActive && self.source != NUSourceNone;
}

- (void)start {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Re-query whenever the provider signals a queue/next-up change.
        int token; // process-lifetime registration; token intentionally not kept
        notify_register_dispatch(kNUChangedNotification, &token, dispatch_get_main_queue(), ^(int t) {
            [self query];
        });
        // Observe prefs so a toggle takes effect live (re-query + re-broadcast the
        // show/grow gates) and a disabled tweak generates zero IPC / media RPCs.
        NUPrefsObserve(^{
            NULog("client: prefs changed — re-querying + re-broadcasting");
            [self startNowPlayingTrackingIfNeeded]; // may have just been enabled
            [self query];      // a just-re-enabled source was never queried while off
            [self postChange];
        });
        NULog("client: registered for change notifications");
    });
    if (!NUMasterEnabled()) return;   // disabled: no MediaRemote calls, no query
    [self startNowPlayingTrackingIfNeeded];
    [self refreshNowPlayingApp];
    // Throttle only -start's roundtrip; change notifications and now-playing-app
    // switches call -query directly and are never throttled.
    // 0.25s: just long enough to swallow the appear-time settle ticks
    // (NUHooksNowPlaying) that would refetch an identical snapshot.
    if (self.lastQueryStamp > 0 && self.source == self.lastQuerySource
        && CACurrentMediaTime() - self.lastQueryStamp < 0.25) return;
    [self query];
}

// Query the Music provider's LightMessaging service for the current next-up.
// Runs synchronously on the caller so `active` is set before the platter is
// measured — which makes the height growth reliable on first appearance. The
// round-trip is sub-millisecond when Music is live and bounded by
// LIGHTMESSAGING_TIMEOUT (Makefile) when it is suspended: a suspended app's
// runloop never services the port, and without the timeout this call would
// block SpringBoard's main thread until the watchdog resprings.
- (void)query {
    // Disabled in Settings → no IPC at all.
    if (!NUMasterEnabled() || !NUAppEnabled(self.source)) { [self applyDictionary:nil]; return; }
    LMConnection *conn = NUConnectionForSource(self.source);
    if (!conn) { [self applyDictionary:nil]; return; } // no supported media app on screen
    LMResponseBuffer buffer;
    kern_return_t kr = LMConnectionSendTwoWay(conn, 0, NULL, 0, &buffer);
    if (kr == MACH_SEND_TIMED_OUT || kr == MACH_RCV_TIMED_OUT) {
        // Music exists but didn't answer in time (suspended or busy). Keep the
        // last snapshot — dropping to inactive would hide the row / flash the
        // placeholder for no reason — and retry once off the UI-critical path.
        NULog("client: query timed out kr=%d — keeping last snapshot", kr);
        [self scheduleTimeoutRequery];
        return;
    }
    if (kr != 0) {
        NULog("client: query kr=%d (provider not up?)", kr);
        [self applyDictionary:nil];
        return;
    }
    id plist = LMResponseConsumePropertyList(&buffer);
    NSDictionary *dict = [plist isKindOfClass:[NSDictionary class]] ? plist : nil;
    self.lastQueryStamp = CACurrentMediaTime();
    self.lastQuerySource = self.source;
    [self applyDictionary:dict];
}

// One deferred re-query after a timeout, run on a background queue so a still
// unresponsive provider only ever costs the timeout there, never on main.
// Coalesced: a burst of timed-out queries schedules a single retry.
- (void)scheduleTimeoutRequery {
    static BOOL pending = NO;
    if (pending) return;
    pending = YES;
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("com.yves.nextup3.requery", DISPATCH_QUEUE_SERIAL); });
    // 1s retry delay: give the provider time to re-register after a dead-name send.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), q, ^{
        // Own connection (fresh lookup): the shared gConn* isn't safe to share with a
        // concurrent main-thread query — LMMachMsg mutates its serverPort on a
        // dead-name send. Retries are rare, so the extra lookup is negligible.
        LMConnection *base = NUConnectionForSource(self.source);
        if (!base) { dispatch_async(dispatch_get_main_queue(), ^{ pending = NO; [self applyDictionary:nil]; }); return; }
        LMConnection conn = *base;          // copy the service name; use a fresh port so
        conn.serverPort = MACH_PORT_NULL;   // we don't share serverPort with the main-thread query
        LMResponseBuffer buffer;
        kern_return_t kr = LMConnectionSendTwoWay(&conn, 0, NULL, 0, &buffer);
        if (conn.serverPort != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), conn.serverPort);
        NSDictionary *dict = nil;
        BOOL apply = NO;
        if (kr == 0) {
            id plist = LMResponseConsumePropertyList(&buffer);
            dict = [plist isKindOfClass:[NSDictionary class]] ? plist : nil;
            apply = YES;
        } else if (kr != MACH_SEND_TIMED_OUT && kr != MACH_RCV_TIMED_OUT) {
            apply = YES; // provider gone → deactivate; still timing out → keep waiting for a notify
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            pending = NO;
            if (apply) [self applyDictionary:dict];
        });
    });
}

// The reply crosses a mach boundary, so treat every value as untrusted: a
// wrong-typed value (e.g. an NSNumber where a string belongs) is handled exactly
// like an absent key instead of type-confusing a later -length / -imageWithData:.
static NSString *NUDictString(NSDictionary *d, NSString *k) {
    id v = d[k]; return [v isKindOfClass:[NSString class]] ? v : nil;
}
static NSData *NUDictData(NSDictionary *d, NSString *k) {
    id v = d[k]; return [v isKindOfClass:[NSData class]] ? v : nil;
}
static BOOL NUDictBool(NSDictionary *d, NSString *k) {
    id v = d[k]; return [v isKindOfClass:[NSNumber class]] && [v boolValue];
}

- (void)applyDictionary:(NSDictionary *)dict {
    BOOL active = NUDictBool(dict, kNUKeyActive);
    if (!active) {
        // Reset every snapshot slot; a missed one leaks stale artwork across source switches.
        if (self.providerActive) { self.providerActive = NO; self.nextTitle = nil; self.nextSubtitle = nil;
                           self.nextArtwork = nil; self.canSkip = NO; self.canPrevious = NO;
                           self.fwdTitle = nil; self.fwdSubtitle = nil; self.fwdArtwork = nil;
                           self.backTitle = nil; self.backSubtitle = nil; self.backArtwork = nil;
                           self.backAdamID = nil;
                           self.lastNextArtworkData = nil; self.lastFwdArtworkData = nil;
                           self.lastBackArtworkData = nil;
                           [self postChange]; }
        return;
    }
    self.providerActive = YES;
    NSString *oldNextTitle = self.nextTitle, *oldNextSubtitle = self.nextSubtitle;
    NSString *oldFwdTitle = self.fwdTitle, *oldFwdSubtitle = self.fwdSubtitle;
    NSString *oldBackTitle = self.backTitle, *oldBackSubtitle = self.backSubtitle;
    self.nextTitle = NUDictString(dict, kNUKeyTitle);
    self.nextSubtitle = NUDictString(dict, kNUKeySubtitle);
    self.canSkip = NUDictBool(dict, kNUKeyCanSkip);
    self.canPrevious = NUDictBool(dict, kNUKeyCanPrev);
    // A same-track snapshot without artwork data (cold cache / fetch still in flight)
    // must not downgrade artwork we already show to the placeholder — keep it.
    NSData *png = NUDictData(dict, kNUKeyArtwork);
    if (png) {
        if (!self.nextArtwork || ![png isEqualToData:self.lastNextArtworkData]) {
            self.nextArtwork = [UIImage imageWithData:png];
            self.lastNextArtworkData = png;
        }
    } else if (!NUSameTrack(self.nextTitle, self.nextSubtitle, oldNextTitle, oldNextSubtitle)) {
        self.nextArtwork = nil; self.lastNextArtworkData = nil;
    }

    self.fwdTitle = NUDictString(dict, kNUKeyFwdTitle);
    self.fwdSubtitle = NUDictString(dict, kNUKeyFwdSubtitle);
    NSData *fpng = NUDictData(dict, kNUKeyFwdArtwork);
    if (fpng) {
        if (!self.fwdArtwork || ![fpng isEqualToData:self.lastFwdArtworkData]) {
            self.fwdArtwork = [UIImage imageWithData:fpng];
            self.lastFwdArtworkData = fpng;
        }
    } else if (!NUSameTrack(self.fwdTitle, self.fwdSubtitle, oldFwdTitle, oldFwdSubtitle)) {
        self.fwdArtwork = nil; self.lastFwdArtworkData = nil;
    }
    self.backTitle = NUDictString(dict, kNUKeyBackTitle);
    self.backSubtitle = NUDictString(dict, kNUKeyBackSubtitle);
    NSData *bpng = NUDictData(dict, kNUKeyBackArtwork);
    if (bpng) {
        if (!self.backArtwork || ![bpng isEqualToData:self.lastBackArtworkData]) {
            self.backArtwork = [UIImage imageWithData:bpng];
            self.lastBackArtworkData = bpng;
        }
    } else if (!NUSameTrack(self.backTitle, self.backSubtitle, oldBackTitle, oldBackSubtitle)) {
        self.backArtwork = nil; self.lastBackArtworkData = nil;
    }
    self.backAdamID = NUDictString(dict, kNUKeyBackAdamID);
    NULog("client: next='%{public}@' — '%{public}@' art=%d skip=%d",
          self.nextTitle, self.nextSubtitle, self.nextArtwork != nil, self.canSkip);
    [self postChange];
}

- (BOOL)canActionPrevious {
    if (!self.canPrevious || self.backTitle.length == 0) return NO;
    // Sources that enqueue 'previous' provider-side (they have a prev notification) need no
    // store id; a display-side-enqueue source (Music) needs one.
    if (NUPrevNotificationForSource(self.source)) return YES;
    return self.backAdamID.length > 0;
}

- (void)skipNextTrack {
    if (!self.active || !self.canSkip) return;
    const char *note = NUSkipNotificationForSource(self.source);
    if (note) notify_post(note);
}

// MediaRemote.framework is already loaded in the display processes (MediaRemoteUI /
// SpringBoard); resolve it lazily so we don't need a link-time dependency.
static void *NUMRHandle(void) {
    static void *h; static dispatch_once_t once;
    dispatch_once(&once, ^{
        h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
        NULog("client: MediaRemote handle=%p", h);
    });
    return h;
}

// MediaRemote transport commands. Sending to the now-playing app (Apple Music)
// drives the exact same transport as the player's prev/next buttons.
static Boolean (*NUSendMRCommand(void))(unsigned int, id) {
    static Boolean (*fn)(unsigned int, id) = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = NUMRHandle();
        if (h) fn = (Boolean (*)(unsigned int, id))dlsym(h, "MRMediaRemoteSendCommand");
        NULog("client: MRMediaRemoteSendCommand=%p", fn);
    });
    return fn;
}

// Track which app currently owns the now-playing UI. Our row shows Apple Music's
// up-next, so it must only appear when the now-playing app on screen IS Apple Music.
// Register for MediaRemote now-playing notifications exactly once, and only while
// the tweak is enabled. Kept out of -start's dispatch_once so a tweak that starts
// out disabled registers nothing, and enabling it later still wires up.
- (void)startNowPlayingTrackingIfNeeded {
    if (self.nowPlayingTrackingActive || !NUMasterEnabled()) return;
    self.nowPlayingTrackingActive = YES;
    [self registerNowPlayingAppTracking];
}

- (void)registerNowPlayingAppTracking {
    void *h = NUMRHandle();
    if (!h) return;
    void (*reg)(dispatch_queue_t) = dlsym(h, "MRMediaRemoteRegisterForNowPlayingNotifications");
    if (reg) reg(dispatch_get_main_queue());
    // Resolve the MediaRemote notification-name constant at runtime; fall back to the
    // literal because the symbol may not be exported on all versions.
    NSString * __unsafe_unretained *namePtr =
        (NSString * __unsafe_unretained *)dlsym(h, "kMRMediaRemoteNowPlayingApplicationDidChangeNotification");
    NSString *name = namePtr ? *namePtr : @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification";
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshNowPlayingApp)
                                                 name:name object:nil];
}

- (void)refreshNowPlayingApp {
    if (!NUMasterEnabled()) return;  // no media RPCs while disabled
    void *h = NUMRHandle();
    void (*getClient)(dispatch_queue_t, void (^)(id)) =
        h ? dlsym(h, "MRMediaRemoteGetNowPlayingClient") : NULL;
    NSString *(*getBundle)(id) = h ? dlsym(h, "MRNowPlayingClientGetBundleIdentifier") : NULL;
    NSString *(*getParent)(id) = h ? dlsym(h, "MRNowPlayingClientGetParentAppBundleIdentifier") : NULL;
    if (!getClient || (!getBundle && !getParent)) return; // can't tell → keep last value (fail open)
    getClient(dispatch_get_main_queue(), ^(id client) {
        NSString *bid = (client && getBundle) ? getBundle(client) : nil;
        if (!bid && client && getParent) bid = getParent(client);
        NUSource src = NUSourceForBundleID(bid);
        if (src != self.source) {
            self.source = src;
            NULog("client: now-playing app='%{public}@' source=%ld", bid, (long)src);
            [self postChange];
            [self query]; // pull the new source's snapshot immediately
        }
    });
}

- (void)playNextTrack {
    if (!self.active) return;
    // iOS 17+ Podcasts maps the MediaRemote NextTrack command to a 30s skip, not "advance to the
    // next episode" (iOS 16 and earlier still advance, verified on-device). Signal the Podcasts
    // provider to jump directly to the next item's content id instead — iOS 17 via the MT*
    // playback-queue controller, iOS 18 via MPCQueueController. Music and pre-17 Podcasts keep the
    // MR NextTrack command.
    if (self.source == NUSourcePodcasts &&
        NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 17) {
        notify_post(kNUJumpNotificationPodcasts);
        return;
    }
    // YouTube Music drives transport through its own player; jump its queue to the shown next item
    // directly (-playItemAtIndex:) rather than relying on the MediaRemote NextTrack mapping.
    if (self.source == NUSourceYouTubeMusic) {
        notify_post(kNUJumpNotificationYouTubeMusic);
        return;
    }
    Boolean (*send)(unsigned int, id) = NUSendMRCommand();
    if (send) send(4 /* kMRMediaRemoteCommandNextTrack */, nil);
}

// Enqueue the previous track to play NEXT (Apple Music's "Play Next"), leaving the
// current track playing. We do this from the display — a media *client* — via the
// public MPMusicPlayerController queue API; the same call deadlocks inside Music
// itself, but from here it reaches Music's live queue by the track's store id.
- (void)playPreviousTrack {
    if (!self.active || !self.canPrevious) return;
    // Provider-side enqueue (e.g. Podcasts): the enqueue API is in-process, so just signal
    // the provider to re-queue the previous item itself (no adamID / MPMusicPlayer path).
    const char *prevNote = NUPrevNotificationForSource(self.source);
    if (prevNote) { notify_post(prevNote); return; }
    // Otherwise fall through to the Music display-side "Play Next" via a store id.
    if (self.backAdamID.length == 0) return;
    // Enqueue the previous track to play next. Needs the NUMediaTCC usage-description
    // injection on iOS 16 (see hooks/NUHooksTCC.x). Runs in MediaRemoteUI (lock screen)
    // and SpringBoard (Control Center).
    @try {
        Class DescClass = objc_getClass("MPMusicPlayerStoreQueueDescriptor");
        Class CtrlClass = objc_getClass("MPMusicPlayerController");
        MPMusicPlayerStoreQueueDescriptor2 *desc = [[DescClass alloc] initWithStoreIDs:@[ self.backAdamID ]];
        MPMusicPlayerController2 *player = [CtrlClass systemMusicPlayer];
        [player prependQueueDescriptor:desc]; // iOS-17 path; TCC bypass in NUMediaTCC
        NULog("client: play-next enqueued adam=%{public}@ ('%{public}@')", self.backAdamID, self.backTitle);
        // Staggered re-queries: the provider may still be assembling artwork after the
        // first "changed" signal; three spaced retries cover the observed settle window.
        for (NSNumber *delay in @[ @0.35, @0.7, @1.2 ]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [self query]; });
        }
    } @catch (NSException *e) {
        NULog("client: play-next threw %{public}@ :: %{public}@", e.name, e.reason);
    }
}

- (void)postChange {
    [[NSNotificationCenter defaultCenter] postNotificationName:NUNextUpDidChangeNotification object:self];
}

@end
