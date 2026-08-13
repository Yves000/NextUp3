#import "NUYouTubeMusicProvider.h"
#import "NUYouTubeShared.h"
#import "NUShared.h"
#import "LightMessaging.h"
#import <notify.h>
#import <UIKit/UIKit.h>

// Private YouTube Music interfaces (YTM 9.28.4). The read path was verified live on the iOS 18
// iPad; the queue write path was recovered statically from the decrypted IPA. The queue item,
// renderer and queue-edit classes are the same ones the main YouTube app ships and live in
// NUYouTubeShared.h; only the queue controller is declared per provider.
#pragma mark - Private YouTube Music interfaces

// YouTube Music's up-next queue. playbackQueueItems is the FULL list (already-played history sits
// at indices < nowPlayingIndex, like Apple Music), indexed the same as videoRendererAtIndex: and
// the navigable-index accessors. next/prev/after are all in this one index space (verified live).
@interface YTQueueController : NSObject
@property (readonly, nonatomic) unsigned long long queueCount;
@property (readonly, nonatomic) NSArray<YTQueueItem *> *playbackQueueItems;
@property (readonly, nonatomic) unsigned long long nowPlayingIndex; // current track's flat index (read path)
@property (readonly, nonatomic) unsigned long long nextNavigableVideoIndex;
@property (readonly, nonatomic) unsigned long long previousNavigableVideoIndex; // ~NSUIntegerMax when none
- (_Bool)hasNextVideo;
- (_Bool)hasPreviousVideo;
- (id)videoRendererAtIndex:(unsigned long long)index;                          // -> YTIPlaylistPanelVideoRenderer
- (unsigned long long)nextVideoIndexAfterIndex:(unsigned long long)index withAutoplay:(_Bool)autoplay;
- (void)playItemAtIndex:(unsigned long long)index;                             // play-now
- (void)removeVideoID:(id)videoID;                                             // skip (remove without playing)
- (id)indicesOfVideoID:(id)videoID;                                            // -> NSIndexSet (flat indices)
- (void)removeItemAtIndexPath:(id)path userTriggered:(_Bool)triggered;         // skip fallback
@end

#pragma mark - Provider

@interface NUYouTubeMusicProvider ()
@property (nonatomic, weak) YTQueueController *controller;
// The artwork cache (videoId → raw downloaded bytes) lives in NUProviderBase.
@end

@implementation NUYouTubeMusicProvider

+ (instancetype)shared {
    static NUYouTubeMusicProvider *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [NUYouTubeMusicProvider new]; });
    return s;
}

- (NSString *)appPrefKey { return @"enabledYouTubeMusic"; }

// Called from the YTQueueController hooks so we always hold the live controller.
- (void)captureController:(id)qc {
    if (qc && self.controller != qc) {
        self.controller = (YTQueueController *)qc;
        NULog("ytm provider: captured YTQueueController %p", qc);
    }
}

#pragma mark - Queue reading

- (NSUInteger)queueCount {
    NSUInteger c = 0; @try { c = (NSUInteger)self.controller.queueCount; } @catch (__unused NSException *e) {}
    return c;
}

// Index of the next-to-play item (shuffle/loop-aware). NSNotFound if none.
- (NSUInteger)nextIndex {
    YTQueueController *qc = self.controller;
    if (!qc) return NSNotFound;
    BOOL has = NO; @try { has = qc.hasNextVideo; } @catch (__unused NSException *e) {}
    if (!has) return NSNotFound;
    NSUInteger idx = NSNotFound; @try { idx = (NSUInteger)qc.nextNavigableVideoIndex; } @catch (__unused NSException *e) {}
    return (idx < [self queueCount]) ? idx : NSNotFound;
}

// The current track's flat index, or NSNotFound. Guarded: a YTM build without the
// accessor just skips the history-region guards below (behaviour as before).
- (NSUInteger)currentIndex {
    YTQueueController *qc = self.controller;
    if (!qc || ![qc respondsToSelector:@selector(nowPlayingIndex)]) return NSNotFound;
    NSUInteger idx = NSNotFound;
    @try { idx = (NSUInteger)qc.nowPlayingIndex; } @catch (__unused NSException *e) {}
    return (idx < [self queueCount]) ? idx : NSNotFound;
}

// The item that becomes next AFTER a skip of `idx` (forward carousel neighbour). NSNotFound if none.
- (NSUInteger)indexAfter:(NSUInteger)idx {
    if (idx == NSNotFound) return NSNotFound;
    NSUInteger after = NSNotFound;
    @try { after = (NSUInteger)[self.controller nextVideoIndexAfterIndex:idx withAutoplay:YES]; }
    @catch (__unused NSException *e) {}
    return (after < [self queueCount]) ? after : NSNotFound;
}

// Previously-played item (back carousel card). Guards the ~NSUIntegerMax sentinel returned when
// there is no history (verified: previousNavigableVideoIndex == 18446744073709551000 at index 0).
- (NSUInteger)previousIndex {
    YTQueueController *qc = self.controller;
    if (!qc) return NSNotFound;
    BOOL has = NO; @try { has = qc.hasPreviousVideo; } @catch (__unused NSException *e) {}
    if (!has) return NSNotFound;
    NSUInteger idx = NSNotFound; @try { idx = (NSUInteger)qc.previousNavigableVideoIndex; } @catch (__unused NSException *e) {}
    return (idx < [self queueCount]) ? idx : NSNotFound;
}

// {title, subtitle, videoId, item, artwork?} snapshot for the queue item at `index`, or nil if blank.
// `item` is kept for the artwork fetch (not serialized; the wire dict is built field-by-field).
- (NSDictionary *)infoForIndex:(NSUInteger)index {
    YTQueueController *qc = self.controller;
    if (!qc || index == NSNotFound) return nil;
    NSArray<YTQueueItem *> *items = nil;
    @try { items = qc.playbackQueueItems; } @catch (__unused NSException *e) { return nil; }
    if (index >= items.count) return nil;
    YTQueueItem *item = items[index];

    YTIPlaylistPanelVideoRenderer *r = nil;
    @try { r = [qc videoRendererAtIndex:index]; } @catch (__unused NSException *e) {}
    if (!r) { @try { r = [item rendererForContentMode:kNUYTContentModeArtTrack]; } @catch (__unused NSException *e) {} }
    if (!r) return nil;

    // The renderer accessors are private YTM API — guard the property reads
    // themselves too (a renamed selector must degrade, not throw into the caller).
    NSString *title = nil, *artist = nil, *videoId = nil;
    @try { title = NUYTFormattedText(r.title); } @catch (__unused NSException *e) {}
    @try { artist = NUYTFormattedText(r.shortBylineText); } @catch (__unused NSException *e) {}
    @try { videoId = r.videoId; } @catch (__unused NSException *e) {}
    if (title.length == 0 || videoId.length == 0) return nil;

    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"title"] = title;
    d[@"subtitle"] = artist ?: @"";
    d[@"videoId"] = videoId;
    d[@"item"] = item;
    NSData *art = [self cachedArtworkForKey:videoId];
    if (art) d[@"artwork"] = art;
    return d;
}

#pragma mark - Artwork (async URL fetch, cached by videoId)

// The artwork URL rule ("prefer the square art-track cover, fall back to the 16:9 YT
// thumbnail", verified in both app modes) is NUYTArtworkURLForItem() in NUYouTubeShared.h.

// Kick an async fetch for a snapshot's item if not cached / in flight; the base posts a change on
// arrival so the display re-queries and picks it up. The row shows its placeholder until then.
- (void)prefetchArtworkFor:(NSDictionary *)info {
    NSString *vid = info[@"videoId"];
    YTQueueItem *item = info[@"item"];
    if (vid.length == 0 || !item) return;
    if ([self cachedArtworkForKey:vid]) return;         // a track's cover never changes
    if ([self artworkFetchInFlightForKey:vid]) return;  // already fetching
    NSString *urlStr = NUYTArtworkURLForItem(item);
    NSURL *url = urlStr.length ? [NSURL URLWithString:urlStr] : nil;
    if (url) [self fetchArtworkAtURL:url forKey:vid];
}

// The on-screen next/fwd/back window the base prune must never evict.
- (NSArray<NSString *> *)artworkKeysToProtect {
    NSMutableArray *keys = [NSMutableArray array];
    NSUInteger ni = [self nextIndex];
    for (NSNumber *n in @[ @(ni), @([self indexAfter:ni]), @([self previousIndex]) ]) {
        NSString *v = [self infoForIndex:n.unsignedIntegerValue][@"videoId"];
        if (v) [keys addObject:v];
    }
    return keys;
}

#pragma mark - Snapshot (same wire shape as NUMusicProvider / NUPodcastProvider)

- (NSDictionary *)nextUpDictionary {
    if (![self providerEnabled]) return @{ kNUKeyActive : @NO }; // disabled in Settings → no queue/artwork work
    NSUInteger nextIdx = [self nextIndex];
    NSDictionary *nextInfo = [self infoForIndex:nextIdx];
    if (!nextInfo) return @{ kNUKeyActive : @NO };
    [self prefetchArtworkFor:nextInfo];

    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[kNUKeyActive] = @YES;
    dict[kNUKeyTitle] = nextInfo[@"title"];
    dict[kNUKeySubtitle] = nextInfo[@"subtitle"];
    if (nextInfo[@"artwork"]) dict[kNUKeyArtwork] = nextInfo[@"artwork"];
    dict[kNUKeyCanSkip] = @YES;

    // Forward carousel neighbour (what becomes next after a skip) — slides in on a left/skip swipe.
    NSDictionary *fwdInfo = [self infoForIndex:[self indexAfter:nextIdx]];
    if (fwdInfo) {
        [self prefetchArtworkFor:fwdInfo];
        dict[kNUKeyFwdTitle] = fwdInfo[@"title"];
        dict[kNUKeyFwdSubtitle] = fwdInfo[@"subtitle"];
        if (fwdInfo[@"artwork"]) dict[kNUKeyFwdArtwork] = fwdInfo[@"artwork"];
    }
    // Previously-played track (back card) straight from the queue history — re-queued on a right
    // swipe via -playPrevious (provider-side; no adamID, like Podcasts).
    NSDictionary *backInfo = [self infoForIndex:[self previousIndex]];
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

// Skip = remove the next track from the queue WITHOUT playing it.
- (void)skipNext {
    YTQueueController *qc = self.controller;
    if (!qc) { NULog("ytm skip: no controller"); return; }
    NSUInteger nextIdx = [self nextIndex];
    NSString *vid = [self infoForIndex:nextIdx][@"videoId"];
    if (vid.length == 0) { NULog("ytm skip: no next videoId"); return; }
    // Repeat-all at the queue tail wraps nextNavigableVideoIndex back to (or before)
    // the current track. Removing there mutates the HISTORY region — removals before
    // nowPlayingIndex shift later slots without adjusting it, which crashes YTM and
    // corrupts the persisted restorableQueueState. Refuse: a wrap
    // target isn't a skippable "up next" anyway.
    NSUInteger curIdx = [self currentIndex];
    if (curIdx != NSNotFound && nextIdx != NSNotFound && nextIdx <= curIdx) {
        NULog("ytm skip: next index %lu is at/before current %lu (repeat wrap) — refusing",
              (unsigned long)nextIdx, (unsigned long)curIdx);
        return;
    }
    @try {
        [qc removeVideoID:vid];
        NULog("ytm skip: removed '%{public}@'", vid);
    } @catch (__unused NSException *e) {
        // Fallback: index-path removal. -indicesOfVideoID: is
        // [queueItems indexesOfObjectsPassingTest:], i.e. an NSIndexSet of flat indices — not
        // index paths. offsetForHeaderItem is 0, so index i maps to row i in section 0.
        @try {
            NSIndexSet *indexes = [qc indicesOfVideoID:vid];
            // The same videoId can ALSO sit in the history region (replayed earlier this
            // session) — firstIndex would land on that slot and remove pre-current history
            // (the corruption case above). Prefer the exact next-up slot; otherwise the
            // first occurrence strictly after the current track; only with no current
            // index available fall back to the old firstIndex behaviour.
            NSUInteger row = NSNotFound;
            if ([indexes containsIndex:nextIdx]) row = nextIdx;
            else if (curIdx != NSNotFound)       row = [indexes indexGreaterThanIndex:curIdx];
            else if ([indexes respondsToSelector:@selector(firstIndex)]) row = indexes.firstIndex;
            if (row == NSNotFound) {
                NULog("ytm skip: '%{public}@' has no removable occurrence after current", vid);
            } else {
                [qc removeItemAtIndexPath:[NSIndexPath indexPathForRow:(NSInteger)row inSection:0] userTriggered:NO];
                NULog("ytm skip: removed via index path row %lu", (unsigned long)row);
            }
        } @catch (NSException *e2) { NULog("ytm skip threw %{public}@", e2.name); }
    }
    [self changedSoon];
}

// Play the up-next track now (cover tap). Signaled by the display via kNUJumpNotificationYouTubeMusic.
- (void)jumpToNext {
    YTQueueController *qc = self.controller;
    NSUInteger nextIdx = [self nextIndex];
    if (!qc || nextIdx == NSNotFound) return;
    @try { [qc playItemAtIndex:nextIdx]; NULog("ytm jump: playItemAtIndex %lu", (unsigned long)nextIdx); }
    @catch (NSException *e) { NULog("ytm jump threw %{public}@", e.name); }
    [self changedSoon];
}

// Re-queue the previously-played track to play NEXT, leaving the current track playing (Apple
// Music's "Play Next" semantic) and leaving the history intact.
//
// This must NOT move the history item into the next-up slot. -moveItemAtIndexPath:toIndexPath:
// does not adjust nowPlayingIndex, so moving an item out from BEFORE the current track shifts
// every later slot down by one and leaves nowPlayingIndex pointing at the wrong track — which
// crashes YTM and corrupts the persisted restorableQueueState.
//
// Instead we do what YTM's own "Play next" does: build a queue item and hand it to
// YTQueueModificationNotificationData at position InsertAfterCurrentVideo. That resolves to
// nowPlayingIndex + 1, so nothing before the current track moves and nowPlayingIndex stays valid.
// No network round trip is needed — unlike YTM's endpoint flow (which fetches renderers over
// watchNext for an arbitrary videoId) we already hold the previous track's renderers.
- (void)playPrevious {
    YTQueueController *qc = self.controller;
    if (!qc) { NULog("ytm prev: no controller"); return; }
    NSUInteger prevIdx = [self previousIndex];
    if (prevIdx == NSNotFound) { NULog("ytm prev: no previous"); return; }

    NSArray<YTQueueItem *> *items = nil;
    @try { items = qc.playbackQueueItems; } @catch (__unused NSException *e) { return; }
    if (prevIdx >= items.count) { NULog("ytm prev: index out of range"); return; }
    YTQueueItem *src = items[prevIdx];

    Class itemClass = NSClassFromString(@"YTQueueItem");
    Class notificationClass = NSClassFromString(@"YTQueueModificationNotificationData");
    if (!itemClass || !notificationClass) { NULog("ytm prev: YTM queue classes unavailable"); return; }

    @try {
        YTIPlaylistPanelVideoRenderer *base = src.videoRenderer;
        if (!base) { NULog("ytm prev: source item has no renderer"); return; }

        // A fresh item, so it mints its own localID — re-inserting `src` itself (or a -copy, which
        // carries localID over) would put two queue slots behind one identity.
        YTQueueItem *fresh = [itemClass queueItemWithPlaylistPanelVideoRenderer:base];
        if (!fresh) { NULog("ytm prev: could not build queue item"); return; }
        fresh.audioModeRenderer = src.audioModeRenderer;
        fresh.videoModeRenderer = src.videoModeRenderer;
        fresh.hasATVOMVPair = src.hasATVOMVPair;
        fresh.supportsAudioVideoSwitching = src.supportsAudioVideoSwitching;

        // predecessorSetVideoID / responseForLogging are only read for the InsertAtEnd and
        // InsertAfterSetVideoId positions and for YTM's own logging — nil is correct here.
        YTQueueModificationNotificationData *note =
            [notificationClass addToQueueNotificationWithQueueItems:@[fresh]
                                                  atInsertPosition:kNUYTInsertAfterCurrentVideo
                                             predecessorSetVideoID:nil
                                                responseForLogging:nil];
        if (!note) { NULog("ytm prev: could not build modification"); return; }
        [note send];
        NULog("ytm prev: enqueued '%{public}@' after current", NUYTFormattedText(base.title));
    } @catch (NSException *e) { NULog("ytm prev threw %{public}@", e.name); }
    [self changedSoon];
}

// -changed is NUProviderBase's (no self-tracked history — the queue holds it).

#pragma mark - LightMessaging server (YTM registers the service via libSandy)

- (void)startServer {
    [self startServerWithService:kNUServiceNameYouTubeMusic
                            skip:kNUSkipNotificationYouTubeMusic
                            prev:kNUPrevNotificationYouTubeMusic
                            jump:kNUJumpNotificationYouTubeMusic];
}

@end
