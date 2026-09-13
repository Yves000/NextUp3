#import "NUSoundCloudProvider.h"
#import "NUShared.h"
#import "LightMessaging.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

// Private SoundCloud interfaces (SoundCloud 8.75.0). Recovered statically from the decrypted IPA.
//
// Everything here is declared, never implemented: the app supplies it. SoundCloud is a
// third-party app that updates on its own schedule, so every cross-version call below is guarded
// by -respondsToSelector: and/or @try — an app update must degrade to a blank row, never a crash.
//
// These are protocols rather than @interfaces on purpose: the concrete types are Swift classes
// with mangled runtime names (and `Urn` is a name generic enough to collide), and we only ever
// message objects the app hands us. A protocol declares the selectors without claiming a name.
#pragma mark - Private SoundCloud interfaces

// SCFoundation.Urn — the stable identity of a track. Used as the artwork cache key.
@protocol NUSCUrn <NSObject>
@property (readonly, nonatomic) NSString *stringValue;
@end

// Middleware.PlayQueueItem (+ the PlayQueueItemTrack refinement, whose members are marked below).
// Every one of these is an @objc property, so the whole snapshot is a plain ObjC read.
@protocol NUSCPlayQueueItem <NSObject>
@property (readonly, nonatomic) id<NUSCUrn> urn;
@property (readonly, copy, nonatomic) NSString *title;
@property (readonly, copy, nonatomic) NSString *artistName;
@property (readonly, copy, nonatomic) NSURL *artworkURL;
@property (readonly, nonatomic) long long itemType;
// PlayQueueItemTrack only — a bare PlayQueueItem (e.g. an ad) does not carry these.
@property (readonly, copy, nonatomic) NSString *imageUrlTemplate;
@property (readonly, nonatomic) BOOL isPlayable;
@end

// Playback.MutablePlayQueue, implemented by Playback.PlayerItemQueue. -addWithItems:… is the ONLY
// @objc write on the whole queue stack, and it is what the 'previous' re-queue goes through.
// `currentItem` is matched by POINTER IDENTITY inside PlayQueueStore.add — hand it the very object
// the service just returned, or the call silently does nothing.
@protocol NUSCPlayQueue <NSObject>
- (void)addWithItems:(NSArray *)items
            position:(NSInteger)position
         currentItem:(id)currentItem
         uiComponent:(id)uiComponent;
@end

// Playback.PlayQueueManager — whichever of Basic/Ad/GoogleCast is live. We only need it as the
// route to the mutable queue; every read goes through the service instead.
@protocol NUSCPlayQueueManager <NSObject>
@property (readonly, nonatomic) id<NUSCPlayQueue> playQueue;
@end

// Playback.PlaybackService. An @objc NSObject subclass with a real +sharedInstance; it owns the
// live PlayQueueManager and forwards the queue accessors to it, which is exactly why we talk to
// the service and never to a manager class.
@protocol NUSCPlaybackService <NSObject>
@property (readonly, nonatomic) id<NUSCPlayQueueItem> currentPlayQueueItem;
@property (readonly, nonatomic) id<NUSCPlayQueueManager> playQueueManager;
@property (nonatomic) long long repeatMode;
- (id<NUSCPlayQueueItem>)playQueueItemAfter:(id)item;
- (id<NUSCPlayQueueItem>)playQueueItemBefore:(id)item;
// PlayQueueSkipInteracting. The interaction is a __C.PlayQueueInteraction; 3 is what the app's own
// -[RemoteCommandCenter handleNextTrackCommand:] passes, and it is the value that makes
// moveToNextItem take the *playable*-item lookup. 0 reads as "unknown", 1/2 as "starting a new
// queue" — neither is what a lock-screen tap means.
- (void)jumpToItem:(id)item withInteraction:(NSUInteger)interaction;
@end

#pragma mark - Constants

// Middleware.PlayQueueItemType raw values. Decoded from -description's jump table and confirmed
// against -isAd, which is literally `(raw & ~1) == 2`.
typedef NS_ENUM(long long, NUSCItemType) {
    NUSCItemTypeProxy   = 0,   // placeholder for a not-yet-loaded entry
    NUSCItemTypeTrack   = 1,
    NUSCItemTypeAudioAd = 2,
    NUSCItemTypeVideoAd = 3,
};

// Middleware.NextUpTrackAddPosition. The enum has exactly two cases (its init(rawValue:) rejects
// anything above 1), and PlayQueueStore.add reads them as: 0 → insert at currentIndex + 1, i.e.
// immediately after the playing track; 1 → after the manually-queued region, before the autoplay
// tail. We want 0. Anything else traps in Swift, so this must never be a guess at runtime.
static const NSInteger kNUSCAddPositionNext = 0;

// __C.PlayQueueInteraction. Read out of the app's own -[RemoteCommandCenter handleNextTrackCommand:],
// which loads w2 = 3 before calling the service — i.e. exactly the "transport control outside the
// app" case a Lock Screen / Control Center tap is.
static const NSUInteger kNUSCInteractionRemoteCommand = 3;

// Playback.PlaybackRepeatMode: 0 = off, 1 = one, 2 = all (determined on-device; the reflection
// field order in Middleware is NOT the raw-value order). Repeating one track means the queue never
// advances, so there is no "next up" to show even though playQueueItemAfter: still reports the
// untouched next queue entry.
static const long long kNUSCRepeatOne = 1;

// How far to walk past ads / placeholders before giving up. A free account gets at most a couple
// of consecutive ad entries; the cap exists so a repeat-mode queue that cycles cannot spin here.
static const int kNUSCMaxWalk = 8;

// The CDN size token substituted into imageUrlTemplate's `{size}` placeholder. The row's artwork
// is ~120pt, i.e. 360px at @3x, so the 500px square is the smallest one that never upscales.
static NSString *const kNUSCArtworkSize = @"t500x500";

#pragma mark - Item helpers

// Is this a real, showable track? Ads and proxy placeholders are genuine queue entries on a free
// account, and showing one as "up next" would be worse than showing nothing.
static BOOL NUSCIsRealTrack(id<NUSCPlayQueueItem> item) {
    if (!item) return NO;
    @try {
        if (![item respondsToSelector:@selector(itemType)]) return NO;
        if (item.itemType != NUSCItemTypeTrack) return NO;
        // isPlayable is PlayQueueItemTrack-only and false for geo-blocked / removed uploads;
        // a missing selector must not disqualify the track.
        if ([item respondsToSelector:@selector(isPlayable)] && !item.isPlayable) return NO;
    } @catch (__unused NSException *e) { return NO; }
    return YES;
}

static NSString *NUSCItemKey(id<NUSCPlayQueueItem> item) {
    if (!item) return nil;
    @try {
        id<NUSCUrn> urn = item.urn;
        if ([urn respondsToSelector:@selector(stringValue)]) return urn.stringValue;
    } @catch (__unused NSException *e) {}
    return nil;
}

// Cover URL. imageUrlTemplate is the app's `https://i1.sndcdn.com/artworks-…-{size}.jpg` form,
// which lets us pick the resolution; artworkURL is whatever size the app already resolved, so it
// is only the fallback.
static NSURL *NUSCArtworkURL(id<NUSCPlayQueueItem> item) {
    if (!item) return nil;
    @try {
        if ([item respondsToSelector:@selector(imageUrlTemplate)]) {
            NSString *tpl = item.imageUrlTemplate;
            if (tpl.length) {
                NSString *s = [tpl stringByReplacingOccurrencesOfString:@"{size}"
                                                             withString:kNUSCArtworkSize];
                NSURL *u = [NSURL URLWithString:s];
                if (u) return u;
            }
        }
    } @catch (__unused NSException *e) {}
    @try {
        if ([item respondsToSelector:@selector(artworkURL)]) return item.artworkURL;
    } @catch (__unused NSException *e) {}
    return nil;
}

#pragma mark - Skip (the one operation with no @objc path)

// Playback's entire @objc queue surface is add-only, so removing the upcoming track means calling
// Swift directly. The target is Playback.NewPlayQueueNextUp.removeItem(fromSection:row:) — the
// app's OWN removal path (what the Next Up screen's swipe-to-delete drives), so it handles repeat
// mode and republishes through the store the same way the app does. Every symbol it needs is an
// exported `T`, so dlsym reaches them; clang's swiftcall attributes express the ABI (self in the
// context register x20, the error slot in x21) without hand-written assembly.
//
// Two hard constraints, both read out of the disassembly:
//   - `row` out of range TRAPS (brk #1) rather than throwing, so a section must be proven
//     non-empty before we index into it.
//   - only .next (2) and .autoplay (3) are accepted; every other section throws.
//
// Anything unresolvable here leaves gSCSkipReady NO, which reports canSkip = NO to the display —
// a SoundCloud update that renames these symbols costs the skip button, never a crash.

typedef NS_ENUM(uint8_t, NUSCSection) {
    NUSCSectionNext     = 2,
    NUSCSectionAutoplay = 3,
};

typedef void *(*NUSCMetaFn)(long request);
typedef void *(*NUSCInitFn)(void *meta __attribute__((swift_context))) __attribute__((swiftcall));
typedef void *(*NUSCArrayGetFn)(void *ctx __attribute__((swift_context))) __attribute__((swiftcall));
typedef void *(*NUSCRemoveFn)(uint8_t section, long row,
                              void *ctx __attribute__((swift_context)),
                              void **err __attribute__((swift_error_result))) __attribute__((swiftcall));

static NUSCMetaFn     gSCMeta;
static NUSCInitFn     gSCInit;
static NUSCArrayGetFn gSCNextGet;
static NUSCArrayGetFn gSCAutoplayGet;
static NUSCRemoveFn   gSCRemove;
static void (*gSCArrayRelease)(void *);
static void (*gSCErrorRelease)(void *);
static BOOL gSCSkipReady;

static void NUSCResolveSkipSymbols(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gSCMeta         = (NUSCMetaFn)dlsym(RTLD_DEFAULT, "$s8Playback18NewPlayQueueNextUpCMa");
        gSCInit         = (NUSCInitFn)dlsym(RTLD_DEFAULT, "$s8Playback18NewPlayQueueNextUpCACycfC");
        gSCNextGet      = (NUSCArrayGetFn)dlsym(RTLD_DEFAULT,
            "$s8Playback18NewPlayQueueNextUpC4nextSay10Middleware0cD9ItemTrack_pGvg");
        gSCAutoplayGet  = (NUSCArrayGetFn)dlsym(RTLD_DEFAULT,
            "$s8Playback18NewPlayQueueNextUpC8autoplaySay10Middleware0cD9ItemTrack_pGvg");
        gSCRemove       = (NUSCRemoveFn)dlsym(RTLD_DEFAULT,
            "$s8Playback18NewPlayQueueNextUpC10removeItem11fromSection3row12SCFoundation3UrnCAC0J0O_SitKF");
        gSCArrayRelease = (void (*)(void *))dlsym(RTLD_DEFAULT, "swift_bridgeObjectRelease");
        gSCErrorRelease = (void (*)(void *))dlsym(RTLD_DEFAULT, "swift_errorRelease");
        gSCSkipReady = (gSCMeta && gSCInit && gSCNextGet && gSCAutoplayGet && gSCRemove
                        && gSCArrayRelease);
        NULog("soundcloud skip: symbols %{public}@ (meta=%p init=%p next=%p autoplay=%p remove=%p)",
              gSCSkipReady ? @"resolved" : @"MISSING",
              gSCMeta, gSCInit, gSCNextGet, gSCAutoplayGet, gSCRemove);
    });
}

// Swift's Array is one pointer to its buffer. For a natively allocated buffer the object header is
// followed by the element count at +0x10. A tagged pointer or a lazily-bridged NSArray sets the
// discriminator bits — we refuse to read those rather than guess at a foreign layout, which just
// means the skip no-ops that once.
static BOOL NUSCSwiftArrayCount(void *array, long *outCount) {
    uintptr_t bo = (uintptr_t)array;
    if (!bo) return NO;
    if (bo & 0xC000000000000001ULL) return NO;
    long n = *(long *)(bo + 0x10);
    if (n < 0 || n > 100000) return NO;   // implausible → we are not looking at a count
    *outCount = n;
    return YES;
}

// The view model is a live view over PlaybackService (its only stored state is that service, a UI
// launcher and Combine subscriptions), so one instance is built lazily on the first skip and kept:
// its init installs subscriptions, and churning instances would churn those too.
// Held as a raw pointer, not an `id`: Swift's __allocating_init returns the instance at +1, so
// keeping the raw pointer keeps exactly that one reference for the process lifetime, with no ARC
// retain/release racing Swift's own count.
static void *NUSCNextUpViewModel(void) {
    static void *vm;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *meta = gSCMeta(0);
        if (!meta) { NULog("soundcloud skip: metadata accessor returned null"); return; }
        vm = gSCInit(meta);
        NULog("soundcloud skip: view model %p", vm);
    });
    return vm;
}

#pragma mark - Provider

@interface NUSoundCloudProvider ()
// Not cached: +sharedInstance is a dispatch_once accessor, and holding the service would only
// risk pinning a stale one across an account switch.
@property (nonatomic, readonly) id<NUSCPlaybackService> service;
@property (nonatomic) BOOL observing;
@property (nonatomic, copy) NSString *lastSignature;
@end

@implementation NUSoundCloudProvider

+ (instancetype)shared {
    static NUSoundCloudProvider *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [NUSoundCloudProvider new]; });
    return s;
}

- (NSString *)appPrefKey { return @"enabledSoundCloud"; }

// Resolved lazily, never from a %ctor: +sharedInstance's swift_once initialiser reads
// PlaybackModule.dependencies, so forcing it before the app has bootstrapped would build the
// service against an empty dependency bag.
- (id<NUSCPlaybackService>)service {
    Class cls = objc_getClass("_TtC8Playback15PlaybackService");
    if (!cls || ![cls respondsToSelector:@selector(sharedInstance)]) return nil;
    @try {
        return [cls performSelector:@selector(sharedInstance)];
    } @catch (NSException *e) {
        NULog("soundcloud: sharedInstance threw %{public}@", e.name);
        return nil;
    }
}

#pragma mark - Queue reading

- (id<NUSCPlayQueueItem>)currentItem {
    id<NUSCPlaybackService> svc = self.service;
    if (![svc respondsToSelector:@selector(currentPlayQueueItem)]) return nil;
    @try { return svc.currentPlayQueueItem; } @catch (__unused NSException *e) { return nil; }
}

// Walk forwards (or backwards) from `item` to the next REAL track, stepping over ads and proxy
// placeholders. nil `item` means "from the current track".
- (id<NUSCPlayQueueItem>)realItemFrom:(id<NUSCPlayQueueItem>)item forward:(BOOL)forward {
    id<NUSCPlaybackService> svc = self.service;
    SEL sel = forward ? @selector(playQueueItemAfter:) : @selector(playQueueItemBefore:);
    if (![svc respondsToSelector:sel]) return nil;
    id<NUSCPlayQueueItem> cur = item ?: [self currentItem];
    if (!cur) return nil;
    for (int i = 0; i < kNUSCMaxWalk; i++) {
        id<NUSCPlayQueueItem> nxt = nil;
        @try {
            nxt = forward ? [svc playQueueItemAfter:cur] : [svc playQueueItemBefore:cur];
        } @catch (__unused NSException *e) { return nil; }
        if (!nxt || nxt == cur) return nil;      // end of queue, or a self-referencing entry
        if (NUSCIsRealTrack(nxt)) return nxt;
        cur = nxt;
    }
    return nil;
}

// {title, subtitle, key, item, artwork?}, or nil when the entry carries no usable metadata.
- (NSDictionary *)infoForItem:(id<NUSCPlayQueueItem>)item {
    if (!item) return nil;
    NSString *title = nil, *artist = nil;
    @try { title = item.title; artist = item.artistName; } @catch (__unused NSException *e) {}
    NSString *key = NUSCItemKey(item);
    if (title.length == 0 || key.length == 0) return nil;

    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"title"] = title;
    d[@"subtitle"] = artist ?: @"";
    d[@"key"] = key;
    d[@"item"] = item;
    NSData *art = [self cachedArtworkForKey:key];
    if (art) d[@"artwork"] = art;
    return d;
}

#pragma mark - Artwork (async CDN fetch, cached by urn — cache lives in NUProviderBase)

- (void)prefetchArtworkFor:(NSDictionary *)info {
    NSString *key = info[@"key"];
    id<NUSCPlayQueueItem> item = info[@"item"];
    if (key.length == 0 || !item) return;
    if ([self cachedArtworkForKey:key]) return;         // a track's cover never changes
    if ([self artworkFetchInFlightForKey:key]) return;  // already fetching
    NSURL *url = NUSCArtworkURL(item);
    if (url) [self fetchArtworkAtURL:url forKey:key];
}

// The on-screen next/fwd/back window the base prune must never evict.
- (NSArray<NSString *> *)artworkKeysToProtect {
    NSMutableArray *keys = [NSMutableArray array];
    id<NUSCPlayQueueItem> next = [self realItemFrom:nil forward:YES];
    NSString *k = NUSCItemKey(next);
    if (k) [keys addObject:k];
    if (next) {
        NSString *f = NUSCItemKey([self realItemFrom:next forward:YES]);
        if (f) [keys addObject:f];
    }
    NSString *p = NUSCItemKey([self realItemFrom:nil forward:NO]);
    if (p) [keys addObject:p];
    return keys;
}

#pragma mark - Snapshot (same wire shape as the other providers)

- (NSDictionary *)nextUpDictionary {
    if (![self providerEnabled]) return @{ kNUKeyActive : @NO }; // disabled → no queue/artwork work

    // Repeat-one loops the current track forever: nothing is up next, so the row must go.
    id<NUSCPlaybackService> svc = self.service;
    long long repeat = -1;
    if ([svc respondsToSelector:@selector(repeatMode)]) {
        @try { repeat = svc.repeatMode; } @catch (__unused NSException *e) {}
    }

    id<NUSCPlayQueueItem> next = [self realItemFrom:nil forward:YES];
    NSDictionary *nextInfo = [self infoForItem:next];
    NULog("soundcloud snapshot: current='%{public}@' next='%{public}@' repeat=%lld",
          NUSCItemKey([self currentItem]), nextInfo[@"title"] ?: @"(none)", repeat);
    if (repeat == kNUSCRepeatOne) return @{ kNUKeyActive : @NO };
    if (!nextInfo) return @{ kNUKeyActive : @NO };
    [self prefetchArtworkFor:nextInfo];

    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[kNUKeyActive] = @YES;
    dict[kNUKeyTitle] = nextInfo[@"title"];
    dict[kNUKeySubtitle] = nextInfo[@"subtitle"];
    if (nextInfo[@"artwork"]) dict[kNUKeyArtwork] = nextInfo[@"artwork"];
    // Skip goes through Swift (see -skipNext); if those symbols didn't resolve the row drops
    // its skip button rather than offering one that does nothing.
    NUSCResolveSkipSymbols();
    dict[kNUKeyCanSkip] = @(gSCSkipReady);

    // Forward carousel neighbour (what the row shows sliding in behind the next track).
    NSDictionary *fwdInfo = [self infoForItem:[self realItemFrom:next forward:YES]];
    if (fwdInfo) {
        [self prefetchArtworkFor:fwdInfo];
        dict[kNUKeyFwdTitle] = fwdInfo[@"title"];
        dict[kNUKeyFwdSubtitle] = fwdInfo[@"subtitle"];
        if (fwdInfo[@"artwork"]) dict[kNUKeyFwdArtwork] = fwdInfo[@"artwork"];
    }
    // Previously-played track (back card), re-queued on a right swipe via -playPrevious.
    NSDictionary *backInfo = [self infoForItem:[self realItemFrom:nil forward:NO]];
    dict[kNUKeyCanPrev] = @(backInfo != nil);
    if (backInfo) {
        [self prefetchArtworkFor:backInfo];
        dict[kNUKeyBackTitle] = backInfo[@"title"];
        dict[kNUKeyBackSubtitle] = backInfo[@"subtitle"];
        if (backInfo[@"artwork"]) dict[kNUKeyBackArtwork] = backInfo[@"artwork"];
    }
    return dict;
}

#pragma mark - Actions (run on the main queue via the notify handlers)

// Remove the upcoming track WITHOUT disturbing what is playing. Picks the section the next track
// lives in — user-queued items are in .next, algorithmic suggestions in .autoplay — proving it
// non-empty first (see above: an out-of-range row traps).
- (void)skipNext {
    if (![self providerEnabled]) return;
    NUSCResolveSkipSymbols();
    if (!gSCSkipReady) { NULog("soundcloud skip: unavailable"); return; }

    void *vm = NUSCNextUpViewModel();
    if (!vm) { NULog("soundcloud skip: no view model"); return; }

    // Probe .next first: it is the user-queued region, and it is what the row shows whenever the
    // user has queued anything at all.
    NUSCSection section;
    long count = 0;
    void *arr = gSCNextGet(vm);
    BOOL ok = NUSCSwiftArrayCount(arr, &count);
    if (arr) gSCArrayRelease(arr);
    if (!ok) { NULog("soundcloud skip: next section unreadable"); return; }
    if (count > 0) {
        section = NUSCSectionNext;
    } else {
        arr = gSCAutoplayGet(vm);
        ok = NUSCSwiftArrayCount(arr, &count);
        if (arr) gSCArrayRelease(arr);
        if (!ok || count == 0) { NULog("soundcloud skip: both sections empty/unreadable"); return; }
        section = NUSCSectionAutoplay;
    }

    void *err = NULL;
    void *removed = gSCRemove((uint8_t)section, 0, vm, &err);
    if (err) {
        // The error is owned and is a SwiftError box, not a bridge object — swift_errorRelease,
        // not the array release. Only an invalid section throws, and we never pass one.
        NULog("soundcloud skip: removeItem threw");
        if (gSCErrorRelease) gSCErrorRelease(err);
        return;
    }
    // The returned Urn is +1 and is an NSObject subclass, so balance it.
    NULog("soundcloud skip: removed row 0 of section %d", (int)section);
    if (removed) CFRelease((CFTypeRef)removed);
    [self changedSoon];
}

// Play the shown next-up track NOW (the cover tap). The MediaRemote NextTrack command does not
// reliably advance the queue or fire the delegate callback (see kNUJumpNotificationSoundCloud),
// so jump the queue directly — to the exact item displayed, so the tap can never land on a
// different track than the one on screen.
- (void)jumpToNext {
    if (![self providerEnabled]) return;
    id<NUSCPlayQueueItem> next = [self realItemFrom:nil forward:YES];
    if (!next) { NULog("soundcloud jump: no next track"); return; }
    id<NUSCPlaybackService> svc = self.service;
    if (![svc respondsToSelector:@selector(jumpToItem:withInteraction:)]) {
        NULog("soundcloud jump: API missing");
        return;
    }
    @try {
        [svc jumpToItem:next withInteraction:kNUSCInteractionRemoteCommand];
        NULog("soundcloud jump: playing '%{public}@'", NUSCItemKey(next));
    } @catch (NSException *e) {
        NULog("soundcloud jump threw %{public}@", e.name);
        return;
    }
    [self changedSoon];
}

// Re-queue the previously-played track to play NEXT, leaving the current track playing (the
// "Play Next" semantic the display's right swipe means).
//
// NOT via -addSourceNextUp:position:, which is the obvious-looking route: that wants a
// Middleware.PlayQueueInsertionSource (an async fetch protocol whose result type has Swift-only
// constructors), while the ObjC bridge factory next to it vends a PlayQueueSource for STARTING a
// queue — different protocol. The insert that is genuinely reachable from ObjC is the mutable
// queue's own -addWithItems:…, which is also what the mutator ends up calling.
- (void)playPrevious {
    if (![self providerEnabled]) return;
    id<NUSCPlayQueueItem> prev = [self realItemFrom:nil forward:NO];
    if (!prev) { NULog("soundcloud prev: no history"); return; }

    id<NUSCPlaybackService> svc = self.service;
    id<NUSCPlayQueueItem> cur = [self currentItem];
    if (!cur || ![svc respondsToSelector:@selector(playQueueManager)]) {
        NULog("soundcloud prev: no current item / manager");
        return;
    }

    @try {
        id<NUSCPlayQueue> queue = svc.playQueueManager.playQueue;
        if (![queue respondsToSelector:@selector(addWithItems:position:currentItem:uiComponent:)]) {
            NULog("soundcloud prev: mutable queue API missing");
            return;
        }
        // Copy: the queue is searched by pointer identity in several places, so re-inserting the
        // very same object would put one instance at two indices. PlayQueueItemTrack is NSCopying.
        [queue addWithItems:@[ [(id)prev copy] ]
                   position:kNUSCAddPositionNext
                currentItem:cur          // matched by pointer identity; a stale one = silent no-op
                uiComponent:nil];
        NULog("soundcloud prev: enqueued '%{public}@' to play next", NUSCItemKey(prev));
    } @catch (NSException *e) {
        NULog("soundcloud prev threw %{public}@", e.name);
        return;
    }
    [self changedSoon];
}

#pragma mark - Change signal

// SoundCloud's own NSNotifications are the primary signal, NOT the @objc hooks in
// NUHooksSoundCloudProvider.x: PlaybackService is a Swift class, so its internal assignments to
// `currentPlayQueueItem` write the stored property directly and never reach the @objc setter
// thunk we hook.
//
// Notifications don't have that problem: they go through NSNotificationCenter, which is ObjC for
// everyone. Names are read from the app's own class methods where it exposes them, because the
// literal pool carries both bare and "PlaybackService"-prefixed spellings and guessing wrong is
// silent. The literals are the fallback.
- (void)observeQueueNotifications {
    if (self.observing) return;
    self.observing = YES;

    NSMutableSet<NSString *> *names = [NSMutableSet set];
    void (^addFrom)(Class, NSString *) = ^(Class cls, NSString *selName) {
        SEL sel = NSSelectorFromString(selName);
        if (!cls || ![cls respondsToSelector:sel]) return;
        @try {
            // Typed objc_msgSend rather than -performSelector:, which ARC cannot reason about
            // for a selector built at runtime (-Warc-performSelector-leaks).
            NSString *(*getName)(Class, SEL) = (NSString *(*)(Class, SEL))objc_msgSend;
            NSString *n = getName(cls, sel);
            if ([n isKindOfClass:NSString.class] && n.length) [names addObject:n];
        } @catch (__unused NSException *e) {}
    };
    addFrom(objc_getClass("_TtC8Playback15PlayerItemQueue"), @"didChangeNotification");
    Class svc = objc_getClass("_TtC8Playback15PlaybackService");
    addFrom(svc, @"PlayQueueChangedNotification");
    addFrom(svc, @"PlaybackItemChangedNotification");
    addFrom(svc, @"PlaySessionChangedNotification");

    if (names.count == 0) {
        [names addObjectsFromArray:@[ @"PlayQueueDidChangeNotification",
                                      @"PlaybackItemChangedNotification" ]];
        NULog("soundcloud: no notification-name accessors, using literals");
    }
    for (NSString *n in names) {
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(queueChanged)
                                                   name:n
                                                 object:nil];
        NULog("soundcloud: observing '%{public}@'", n);
    }
}

// May arrive on any thread (the notifications are posted from whatever advanced the queue), and
// every read below is main-queue-confined like the LM server's. The change can also land before
// the queue has settled, which is what -changedSoon's second, delayed post covers.
- (void)queueChanged {
    if (!self.serverStarted) return;
    dispatch_async(dispatch_get_main_queue(), ^{ [self changedSoon]; });
}

// Same signal, but deduplicated — for callers that fire far more often than the queue actually
// changes. -[MPNowPlayingInfoCenter setNowPlayingInfo:] is the only dependable track-TRANSITION
// hook this app offers (the delegate callback covers queue edits, not transitions — see
// NUHooksSoundCloudProvider.x), but it is also re-sent for elapsed-time updates roughly once a
// second, and signalling on each of those would have the display re-query continuously.
//
// The signature covers both what is playing and what is next, so it moves on a transition AND on
// a queue edit that leaves the current track alone.
- (void)signalIfChanged {
    if (!self.serverStarted || ![self providerEnabled]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *cur = NUSCItemKey([self currentItem]) ?: @"-";
        NSString *nxt = NUSCItemKey([self realItemFrom:nil forward:YES]) ?: @"-";
        NSString *sig = [cur stringByAppendingFormat:@"|%@", nxt];
        if ([sig isEqualToString:self.lastSignature]) return;
        self.lastSignature = sig;
        NULog("soundcloud: queue moved (%{public}@)", sig);
        [self changedSoon];
    });
}

#pragma mark - LightMessaging server (SoundCloud registers the service via libSandy)

- (void)startServer {
    [self startServerWithService:kNUServiceNameSoundCloud
                            skip:kNUSkipNotificationSoundCloud
                            prev:kNUPrevNotificationSoundCloud
                            jump:kNUJumpNotificationSoundCloud];
    // Deferred: the notification-name accessors live on Playback classes that may still be
    // initialising when the hooks arm, and observing is pointless before the server is up anyway.
    dispatch_async(dispatch_get_main_queue(), ^{ [self observeQueueNotifications]; });
}

@end
