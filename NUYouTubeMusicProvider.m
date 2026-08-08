#import "NUYouTubeMusicProvider.h"
#import "NUShared.h"
#import "LightMessaging.h"
#import <notify.h>
#import <UIKit/UIKit.h>

// Private YouTube Music interfaces (YTM 9.28.4). The read path was verified live on the iOS 18
// iPad; the queue write path was recovered statically from the decrypted IPA.
#pragma mark - Private YouTube Music interfaces

// Content-mode selector for -[YTQueueItem rendererForContentMode:]. Mode 0 = the art-track
// (ATV) renderer whose thumbnail is the clean 1:1 cover (yt3/lh3.googleusercontent, resizable);
// mode 1 = the 16:9 OMV video thumbnail (i.ytimg.com). Verified: mode 0 yields the square cover
// for current AND queued items even while the app is in video mode.
static const unsigned long long kYTMContentModeArtTrack = 0;
static const unsigned long long kYTMContentModeVideo    = 1;

// Artwork request size in px (the row downsizes). yt3/lh3 URLs are freely resizable.
static const int kNUYTMArtworkPx = 360;

// YTIQueueInsertPosition — the proto enum driving -[YTQueueController handleQueueModification:].
// Values read out of the 9.28.4 binary's GPB enum descriptor and confirmed against that method's
// own `cmp w0, 1 / 2 / 3` dispatch. Position 1 is what YTM's own "Play next" sends;
// it resolves to `nowPlayingIndex + 1`, i.e. an insert strictly AFTER the current track, which is
// why it never disturbs nowPlayingIndex.
static const int kYTMInsertAfterCurrentVideo = 1;

@interface YTIFormattedString : NSObject
- (NSString *)simpleText;               // plain text for a single-run string
- (NSString *)stringWithFormattingRemoved; // concatenated runs (multi-run fallback)
@end

@interface YTIThumbnailDetails_Thumbnail : NSObject
@property (copy, nonatomic) NSString *URL;   // capital URL
@property (nonatomic) unsigned int width;
@property (nonatomic) unsigned int height;
@end

@interface YTIThumbnailDetails : NSObject
@property (retain, nonatomic) NSMutableArray<YTIThumbnailDetails_Thumbnail *> *thumbnailsArray;
@end

// The playlist-panel video renderer wrapped by each queue item — carries the metadata.
@interface YTIPlaylistPanelVideoRenderer : NSObject
@property (retain, nonatomic) YTIFormattedString *title;
@property (retain, nonatomic) YTIFormattedString *shortBylineText; // clean artist ("Lil Tees & Kidd Kazama")
@property (retain, nonatomic) YTIThumbnailDetails *thumbnail;
@property (copy, nonatomic) NSString *videoId;                     // stable key (artwork cache / dedup)
@end

// One queue entry. `localID` is a per-object NSUUID string, minted lazily on first access — it is
// YTM's identity key for a queue slot, so two entries for the same videoId are only distinct while
// their YTQueueItem objects are distinct. Never re-insert (or -copy, which carries localID over)
// an item that is already in the queue; build a fresh one from the renderer instead.
@interface YTQueueItem : NSObject
+ (instancetype)queueItemWithPlaylistPanelVideoRenderer:(id)renderer; // sets `videoRenderer` only
// -rendererForContentMode: reads audioModeRenderer (mode 0) / videoModeRenderer (mode 1) and falls
// back to videoRenderer, so a rebuilt item must carry the ATV/OMV pair to keep the square cover.
@property (retain, nonatomic) YTIPlaylistPanelVideoRenderer *videoRenderer;
@property (retain, nonatomic) YTIPlaylistPanelVideoRenderer *audioModeRenderer;
@property (retain, nonatomic) YTIPlaylistPanelVideoRenderer *videoModeRenderer;
@property (nonatomic) BOOL hasATVOMVPair;
@property (nonatomic) BOOL supportsAudioVideoSwitching;
- (id)rendererForContentMode:(unsigned long long)mode; // -> YTIPlaylistPanelVideoRenderer
@end

// YTM's own queue-edit channel. -send posts NSNotification "YTQueueModificationNotification" with
// the data as -object; YTQueueController observes it and runs -handleQueueModification:, which
// resolves the insert index, calls -recordUserQueueModification, then -insertQueueItems:atIndex:
// and notifies its observers. This is the ONLY sanctioned way into the queue: it is exactly what
// -[YTMQueueAddEndpointCommandImpl addQueueItems:atInsertPosition:predecessorSetVideoID:responseForLogging:]
// does when the user taps "Play next".
@interface YTQueueModificationNotificationData : NSObject
+ (instancetype)addToQueueNotificationWithQueueItems:(id)items
                                    atInsertPosition:(int)position
                               predecessorSetVideoID:(id)predecessorSetVideoID
                                  responseForLogging:(id)responseForLogging;
- (void)send;
@end

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

#pragma mark - Metadata / artwork-URL helpers

// Plain text from a YTIFormattedString: prefer -simpleText, fall back to -stringWithFormattingRemoved.
static NSString *NUFormattedText(YTIFormattedString *fstr) {
    if (!fstr) return nil;
    @try {
        NSString *s = [fstr simpleText];
        if (s.length) return s;
        s = [fstr stringWithFormattingRemoved];
        if (s.length) return s;
    } @catch (__unused NSException *e) {}
    return nil;
}

// Rewrite a googleusercontent image URL to an exact square size. The size spec is the tail after
// the last '=' (e.g. "…=w544-h544-l90-rj"); replace it, keeping quality/format flags.
static NSString *NUGUCSquareURL(NSString *url, int px) {
    if (url.length == 0) return nil;
    NSRange eq = [url rangeOfString:@"=" options:NSBackwardsSearch];
    NSString *base = (eq.location != NSNotFound) ? [url substringToIndex:eq.location] : url;
    return [NSString stringWithFormat:@"%@=w%d-h%d-l90-rj", base, px, px];
}

// The clean 1:1 cover URL from an art-track renderer's thumbnails: the largest square
// googleusercontent entry, rewritten to `px`. nil when the track has no square art (genuine
// video uploads) — the caller then falls back to the 16:9 video thumbnail.
static NSString *NUSquareCoverURL(YTIThumbnailDetails *thumb, int px) {
    if (!thumb) return nil;
    NSArray *arr = nil;
    @try { arr = thumb.thumbnailsArray; } @catch (__unused NSException *e) { return nil; }
    NSString *bestURL = nil; unsigned bestW = 0;
    for (YTIThumbnailDetails_Thumbnail *t in arr) {
        unsigned w = 0, h = 0; NSString *u = nil;
        @try { w = t.width; h = t.height; u = t.URL; } @catch (__unused NSException *e) { continue; }
        if (w && w == h && u.length && [u containsString:@"googleusercontent"] && w >= bestW) {
            bestW = w; bestURL = u;
        }
    }
    return bestURL ? NUGUCSquareURL(bestURL, px) : nil;
}

// Largest thumbnail URL (used for the 16:9 ytimg fallback), as-is.
static NSString *NULargestThumbURL(YTIThumbnailDetails *thumb) {
    if (!thumb) return nil;
    NSArray *arr = nil;
    @try { arr = thumb.thumbnailsArray; } @catch (__unused NSException *e) { return nil; }
    NSString *bestURL = nil; unsigned bestW = 0;
    for (YTIThumbnailDetails_Thumbnail *t in arr) {
        unsigned w = 0; NSString *u = nil;
        @try { w = t.width; u = t.URL; } @catch (__unused NSException *e) { continue; }
        if (u.length && w >= bestW) { bestW = w; bestURL = u; }
    }
    return bestURL;
}

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
    if (!r) { @try { r = [item rendererForContentMode:kYTMContentModeArtTrack]; } @catch (__unused NSException *e) {} }
    if (!r) return nil;

    // The renderer accessors are private YTM API — guard the property reads
    // themselves too (a renamed selector must degrade, not throw into the caller).
    NSString *title = nil, *artist = nil, *videoId = nil;
    @try { title = NUFormattedText(r.title); } @catch (__unused NSException *e) {}
    @try { artist = NUFormattedText(r.shortBylineText); } @catch (__unused NSException *e) {}
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

// Best artwork URL for an item: the clean 1:1 cover from the art-track renderer (mode 0) when the
// track has one, else the largest 16:9 video thumbnail (mode 1). Exactly the "prefer square,
// fall back to YT thumbnail" rule (verified both app modes).
- (NSString *)artworkURLForItem:(YTQueueItem *)item {
    if (!item) return nil;
    YTIPlaylistPanelVideoRenderer *art = nil, *vid = nil;
    id artThumb = nil, vidThumb = nil; // guard the .thumbnail hops too (private API)
    @try { art = [item rendererForContentMode:kYTMContentModeArtTrack]; } @catch (__unused NSException *e) {}
    @try { artThumb = art.thumbnail; } @catch (__unused NSException *e) {}
    NSString *square = NUSquareCoverURL(artThumb, kNUYTMArtworkPx);
    if (square) return square;
    @try { vid = [item rendererForContentMode:kYTMContentModeVideo]; } @catch (__unused NSException *e) {}
    @try { vidThumb = vid.thumbnail; } @catch (__unused NSException *e) {}
    NSString *fallback = NULargestThumbURL(vidThumb);
    return fallback ?: NULargestThumbURL(artThumb);
}

// Kick an async fetch for a snapshot's item if not cached / in flight; the base posts a change on
// arrival so the display re-queries and picks it up. The row shows its placeholder until then.
- (void)prefetchArtworkFor:(NSDictionary *)info {
    NSString *vid = info[@"videoId"];
    YTQueueItem *item = info[@"item"];
    if (vid.length == 0 || !item) return;
    if ([self cachedArtworkForKey:vid]) return;         // a track's cover never changes
    if ([self artworkFetchInFlightForKey:vid]) return;  // already fetching
    NSString *urlStr = [self artworkURLForItem:item];
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
                                                  atInsertPosition:kYTMInsertAfterCurrentVideo
                                             predecessorSetVideoID:nil
                                                responseForLogging:nil];
        if (!note) { NULog("ytm prev: could not build modification"); return; }
        [note send];
        NULog("ytm prev: enqueued '%{public}@' after current", NUFormattedText(base.title));
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
