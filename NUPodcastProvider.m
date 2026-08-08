#import "NUPodcastProvider.h"
#import "NUShared.h"
#import "LightMessaging.h"
#import <notify.h>
#import <UIKit/UIKit.h>

#pragma mark - Private Podcasts interfaces (verified live via Frida)

@interface MTEpisode : NSObject
- (NSString *)bestTitle;      // clean episode title, e.g. "Bierlos in Boston (#409)"
- (NSString *)episodeIdentifier;
@end

// Wraps an episode's identifiers. episodeUUID is the string currency for the queue
// mutation API (addEpisodeUuidToPlayNext: / containsEpisodeUuid: / removeEpisodesForUuid:).
@interface MTEpisodeIdentifier : NSObject
- (NSString *)episodeUUID;
@end

// The MPNowPlayingContentItem behind a player item (iOS 14.2). MTPlayerItem's -episode is
// lazily nil there (content not loaded), but this content item carries the resolved title.
@interface MPNowPlayingContentItem : NSObject
- (NSString *)title;          // real episode title, e.g. "EDELTALK x HOBBYLOS: … (#397)"
- (NSString *)subtitle;
@end

@interface MTPlayerItem : NSObject
- (MTEpisode *)episode;
- (NSString *)subtitle;       // "Show — date", e.g. "Edeltalk - mit Dominik & Kevin — June 28, 2026"
- (NSString *)contentItemIdentifier;
- (MTEpisodeIdentifier *)episodeIdentifier;
- (MPNowPlayingContentItem *)contentItem;  // iOS 14.2 title fallback (see infoForItem)
- (NSString *)episodeUuid;                 // direct uuid accessor (present on some builds)
// Async artwork (verified signature v40@0:8@?16{CGSize=dd}24 — block + CGSize). The
// completion fires with the loaded image (or nil if not ready). Non-blocking, unlike
// -[MTEpisode artworkWithSize:], which does synchronous I/O.
- (void)retrieveArtwork:(void (^)(UIImage *image))completion withSize:(CGSize)size;
@end

// Podcasts' up-next queue. playerItems holds ONLY the upcoming episodes (the
// current one is not in it), so playerItems[0] is the NEXT episode.
@interface MTUpNextController : NSObject
- (NSUInteger)count;
- (BOOL)hasItemsInQueue;
- (NSArray<MTPlayerItem *> *)playerItems;
// Index of the NEXT-to-play episode within playerItems. When playing FROM the up-next
// queue, playerItems[0] is the CURRENT episode and this is > 0; otherwise it's 0 and
// the current episode isn't in the list. Verified live (isPlayingFromUpNext true→1, false→0).
- (NSUInteger)upNextOffset;
- (void)removeEpisodesForUuid:(NSString *)uuid;       // removes ALL entries with this episode uuid (synchronous)
- (void)addEpisodeUuidToPlayNext:(NSString *)uuid;    // appends a fresh entry at the tail (synchronous)
- (BOOL)moveEpisodeFrom:(NSUInteger)from to:(NSUInteger)to; // raw playerItems index space (verified)
- (id)playerController;
// iOS 14.2 path (queued items expose no episode uuid — verified live). Index-space removal and
// player-item re-enqueue work identically on both iOS versions.
- (void)removeEpisodeAtIndex:(NSUInteger)index;       // raw playerItems index
- (void)addPlayerItemToPlayNext:(MTPlayerItem *)item; // inserts at upNextOffset (the next slot)
- (void)beginUpdates;
- (void)endUpdates;
@end

// Plays a queue episode by its content id — the MT* "play this now" lever (iOS 17). Reached from
// the player controller; -playItemAtIndex: uses a different (non-playerItems) index space, so
// content-id is the reliable handle. Verified live on iOS 17.
@interface MTPlaybackQueueController : NSObject
- (void)playItemWithContentID:(NSString *)contentID;
@end

@interface MTPlayerController : NSObject
- (MTUpNextController *)upNextController;
- (MTPlayerItem *)currentItem;
- (NSString *)playingEpisodeUuid;
- (MTPlaybackQueueController *)playbackQueueController;
@end

#pragma mark - Provider

@interface NUPodcastProvider ()
@property (nonatomic, weak) MTPlayerController *controller;
@property (nonatomic, weak) MTUpNextController *capturedUpNext; // iOS 14.2: no controller->upNext accessor
// episodeUUID → pre-encoded PNG. Keyed by the STABLE episode uuid (not the per-slot
// contentItemIdentifier, which differs each time an episode moves between next/current/
// history slots — so a slot key can't follow an episode into the back/history card).
// Encoded off the main thread so the LM server reply (read on the main thread) stays cheap.
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSData *> *artworkPNGByUUID;
// uuid → when its fetch started. Date-stamped (not a bare set) so a fetch whose
// completion the MT machinery swallowed goes STALE and can be retried — a bare
// in-flight mark would block that episode's artwork for the process lifetime
// (the exact failure the Music provider's chain watchdog exists for).
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDate *> *artworkInFlightSince;
// Self-recorded play history (in-memory), oldest→newest, excluding the current
// episode. Each entry: {uuid, title, subtitle, contentId, artwork?}. The last entry
// is the "previous" episode shown on the back carousel card / re-queued on play-prev.
// We snapshot metadata ourselves so the back card needs no uuid→episode resolution
// (that path is a CoreData lookup and Podcasts is crash-prone under introspection).
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *playHistory;
@property (nonatomic, strong) NSDictionary *currentInfo; // the episode currently playing
@end

// Artwork request size (points; the row downsizes). Large enough to stay crisp at 3x.
static const CGFloat kNUPodcastArtworkSize = 120.0;

@implementation NUPodcastProvider

+ (instancetype)shared {
    static NUPodcastProvider *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [NUPodcastProvider new]; });
    return s;
}

- (NSString *)appPrefKey { return @"enabledPodcasts"; }

// Called from the MT* hooks so we always hold the live singleton controller.
- (void)captureController:(id)pc {
    if (pc && self.controller != pc) {
        self.controller = (MTPlayerController *)pc;
        NULog("pc provider: captured MTPlayerController %p", pc);
    }
}

- (void)captureUpNext:(id)up {
    if (up && self.capturedUpNext != up) {
        self.capturedUpNext = (MTUpNextController *)up;
        NULog("pc provider: captured MTUpNextController %p", up);
    }
}

- (MTUpNextController *)upNext {
    // Prefer the directly-captured controller (the only handle on iOS 14.2, where
    // -[MTPlayerController upNextController] doesn't exist); fall back to the accessor on
    // builds that have it (iOS 17) in case a query beats the first hook.
    if (self.capturedUpNext) return self.capturedUpNext;
    @try {
        if ([self.controller respondsToSelector:@selector(upNextController)])
            return [self.controller upNextController];
    } @catch (__unused NSException *e) {}
    return nil;
}

// Stable per-episode key. iOS 17 has episodeUUID; on iOS 14.2 both uuid paths are nil for a
// not-yet-loaded queue item, so fall back to contentItemIdentifier (enough to key artwork and
// identify the visible next item).
- (NSString *)uuidForItem:(MTPlayerItem *)item {
    NSString *u = nil;
    @try { u = [[item episodeIdentifier] episodeUUID]; } @catch (__unused NSException *e) {}
    if (u.length) return u;
    @try { u = [item episodeUuid]; } @catch (__unused NSException *e) {}
    if (u.length) return u;
    @try { u = [item contentItemIdentifier]; } @catch (__unused NSException *e) {}
    return u;
}

// Up-next item, `index` steps ahead of the current position (0 = next episode).
// playerItems is indexed from upNextOffset: [upNextOffset] is the next episode, and
// entries before it are the current/already-played ones (present only when playing
// from the queue). Using the offset avoids showing the current episode as "next".
- (MTPlayerItem *)itemAtQueueIndex:(NSUInteger)index {
    MTUpNextController *up = [self upNext];
    if (!up) return nil;
    @try {
        if (![up hasItemsInQueue]) return nil;
        NSArray<MTPlayerItem *> *items = [up playerItems];
        NSInteger base = 0;
        @try { base = (NSInteger)[up upNextOffset]; } @catch (__unused NSException *e) {}
        NSInteger idx = base + (NSInteger)index;
        if (idx < 0 || idx >= (NSInteger)items.count) return nil;
        return items[idx];
    } @catch (__unused NSException *e) { return nil; }
}

- (MTPlayerItem *)nextItem { return [self itemAtQueueIndex:0]; }

// {uuid, title, subtitle, contentId, artwork?} snapshot for an item, or nil if blank.
- (NSDictionary *)infoForItem:(MTPlayerItem *)item {
    if (!item) return nil;
    NSString *title = nil, *subtitle = nil, *cid = nil, *uuid = nil;
    @try { title = [[item episode] bestTitle]; } @catch (__unused NSException *e) {}
    // iOS 14.2: -episode is lazily nil for a queued-but-unplayed item, so the episode title
    // is unavailable that way — the loaded content item carries it instead.
    if (title.length == 0) { @try { title = [[item contentItem] title]; } @catch (__unused NSException *e) {} }
    @try { subtitle = [item subtitle]; } @catch (__unused NSException *e) {}
    @try { cid = [item contentItemIdentifier]; } @catch (__unused NSException *e) {}
    uuid = [self uuidForItem:item];
    if (title.length == 0) return nil;
    // Real episode uuid, only when the item actually exposes one (iOS 17). On iOS 14.2 this is
    // nil, which is how -playPrevious decides between the uuid procedure and the player-item one.
    NSString *realUuid = nil;
    @try { realUuid = [[item episodeIdentifier] episodeUUID]; } @catch (__unused NSException *e) {}
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"title"] = title;
    d[@"subtitle"] = subtitle ?: @"";
    if (cid) d[@"contentId"] = cid;
    if (uuid) d[@"uuid"] = uuid;
    if (realUuid.length) d[@"episodeUUID"] = realUuid;
    // Keep a strong ref to the item ONLY on the iOS 14.2 path that needs it: -playPrevious re-queues
    // by player item when there's no episode uuid. Where a uuid exists (iOS 17) the item is never
    // used, so don't pin its episode/artwork/AVAsset graph in up to 25 history entries. Not
    // serialized — the wire dict is built field-by-field.
    if (item && realUuid.length == 0) d[@"playerItem"] = item;
    NSData *png = uuid ? self.artworkPNGByUUID[uuid] : nil; // keyed by stable episode uuid
    if (png) d[@"artwork"] = png;
    return d;
}

// Keep playHistory in step with actual play order: when the current episode changes,
// push the one we just left (or pop, if we went backward to it). Mirrors
// NUMusicProvider -recordCurrentTrack.
- (void)recordCurrentItem {
    MTPlayerItem *cur = nil;
    @try { cur = [self.controller currentItem]; } @catch (__unused NSException *e) {}
    NSDictionary *info = [self infoForItem:cur];
    NSString *uuid = info[@"uuid"];
    if (!uuid) return;
    if ([self.currentInfo[@"uuid"] isEqualToString:uuid]) return; // unchanged

    if (!self.playHistory) self.playHistory = [NSMutableArray array];
    // "Went backward" match: by uuid, or — for iOS 14.2, where the uuid falls back
    // to the per-SLOT contentItemIdentifier that changes as an episode moves
    // between next/current/history — by the retained player-item's identity, so
    // backward navigation still pops instead of pushing a duplicate entry.
    NSDictionary *last = self.playHistory.lastObject;
    BOOL wentBack = last && ([last[@"uuid"] isEqualToString:uuid] ||
                             (last[@"playerItem"] != nil && last[@"playerItem"] == cur));
    if (wentBack) {
        [self.playHistory removeLastObject]; // went backward to the previous episode
    } else if (self.currentInfo) {
        [self.playHistory addObject:self.currentInfo]; // left the previous current
        while (self.playHistory.count > 25) [self.playHistory removeObjectAtIndex:0];
    }
    self.currentInfo = info;
}

- (void)changed {
    // -recordCurrentItem mutates playHistory/currentInfo. The MT* hooks (-_upNextDidChange /
    // -setPlayerItems:) fire on a background AMS queue, while the LM server callback also runs
    // -recordCurrentItem (via -nextUpDictionary) on the main thread — so pin every mutation to the
    // main queue, otherwise two threads mutate the same NSMutableArray and Podcasts crashes.
    if ([NSThread isMainThread]) [self recordCurrentItem];
    else dispatch_async(dispatch_get_main_queue(), ^{ [self recordCurrentItem]; });
    notify_post(kNUChangedNotification);
}

#pragma mark - Artwork (async fetch, cached by content id as PNG)

// Kick an async artwork fetch for `item` if not already cached / in flight. On
// arrival the PNG is cached and a change is posted so the display re-queries and
// picks it up — the row shows its placeholder until then.
- (void)prefetchArtworkForItem:(MTPlayerItem *)item {
    if (!item) return;
    NSString *uuid = [self uuidForItem:item];
    if (uuid.length == 0) return;
    if (!self.artworkPNGByUUID) self.artworkPNGByUUID = [NSMutableDictionary dictionary];
    if (!self.artworkInFlightSince) self.artworkInFlightSince = [NSMutableDictionary dictionary];
    if (self.artworkPNGByUUID[uuid]) return;               // cached (an episode's artwork never changes)
    NSDate *since = self.artworkInFlightSince[uuid];
    if (since && -since.timeIntervalSinceNow < 20.0) return; // a live fetch is running
    if (since) NULog("pc provider: stale artwork fetch for '%{public}@' — retrying", uuid);
    self.artworkInFlightSince[uuid] = [NSDate date];

    __weak typeof(self) weakSelf = self;
    void (^completion)(UIImage *) = ^(UIImage *image) {
        if (!image) {
            // Not ready yet — drop the in-flight mark so a later query retries.
            dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf.artworkInFlightSince removeObjectForKey:uuid]; });
            return;
        }
        // Encode the PNG off the main thread — the server reply reads this cache on
        // the main thread and must never pay for encoding there.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSData *png = UIImagePNGRepresentation(image);
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) self = weakSelf; if (!self) return;
                [self.artworkInFlightSince removeObjectForKey:uuid];
                if (!png) return;
                self.artworkPNGByUUID[uuid] = png;
                // Artwork often lands only after its episode moved to current/history — patch
                // those snapshots so the back card shows art during the swipe, not just once
                // the item is a live queue slot again.
                [self backfillArtwork:png forUUID:uuid];
                // Bound the live cache. History entries keep their OWN PNG copy (infoForItem
                // snapshots it), so pruning here can't blank a back/history card. The bound
                // check INSIDE the loop is what makes this a trim — without it (the old bug,
                // a drift from the Spotify/YTM siblings) one new arrival evicted every other
                // entry, so the visible cards flashed placeholders and refetched forever.
                // Protect the whole on-screen window (next / fwd / back-fallback), not just
                // the arrived uuid — allKeys is unordered, so an unprotected prune can evict
                // the very artwork a visible card is showing (the same keep-set the
                // Spotify/YTM prune in NUProviderBase uses).
                if (self.artworkPNGByUUID.count > 12) {
                    NSMutableSet *keep = [NSMutableSet setWithObject:uuid];
                    NSString *n = [self uuidForItem:[self nextItem]];
                    if (n) [keep addObject:n];
                    NSString *f = [self uuidForItem:[self itemAtQueueIndex:1]];
                    if (f) [keep addObject:f];
                    NSString *b = self.playHistory.lastObject[@"uuid"];
                    if (b) [keep addObject:b];
                    for (NSString *k in self.artworkPNGByUUID.allKeys) {
                        if (self.artworkPNGByUUID.count <= 12) break;
                        if (![keep containsObject:k]) [self.artworkPNGByUUID removeObjectForKey:k];
                    }
                }
                NULog("pc provider: cached artwork for episode '%{public}@'", uuid);
                notify_post(kNUChangedNotification); // artwork now available
            });
        });
    };
    @try {
        [item retrieveArtwork:completion withSize:CGSizeMake(kNUPodcastArtworkSize, kNUPodcastArtworkSize)];
    } @catch (__unused NSException *e) {
        [self.artworkInFlightSince removeObjectForKey:uuid];
    }
}

// Patch a freshly-loaded PNG into the current-episode snapshot and any history entries
// with the same uuid, so the back/history card isn't stuck on a placeholder when the
// artwork arrived after the episode had already moved out of the live queue window.
- (void)backfillArtwork:(NSData *)png forUUID:(NSString *)uuid {
    if (!png || uuid.length == 0) return;
    if ([self.currentInfo[@"uuid"] isEqualToString:uuid] && !self.currentInfo[@"artwork"]) {
        NSMutableDictionary *m = [self.currentInfo mutableCopy]; m[@"artwork"] = png; self.currentInfo = m;
    }
    for (NSUInteger i = 0; i < self.playHistory.count; i++) {
        NSDictionary *e = self.playHistory[i];
        if ([e[@"uuid"] isEqualToString:uuid] && !e[@"artwork"]) {
            NSMutableDictionary *m = [e mutableCopy]; m[@"artwork"] = png; self.playHistory[i] = m;
        }
    }
}

// Same wire shape as NUMusicProvider so the display renders it identically:
// next episode (title/subtitle/artwork) + skip, the forward carousel neighbour, and the
// previous episode (from our recorded history) on the back card.
- (NSDictionary *)nextUpDictionary {
    if (![self providerEnabled]) return @{ kNUKeyActive : @NO }; // disabled in Settings → no queue/artwork work
    [self recordCurrentItem]; // keep history/current fresh even without a change hook

    MTPlayerItem *next = [self nextItem];
    NSDictionary *nextInfo = [self infoForItem:next];
    if (!nextInfo) return @{ kNUKeyActive : @NO };

    // A query means a display wants the window — kick artwork loading now for the
    // visible cards; retrieveArtwork's completion notifies when it lands.
    [self prefetchArtworkForItem:next];
    MTPlayerItem *fwd = [self itemAtQueueIndex:1];
    [self prefetchArtworkForItem:fwd];

    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[kNUKeyActive] = @YES;
    dict[kNUKeyTitle] = nextInfo[@"title"];
    dict[kNUKeySubtitle] = nextInfo[@"subtitle"];
    if (nextInfo[@"artwork"]) dict[kNUKeyArtwork] = nextInfo[@"artwork"];
    dict[kNUKeyCanSkip] = @YES;

    // Forward carousel neighbour (next-next) — slides in on a left/skip swipe.
    NSDictionary *fwdInfo = [self infoForItem:fwd];
    if (fwdInfo) {
        dict[kNUKeyFwdTitle] = fwdInfo[@"title"];
        dict[kNUKeyFwdSubtitle] = fwdInfo[@"subtitle"];
        if (fwdInfo[@"artwork"]) dict[kNUKeyFwdArtwork] = fwdInfo[@"artwork"];
    }
    // Previous episode (back carousel card) from our recorded history; re-queued on a
    // right swipe via -playPrevious. No adamID needed — the provider does the enqueue.
    NSDictionary *back = self.playHistory.lastObject;
    dict[kNUKeyCanPrev] = @(back != nil);
    if (back) {
        dict[kNUKeyBackTitle] = back[@"title"];
        dict[kNUKeyBackSubtitle] = back[@"subtitle"];
        NSData *bpng = back[@"artwork"];
        if (!bpng && back[@"uuid"]) bpng = self.artworkPNGByUUID[back[@"uuid"]]; // live cache fallback
        if (bpng) dict[kNUKeyBackArtwork] = bpng;
    }
    return dict;
}

- (void)skipNext {
    @try {
        MTUpNextController *up = [self upNext];
        if (!up) { NULog("pc skip: no up-next controller"); return; }
        MTPlayerItem *next = [self nextItem];
        if (!next) { NULog("pc skip: no next item"); return; }
        NSString *uuid = nil;
        @try { uuid = [[next episodeIdentifier] episodeUUID]; } @catch (__unused NSException *e) {}
        // Never uuid-remove the currently-playing episode: when playing FROM the queue its
        // live entry sits in playerItems too, and removeEpisodesForUuid: rips out EVERY
        // entry with that uuid — including the live one, disrupting playback mid-episode
        // (same hazard -playPrevious already guards). If the queued copy of the current
        // episode is next, fall through to the slot-precise index removal instead.
        if (uuid.length) {
            NSString *playing = nil;
            @try { playing = [self.controller playingEpisodeUuid]; } @catch (__unused NSException *e) {}
            if (playing.length && [uuid isEqualToString:playing]) uuid = nil;
        }
        if (uuid.length) {
            [up removeEpisodesForUuid:uuid]; // iOS 17: remove the next episode by uuid (dedups copies)
            NULog("pc skip: removed next uuid '%{public}@'", uuid);
        } else {
            // iOS 14.2 (no episode uuid) — or the uuid path was refused above: remove the next
            // by index. The next episode is playerItems[upNextOffset] (indices below it are
            // the current/played ones). Index removal works identically on both iOS versions.
            NSInteger idx = 0;
            @try { idx = (NSInteger)[up upNextOffset]; } @catch (__unused NSException *e) {}
            NSArray *items = nil;
            @try { items = [up playerItems]; } @catch (__unused NSException *e) {}
            if (idx < 0 || idx >= (NSInteger)items.count) { NULog("pc skip: next index %ld out of range", (long)idx); return; }
            @try { [up beginUpdates]; } @catch (__unused NSException *e) {}
            [up removeEpisodeAtIndex:(NSUInteger)idx];
            @try { [up endUpdates]; } @catch (__unused NSException *e) {}
            NULog("pc skip: removed next at index %ld", (long)idx);
        }
        // The controller fires its own _upNextDidChange (hooked → changed), but
        // push an update ourselves too and again shortly after it settles.
        [self changedSoon];
    } @catch (NSException *e) {
        NULog("pc skip: threw %{public}@", e.name);
    }
}

// Re-queue the previously-played episode to play next (mirrors Music's "Play Next"
// on the back carousel card). The enqueue must run here (the MTUpNextController is
// in-process), triggered by the display via kNUPrevNotificationPodcasts.
// Make the previous episode the IMMEDIATE next, with no duplicates. Verified procedure
// (empirical reverse-engineering): dedup all copies, append one fresh entry, then move it
// to upNextOffset. All three mutators are synchronous on the main thread (this runs on the
// main queue via the notify handler); moveEpisodeFrom:to: uses raw playerItems indices.
- (void)playPrevious {
    @try {
        NSDictionary *back = self.playHistory.lastObject;
        if (!back) { NULog("pc prev: no history"); return; }
        MTUpNextController *up = [self upNext];
        if (!up) { NULog("pc prev: no up-next controller"); return; }

        NSString *uuid = back[@"episodeUUID"]; // real episode uuid — present only on iOS 17
        if (uuid.length) {
            // Never touch the currently-playing episode: removeEpisodesForUuid: would rip out
            // the live entry when playing from the queue.
            NSString *playing = nil;
            @try { playing = [self.controller playingEpisodeUuid]; } @catch (__unused NSException *e) {}
            if ([uuid isEqualToString:playing]) { NULog("pc prev: uuid is current — skip"); return; }

            [up removeEpisodesForUuid:uuid];   // dedup (no-op if absent)
            [up addEpisodeUuidToPlayNext:uuid]; // one fresh entry at the tail

            // Locate the fresh entry by uuid (don't assume tail) and move it to the next slot.
            NSArray<MTPlayerItem *> *items = [up playerItems];
            NSUInteger idx = NSNotFound;
            for (NSUInteger i = 0; i < items.count; i++) {
                NSString *u = nil;
                @try { u = [[items[i] episodeIdentifier] episodeUUID]; } @catch (__unused NSException *e) {}
                if ([u isEqualToString:uuid]) { idx = i; break; }
            }
            NSUInteger off = 0;
            @try { off = [up upNextOffset]; } @catch (__unused NSException *e) {}
            if (idx != NSNotFound && idx != off && off < items.count) [up moveEpisodeFrom:idx to:off];
            NULog("pc prev: '%{public}@' -> next (idx=%lu off=%lu)", uuid, (unsigned long)idx, (unsigned long)off);
        } else {
            // iOS 14.2: no episode uuid to enqueue by. Re-queue the retained MTPlayerItem we kept
            // when it was the current episode — -addPlayerItemToPlayNext: inserts it at upNextOffset
            // (verified live). No dedup needed: a just-left episode isn't already in the queue.
            MTPlayerItem *prevItem = back[@"playerItem"];
            if (!prevItem) { NULog("pc prev: no retained player item"); return; }
            // Safety net: don't re-add the current episode (compare by content id — no uuid on 14).
            NSString *prevCid = nil, *curCid = nil;
            @try { prevCid = [prevItem contentItemIdentifier]; } @catch (__unused NSException *e) {}
            @try { curCid = [[self.controller currentItem] contentItemIdentifier]; } @catch (__unused NSException *e) {}
            if (prevCid.length && [prevCid isEqualToString:curCid]) { NULog("pc prev: item is current — skip"); return; }
            @try { [up beginUpdates]; } @catch (__unused NSException *e) {}
            [up addPlayerItemToPlayNext:prevItem];
            @try { [up endUpdates]; } @catch (__unused NSException *e) {}
            NULog("pc prev: re-queued retained item '%{public}@' as next", back[@"title"]);
        }

        [self changedSoon];
    } @catch (NSException *e) {
        NULog("pc prev: threw %{public}@", e.name);
    }
}

#pragma mark - LightMessaging server (Podcasts registers the service via libSandy)

- (void)startServer {
    [self startServerWithService:kNUServiceNamePodcasts
                            skip:kNUSkipNotificationPodcasts
                            prev:kNUPrevNotificationPodcasts
                            jump:kNUJumpNotificationPodcasts];
}

// Play the next-up episode now (cover tap). iOS 17 Podcasts maps the MediaRemote NextTrack command
// to a 30s skip, so jump the playback queue to the next episode's content id directly instead.
// (Only reached on iOS 17: the display gates this to iOS>=17, and iOS 18 uses the MPC provider.)
- (void)jumpToNext {
    @try {
        MTPlayerItem *next = [self nextItem];
        NSString *cid = nil;
        @try { cid = [next contentItemIdentifier]; } @catch (__unused NSException *e) {}
        if (cid.length == 0) { NULog("pc jump: no next content id"); return; }
        MTPlaybackQueueController *qc = nil;
        @try { if ([self.controller respondsToSelector:@selector(playbackQueueController)]) qc = [self.controller playbackQueueController]; } @catch (__unused NSException *e) {}
        if (!qc) { NULog("pc jump: no playback queue controller"); return; }
        [qc playItemWithContentID:cid];
        NULog("pc jump: -> '%{public}@'", cid);
        [self changedSoonAfter:0.5];
    } @catch (NSException *e) {
        NULog("pc jump: threw %{public}@ :: %{public}@", e.name, e.reason);
    }
}

@end
