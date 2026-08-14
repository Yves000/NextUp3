#import "NUMusicProvider.h"
#import "NUShared.h"
#import "LightMessaging.h"
#import <notify.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>

#pragma mark - Private Music/MediaPlayer interfaces (verified live via Frida)

@interface MPArtworkCatalog : NSObject
@property (nonatomic) CGSize fittingSize;
@property (nonatomic) double destinationScale;
- (void)requestImageWithCompletionHandler:(void (^)(UIImage *image))handler;
@end

@interface MPModelArtist : NSObject
- (NSString *)name;
@end

@interface MPIdentifierSet : NSObject
- (unsigned long long)storeAdamID; // Apple Music catalog id, for MPMusicPlayer enqueue
- (NSString *)databaseID;          // Podcasts episode local UUID (iOS 18 play-next token, see -playPrevious)
@end

@interface MPModelSong : NSObject
- (NSString *)title;
- (MPModelArtist *)artist;
- (MPArtworkCatalog *)artworkCatalog;
- (MPIdentifierSet *)identifiers;
@end

@interface MPModelGenericObject : NSObject
- (MPModelSong *)song;
- (MPArtworkCatalog *)artworkCatalog;
- (MPIdentifierSet *)identifiers; // Podcasts: -> -databaseID episode UUID
@end

@interface MPCModelGenericAVItem : NSObject
- (NSString *)mainTitle;
- (NSString *)artist;
- (MPModelGenericObject *)modelGenericObject;
@end

// The live queue controller inside the Music app.
@interface MPCQueueController : NSObject
- (long long)displayItemCount;
- (id)currentItem;
// offset +1 = next item; mode 0 = default. didReachEnd is a BOOL* out-param.
- (NSString *)contentItemIDWithCurrentItemOffset:(long long)offset mode:(long long)mode didReachEnd:(BOOL *)didReachEnd;
- (id)itemForContentItemID:(NSString *)contentItemID;
- (void)jumpToContentItemID:(NSString *)contentItemID; // play that queue item now (see -jumpToNext)
// Remove a queue item by content id directly — the only skip path that works for
// autoplay/radio contexts, where the queue lookahead reports a next item but no
// captured response tracklist ever materialises it (so the -remove path below
// has no MPCPlayerResponseItem to act on). Verified present on iOS 16. See -skipNext.
- (void)removeContentItemID:(NSString *)contentItemID completion:(void (^)(id))completion;
@end

// Materialised player response — used for the actual skip (removal). Its
// MPCPlayerResponseItem has a working -remove that yields an MPCPlayerCommandRequest.
@interface MPSectionedCollection : NSObject
- (long long)totalItemCount;
- (NSIndexPath *)indexPathForGlobalIndex:(long long)globalIndex;
- (id)itemAtIndexPath:(NSIndexPath *)indexPath;
@end

@interface MPCPlayerResponseItem : NSObject
@property (nonatomic, readonly, copy) NSString *contentItemIdentifier;
- (MPModelGenericObject *)metadataObject;
- (id)remove; // MPCPlayerCommandRequest, or nil
@end

@interface MPCPlayerResponseTracklist : NSObject
@property (nonatomic, readonly, copy) MPSectionedCollection *items;
@property (nonatomic, readonly) long long playingItemGlobalIndex;
- (id)insertCommand; // -> _MPCPlayerInsertItemsCommand (NUInsertItemsCommand below)
@end

// iOS 18 Podcasts "play next": build an MPCPlaybackIntent carrying a tracklist token (a binary
// plist that references the episode by its local UUID; source 500 = Podcasts) and feed it to the
// tracklist's insert command, then perform it like the skip/remove path. Verified live.
@interface MPCPlaybackIntent : NSObject
- (void)setTracklistToken:(NSData *)token;
- (void)setTracklistSource:(long long)source;
@end
@interface NUInsertItemsCommand : NSObject // the concrete class is _MPCPlayerInsertItemsCommand
- (id)insertAfterPlayingItemWithPlaybackIntent:(MPCPlaybackIntent *)intent; // -> MPCPlayerCommandRequest
@end

@interface MPCPlayerResponse : NSObject
@property (nonatomic, readonly) MPCPlayerResponseTracklist *tracklist;
- (id)playerPath;
@end

// The `2` suffix keeps our @interface redeclarations of private classes from
// colliding with any interface the SDK/objc runtime already has (same
// convention in NUNextUpManager.m).
@interface MPCPlayerChangeRequest2 : NSObject
+ (id)requestWithCommandRequests:(NSArray *)commandRequests;
- (void)performWithCompletion:(void (^)(NSError *error))completion;
@end

#pragma mark - Provider

@interface NUMusicProvider ()
@property (nonatomic, weak) MPCQueueController *queueController;
@property (nonatomic, strong) NSMutableArray *capturedResponses; // recent responses, for removal
// contentID → artwork as pre-encoded PNG data. Cached as NSData (not UIImage) so
// the server callback never runs UIImagePNGRepresentation on Music's main thread
// — the display's query blocks synchronously on that thread, so every reply must
// stay cheap.
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSData *> *artworkPNGByID;
// cid → last request/retry activity of its fetch chain. A live chain refreshes
// its stamp on every attempt; a chain whose completion handler never fired goes
// stale and may be replaced (see kNUArtworkChainStaleInterval).
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDate *> *inFlightArtworkSince;
// Self-recorded play history (in-memory): the previous tracks we've observed
// play. Unlike the queue's within-queue history, these include cross-context
// tracks (from other albums) — which are NOT in the current queue and can
// therefore be re-inserted as up-next via the "Play Next" command.
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *playHistory; // oldest→newest, excludes current
@property (nonatomic, copy) NSString *currentTrackID;
@property (nonatomic, strong) NSMutableDictionary *currentTrackMeta;
@property (nonatomic, strong) NSMutableSet<NSString *> *artworkGaveUpIDs; // budget exhausted; don't re-request
@property (nonatomic, strong) dispatch_queue_t artworkQueue;             // serial: one PNG encode at a time
@property (nonatomic, copy) dispatch_block_t pendingHistorySave; // debounced disk write
@property (nonatomic) BOOL nextUpRecheckPending; // an inactive-answer re-poll chain is running
@end

@implementation NUMusicProvider

+ (instancetype)shared {
    static NUMusicProvider *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [NUMusicProvider new]; });
    return s;
}

// Which app's Settings toggle gates this provider (this MPC provider also runs in
// Podcasts on iOS 18). Read via NUProviderBase -providerEnabled.
- (NSString *)appPrefKey {
    return [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.podcasts"]
        ? @"enabledPodcasts" : @"enabledMusic";
}

// Called from the MPCQueueController hooks so we always hold the live instance.
// Pinned to the main queue like every other mutation (see -queueChanged).
- (void)captureController:(id)qc {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self captureController:qc]; });
        return;
    }
    if (qc && self.queueController != qc) {
        self.queueController = (MPCQueueController *)qc;
        NULog("provider: captured MPCQueueController %p", qc);
    }
}

// Music inserts transient placeholder items ("Loading…", content id containing
// "PLACEHOLDER") at the tail of autoplay/radio queues while the next tracks load.
// They must never enter the play history: a placeholder has no store id, so
// previous-navigation would silently no-op and the back card would render empty.
static BOOL NUIsPlaceholderContentID(NSString *cid) {
    return cid.length == 0 || [cid containsString:@"PLACEHOLDER"];
}

- (void)queueChanged {
    // -recordCurrentTrack / -prefetchWindow mutate playHistory / currentTrackMeta /
    // the artwork caches. The MPC hooks can fire on a background queue, while the LM
    // server callback runs the same mutations on the main runloop — so pin the whole
    // body (record BEFORE notify, same order as on-main) to the main queue, otherwise
    // two threads mutate the same NSMutableArray/Dictionary and Music crashes.
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self queueChanged]; });
        return;
    }
    // Disabled in Settings → fully inert: no queue reads, no artwork work.
    if (![self providerEnabled]) return;
    // The window (previous / current / next / next-next) may have shifted — signal
    // the display. Artwork stays cached by content id (an id's artwork never
    // changes), so we don't drop it here.
    //
    // No prefetch from here: the notify makes every live display re-query, and the
    // query path schedules the prefetch — so artwork work only happens when a
    // display is actually asking. A backgrounded app must not poll its own media
    // stack (starves mediaserverd into an RPC-timeout kill on iOS 14.2).
    [self recordCurrentTrack];
    notify_post(kNUChangedNotification);
}

// Track the current item; when it changes, push the track we just left onto the
// history (or pop, if the new current is the track we recorded as the previous
// one). Keeps `playHistory` in step with actual play order across queues.
- (void)recordCurrentTrack {
    NSString *cur = [self contentIDAtOffset:0];
    if (!cur || [cur isEqualToString:self.currentTrackID]) return;
    // Don't let a queue placeholder become the tracked current item — otherwise
    // when the real track loads we'd push the placeholder onto the history stack.
    // Leave currentTrackID/Meta on the last real track so it's still recorded next.
    if (NUIsPlaceholderContentID(cur)) return;

    BOOL changed = NO;
    if (self.playHistory.count && [self.playHistory.lastObject[@"id"] isEqualToString:cur]) {
        [self.playHistory removeLastObject]; changed = YES; // went backward
    } else if (self.currentTrackID && self.currentTrackMeta) {
        NSMutableDictionary *entry = self.currentTrackMeta;
        if (!entry[@"artwork"]) {
            NSData *png = self.artworkPNGByID[self.currentTrackID];
            if (png) entry[@"artwork"] = png;
        }
        if (!self.playHistory) self.playHistory = [NSMutableArray array];
        [self.playHistory addObject:entry];
        while (self.playHistory.count > 50) [self.playHistory removeObjectAtIndex:0]; // 50 = persisted play-history cap
        changed = YES;
    }
    if (changed) [self scheduleHistorySave];

    self.currentTrackID = cur;
    NSDictionary *info = [self infoForContentID:cur];
    self.currentTrackMeta = info ? [info mutableCopy] : nil;
    if (self.currentTrackMeta) self.currentTrackMeta[@"id"] = cur;
}

#pragma mark - History persistence (small atomically-written binary plist)

// Atomic plist write (temp-write-then-rename) survives crashes; no schema needed.
static NSString *NUHistoryPlistPath(void) {
    NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString *base = dirs.firstObject ?: NSTemporaryDirectory();
    NSString *dir = [base stringByAppendingPathComponent:@"NextUp3"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    return [dir stringByAppendingPathComponent:@"history.plist"];
}

- (void)loadHistory {
    NSData *data = [NSData dataWithContentsOfFile:NUHistoryPlistPath()];
    if (!data) return;
    id plist = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL];
    if (![plist isKindOfClass:[NSArray class]]) return;
    NSMutableArray *loaded = [NSMutableArray array];
    for (id e in plist) if ([e isKindOfClass:[NSDictionary class]] && [e[@"id"] isKindOfClass:[NSString class]]) [loaded addObject:e];
    while (loaded.count > 50) [loaded removeObjectAtIndex:0]; // 50 = persisted play-history cap
    self.playHistory = loaded;
    NULog("provider: loaded %lu history entries", (unsigned long)loaded.count);
}

// Debounced ~2s after the last change; each write is a full (tiny) snapshot done
// off the main thread.
- (void)scheduleHistorySave {
    if (self.pendingHistorySave) dispatch_block_cancel(self.pendingHistorySave);
    __weak typeof(self) ws = self;
    dispatch_block_t b = dispatch_block_create(0, ^{
        typeof(self) self = ws; if (!self) return;
        self.pendingHistorySave = nil;
        NSArray *snapshot = [self.playHistory copy];
        NSString *path = NUHistoryPlistPath();
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSData *data = [NSPropertyListSerialization dataWithPropertyList:snapshot
                            format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
            if (data) [data writeToFile:path atomically:YES];
        });
    });
    self.pendingHistorySave = b;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), b);
}

#pragma mark - Previous-track lookup

// depth 1 = the previous track, 2 = the one before that, … Prefer our recorded
// play history (includes cross-context tracks, which — being absent from the
// current queue — can be re-inserted as up-next); fall back to the tracklist's
// within-queue history for the window right after a respring.
- (NSDictionary *)previousInfoAtDepth:(long long)depth {
    if (depth < 1) return nil;
    NSInteger idx = (NSInteger)self.playHistory.count - (NSInteger)depth;
    if (idx >= 0 && idx < (NSInteger)self.playHistory.count) return self.playHistory[idx];
    MPCPlayerResponseItem *ri = [self historyItemAtDepth:depth];
    return ri ? [self infoForResponseItem:ri] : nil;
}

#pragma mark - Reading items by queue offset (0 = current, +1 = next, +2 = after)

- (NSString *)contentIDAtOffset:(long long)offset {
    MPCQueueController *qc = self.queueController;
    if (!qc) return nil;
    @try {
        BOOL reachedEnd = NO;
        NSString *cid = [qc contentItemIDWithCurrentItemOffset:offset mode:0 didReachEnd:&reachedEnd];
        return reachedEnd ? nil : cid;
    } @catch (__unused NSException *e) { return nil; }
}

- (MPCModelGenericAVItem *)itemAtOffset:(long long)offset {
    NSString *cid = [self contentIDAtOffset:offset];
    if (!cid) return nil;
    @try { return [self.queueController itemForContentItemID:cid]; }
    @catch (__unused NSException *e) { return nil; }
}

- (MPCModelGenericAVItem *)nextItem { return [self itemAtOffset:1]; }
- (NSString *)nextContentID { return [self contentIDAtOffset:1]; }
- (BOOL)hasPreviousItem { return [self previousInfoAtDepth:1] != nil; }

#pragma mark - History (already-played tracks) via the materialised tracklist

// The queue controller's contentItemIDWithCurrentItemOffset: clamps at the
// current item for negative offsets — it does NOT expose already-played tracks.
// Those live in the materialised tracklist at globalIndex < playingItemGlobalIndex.
// Pick the captured response whose tracklist's playing item is the one playing now.
- (MPCPlayerResponseTracklist *)liveTracklist {
    NSString *curID = [self contentIDAtOffset:0];
    for (MPCPlayerResponse *response in [self.capturedResponses copy]) {
        @try {
            MPCPlayerResponseTracklist *tl = response.tracklist;
            MPSectionedCollection *items = tl.items;
            long long total = items.totalItemCount;
            if (total <= 1) continue;
            long long pIdx = tl.playingItemGlobalIndex;
            if (pIdx < 0 || pIdx >= total) continue;
            if (curID) {
                NSIndexPath *ip = [items indexPathForGlobalIndex:pIdx];
                MPCPlayerResponseItem *it = ip ? [items itemAtIndexPath:ip] : nil;
                if (![it.contentItemIdentifier isEqualToString:curID]) continue; // stale response
            }
            return tl;
        } @catch (__unused NSException *e) {}
    }
    return nil;
}

// The tracklist to build an insert command on. -liveTracklist requires the snapshot's
// playing item to be the item playing now — the history reader needs that (it indexes
// backwards from it), but an insert does not: -insertAfterPlayingItemWithPlaybackIntent:
// resolves the playing item against the live queue when the request is performed. The
// captured responses can lag the queue (iOS 26 Podcasts), where requiring the match
// would fail every insert — fall back to the newest response carrying a real queue,
// the same set the skip path resolves its items against.
- (MPCPlayerResponseTracklist *)insertableTracklist {
    MPCPlayerResponseTracklist *strict = [self liveTracklist];
    if (strict) return strict;

    for (MPCPlayerResponse *response in [self.capturedResponses copy]) {
        @try {
            MPCPlayerResponseTracklist *tl = response.tracklist;
            if (tl.items.totalItemCount <= 1) continue;
            NULog("tracklist: no playing-item match — using newest queue response");
            return tl;
        } @catch (__unused NSException *e) {}
    }
    return nil;
}

// depth 1 = the previous track, 2 = the one before that, … (backward through history).
- (MPCPlayerResponseItem *)historyItemAtDepth:(long long)depth {
    if (depth < 1) return nil;
    MPCPlayerResponseTracklist *tl = [self liveTracklist];
    if (!tl) return nil;
    @try {
        MPSectionedCollection *items = tl.items;
        long long g = tl.playingItemGlobalIndex - depth;
        if (g < 0) return nil;
        NSIndexPath *ip = [items indexPathForGlobalIndex:g];
        return ip ? [items itemAtIndexPath:ip] : nil;
    } @catch (__unused NSException *e) { return nil; }
}

// The Apple Music catalog (store adam) id for a song, as a string, or nil.
static NSString *NUAdamIDFromSong(MPModelSong *song) {
    if (!song) return nil;
    @try {
        unsigned long long adam = [[song identifiers] storeAdamID];
        if (adam) return [@(adam) stringValue];
    } @catch (__unused NSException *e) {}
    return nil;
}

// {title, subtitle, artwork?, id, adamID?} for a tracklist history item, read
// straight from its metadata object (the queue controller can't resolve played ids).
- (NSDictionary *)infoForResponseItem:(MPCPlayerResponseItem *)item {
    if (!item) return nil;
    NSString *title = nil, *artist = nil, *cid = nil, *adam = nil, *episodeUUID = nil;
    @try {
        cid = item.contentItemIdentifier;
        MPModelGenericObject *mo = [item metadataObject];
        MPModelSong *song = [mo song];
        title = [song title];
        artist = [[song artist] name];
        adam = NUAdamIDFromSong(song);
        // Podcasts: carry the episode UUID here too, so a history entry rebuilt from the tracklist
        // (e.g. right after a respring, before in-memory history fills) can still be re-queued by
        // -playPrevious. Nil/absent for Music items.
        @try { episodeUUID = [[mo identifiers] databaseID]; } @catch (__unused NSException *e2) {}
    } @catch (__unused NSException *e) {}
    if (title.length == 0) return nil;

    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[@"title"] = title;
    info[@"subtitle"] = artist ?: @"";
    if (cid) info[@"id"] = cid;
    if (adam) info[@"adamID"] = adam;
    if (episodeUUID.length) info[@"episodeUUID"] = episodeUUID;
    NSData *art = cid ? self.artworkPNGByID[cid] : nil;
    if (art) info[@"artwork"] = art;
    return info;
}

#pragma mark - Item info

// {title, subtitle, artwork?} for a content id, or nil if unresolvable/blank.
// Forward/current items resolve via the live queue controller; history items,
// which the controller can't resolve, fall back to the tracklist's metadata.
- (NSDictionary *)infoForContentID:(NSString *)cid {
    if (!cid) return nil;
    NSString *title = nil, *artist = nil, *adam = nil, *episodeUUID = nil;
    @try {
        MPCModelGenericAVItem *item = [self.queueController itemForContentItemID:cid];
        if (item) { title = [item mainTitle]; artist = [item artist];
                    adam = NUAdamIDFromSong([[item modelGenericObject] song]);
                    // Podcasts (iOS 18): the episode's local UUID — the only handle needed to
                    // re-queue it later via -playPrevious. Nil/absent for Music items.
                    @try { episodeUUID = [[[item modelGenericObject] identifiers] databaseID]; } @catch (__unused NSException *e2) {} }
    } @catch (__unused NSException *e) {}
    if (title.length == 0) {
        @try {
            MPModelSong *song = [[[self responseItemForContentID:cid] metadataObject] song];
            title = [song title];
            artist = [[song artist] name];
            adam = NUAdamIDFromSong(song);
        } @catch (__unused NSException *e) {}
    }
    if (title.length == 0) return nil;

    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[@"title"] = title;
    info[@"subtitle"] = artist ?: @"";
    if (adam) info[@"adamID"] = adam;
    if (episodeUUID.length) info[@"episodeUUID"] = episodeUUID; // podcasts play-next handle
    NSData *art = self.artworkPNGByID[cid];
    if (art) info[@"artwork"] = art;
    return info;
}

- (NSDictionary *)infoAtOffset:(long long)offset {
    return [self infoForContentID:[self contentIDAtOffset:offset]];
}

- (NSDictionary *)nextUpDictionary {
    if (![self providerEnabled]) return @{ kNUKeyActive : @NO }; // disabled in Settings
    // Prefetch the window's artwork — deferred, never inline: the client's main
    // thread is blocked on this round-trip, and artwork calls can hold the app's
    // (serialized, cross-process) artwork lock for hundreds of ms.
    dispatch_async(dispatch_get_main_queue(), ^{ [self prefetchWindow]; });

    NSDictionary *next = [self infoAtOffset:1];
    if (!next) {
        // A query can land mid queue rebuild (performSetQueue signals before the
        // new items materialise), so "no next item" may mean "not resolvable YET" —
        // and no queue hook fires once it is. A second change signal must come from
        // us: re-poll briefly and signal when the next item turns up.
        [self scheduleNextUpRecheck];
        return @{ kNUKeyActive : @NO };
    }

    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[kNUKeyActive] = @YES;
    dict[kNUKeyTitle] = next[@"title"];
    dict[kNUKeySubtitle] = next[@"subtitle"];
    if (next[@"artwork"]) dict[kNUKeyArtwork] = next[@"artwork"];
    dict[kNUKeyCanSkip] = @YES;
    dict[kNUKeyCanPrev] = @([self hasPreviousItem]);

    // Carousel neighbours: fwd (+2, revealed on left/skip swipe) is the track that
    // becomes up-next after a skip; back (revealed on right/previous swipe) is the
    // PREVIOUS track you navigate to with "previous", taken from our recorded play
    // history. Each right swipe re-centres a step deeper, so the carousel walks
    // further into history (depth 2, 3, …) as the transport steps back.
    NSDictionary *fwd = [self infoAtOffset:2];
    if (fwd) { dict[kNUKeyFwdTitle] = fwd[@"title"]; dict[kNUKeyFwdSubtitle] = fwd[@"subtitle"];
               if (fwd[@"artwork"]) dict[kNUKeyFwdArtwork] = fwd[@"artwork"]; }
    NSDictionary *back = [self previousInfoAtDepth:1];
    if (back) { dict[kNUKeyBackTitle] = back[@"title"]; dict[kNUKeyBackSubtitle] = back[@"subtitle"];
                if (back[@"artwork"]) dict[kNUKeyBackArtwork] = back[@"artwork"];
                if (back[@"adamID"]) dict[kNUKeyBackAdamID] = back[@"adamID"]; }
    return dict;
}

// Coalesced re-poll after an inactive answer while a queue exists: check every
// 0.3s for up to ~2.4s whether offset +1 has become resolvable, and publish a
// queue change the moment it has. Bounded, so a genuinely empty queue (last
// track playing) costs eight cheap reads and then goes quiet.
- (void)scheduleNextUpRecheck {
    if (self.nextUpRecheckPending) return;
    if (!self.queueController) return; // no queue at all — nothing to wait for
    self.nextUpRecheckPending = YES;
    [self nextUpRecheckAttempt:0];
}

- (void)nextUpRecheckAttempt:(NSInteger)attempt {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;
        if (!self) return;
        if ([self infoAtOffset:1]) {
            self.nextUpRecheckPending = NO;
            NULog("provider: next item materialised after inactive answer (attempt %ld)", (long)attempt);
            [self queueChanged]; // record + signal the display + prefetch, like a real queue event
            return;
        }
        if (attempt + 1 < 8) { [self nextUpRecheckAttempt:attempt + 1]; return; } // 8 × 0.3s ≈ 2.4s budget
        self.nextUpRecheckPending = NO;
    });
}

#pragma mark - Artwork (async prefetch for the current window, cached by content id)

// Fast-retry budget for the artwork of a single content id. A future queue
// item's MPArtworkCatalog fires its completion with a nil image until the model
// materialises, so we re-request with a short backoff instead of dropping it.
// After the fast phase the chain drops to a slow cadence while the id stays in
// the live window (slow streams / bad network can take well beyond the fast
// phase, and the row is still showing the track).
static const NSInteger kNUMaxArtworkAttempts = 12;
static const NSTimeInterval kNUArtworkSlowRetryInterval = 3.0;
// The slow phase is BOUNDED: unbounded polling of a backgrounded app's artwork
// stack took down mediaserverd on iOS 14.2. After the budget the
// id is parked in artworkGaveUpIDs until it leaves and re-enters the window.
static const NSInteger kNUMaxSlowArtworkAttempts = 4;   // ≈12s of slow retries
// Only consult the (expensive) captured-response tracklists for a catalog on the
// first attempts: that path enumerates every item of up to 16 responses, so doing
// it on each retry multiplies the model traffic for exactly the ids that are
// failing anyway.
static const NSInteger kNUResponseCatalogMaxAttempt = 3;
// An in-flight chain refreshes its activity stamp on every attempt. If a stamp
// is older than this, the chain is dead (MPArtworkCatalog never called its
// completion handler — happens for not-yet-materialised items) and a new chain
// may start; a swallowed completion must never block an id's artwork forever.
static const NSTimeInterval kNUArtworkChainStaleInterval = 20.0;

// One serial queue for every PNG encode. UIImagePNGRepresentation on an
// MPArtworkCatalog image is NOT a local pixel operation — the image is lazily
// backed, so encoding re-enters the app's artwork/model machinery and takes the
// same lock the app's own main thread needs — so encodes are serialized.
- (dispatch_queue_t)artworkQueue {
    if (!_artworkQueue)
        _artworkQueue = dispatch_queue_create("com.yves.nextup3.artwork", DISPATCH_QUEUE_SERIAL);
    return _artworkQueue;
}

// Is an artwork chain currently running? Only ONE runs at a time — parallel
// chains would compete for the same artwork lock (see -artworkQueue).
- (BOOL)artworkChainInFlight {
    for (NSDate *since in self.inFlightArtworkSince.allValues)
        if (-since.timeIntervalSinceNow < kNUArtworkChainStaleInterval) return YES;
    return NO;
}

- (void)prefetchWindow {
    if (![self providerEnabled]) return;
    if (!self.artworkPNGByID) self.artworkPNGByID = [NSMutableDictionary dictionary];
    if (!self.inFlightArtworkSince) self.inFlightArtworkSince = [NSMutableDictionary dictionary];
    // The live window's ids (current / next / next-next): the fwd carousel card is
    // +2, and the backward one comes from recorded history with its own PNG.
    NSMutableSet *live = [NSMutableSet set];
    for (long long off = 0; off <= 2; off++) { NSString *c = [self contentIDAtOffset:off]; if (c) [live addObject:c]; }
    // An id that left the window gets a fresh budget if it ever comes back.
    if (self.artworkGaveUpIDs.count)
        for (NSString *k in [self.artworkGaveUpIDs.allObjects copy])
            if (![live containsObject:k]) [self.artworkGaveUpIDs removeObject:k];
    // Drop in-flight marks of ids that left the window: their chain is dead (its
    // next retry would only notice on its own timer, up to the stale interval
    // later) and must not hold the single chain slot against a visible track.
    for (NSString *k in [self.inFlightArtworkSince.allKeys copy])
        if (![live containsObject:k]) [self.inFlightArtworkSince removeObjectForKey:k];
    // Start at most one chain per call; the next call picks up the next offset.
    // Order by what the row actually shows: +1 is the up-next track, +2 the forward
    // carousel card, 0 only matters later (recordCurrentTrack snapshots it into the
    // history entry that becomes the back card).
    if (![self artworkChainInFlight])
        for (NSNumber *off in @[ @1, @2, @0 ])
            if ([self prefetchArtworkAtOffset:off.longLongValue]) break;
    // Bound the cache to the live window (history entries keep their own PNG, so
    // pruning the live cache can't blank them).
    if (self.artworkPNGByID.count > 8) { // 8 = cap: the 3-id live window plus slack
        for (NSString *k in self.artworkPNGByID.allKeys) if (![live containsObject:k]) [self.artworkPNGByID removeObjectForKey:k];
    }
}

// YES if a chain was started for this offset.
- (BOOL)prefetchArtworkAtOffset:(long long)offset {
    NSString *cid = [self contentIDAtOffset:offset];
    if (!cid) return NO;
    if (!self.artworkPNGByID) self.artworkPNGByID = [NSMutableDictionary dictionary];
    if (!self.inFlightArtworkSince) self.inFlightArtworkSince = [NSMutableDictionary dictionary];
    if (self.artworkPNGByID[cid]) return NO;               // already cached (art for an id never changes)
    if ([self.artworkGaveUpIDs containsObject:cid]) return NO; // budget spent; waits for a window change
    NSDate *since = self.inFlightArtworkSince[cid];
    if (since && -since.timeIntervalSinceNow < kNUArtworkChainStaleInterval) return NO; // a live chain is running
    if (since) NULog("prefetch: stale chain for '%{public}@' — restarting", cid);
    [self requestArtworkForContentID:cid attempt:0];
    return YES;
}

// Issue one artwork request for `cid`. The chain's activity stamp in
// inFlightArtworkSince keeps overlapping prefetchWindow calls from spawning a
// second chain for the same id; the entry is removed when the artwork caches or
// the id falls out of the live window, and goes stale (replaceable) if the
// catalog swallows a completion.
- (void)requestArtworkForContentID:(NSString *)cid attempt:(NSInteger)attempt {
    NSDate *stamp = [NSDate date];
    self.inFlightArtworkSince[cid] = stamp;

    MPCModelGenericAVItem *item = nil;
    @try { item = [self.queueController itemForContentItemID:cid]; }
    @catch (__unused NSException *e) {}

    MPArtworkCatalog *catalog = nil;
    if (item) {
        @try {
            MPModelGenericObject *mgo = [item modelGenericObject];
            catalog = [mgo artworkCatalog] ?: [[mgo song] artworkCatalog];
        } @catch (NSException *e) { NULog("prefetch: catalog threw %{public}@", e.name); }
    }
    if (!catalog && attempt <= kNUResponseCatalogMaxAttempt) {
        // Second source: the captured response tracklist's item. Its metadata
        // materialises with the tracklist and often has a live catalog before
        // the queue controller's item does (first play after a Music launch).
        // Early attempts only — see kNUResponseCatalogMaxAttempt.
        @try {
            MPModelGenericObject *mgo = [[self responseItemForContentID:cid] metadataObject];
            catalog = [mgo artworkCatalog] ?: [[mgo song] artworkCatalog];
        } @catch (__unused NSException *e) {}
    }
    if (!catalog) { [self retryArtworkForContentID:cid attempt:attempt]; return; }

    @try {
        catalog.fittingSize = CGSizeMake(48.0, 48.0); // 48 = the row's artwork size
        catalog.destinationScale = UIScreen.mainScreen.scale;
    } @catch (__unused NSException *e) {}

    __weak typeof(self) weakSelf = self;
    @try {
        [catalog requestImageWithCompletionHandler:^(UIImage *image) {
            if (!image) {
                // Not materialised yet — try again shortly.
                dispatch_async(dispatch_get_main_queue(), ^{
                    typeof(self) self = weakSelf;
                    if (!self) return;
                    [self retryArtworkForContentID:cid attempt:attempt];
                });
                return;
            }
            // Encode the PNG once, off the main thread — the server callback
            // replies from this cache on Music's main thread, so it must never
            // pay for encoding there. Publish (and notify) only once the data
            // is ready so a query can't see the image without its bytes.
            dispatch_async(self.artworkQueue, ^{   // serial: never two encodes at once
                NSData *png = UIImagePNGRepresentation(image);
                dispatch_async(dispatch_get_main_queue(), ^{
                    typeof(self) self = weakSelf;
                    if (!self) return;
                    if (!png) { [self retryArtworkForContentID:cid attempt:attempt]; return; }
                    self.artworkPNGByID[cid] = png;
                    [self.inFlightArtworkSince removeObjectForKey:cid];
                    [self backfillHistoryArtwork:png forContentID:cid];
                    NULog("prefetch: cached artwork for '%{public}@' (attempt %ld)", cid, (long)attempt);
                    notify_post(kNUChangedNotification); // artwork now available
                });
            });
        }];
    } @catch (__unused NSException *e) { [self.inFlightArtworkSince removeObjectForKey:cid]; }

    // Watchdog: right after a Music launch the catalog sometimes never calls the
    // completion handler at all — and every retry is scheduled FROM a completion,
    // so the chain would die silently. Re-poll if the chain shows no activity
    // since this attempt; identity-compare the stamp so any completion or retry
    // that DID run (each stores a fresh NSDate) disarms the watchdog.
    __weak typeof(self) wdSelf = self;
    // 4s > the 3s slow-retry gap, so a live chain always restamps before it fires.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        typeof(self) self = wdSelf;
        if (!self) return;
        if (self.artworkPNGByID[cid]) return;
        if (self.inFlightArtworkSince[cid] != stamp) return;
        NULog("prefetch: no completion for '%{public}@' (attempt %ld) — watchdog retry", cid, (long)attempt);
        [self retryArtworkForContentID:cid attempt:attempt];
    });
}

// End this id's chain: free the in-flight slot (so another id can start) and park
// the id so nothing re-requests it until it leaves and re-enters the window.
- (void)giveUpArtworkForContentID:(NSString *)cid reason:(const char *)reason {
    [self.inFlightArtworkSince removeObjectForKey:cid];
    if (!self.artworkGaveUpIDs) self.artworkGaveUpIDs = [NSMutableSet set];
    [self.artworkGaveUpIDs addObject:cid];
    NULog("prefetch: giving up on artwork for '%{public}@' (%s)", cid, reason);
}

- (void)retryArtworkForContentID:(NSString *)cid attempt:(NSInteger)attempt {
    // Fast backoff (~0.4s → 1.5s), then a BOUNDED slow phase — total budget
    // kNUMaxArtworkAttempts + kNUMaxSlowArtworkAttempts (see the constants above).
    if (attempt + 1 >= kNUMaxArtworkAttempts + kNUMaxSlowArtworkAttempts) {
        [self giveUpArtworkForContentID:cid reason:"attempt budget exhausted"];
        return;
    }
    BOOL slow = attempt + 1 >= kNUMaxArtworkAttempts;
    NSTimeInterval delay = slow ? kNUArtworkSlowRetryInterval : MIN(0.4 + 0.2 * attempt, 1.5);
    if (slow && attempt + 1 == kNUMaxArtworkAttempts)
        NULog("prefetch: artwork for '%{public}@' still pending after %ld attempts — slow retries", cid, (long)attempt + 1);
    self.inFlightArtworkSince[cid] = [NSDate date];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;
        if (!self) return;
        if (self.artworkPNGByID[cid]) { [self.inFlightArtworkSince removeObjectForKey:cid]; return; }
        if (![self providerEnabled]) { [self.inFlightArtworkSince removeObjectForKey:cid]; return; }
        // Nobody has queried us for a while → no surface is rendering the row, so
        // there is nothing to load artwork FOR. Drop the chain; the next query
        // restarts it (the stamp is cleared, so it isn't parked as given-up).
        if (![self displayRecentlyQueried]) {
            [self.inFlightArtworkSince removeObjectForKey:cid];
            NULog("prefetch: no display interest — pausing artwork chain for '%{public}@'", cid);
            return;
        }
        // Stop if the id has fallen out of the live window (-1..+2) — no point
        // fetching art for a track that's no longer near the current one.
        BOOL live = NO;
        for (long long off = -1; off <= 2; off++) {
            if ([[self contentIDAtOffset:off] isEqualToString:cid]) { live = YES; break; }
        }
        if (!live) { [self.inFlightArtworkSince removeObjectForKey:cid]; return; }
        [self requestArtworkForContentID:cid attempt:attempt + 1];
    });
}

// Artwork often lands only after its track was already recorded into the play
// history (recordCurrentTrack snapshots whatever the cache had at the switch).
// Patch the pending current-track meta and any history entries for this id so
// the back card doesn't keep a permanent placeholder.
- (void)backfillHistoryArtwork:(NSData *)png forContentID:(NSString *)cid {
    if (!png || !cid) return;
    if ([self.currentTrackMeta[@"id"] isEqualToString:cid] && !self.currentTrackMeta[@"artwork"])
        self.currentTrackMeta[@"artwork"] = png;
    BOOL changed = NO;
    for (NSUInteger i = 0; i < self.playHistory.count; i++) {
        NSDictionary *e = self.playHistory[i];
        if ([e[@"id"] isEqualToString:cid] && !e[@"artwork"]) {
            NSMutableDictionary *m = [e mutableCopy];
            m[@"artwork"] = png;
            self.playHistory[i] = m;
            changed = YES;
        }
    }
    if (changed) [self scheduleHistorySave];
}

#pragma mark - Skip

// Called from the MPCPlayerResponseTracklist hook. At init time the tracklist is
// not materialised yet, so we can't judge by item count — capture any
// system-music response and re-validate (item count) lazily at skip time. The
// response object's tracklist fills in after init.
- (void)captureResponse:(MPCPlayerResponse *)response {
    if (!response) return;
    // Pinned to the main queue: -responseItemForContentID: enumerates this array on
    // the main runloop (LM reply path), so all mutation must happen there too.
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self captureResponse:response]; });
        return;
    }
    @try {
        // playerPath is nil during init, so we can't filter by system-music here;
        // capture every response and let the skip-time content-id search pick the
        // right (real queue) one. Keep the most recent ones.
        if (!self.capturedResponses) self.capturedResponses = [NSMutableArray array];
        [self.capturedResponses removeObject:response];
        [self.capturedResponses insertObject:response atIndex:0];
        // Trim preferring responses WITHOUT a real queue: Music spawns response
        // bursts (a dozen per song change with the lyrics page up, similar at app
        // launch) whose tracklists never materialise, and evicting by age alone
        // flushes the ONE response holding the queue — skip, the play history and
        // the title fallback all resolve against this ring. Tracklists fill in
        // after init, so judge at trim time, not capture time; index 0 (the fresh,
        // still-empty capture) is never the victim.
        while (self.capturedResponses.count > 16) { // 16 = captured-responses ring (see kNUResponseCatalogMaxAttempt)
            NSInteger drop = (NSInteger)self.capturedResponses.count - 1;
            for (NSInteger i = (NSInteger)self.capturedResponses.count - 1; i >= 1; i--) {
                MPCPlayerResponse *r = self.capturedResponses[i];
                BOOL real = NO;
                @try { real = r.tracklist.items.totalItemCount > 1; } @catch (__unused NSException *e) {}
                if (!real) { drop = i; break; }
            }
            [self.capturedResponses removeObjectAtIndex:drop];
        }
    } @catch (__unused NSException *e) {}
}

// Find the MPCPlayerResponseItem for a content id across the recently captured
// responses (the queue's real materialised tracklist is one of them).
- (MPCPlayerResponseItem *)responseItemForContentID:(NSString *)targetID {
    for (MPCPlayerResponse *response in [self.capturedResponses copy]) {
        @try {
            MPSectionedCollection *items = response.tracklist.items;
            long long total = items.totalItemCount;
            if (total <= 1) continue;
            for (long long g = 0; g < total; g++) {
                NSIndexPath *ip = [items indexPathForGlobalIndex:g];
                MPCPlayerResponseItem *it = ip ? [items itemAtIndexPath:ip] : nil;
                if ([it.contentItemIdentifier isEqualToString:targetID]) return it;
            }
        } @catch (__unused NSException *e) {}
    }
    return nil;
}

- (void)skipNext {
    @try {
        NSString *targetID = [self nextContentID];
        if (!targetID) { NULog("skip: no next id"); return; }
        MPCPlayerResponseItem *toRemove = [self responseItemForContentID:targetID];
        if (!toRemove) {
            // Autoplay/radio: the next item lives only in the controller's lookahead,
            // not in any materialised response tracklist — remove it by id instead.
            [self skipNextViaController:targetID];
            return;
        }

        id command = [toRemove remove];
        if (!command) { NULog("skip: no remove command"); return; }
        Class CR = objc_getClass("MPCPlayerChangeRequest");
        MPCPlayerChangeRequest2 *req = [CR requestWithCommandRequests:@[ command ]];
        [req performWithCompletion:^(NSError *error) {
            NULog("skip: removed '%{public}@' err=%{public}@", targetID, error ?: @"none");
            // Removing the NEXT track doesn't change the current item, so the
            // queue-change hooks won't fire — push an update ourselves. Re-publish
            // now and shortly after (the queue takes a moment to settle).
            [self changedSoon];
        }];
    } @catch (NSException *e) {
        NULog("skip: threw %{public}@", e.name);
    }
}

// Remove the next item straight off the controller by id, for when no captured
// response tracklist holds it (autoplay/radio). Must stay on the main thread — the
// skip notify is a main-queue dispatch, and MPCQueueController mutation off-main
// crashes Music.
- (void)skipNextViaController:(NSString *)targetID {
    MPCQueueController *qc = self.queueController;
    if (!qc || ![qc respondsToSelector:@selector(removeContentItemID:completion:)]) return;
    @try {
        [qc removeContentItemID:targetID completion:^(id error) { [self changedSoon]; }];
    } @catch (__unused NSException *e) {}
}

#pragma mark - LightMessaging server (Music registers the service via libSandy)

// Route the base's change signal through the full pipeline (record + notify +
// prefetch) so -changedSoon republishes exactly like a real queue event.
- (void)changed {
    [self queueChanged];
}

- (void)startServer {
    if (self.serverStarted) return;
    [self loadHistory]; // restore play history persisted before the last Music restart
    // This MPC provider also runs in the Podcasts process on iOS 18, where Podcasts moved off
    // its legacy MT* stack onto the same MPCQueueController stack Music uses (verified live).
    // Bind to the matching LM service + notifications so the display's per-source routing
    // reaches us. In the Music process this is unchanged: Music keeps its display-side
    // MPMusicPlayer "Play Next" (no prev handler) and the display sends the MediaRemote
    // next-track command directly (no jump handler). Podcasts (iOS 18) does both
    // provider-side, so it registers prev + jump.
    BOOL podcasts = [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.podcasts"];
    [self startServerWithService:(podcasts ? kNUServiceNamePodcasts : kNUServiceNameMusic)
                            skip:(podcasts ? kNUSkipNotificationPodcasts : kNUSkipNotificationMusic)
                            prev:(podcasts ? kNUPrevNotificationPodcasts : NULL)
                            jump:(podcasts ? kNUJumpNotificationPodcasts : NULL)];
    [self prefetchWindow];
}

// Play the next-up episode now (cover tap). iOS 18 Podcasts turns the MediaRemote NextTrack
// command into a 30s skip, so jump the queue to the next item's content id directly instead.
- (void)jumpToNext {
    @try {
        NSString *cid = [self nextContentID];
        if (!cid) { NULog("pc jump: no next content id"); return; }
        [self.queueController jumpToContentItemID:cid];
        NULog("pc jump: -> '%{public}@'", cid);
        [self changedSoonAfter:0.5];
    } @catch (NSException *e) {
        NULog("pc jump: threw %{public}@ :: %{public}@", e.name, e.reason);
    }
}

// Re-queue the previously-played episode to play NEXT on iOS 18 Podcasts (which drives the queue
// through MPCQueueController). We can't reorder — played items leave the tracklist — so we insert
// a fresh reference to the episode. The insert wants an MPCPlaybackIntent whose tracklist token is
// a binary plist referencing the episode by its local UUID (captured into history while it played;
// source 500 = Podcasts). Verified live: a minimal token (UUID + static scaffolding) resolves and
// inserts at the next slot; the app re-resolves the episode from its local DB.
- (void)playPrevious {
    @try {
        NSDictionary *back = [self previousInfoAtDepth:1];
        NSString *uuid = back[@"episodeUUID"];
        if (uuid.length == 0) { NULog("pc prev: no episode uuid in history"); return; }
        MPCPlayerResponseTracklist *tl = [self insertableTracklist];
        if (!tl) { NULog("pc prev: no live tracklist"); return; }

        NSDictionary *tokenPlist = @{
            @"id"       : @{ @"localEpisodes" : @{ @"ids" : @[ uuid ] } },
            @"context"  : @{ @"origin" : @{ @"default" : @{} } },
            @"options"  : @[ @{ @"ignoreContinuousPlaybackSetting" : @{} } ],
            @"mrDesiredSessionID" : [[NSUUID UUID] UUIDString], // any UUID — not validated
            @"isResolved" : @NO,
        };
        NSError *err = nil;
        NSData *token = [NSPropertyListSerialization dataWithPropertyList:tokenPlist
                          format:NSPropertyListBinaryFormat_v1_0 options:0 error:&err];
        if (!token) { NULog("pc prev: token encode failed %{public}@", err); return; }

        MPCPlaybackIntent *intent = [[objc_getClass("MPCPlaybackIntent") alloc] init];
        [intent setTracklistToken:token];
        [intent setTracklistSource:500];

        NUInsertItemsCommand *insert = (NUInsertItemsCommand *)[tl insertCommand];
        id cmdReq = [insert insertAfterPlayingItemWithPlaybackIntent:intent];
        if (!cmdReq) { NULog("pc prev: no insert command request"); return; }

        Class CR = objc_getClass("MPCPlayerChangeRequest");
        MPCPlayerChangeRequest2 *req = [CR requestWithCommandRequests:@[ cmdReq ]];
        [req performWithCompletion:^(NSError *e) {
            NULog("pc prev: enqueued episode '%{public}@' err=%{public}@", uuid, e ?: @"none");
            [self changedSoonAfter:0.5];
        }];
    } @catch (NSException *e) {
        NULog("pc prev: threw %{public}@ :: %{public}@", e.name, e.reason);
    }
}

@end
