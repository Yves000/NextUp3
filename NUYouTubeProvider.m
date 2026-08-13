#import "NUYouTubeProvider.h"
#import "NUYouTubeShared.h"
#import "NUShared.h"
#import "LightMessaging.h"
#import <notify.h>
#import <UIKit/UIKit.h>

// Private YouTube interfaces (YouTube 21.32.4). The shared YT*/YTI* item and renderer
// classes live in NUYouTubeShared.h; only the queue controller is declared here, because
// the main app needs the autoplay-section accessors YouTube Music never uses.
#pragma mark - Private YouTube interfaces

// YouTube's queue. One flat index space over two regions:
//
//   [0, queueCount)   the queue proper — playlist / mix / "Add to queue". Mutable.
//   [queueCount, …)   the autoplay section (and, on a radio playlist, the hidden
//                     lookahead). Read-only; the app refills it server-side.
//
// -queueItemAtIndex:includeAutoplaySection: resolves both and returns nil out of range;
// -videoRendererAtIndex: is that call with YES plus -videoRenderer.
//
// The -nextNavigableVideoIndex property is -nextNavigableVideoIndexWithAutoplay:NO and
// never leaves the queue region, so this provider always passes YES.
@interface YTQueueController : NSObject
@property (readonly, nonatomic) unsigned long long queueCount;          // real-queue length only
@property (readonly, nonatomic) NSArray<YTQueueItem *> *playbackQueueItems; // the real queue, flat
@property (readonly, nonatomic) unsigned long long nowPlayingIndex;     // current item's flat index
@property (readonly, nonatomic) unsigned long long previousNavigableVideoIndex; // ~NSUIntegerMax when none
@property (readonly, nonatomic) unsigned long long autoplayItemCount;   // capped display count
- (unsigned long long)offsetForHeaderItem;                              // 0-2: leading header rows
- (_Bool)hasNextVideo;                                                  // autoplay-aware
- (_Bool)hasPreviousVideo;
- (unsigned long long)nextNavigableVideoIndexWithAutoplay:(_Bool)autoplay;
- (unsigned long long)nextVideoIndexAfterIndex:(unsigned long long)index withAutoplay:(_Bool)autoplay;
- (id)queueItemAtIndex:(unsigned long long)index includeAutoplaySection:(_Bool)includeAutoplay; // -> YTQueueItem
- (id)videoRendererAtIndex:(unsigned long long)index;                   // -> YTIPlaylistPanelVideoRenderer
- (void)playItemAtIndex:(unsigned long long)index;                      // play-now
// -removeVideoID:/-indicesOfVideoID: match on
// videoRenderer.navigationEndpoint.activeOnlineOrOfflineWatchEndpoint.videoId, NOT on
// videoRenderer.videoId — that endpoint is nil for ordinary playlist entries, so they are
// a no-op here and only serve as a fallback. Removal goes through the index path.
- (void)removeVideoID:(id)videoID;
- (id)indicesOfVideoID:(id)videoID;                                     // -> NSIndexSet into the real queue
- (void)removeItemAtIndexPath:(id)path userTriggered:(_Bool)triggered;  // section 0 row = flat queue index
- (void)promoteAutoplayItemsAtIndexPaths:(id)paths userTriggered:(_Bool)triggered;
@end

// The app's own "Up next" card for a standalone video: title, channel, preview and video id
// in one renderer, so the watch-next response needs no parsing.
@interface YTIPlayerOverlayAutoplayRenderer : NSObject
@property (retain, nonatomic) YTIFormattedString *videoTitle;   // the NEXT video's title
@property (retain, nonatomic) YTIFormattedString *byline;       // its channel
@property (retain, nonatomic) YTIThumbnailDetails *nextVideoPreview; // 16:9 preview frames
@property (retain, nonatomic) YTIThumbnailDetails *background;       // endscreen backdrop
@property (copy, nonatomic) NSString *videoId;
@end

// Drives autoplay for the watch page. This is the only source for a standalone video:
// on 21.32.4 YTQueueController stays empty (queueCount 0) throughout such playback.
@interface YTAutoplayAutonavController : NSObject
- (id)autonavRenderer;      // -> YTIPlayerOverlayAutoplayRenderer
- (_Bool)hasAutonavVideo;
- (_Bool)hasAutoplayVideo;
- (_Bool)hasNextVideo;
- (void)playNext;           // play-now for the shown suggestion
@end

// Ceiling for indices from the navigation accessors, which return a ~NSUIntegerMax sentinel
// for "none". The queue accessors handle huge indices safely; this stops one earlier.
static const NSUInteger kNUYTMaxNavigableIndex = 100000;

#pragma mark - Provider

@interface NUYouTubeProvider ()
@property (nonatomic, weak) YTQueueController *controller;
@property (nonatomic, weak) YTAutoplayAutonavController *autonav;
// YES while the served snapshot came from the autoplay renderer rather than the queue —
// jump has to route to a different object then.
@property (nonatomic) BOOL servingAutoplay;
// Play history, depth 1. Held strongly: the back card must survive the slot being removed
// from the queue, and -playPrevious rebuilds from this item's renderer.
@property (nonatomic, strong) YTQueueItem *lastPlayedItem;
@property (nonatomic, copy)   NSString *lastPlayedVideoId;
@property (nonatomic, strong) YTQueueItem *currentItem;
@property (nonatomic, copy)   NSString *currentVideoId;
// Deadline until which the index/count republish stays suppressed. A time window rather
// than a flag around the call: the app publishes through a dispatch queue.
@property (nonatomic) CFTimeInterval lockScreenSuppressUntil;
// The artwork cache (videoId → raw downloaded bytes) lives in NUProviderBase.
@end

@implementation NUYouTubeProvider

+ (instancetype)shared {
    static NUYouTubeProvider *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [NUYouTubeProvider new]; });
    return s;
}

- (NSString *)appPrefKey { return @"enabledYouTube"; }

// Called from the YTQueueController hooks so we always hold the live controller.
- (void)captureController:(id)qc {
    if (qc && self.controller != qc) {
        if (self.controller) [self resetHistory]; // new playback session
        self.controller = (YTQueueController *)qc;
        NULog("yt provider: captured YTQueueController %p", qc);
    }
}

- (void)captureAutonavController:(id)ac {
    if (ac && self.autonav != ac) {
        self.autonav = (YTAutoplayAutonavController *)ac;
        NULog("yt provider: captured YTAutoplayAutonavController %p", ac);
    }
}

// The autoplay suggestion as {title, subtitle, videoId, artURL, inQueue:NO}, or nil. There is
// exactly one and it cannot be removed, so the snapshot reports canSkip NO and no forward card.
- (NSDictionary *)autoplayInfo {
    YTAutoplayAutonavController *ac = self.autonav;
    if (!ac) return nil;
    BOOL has = NO;
    @try { has = (ac.hasAutonavVideo || ac.hasNextVideo || ac.hasAutoplayVideo); }
    @catch (__unused NSException *e) {}
    if (!has) return nil;

    YTIPlayerOverlayAutoplayRenderer *r = nil;
    @try { r = [ac autonavRenderer]; } @catch (__unused NSException *e) {}
    if (!r) return nil;

    NSString *title = nil, *byline = nil, *videoId = nil, *artURL = nil;
    @try { title = NUYTFormattedText(r.videoTitle); } @catch (__unused NSException *e) {}
    @try { byline = NUYTFormattedText(r.byline); } @catch (__unused NSException *e) {}
    @try { videoId = r.videoId; } @catch (__unused NSException *e) {}
    @try { artURL = NUYTLargestThumbURL(r.nextVideoPreview); } @catch (__unused NSException *e) {}
    if (!artURL) { @try { artURL = NUYTLargestThumbURL(r.background); } @catch (__unused NSException *e) {} }
    if (!artURL) artURL = NUYTThumbnailURLForVideoId(videoId);
    if (title.length == 0) return nil;
#ifdef DEBUG
    NULog("yt autoplay: title='%{public}@' vid='%{public}@' art=%{public}@",
          title, videoId, artURL ?: @"(none)");
#endif

    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"title"] = title;
    d[@"subtitle"] = byline ?: @"";
    // The renderer does not always carry a videoId; the preview URL is equally stable per
    // suggestion, so it serves as the cache key instead.
    d[@"videoId"] = videoId.length ? videoId : (artURL ?: title);
    if (artURL) d[@"artURL"] = artURL;
    d[@"inQueue"] = @NO;
    NSData *art = [self cachedArtworkForKey:d[@"videoId"]];
    if (art) d[@"artwork"] = art;
    return d;
}

// Long enough to cover the app's async now-playing publish, short enough that a real track
// change landing right after a skip still reaches the Lock Screen.
static const CFTimeInterval kNUYTLockScreenSuppressWindow = 0.5;

// Monotonic clock: the wall clock is settable, and a backwards step inside the window would
// extend the suppression by the size of that step.
- (void)beginQueueMutation {
    self.lockScreenSuppressUntil = CACurrentMediaTime() + kNUYTLockScreenSuppressWindow;
}

- (BOOL)suppressesLockScreenIndexUpdate {
    return CACurrentMediaTime() < self.lockScreenSuppressUntil;
}

#pragma mark - Queue reading

// Length of the mutable region. An index below this is a real queue slot (skippable);
// at or above it the item comes from the autoplay section, which the app owns.
- (NSUInteger)queueCount {
    NSUInteger c = 0; @try { c = (NSUInteger)self.controller.queueCount; } @catch (__unused NSException *e) {}
    return c;
}

- (BOOL)isQueueIndex:(NSUInteger)index {
    return index != NSNotFound && index < [self queueCount];
}

// The YTQueueItem at a flat index across BOTH regions, or nil.
- (YTQueueItem *)itemAtIndex:(NSUInteger)index {
    YTQueueController *qc = self.controller;
    if (!qc || index == NSNotFound || index > kNUYTMaxNavigableIndex) return nil;
    if ([qc respondsToSelector:@selector(queueItemAtIndex:includeAutoplaySection:)]) {
        @try {
            YTQueueItem *item = [qc queueItemAtIndex:index includeAutoplaySection:YES];
            if (item) return item;
        } @catch (__unused NSException *e) {}
    }
    // Fallback for a build without that selector: the real queue only.
    NSArray<YTQueueItem *> *items = nil;
    @try { items = qc.playbackQueueItems; } @catch (__unused NSException *e) { return nil; }
    return (index < items.count) ? items[index] : nil;
}

// Index of the next-to-play item, autoplay section included. NSNotFound if none.
- (NSUInteger)nextIndex {
    YTQueueController *qc = self.controller;
    if (!qc) return NSNotFound;
    BOOL has = NO; @try { has = qc.hasNextVideo; } @catch (__unused NSException *e) {}
    if (!has) return NSNotFound;
    NSUInteger idx = NSNotFound;
    @try { idx = (NSUInteger)[qc nextNavigableVideoIndexWithAutoplay:YES]; } @catch (__unused NSException *e) {}
    return (idx <= kNUYTMaxNavigableIndex) ? idx : NSNotFound;
}

// The current item's flat index, or NSNotFound.
- (NSUInteger)currentIndex {
    YTQueueController *qc = self.controller;
    if (!qc || ![qc respondsToSelector:@selector(nowPlayingIndex)]) return NSNotFound;
    NSUInteger idx = NSNotFound;
    @try { idx = (NSUInteger)qc.nowPlayingIndex; } @catch (__unused NSException *e) {}
    return (idx < [self queueCount]) ? idx : NSNotFound;
}

// The item that becomes next AFTER a skip of `idx` (forward carousel neighbour).
- (NSUInteger)indexAfter:(NSUInteger)idx {
    if (idx == NSNotFound || idx > kNUYTMaxNavigableIndex) return NSNotFound;
    NSUInteger after = NSNotFound;
    @try { after = (NSUInteger)[self.controller nextVideoIndexAfterIndex:idx withAutoplay:YES]; }
    @catch (__unused NSException *e) {}
    return (after <= kNUYTMaxNavigableIndex && after != idx) ? after : NSNotFound;
}

// {title, subtitle, videoId, item, inQueue, artwork?} snapshot for `index`, or nil if blank.
// `item` is kept for the artwork fetch (not serialized; the wire dict is built field-by-field);
// `inQueue` says whether the entry is mutable (real queue) or an app-owned autoplay suggestion.
- (NSDictionary *)infoForItem:(YTQueueItem *)item
                     renderer:(YTIPlaylistPanelVideoRenderer *)renderer
                      inQueue:(BOOL)inQueue {
    YTIPlaylistPanelVideoRenderer *r = renderer;
    if (!r) { @try { r = [item rendererForContentMode:kNUYTContentModeArtTrack]; } @catch (__unused NSException *e) {} }
    if (!r) { @try { r = item.videoRenderer; } @catch (__unused NSException *e) {} }
    if (!r) return nil;

    // The renderer accessors are private API — guard the property reads themselves too
    // (a renamed selector must degrade, not throw into the caller).
    NSString *title = nil, *byline = nil, *videoId = nil;
    @try { title = NUYTFormattedText(r.title); } @catch (__unused NSException *e) {}
    @try { byline = NUYTFormattedText(r.shortBylineText); } @catch (__unused NSException *e) {}
    @try { videoId = r.videoId; } @catch (__unused NSException *e) {}
    if (title.length == 0 || videoId.length == 0) return nil;

    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"title"] = title;
    d[@"subtitle"] = byline ?: @"";   // channel name for a plain video, artist for a music track
    d[@"videoId"] = videoId;
    d[@"item"] = item;
    d[@"inQueue"] = @(inQueue);
    NSData *art = [self cachedArtworkForKey:videoId];
    if (art) d[@"artwork"] = art;
    return d;
}

- (NSDictionary *)infoForIndex:(NSUInteger)index {
    YTQueueController *qc = self.controller;
    if (!qc || index == NSNotFound) return nil;
    YTQueueItem *item = [self itemAtIndex:index];
    if (!item) return nil;
    YTIPlaylistPanelVideoRenderer *r = nil;
    @try { r = [qc videoRendererAtIndex:index]; } @catch (__unused NSException *e) {}
    return [self infoForItem:item renderer:r inQueue:[self isQueueIndex:index]];
}

// The back card is the last video that played, which kNUKeyBackTitle defines as recorded
// history at depth 1. -previousNavigableVideoIndex is nowPlayingIndex - 1, i.e. list order,
// and diverges from history as soon as anything jumps around the queue.
- (NSDictionary *)previousPlayedInfo {
    YTQueueItem *item = self.lastPlayedItem;
    if (!item) return nil;
    // Re-queueing works from the retained renderer, so the entry survives its slot being
    // removed from the queue.
    return [self infoForItem:item renderer:nil inQueue:YES];
}

// When the now-playing video id moves on, the item that was current becomes the history
// entry. Only the queue path can be tracked: for a standalone video the queue is empty and
// the autonav renderer describes the next video, never the one playing, so there is nothing
// to identify the current item with and the back card stays absent.
- (void)recordNowPlayingTransition {
    NSUInteger cur = [self currentIndex];
    if (cur == NSNotFound) return;
    YTQueueItem *item = [self itemAtIndex:cur];
    if (!item) return;
    NSString *vid = nil;
    @try { vid = [self infoForItem:item renderer:nil inQueue:YES][@"videoId"]; } @catch (__unused NSException *e) {}
    if (vid.length == 0 || [vid isEqualToString:self.currentVideoId]) return;

    if (self.lastPlayedVideoId && [vid isEqualToString:self.lastPlayedVideoId]) {
        // Moved backward onto the history entry: pop rather than push, or the back card
        // would name the video that is now up next and a right swipe would duplicate it.
        self.lastPlayedItem = nil;
        self.lastPlayedVideoId = nil;
    } else if (self.currentItem) {
        self.lastPlayedItem = self.currentItem;
        self.lastPlayedVideoId = self.currentVideoId;
        NULog("yt history: '%{public}@' -> previous", self.currentVideoId);
    }
    self.currentVideoId = vid;
    self.currentItem = item;
}

// Drop the back card, keeping the current-item tracking intact.
- (void)resetHistoryEntry {
    self.lastPlayedItem = nil;
    self.lastPlayedVideoId = nil;
}

// A new controller is a new playback session: history from the old queue would name a video
// that queue no longer backs.
- (void)resetHistory {
    self.lastPlayedItem = nil;
    self.lastPlayedVideoId = nil;
    self.currentItem = nil;
    self.currentVideoId = nil;
}

// History is recorded before the notification so the snapshot the display fetches next
// already reflects the transition. -recordNowPlayingTransition mutates state the LM server
// callback reads on the main runloop, and the YT hooks can fire off-main, so the mutation is
// pinned to main as in NUMusicProvider / NUPodcastProvider.
- (void)changed {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self changed]; });
        return;
    }
    // Disabled in Settings → no queue reads at all: a backgrounded app polling its own media
    // stack starves mediaserverd into a watchdog kill on iOS 14.2.
    if ([self providerEnabled]) [self recordNowPlayingTransition];
    [super changed];
}

#pragma mark - Artwork (async URL fetch, cached by videoId)

// Async fetch for a snapshot's item unless cached or in flight; the base posts a change on
// arrival. Always the 16:9 thumbnail — the row draws a 16:9 well for this source
// (NUNextUpManager.prefersWideArtwork).
- (void)prefetchArtworkFor:(NSDictionary *)info {
    NSString *vid = info[@"videoId"];
    YTQueueItem *item = info[@"item"];
    if (vid.length == 0) return;
    if ([self cachedArtworkForKey:vid]) return;         // a video's thumbnail never changes
    if ([self artworkFetchInFlightForKey:vid]) return;  // already fetching
    // The autoplay path carries its URL directly; the queue path derives it from the item.
    NSString *urlStr = info[@"artURL"];
    if (!urlStr && item) urlStr = NUYTVideoThumbnailURLForItem(item);
    NSURL *url = urlStr.length ? [NSURL URLWithString:urlStr] : nil;
    if (url) [self fetchArtworkAtURL:url forKey:vid];
}

// The on-screen next/fwd/back window the base prune must never evict.
- (NSArray<NSString *> *)artworkKeysToProtect {
    NSMutableArray *keys = [NSMutableArray array];
    NSUInteger ni = [self nextIndex];
    for (NSNumber *n in @[ @(ni), @([self indexAfter:ni]) ]) {
        NSString *v = [self infoForIndex:n.unsignedIntegerValue][@"videoId"];
        if (v) [keys addObject:v];
    }
    NSString *back = [self previousPlayedInfo][@"videoId"];
    if (back) [keys addObject:back];
    NSString *autoplay = [self autoplayInfo][@"videoId"];
    if (autoplay) [keys addObject:autoplay];
    return keys;
}

#pragma mark - Snapshot (same wire shape as the other providers)

// Queue shape at snapshot time (DEBUG only). Separates "no controller captured" from
// "controller but empty queue" from "index found but renderer unreadable".
- (void)logQueueShapeForIndex:(NSUInteger)nextIdx resolved:(BOOL)resolved {
#ifdef DEBUG
    YTQueueController *qc = self.controller;
    unsigned long apCount = 0, headerOffset = 0; BOOL hasNext = NO;
    @try { apCount = (unsigned long)qc.autoplayItemCount; } @catch (__unused NSException *e) {}
    @try { hasNext = qc.hasNextVideo; } @catch (__unused NSException *e) {}
    @try { headerOffset = (unsigned long)qc.offsetForHeaderItem; } @catch (__unused NSException *e) {}
    YTAutoplayAutonavController *ac = self.autonav;
    BOOL acHas = NO; BOOL acRenderer = NO;
    @try { acHas = (ac.hasAutonavVideo || ac.hasNextVideo || ac.hasAutoplayVideo); }
    @catch (__unused NSException *e) {}
    @try { acRenderer = ([ac autonavRenderer] != nil); } @catch (__unused NSException *e) {}
    NULog("yt snapshot: ctrl=%p queueCount=%lu autoplay=%lu headerOffset=%lu hasNext=%d "
          "nextIdx=%lu inQueue=%d resolved=%d | autonav=%p has=%d renderer=%d serving=%d",
          qc, (unsigned long)[self queueCount], apCount, headerOffset, hasNext,
          (unsigned long)nextIdx, [self isQueueIndex:nextIdx], resolved,
          ac, acHas, acRenderer, self.servingAutoplay);
#endif
}

- (NSDictionary *)nextUpDictionary {
    if (![self providerEnabled]) return @{ kNUKeyActive : @NO }; // disabled in Settings → no queue/artwork work
    // Queue first: a playlist / mix / queued item is a real, mutable next-up. The autoplay
    // suggestion applies only when there is none, i.e. the standalone-video case.
    NSUInteger nextIdx = [self nextIndex];
    NSDictionary *nextInfo = [self infoForIndex:nextIdx];
    self.servingAutoplay = NO;
    if (!nextInfo) {
        nextInfo = [self autoplayInfo];
        self.servingAutoplay = (nextInfo != nil);
    }
    [self logQueueShapeForIndex:nextIdx resolved:(nextInfo != nil)];
    if (!nextInfo) return @{ kNUKeyActive : @NO };
    [self prefetchArtworkFor:nextInfo];

    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[kNUKeyActive] = @YES;
    dict[kNUKeyTitle] = nextInfo[@"title"];
    dict[kNUKeySubtitle] = nextInfo[@"subtitle"];
    if (nextInfo[@"artwork"]) dict[kNUKeyArtwork] = nextInfo[@"artwork"];
    // An autoplay suggestion is not a queue slot — the app refetches it immediately — so the
    // row must not offer the skip gesture.
    dict[kNUKeyCanSkip] = nextInfo[@"inQueue"] ?: @NO;

    // Forward carousel neighbour (what becomes next after a skip). The autoplay path has
    // none: a single suggestion, no skip.
    NSDictionary *fwdInfo = self.servingAutoplay ? nil : [self infoForIndex:[self indexAfter:nextIdx]];
    if (fwdInfo) {
        [self prefetchArtworkFor:fwdInfo];
        dict[kNUKeyFwdTitle] = fwdInfo[@"title"];
        dict[kNUKeyFwdSubtitle] = fwdInfo[@"subtitle"];
        if (fwdInfo[@"artwork"]) dict[kNUKeyFwdArtwork] = fwdInfo[@"artwork"];
    }
    // Previously-played video (back card) from the depth-1 history, re-queued on a right
    // swipe via -playPrevious (provider-side, no adamID, like Podcasts).
    // No back card on the autoplay path: history is only tracked through the queue, so an
    // entry surviving there would name a video from an earlier session.
    NSDictionary *backInfo = self.servingAutoplay ? nil : [self previousPlayedInfo];
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

// Skip = remove the next video from the queue WITHOUT playing it.
- (void)skipNext {
    YTQueueController *qc = self.controller;
    if (!qc) { NULog("yt skip: no controller"); return; }
    NSUInteger nextIdx = [self nextIndex];
    // Autoplay suggestions live in section 1 and the app refetches them server-side; the
    // snapshot already reports canSkip NO for them.
    if (![self isQueueIndex:nextIdx]) {
        NULog("yt skip: index %lu is outside the mutable queue — refusing", (unsigned long)nextIdx);
        return;
    }
    NSString *vid = [self infoForIndex:nextIdx][@"videoId"];
    if (vid.length == 0) { NULog("yt skip: no next videoId"); return; }
    // Repeat-all at the queue tail wraps the navigable index back to or before the current
    // item. Removing there shifts later slots without adjusting nowPlayingIndex, which crashes
    // the app and corrupts the persisted restorableQueueState.
    NSUInteger curIdx = [self currentIndex];
    if (curIdx != NSNotFound && nextIdx <= curIdx) {
        NULog("yt skip: next index %lu is at/before current %lu (repeat wrap) — refusing",
              (unsigned long)nextIdx, (unsigned long)curIdx);
        return;
    }
    NSUInteger countBefore = [self queueCount];

    // Remove by index, not by video id. -removeVideoID: resolves the slot through
    // -indicesOfVideoID:, which matches on
    // videoRenderer.navigationEndpoint.activeOnlineOrOfflineWatchEndpoint.videoId. That field
    // is nil for ordinary playlist entries, so the match set is empty and the call removes
    // nothing without throwing (21.32.4: matches=0 for a slot with a valid videoId).
    // -removeItemAtIndexPath: takes section 0 row i as queue index i and notifies observers,
    // so the app's own queue UI follows.
    BOOL removed = NO, threw = NO;
    [self beginQueueMutation];
    @try {
        [qc removeItemAtIndexPath:[NSIndexPath indexPathForRow:(NSInteger)nextIdx inSection:0]
                    userTriggered:NO];
        removed = ([self queueCount] < countBefore);
        NULog("yt skip: removeItemAtIndexPath row=%lu -> count %lu -> %lu",
              (unsigned long)nextIdx, (unsigned long)countBefore, (unsigned long)[self queueCount]);
    } @catch (NSException *e) { threw = YES; NULog("yt skip: index-path removal threw %{public}@", e.name); }

    // Only on the exception path. Gating on the count alone would double-remove if the app
    // ever defers the removal past this check: -removeVideoID: is a no-op for ordinary
    // playlist entries but not for watch-next "Add to queue" items, which carry that videoId.
    if (threw && !removed) {
        @try {
            [qc removeVideoID:vid];
            removed = ([self queueCount] < countBefore);
            NULog("yt skip: fallback removeVideoID '%{public}@' -> count %lu -> %lu",
                  vid, (unsigned long)countBefore, (unsigned long)[self queueCount]);
        } @catch (NSException *e) { NULog("yt skip: removeVideoID threw %{public}@", e.name); }
    }
    if (!removed) NULog("yt skip: '%{public}@' at %lu could not be removed", vid, (unsigned long)nextIdx);
    [self changedSoon];
}

// Play the up-next video now (cover tap). Signaled by the display via kNUJumpNotificationYouTube.
// -playItemAtIndex: goes through -checkVideoRendererAndMaybePlayItemAtIndex:, which resolves the
// renderer with the autoplay section included, so an autoplay index plays too.
- (void)jumpToNext {
    YTQueueController *qc = self.controller;
    NSUInteger nextIdx = [self nextIndex];
    // Follow the snapshot that was served, not a fresh derivation: a queue index can exist
    // while -infoForIndex: rejects it, in which case the row shows the autoplay suggestion.
    if (!self.servingAutoplay && qc && nextIdx != NSNotFound) {
        @try { [qc playItemAtIndex:nextIdx]; NULog("yt jump: playItemAtIndex %lu", (unsigned long)nextIdx); }
        @catch (NSException *e) { NULog("yt jump threw %{public}@", e.name); }
        [self changedSoon];
        return;
    }
    // The row is showing the autoplay suggestion; the autonav controller plays it on the same
    // path its own countdown uses.
    YTAutoplayAutonavController *ac = self.autonav;
    if (!ac) { NULog("yt jump: nothing to play"); return; }
    @try { [ac playNext]; NULog("yt jump: autonav playNext"); }
    @catch (NSException *e) { NULog("yt jump (autonav) threw %{public}@", e.name); }
    [self changedSoon];
}

// Re-queue the previously-played video to play next, leaving the current one playing (Apple
// Music's "Play Next" semantic).
//
// Not a move: -moveItemAtIndexPath:toIndexPath: does not adjust nowPlayingIndex, so taking an
// item from before the current one shifts every later slot and leaves nowPlayingIndex on the
// wrong video, which crashes the app and corrupts the persisted restorableQueueState. This
// takes the same path as the app's own "Play next" instead — a queue item handed to
// YTQueueModificationNotificationData at InsertAfterCurrentVideo, which resolves to
// nowPlayingIndex + 1. No network round trip: the renderers are already held.
- (void)playPrevious {
    YTQueueController *qc = self.controller;
    if (!qc) { NULog("yt prev: no controller"); return; }
    YTQueueItem *src = self.lastPlayedItem;
    if (!src) { NULog("yt prev: no recorded history"); return; }

    Class itemClass = NSClassFromString(@"YTQueueItem");
    Class notificationClass = NSClassFromString(@"YTQueueModificationNotificationData");
    if (!itemClass || !notificationClass) { NULog("yt prev: queue classes unavailable"); return; }

    @try {
        YTIPlaylistPanelVideoRenderer *base = src.videoRenderer;
        if (!base) { NULog("yt prev: source item has no renderer"); return; }

        // A fresh item mints its own localID; re-inserting `src` (or a -copy, which carries
        // localID over) would put two queue slots behind one identity.
        YTQueueItem *fresh = [itemClass queueItemWithPlaylistPanelVideoRenderer:base];
        if (!fresh) { NULog("yt prev: could not build queue item"); return; }
        fresh.audioModeRenderer = src.audioModeRenderer;
        fresh.videoModeRenderer = src.videoModeRenderer;
        fresh.hasATVOMVPair = src.hasATVOMVPair;
        fresh.supportsAudioVideoSwitching = src.supportsAudioVideoSwitching;

        // predecessorSetVideoID / responseForLogging are read only for the InsertAtEnd and
        // InsertAfterSetVideoId positions and for the app's logging.
        YTQueueModificationNotificationData *note =
            [notificationClass addToQueueNotificationWithQueueItems:@[fresh]
                                                  atInsertPosition:kNUYTInsertAfterCurrentVideo
                                             predecessorSetVideoID:nil
                                                responseForLogging:nil];
        if (!note) { NULog("yt prev: could not build modification"); return; }
        NSUInteger countBefore = [self queueCount];
        [self beginQueueMutation];
        [note send];
        // Consume the entry: otherwise every further right swipe inserts another copy, since
        // nothing clears it until a transition is recorded.
        [self resetHistoryEntry];
        NULog("yt prev: enqueued '%{public}@' (vid='%{public}@') after current — count %lu -> %lu, "
              "curIdx=%lu nextIdx=%lu",
              NUYTFormattedText(base.title), base.videoId,
              (unsigned long)countBefore, (unsigned long)[self queueCount],
              (unsigned long)[self currentIndex], (unsigned long)[self nextIndex]);
    } @catch (NSException *e) { NULog("yt prev threw %{public}@", e.name); }
    [self changedSoon];
}

// -changed is NUProviderBase's (no self-tracked history — the queue holds it).

#pragma mark - LightMessaging server (YouTube registers the service via libSandy)

- (void)startServer {
    [self startServerWithService:kNUServiceNameYouTube
                            skip:kNUSkipNotificationYouTube
                            prev:kNUPrevNotificationYouTube
                            jump:kNUJumpNotificationYouTube];
}

@end
