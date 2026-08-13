#import <Foundation/Foundation.h>

// Private interfaces and metadata helpers shared by the two Google clients.
// YouTube Music (9.28.4) and the main YouTube app (21.32.4) are built on the same
// YT* client stack: the queue item, the playlist-panel renderer, the protobuf
// string/thumbnail wrappers and the queue-edit notification are the same classes
// with the same selectors in both binaries (verified against both decrypted IPAs).
// Only YTQueueController differs in what parts of it each provider needs, so that
// one stays declared per provider.

#pragma mark - Content modes

// Selector for -[YTQueueItem rendererForContentMode:]. Mode 0 = the art-track (ATV)
// renderer whose thumbnail is the clean 1:1 cover (yt3/lh3.googleusercontent,
// resizable); mode 1 = the 16:9 video thumbnail (i.ytimg.com). Mode 0 yields the
// square cover for current AND queued items even while the app is in video mode.
// In the main YouTube app only music tracks carry an art-track renderer; plain
// video uploads have mode 1 only, hence the fallback in NUYouTubeArtworkURL().
static const unsigned long long kNUYTContentModeArtTrack = 0;
static const unsigned long long kNUYTContentModeVideo    = 1;

// Artwork request size in px (the row downsizes). yt3/lh3 URLs are freely resizable.
static const int kNUYTArtworkPx = 360;

// YTIQueueInsertPosition — the proto enum driving -[YTQueueController
// handleQueueModification:]. Confirmed against that method's own `cmp w0, 1 / 2 / 3`
// dispatch in both binaries. Position 1 is what the apps' own "Play next" sends; it
// resolves to `nowPlayingIndex + 1`, i.e. an insert strictly AFTER the current item,
// which is why it never disturbs nowPlayingIndex.
static const int kNUYTInsertAfterCurrentVideo = 1;

#pragma mark - Private YT* / YTI* interfaces

@interface YTIFormattedString : NSObject
- (NSString *)simpleText;                  // plain text for a single-run string
- (NSString *)stringWithFormattingRemoved; // concatenated runs (multi-run fallback)
@end

@interface YTIThumbnailDetails_Thumbnail : NSObject
@property (copy, nonatomic) NSString *URL; // capital URL
@property (nonatomic) unsigned int width;
@property (nonatomic) unsigned int height;
@end

@interface YTIThumbnailDetails : NSObject
@property (retain, nonatomic) NSMutableArray<YTIThumbnailDetails_Thumbnail *> *thumbnailsArray;
@end

// The playlist-panel video renderer wrapped by each queue item — carries the metadata.
@interface YTIPlaylistPanelVideoRenderer : NSObject
@property (retain, nonatomic) YTIFormattedString *title;
@property (retain, nonatomic) YTIFormattedString *shortBylineText; // clean artist / channel name
@property (retain, nonatomic) YTIThumbnailDetails *thumbnail;
@property (copy, nonatomic) NSString *videoId;                     // stable key (artwork cache / dedup)
@end

// One queue entry. `localID` is a per-object NSUUID string, minted lazily on first
// access — it is the apps' identity key for a queue slot, so two entries for the same
// videoId are only distinct while their YTQueueItem objects are distinct. Never
// re-insert (or -copy, which carries localID over) an item that is already in the
// queue; build a fresh one from the renderer instead.
@interface YTQueueItem : NSObject
+ (instancetype)queueItemWithPlaylistPanelVideoRenderer:(id)renderer; // sets `videoRenderer` only
// -rendererForContentMode: reads audioModeRenderer (mode 0) / videoModeRenderer (mode 1)
// and falls back to videoRenderer, so a rebuilt item must carry the ATV/OMV pair to keep
// the square cover.
@property (retain, nonatomic) YTIPlaylistPanelVideoRenderer *videoRenderer;
@property (retain, nonatomic) YTIPlaylistPanelVideoRenderer *audioModeRenderer;
@property (retain, nonatomic) YTIPlaylistPanelVideoRenderer *videoModeRenderer;
@property (nonatomic) BOOL hasATVOMVPair;
@property (nonatomic) BOOL supportsAudioVideoSwitching;
- (id)rendererForContentMode:(unsigned long long)mode; // -> YTIPlaylistPanelVideoRenderer
@end

// The apps' own queue-edit channel. -send posts NSNotification
// "YTQueueModificationNotification" with the data as -object; YTQueueController observes
// it and runs -handleQueueModification:, which resolves the insert index, calls
// -recordUserQueueModification, then -insertQueueItems:atIndex: and notifies its
// observers. This is the ONLY sanctioned way into the queue: it is exactly what the
// apps' "Play next" menu command does.
@interface YTQueueModificationNotificationData : NSObject
+ (instancetype)addToQueueNotificationWithQueueItems:(id)items
                                    atInsertPosition:(int)position
                               predecessorSetVideoID:(id)predecessorSetVideoID
                                  responseForLogging:(id)responseForLogging;
- (void)send;
@end

#pragma mark - Metadata / artwork-URL helpers

// Plain text from a YTIFormattedString: prefer -simpleText, fall back to
// -stringWithFormattingRemoved.
static inline NSString *NUYTFormattedText(YTIFormattedString *fstr) {
    if (!fstr) return nil;
    @try {
        NSString *s = [fstr simpleText];
        if (s.length) return s;
        s = [fstr stringWithFormattingRemoved];
        if (s.length) return s;
    } @catch (__unused NSException *e) {}
    return nil;
}

// Rewrite a googleusercontent image URL to an exact square size. The size spec is the
// tail after the last '=' (e.g. "…=w544-h544-l90-rj"); replace it, keeping
// quality/format flags.
static inline NSString *NUYTSquareResizedURL(NSString *url, int px) {
    if (url.length == 0) return nil;
    NSRange eq = [url rangeOfString:@"=" options:NSBackwardsSearch];
    NSString *base = (eq.location != NSNotFound) ? [url substringToIndex:eq.location] : url;
    return [NSString stringWithFormat:@"%@=w%d-h%d-l90-rj", base, px, px];
}

// The clean 1:1 cover URL from an art-track renderer's thumbnails: the largest square
// googleusercontent entry, rewritten to `px`. nil when the item has no square art
// (genuine video uploads) — the caller then falls back to the 16:9 video thumbnail.
static inline NSString *NUYTSquareCoverURL(YTIThumbnailDetails *thumb, int px) {
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
    return bestURL ? NUYTSquareResizedURL(bestURL, px) : nil;
}

// Largest thumbnail URL (used for the 16:9 ytimg fallback), as-is.
static inline NSString *NUYTLargestThumbURL(YTIThumbnailDetails *thumb) {
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

// Canonical 16:9 still for a video id. i.ytimg.com serves mqdefault at 320x180 for every
// public video — above the row's 78x44pt well even at 3x — so it is a reliable last resort
// when a renderer ships without thumbnails.
static inline NSString *NUYTThumbnailURLForVideoId(NSString *videoId) {
    if (videoId.length == 0) return nil;
    return [NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/mqdefault.jpg", videoId];
}

// The 16:9 video thumbnail: mode 1 first, for the main YouTube app's 16:9 artwork well. An
// item carrying a square art-track cover (music videos do) would be centre-cropped there.
static inline NSString *NUYTVideoThumbnailURLForItem(YTQueueItem *item) {
    if (!item) return nil;
    YTIPlaylistPanelVideoRenderer *vid = nil;
    id vidThumb = nil;
    @try { vid = [item rendererForContentMode:kNUYTContentModeVideo]; } @catch (__unused NSException *e) {}
    @try { vidThumb = vid.thumbnail; } @catch (__unused NSException *e) {}
    NSString *wide = NUYTLargestThumbURL(vidThumb);
    if (wide) return wide;
    // No fallback to the square art-track cover: aspect-filling a 1:1 image into the 16:9 well
    // crops ~44% of its height, the failure the wide well exists to avoid.
    NSString *videoId = nil;
    @try { videoId = vid.videoId; } @catch (__unused NSException *e) {}
    if (videoId.length == 0) { @try { videoId = item.videoRenderer.videoId; } @catch (__unused NSException *e) {} }
    return NUYTThumbnailURLForVideoId(videoId);
}

// Best artwork URL for a queue item: the clean 1:1 cover from the art-track renderer
// (mode 0) when the item has one, else the largest 16:9 video thumbnail (mode 1).
static inline NSString *NUYTArtworkURLForItem(YTQueueItem *item) {
    if (!item) return nil;
    YTIPlaylistPanelVideoRenderer *art = nil, *vid = nil;
    id artThumb = nil, vidThumb = nil; // guard the .thumbnail hops too (private API)
    @try { art = [item rendererForContentMode:kNUYTContentModeArtTrack]; } @catch (__unused NSException *e) {}
    @try { artThumb = art.thumbnail; } @catch (__unused NSException *e) {}
    NSString *square = NUYTSquareCoverURL(artThumb, kNUYTArtworkPx);
    if (square) return square;
    @try { vid = [item rendererForContentMode:kNUYTContentModeVideo]; } @catch (__unused NSException *e) {}
    @try { vidThumb = vid.thumbnail; } @catch (__unused NSException *e) {}
    NSString *fallback = NUYTLargestThumbURL(vidThumb);
    return fallback ?: NUYTLargestThumbURL(artThumb);
}
