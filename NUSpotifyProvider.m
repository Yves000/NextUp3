#import "NUSpotifyProvider.h"
#import "NUShared.h"
#import "LightMessaging.h"
#import <notify.h>
#import <UIKit/UIKit.h>

// Private Spotify interfaces (Spotify 9.1.62). Recovered statically from the decrypted IPA.
//
// Everything here is declared, never implemented: the app supplies it. Spotify is a third-party
// app that updates on its own schedule, so every cross-version call below is guarded by
// -respondsToSelector: and/or @try — a Spotify update must degrade to a blank row, never a crash.
#pragma mark - Private Spotify interfaces

// How much history / lookahead to ask the core for. The state handed to a plain observer can carry
// an empty `reverse`, so we always re-fetch with explicit caps (that is what the reverseCap: /
// futureCap: variant exists for). 2 back = the back card; 4 forward = next + the fwd card with
// room for delimiter pseudo-entries in between.
static const unsigned long long kNUSpotifyReverseCap = 2;
static const unsigned long long kNUSpotifyFutureCap  = 4;

// Artwork side length in points; Spotify maps it onto one of its CDN's fixed sizes.
static const double kNUSpotifyArtworkPt = 120.0;

// title/artist/imageURL are all derived from the track's `metadata` dict (via Spotify's
// NSDictionary (IDZKAdditions) category), so a track the core hasn't filled in yet reads blank.
@interface SPTPlayerTrack : NSObject
@property (readonly, copy, nonatomic) NSURL *URI;
@property (copy, nonatomic) NSString *UID;      // per-queue-slot identity (a URI can repeat)
@property (readonly, nonatomic) NSString *trackTitle;
@property (readonly, nonatomic) NSString *artistName;
@property (readonly, nonatomic) NSURL *imageURL; // spotify:image:<hex>
@end

@interface SPTPlayerState : NSObject
@property (retain, nonatomic) SPTPlayerTrack *track;              // currently playing
@property (copy, nonatomic) NSArray<SPTPlayerTrack *> *future;   // upcoming, [0] = next
@property (copy, nonatomic) NSArray<SPTPlayerTrack *> *reverse;  // history, [0] = most recent
@property (copy, nonatomic) NSString *queueRevision;
@end

// The mutable queue object. `nextTracks` is settable, and `revision` is an optimistic-concurrency
// token the core validates on write — so a queue edit must be read-modify-write on a freshly
// fetched object, never a hand-built one.
@protocol SPTPlayerQueue <NSObject>
@property (copy, nonatomic) NSArray<SPTPlayerTrack *> *nextTracks;
@property (copy, nonatomic) NSString *revision;
@end

@protocol SPTPlayer <NSObject>
@property (readonly, copy, nonatomic) SPTPlayerState *state;
- (void)fetchQueue:(void (^)(id<SPTPlayerQueue> queue))block on:(dispatch_queue_t)on;
- (id)setQueue:(id)queue;
- (void)addPlayerObserver:(id)observer;
- (void)removePlayerObserver:(id)observer;
- (void)fetchState:(void (^)(SPTPlayerState *state))block
        reverseCap:(unsigned long long)reverseCap
         futureCap:(unsigned long long)futureCap
                on:(dispatch_queue_t)on;
@end

@protocol SPTPlayerObserver <NSObject>
@optional
- (void)player:(id)player stateDidChange:(id)state;
- (void)player:(id)player stateDidChange:(id)state fromState:(id)fromState;
@end

// Spotify's DI service that vends players. It keeps a dedicated observation player
// (-loadObservationPlayer) wired to the core, which is why -addPlayerObserver: here is more
// reliable than observing an arbitrary feature player.
@interface SPTPlayerServiceImplementation : NSObject
- (id)providePlayerWithViewURI:(id)uri featureIdentifier:(id)identifier;
- (void)addPlayerObserver:(id)observer;
- (void)removePlayerObserver:(id)observer;
- (void)fetchPlayerState:(void (^)(SPTPlayerState *state))block on:(dispatch_queue_t)on;
@end

// NSURL (BetamaxSDK) — Spotify's own URI helpers, implemented in the app binary.
@interface NSURL (NUSpotifyBetamax)
+ (id)spt_HTTPURLForImageWithSpotifyLink:(id)link size:(unsigned long long)size;
+ (unsigned long long)spt_optimalCDNImageSizeForSideInPoints:(double)points screenScale:(double)scale;
- (BOOL)spt_isDelimiter;
- (BOOL)spt_isMetaTrack;
@end

#pragma mark - Track helpers

static BOOL NUSameStr(NSString *a, NSString *b) { return a == b || [a isEqualToString:b]; }

// Spotify's up-next list is NOT all songs: the core splices in `spotify:delimiter` and
// `spotify:meta:*` pseudo-entries (they mark the queued/context boundary and similar). Showing or
// skipping one would be a bug, so every read filters them out. Prefer Spotify's own predicates;
// the literal check is the fallback if a future version drops the category.
static BOOL NUSpotifyIsRealTrack(SPTPlayerTrack *track) {
    if (!track) return NO;
    NSURL *uri = nil;
    @try { uri = track.URI; } @catch (__unused NSException *e) { return NO; }
    if (!uri) return NO;
    @try {
        if ([uri respondsToSelector:@selector(spt_isDelimiter)] && [uri spt_isDelimiter]) return NO;
        if ([uri respondsToSelector:@selector(spt_isMetaTrack)] && [uri spt_isMetaTrack]) return NO;
    } @catch (__unused NSException *e) {}
    NSString *s = uri.absoluteString;
    if ([s hasPrefix:@"spotify:delimiter"] || [s hasPrefix:@"spotify:meta:"]) return NO;
    return YES;
}

static NSString *NUSpotifyTrackURI(SPTPlayerTrack *t) {
    @try { return t.URI.absoluteString; } @catch (__unused NSException *e) { return nil; }
}
static NSString *NUSpotifyTrackUID(SPTPlayerTrack *t) {
    @try { return t.UID; } @catch (__unused NSException *e) { return nil; }
}

// The public CDN URL for a track's cover. -imageURL is a `spotify:image:<hex>` URI whose hex
// prefix encodes the size, so Spotify's helper (which rewrites that prefix) is preferred; the
// manual rewrite is the fallback and yields whatever size the metadata already names.
static NSURL *NUSpotifyArtworkURL(SPTPlayerTrack *track) {
    NSURL *link = nil;
    @try { link = track.imageURL; } @catch (__unused NSException *e) {}
    if (!link) return nil;
    if ([link.scheme hasPrefix:@"http"]) return link; // already a CDN URL

    unsigned long long size = 0;
    @try {
        if ([NSURL respondsToSelector:@selector(spt_optimalCDNImageSizeForSideInPoints:screenScale:)]) {
            size = [NSURL spt_optimalCDNImageSizeForSideInPoints:kNUSpotifyArtworkPt
                                                    screenScale:UIScreen.mainScreen.scale];
        }
    } @catch (__unused NSException *e) {}
    @try {
        if (size && [NSURL respondsToSelector:@selector(spt_HTTPURLForImageWithSpotifyLink:size:)]) {
            NSURL *u = [NSURL spt_HTTPURLForImageWithSpotifyLink:link size:size];
            if (u) return u;
        }
    } @catch (__unused NSException *e) {}

    NSString *s = link.absoluteString;
    NSString *prefix = @"spotify:image:";
    if ([s hasPrefix:prefix]) {
        NSString *hex = [s substringFromIndex:prefix.length];
        if (hex.length) return [NSURL URLWithString:[@"https://i.scdn.co/image/" stringByAppendingString:hex]];
    }
    return nil;
}

#pragma mark - Provider

@interface NUSpotifyProvider () <SPTPlayerObserver>
@property (nonatomic, weak) SPTPlayerServiceImplementation *service;
@property (nonatomic, weak) id<SPTPlayer> capturedPlayer;  // fallback if the service never appears
@property (nonatomic, strong) id<SPTPlayer> ownPlayer;     // minted from the service (we own it)
@property (nonatomic, strong) SPTPlayerState *cachedState;
@property (nonatomic) BOOL observerAttached;
// Last seen queue revision + current track, to drop position-only state updates (they fire
// constantly while playing).
@property (nonatomic, copy) NSString *lastRevision;
@property (nonatomic, copy) NSString *lastTrackURI;
// The artwork cache (track URI → raw downloaded bytes) lives in NUProviderBase.
@end

@implementation NUSpotifyProvider

+ (instancetype)shared {
    static NUSpotifyProvider *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [NUSpotifyProvider new]; });
    return s;
}

#pragma mark - Capture / observation

- (NSString *)appPrefKey { return @"enabledSpotify"; }

- (void)captureService:(id)service {
    if (!service || self.service == service) return;
    // A NEW service means Spotify tore down and rebuilt its player stack (account
    // switch, service reload). Everything derived from the old service is dead:
    // the observer registration and any player it minted. Reset both so the
    // attach below re-observes the LIVE service — otherwise observerAttached
    // stays YES, stateDidChange never fires again, and -player keeps returning a
    // detached _ownPlayer forever (stale row + skip/prev into the void, plus the
    // retired player graph held alive).
    if (self.service) {
        // Best-effort detach from the retired objects first: while they stay alive
        // they'd keep driving -handleState: and could overwrite cachedState with a
        // detached player's snapshot. (The observer was attached to whichever of
        // service/ownPlayer succeeded in -attachObserver — detach from both.)
        SPTPlayerServiceImplementation *old = self.service;
        if ([old respondsToSelector:@selector(removePlayerObserver:)]) {
            @try { [old removePlayerObserver:self]; } @catch (__unused NSException *e) {}
        }
        if ([self.ownPlayer respondsToSelector:@selector(removePlayerObserver:)]) {
            @try { [self.ownPlayer removePlayerObserver:self]; } @catch (__unused NSException *e) {}
        }
        self.observerAttached = NO;
        self.ownPlayer = nil;
    }
    self.service = (SPTPlayerServiceImplementation *)service;
    NULog("spotify provider: captured SPTPlayerService %p", service);
    // The service may still be mid-init; attach on the next main-queue turn.
    dispatch_async(dispatch_get_main_queue(), ^{ [self attachObserver]; });
}

- (void)capturePlayer:(id)player {
    if (!player || self.capturedPlayer == player) return;
    self.capturedPlayer = (id<SPTPlayer>)player;
    NULog("spotify provider: captured SPTPlayer %p", player);
    dispatch_async(dispatch_get_main_queue(), ^{ [self attachObserver]; });
}

// A player to issue reads/writes through. Prefer one minted from the service (that is exactly how
// every Spotify feature gets one); fall back to whichever player the hooks caught.
- (id<SPTPlayer>)player {
    if (_ownPlayer) return _ownPlayer;
    SPTPlayerServiceImplementation *svc = self.service;
    if (svc && [svc respondsToSelector:@selector(providePlayerWithViewURI:featureIdentifier:)]) {
        @try {
            _ownPlayer = [svc providePlayerWithViewURI:[NSURL URLWithString:@"spotify:app:nextup3"]
                                     featureIdentifier:@"nextup3"];
            if (_ownPlayer) NULog("spotify provider: minted player %p", _ownPlayer);
        } @catch (NSException *e) { NULog("spotify: providePlayer threw %{public}@", e.name); }
    }
    return _ownPlayer ?: self.capturedPlayer;
}

- (void)attachObserver {
    if (self.observerAttached) return;
    SPTPlayerServiceImplementation *svc = self.service;
    if (svc && [svc respondsToSelector:@selector(addPlayerObserver:)]) {
        @try { [svc addPlayerObserver:self]; self.observerAttached = YES; }
        @catch (NSException *e) { NULog("spotify: service addPlayerObserver threw %{public}@", e.name); }
    }
    if (!self.observerAttached) {
        id<SPTPlayer> p = [self player];
        if (p && [p respondsToSelector:@selector(addPlayerObserver:)]) {
            @try { [p addPlayerObserver:self]; self.observerAttached = YES; }
            @catch (NSException *e) { NULog("spotify: player addPlayerObserver threw %{public}@", e.name); }
        }
    }
    if (self.observerAttached) {
        NULog("spotify provider: observing player state");
        [self refreshState]; // nothing has changed yet, so seed the cache
    }
}

#pragma mark - SPTPlayerObserver

- (void)player:(id)player stateDidChange:(id)state { [self handleState:state]; }
- (void)player:(id)player stateDidChange:(id)state fromState:(id)fromState { [self handleState:state]; }

// Called on Spotify's player queue, so hop to main first — every property below is read there by
// the LM server. Drops the churn (this also fires for pause/seek/option changes), then caches and
// re-fetches.
- (void)handleState:(SPTPlayerState *)state {
    if (!state) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        // Read rev/uri separately and keep going on a throw: an update that drops
        // one accessor must degrade to "treat as changed", not silently return —
        // a blanket return here would swallow EVERY state update.
        NSString *rev = nil, *uri = nil;
        @try { rev = state.queueRevision; } @catch (__unused NSException *e) {}
        @try { uri = NUSpotifyTrackURI(state.track); } @catch (__unused NSException *e) {}
        // Drop churn only when the cached snapshot is comparable AND serviceable:
        // the core fills a track's metadata in lazily WITHOUT bumping rev/uri, so
        // if the cached next-up still has no usable title the fill-in update would
        // match rev+uri and be dropped — leaving the row inactive until the next
        // real queue change.
        BOOL comparable = (rev != nil || uri != nil);
        NSArray *fut = [self realFutureTracks];
        BOOL unfilled = fut.count > 0 && ![self infoForTrack:fut.firstObject];
        if (comparable && !unfilled
            && NUSameStr(rev, self.lastRevision) && NUSameStr(uri, self.lastTrackURI)) return;
        self.lastRevision = rev;
        self.lastTrackURI = uri;
        self.cachedState = state; // never serve an empty row while the richer fetch is in flight
        [self changed];
        [self refreshState];
    });
}

// Re-read the state with explicit history/lookahead caps and cache it. The LM server replies
// synchronously, so -nextUpDictionary can never await anything — it reads this cache only.
- (void)refreshState {
    __weak typeof(self) weakSelf = self;
    void (^store)(SPTPlayerState *) = ^(SPTPlayerState *st) {
        typeof(self) self = weakSelf;
        if (!self || !st) return;
        self.cachedState = st;
        [self changed];
    };
    id<SPTPlayer> p = [self player];
    if (p && [p respondsToSelector:@selector(fetchState:reverseCap:futureCap:on:)]) {
        @try {
            [p fetchState:store reverseCap:kNUSpotifyReverseCap futureCap:kNUSpotifyFutureCap
                       on:dispatch_get_main_queue()];
            return;
        } @catch (NSException *e) { NULog("spotify: fetchState threw %{public}@", e.name); }
    }
    SPTPlayerServiceImplementation *svc = self.service;
    if (svc && [svc respondsToSelector:@selector(fetchPlayerState:on:)]) {
        @try { [svc fetchPlayerState:store on:dispatch_get_main_queue()]; }
        @catch (NSException *e) { NULog("spotify: fetchPlayerState threw %{public}@", e.name); }
    }
}

#pragma mark - Queue reading

// Upcoming real tracks, pseudo-entries stripped: [0] = next up, [1] = the fwd carousel card.
- (NSArray<SPTPlayerTrack *> *)realFutureTracks {
    NSArray *future = nil;
    @try { future = self.cachedState.future; } @catch (__unused NSException *e) { return @[]; }
    NSMutableArray *out = [NSMutableArray array];
    for (SPTPlayerTrack *t in future) if (NUSpotifyIsRealTrack(t)) [out addObject:t];
    return out;
}

// Most recently played track (back card). `reverse` is reverse-chronological, so [0] is the one
// that just finished — unlike SPTPlayerQueue.prevTracks, which is the forward-ordered history.
- (SPTPlayerTrack *)previousTrack {
    NSArray *reverse = nil;
    @try { reverse = self.cachedState.reverse; } @catch (__unused NSException *e) { return nil; }
    for (SPTPlayerTrack *t in reverse) if (NUSpotifyIsRealTrack(t)) return t;
    return nil;
}

// {title, subtitle, uri, track, artwork?} snapshot, or nil if the track carries no usable metadata
// (title/artist/artwork are all derived from -metadata, which the core may not have filled in yet).
- (NSDictionary *)infoForTrack:(SPTPlayerTrack *)track {
    if (!track) return nil;
    NSString *title = nil, *artist = nil;
    @try { title = track.trackTitle; artist = track.artistName; } @catch (__unused NSException *e) {}
    NSString *uri = NUSpotifyTrackURI(track);
    if (title.length == 0 || uri.length == 0) return nil;

    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"title"] = title;
    d[@"subtitle"] = artist ?: @"";
    d[@"uri"] = uri;
    d[@"track"] = track;
    NSData *art = [self cachedArtworkForKey:uri];
    if (art) d[@"artwork"] = art;
    return d;
}

#pragma mark - Artwork (async CDN fetch, cached by track URI — cache in NUProviderBase)

- (void)prefetchArtworkFor:(NSDictionary *)info {
    NSString *uri = info[@"uri"];
    SPTPlayerTrack *track = info[@"track"];
    if (uri.length == 0 || !track) return;
    if ([self cachedArtworkForKey:uri]) return;         // a track's cover never changes
    if ([self artworkFetchInFlightForKey:uri]) return;  // already fetching
    NSURL *url = NUSpotifyArtworkURL(track);
    if (url) [self fetchArtworkAtURL:url forKey:uri];
}

// The on-screen next/fwd/back window the base prune must never evict.
- (NSArray<NSString *> *)artworkKeysToProtect {
    NSMutableArray *keys = [NSMutableArray array];
    NSArray<SPTPlayerTrack *> *fut = [self realFutureTracks];
    if (fut.count > 0) { NSString *u = NUSpotifyTrackURI(fut[0]); if (u) [keys addObject:u]; }
    if (fut.count > 1) { NSString *u = NUSpotifyTrackURI(fut[1]); if (u) [keys addObject:u]; }
    NSString *pu = NUSpotifyTrackURI([self previousTrack]);
    if (pu) [keys addObject:pu];
    return keys;
}

#pragma mark - Snapshot (same wire shape as the other providers)

- (NSDictionary *)nextUpDictionary {
    if (![self providerEnabled]) return @{ kNUKeyActive : @NO }; // disabled in Settings → no queue/artwork work
    NSArray<SPTPlayerTrack *> *future = [self realFutureTracks];
    NSDictionary *nextInfo = [self infoForTrack:future.firstObject];
    if (!nextInfo) return @{ kNUKeyActive : @NO };
    [self prefetchArtworkFor:nextInfo];

    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[kNUKeyActive] = @YES;
    dict[kNUKeyTitle] = nextInfo[@"title"];
    dict[kNUKeySubtitle] = nextInfo[@"subtitle"];
    if (nextInfo[@"artwork"]) dict[kNUKeyArtwork] = nextInfo[@"artwork"];
    dict[kNUKeyCanSkip] = @YES;

    // Forward carousel neighbour (what becomes next after a skip).
    NSDictionary *fwdInfo = (future.count > 1) ? [self infoForTrack:future[1]] : nil;
    if (fwdInfo) {
        [self prefetchArtworkFor:fwdInfo];
        dict[kNUKeyFwdTitle] = fwdInfo[@"title"];
        dict[kNUKeyFwdSubtitle] = fwdInfo[@"subtitle"];
        if (fwdInfo[@"artwork"]) dict[kNUKeyFwdArtwork] = fwdInfo[@"artwork"];
    }
    // Previously-played track (back card), re-queued on a right swipe via -playPrevious
    // (provider-side; no adamID, like Podcasts / YTM).
    NSDictionary *backInfo = [self infoForTrack:[self previousTrack]];
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

// Every queue edit is a read-modify-write on a freshly fetched queue: `revision` is a concurrency
// token the core validates, so the object we write back must be the one we just read. This is
// exactly what Spotify's own -[SPTPlayerQueueWrapperImpl queueTrackPlayNext:] does
// (fetchQueueInternal → chain → set), and it is the only sanctioned way in — there is no
// insert/remove primitive on the player.
//
// `mutate` runs on the main queue with the live queue object and returns whether to write it back.
- (void)mutateQueue:(NSString *)what using:(BOOL (^)(id<SPTPlayerQueue> queue))mutate {
    id<SPTPlayer> p = [self player];
    if (!p || ![p respondsToSelector:@selector(fetchQueue:on:)] || ![p respondsToSelector:@selector(setQueue:)]) {
        NULog("spotify %{public}@: no usable player", what);
        return;
    }
    __weak typeof(self) weakSelf = self;
    @try {
        [p fetchQueue:^(id<SPTPlayerQueue> q) {
            typeof(self) self = weakSelf;
            if (!self || !q) { NULog("spotify %{public}@: no queue", what); return; }
            @try {
                if (!mutate(q)) return;
                [p setQueue:q];
                NULog("spotify %{public}@: queue written (revision %{public}@)", what, q.revision);
            } @catch (NSException *e) { NULog("spotify %{public}@ threw %{public}@", what, e.name); }
            [self changedSoon];
        } on:dispatch_get_main_queue()];
    } @catch (NSException *e) { NULog("spotify %{public}@ fetchQueue threw %{public}@", what, e.name); }
}

// Skip = remove the next track from the queue WITHOUT playing it.
- (void)skipNext {
    SPTPlayerTrack *target = [self realFutureTracks].firstObject;
    if (!target) { NULog("spotify skip: no next track"); return; }
    NSString *uid = NUSpotifyTrackUID(target);
    NSString *uri = NUSpotifyTrackURI(target);

    [self mutateQueue:@"skip" using:^BOOL(id<SPTPlayerQueue> q) {
        NSMutableArray *next = [q.nextTracks mutableCopy];
        // Locate the slot we actually displayed. The first real entry is normally it, but the
        // queue can move under us between the snapshot and the fetch — so verify by UID (the
        // per-slot identity; a URI can legitimately repeat) and only fall back to a URI search.
        NSUInteger victim = NSNotFound;
        // Only the FIRST real entry is a candidate (it's the one the row showed);
        // the loop exists solely to step over leading non-real entries, so it always
        // stops after inspecting that first real slot — match or not.
        for (NSUInteger i = 0; i < next.count; i++) {
            if (!NUSpotifyIsRealTrack(next[i])) continue;
            BOOL match = uid.length ? NUSameStr(NUSpotifyTrackUID(next[i]), uid)
                                    : NUSameStr(NUSpotifyTrackURI(next[i]), uri);
            if (match) victim = i;
            break;
        }
        if (victim == NSNotFound && uid.length) { // it moved — find it anywhere in the queue
            for (NSUInteger i = 0; i < next.count; i++) {
                if (NUSameStr(NUSpotifyTrackUID(next[i]), uid)) { victim = i; break; }
            }
        }
        if (victim == NSNotFound) {
            NULog("spotify skip: '%{public}@' is not in nextTracks — refusing to remove another slot", uri);
            return NO;
        }
        [next removeObjectAtIndex:victim];
        q.nextTracks = next;
        NULog("spotify skip: removing '%{public}@' at %lu", uri, (unsigned long)victim);
        return YES;
    }];
}

// Re-queue the previously-played track to play NEXT, leaving the current track playing (Apple
// Music's "Play Next" semantic, which is what the display's right-swipe means). Same read-modify-
// write as skip, just an insert at the head of nextTracks.
- (void)playPrevious {
    SPTPlayerTrack *prev = [self previousTrack];
    if (!prev) { NULog("spotify prev: no history"); return; }
    NSString *uri = NUSpotifyTrackURI(prev);

    [self mutateQueue:@"prev" using:^BOOL(id<SPTPlayerQueue> q) {
        NSMutableArray *next = [q.nextTracks mutableCopy] ?: [NSMutableArray array];
        [next insertObject:prev atIndex:0];
        q.nextTracks = next;
        NULog("spotify prev: enqueuing '%{public}@' to play next", uri);
        return YES;
    }];
}

// -changed is NUProviderBase's (no self-tracked history — the player state carries it).

#pragma mark - LightMessaging server (Spotify registers the service via libSandy)

- (void)startServer {
    // No jump notification: Spotify maps the MediaRemote NextTrack command to a real
    // advance-to-next-track (LockScreenRemoteNextTrackCommand), like Music — unlike iOS 17+
    // Podcasts, which mis-maps it to a 30s skip. The display sends the MR command directly.
    [self startServerWithService:kNUServiceNameSpotify
                            skip:kNUSkipNotificationSpotify
                            prev:kNUPrevNotificationSpotify
                            jump:NULL];
}

@end
