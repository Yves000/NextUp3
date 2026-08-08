// YouTube-Music-provider hooks (com.google.ios.youtubemusic). Capture the live
// YTQueueController (a persistent singleton per playback session) and observe queue /
// now-playing changes so the provider can serve the next-up snapshot and perform skips.
// Parallel to NUHooksMusicProvider.x / NUHooksPodcastProvider.x; YTM uses its own YT* queue
// stack, not MPCQueueController and not the low-level ML* player.
#import "NUHooksShared.h"
#import "NUYouTubeMusicProvider.h"

@interface YTQueueController : NSObject
- (void)commonInit;
- (id)initWithAccountID:(id)accountID parentResponder:(id)responder;
- (id)initWithAccountID:(id)accountID restorableQueueState:(id)state parentResponder:(id)responder;
- (void)playbackControllerDidLoadPlayerWithPlaybackData:(id)data;
- (void)updateNowPlayingVideoWithPlaylistPanelVideoRenderer:(id)renderer;
- (void)playItemAtIndex:(unsigned long long)index;
- (void)advanceToNextWithAutoplay:(BOOL)autoplay isPlaybackControllerInternalTransition:(BOOL)transition unplayableVideoID:(id)videoID;
- (void)removeItemAtIndexPath:(id)path userTriggered:(BOOL)triggered;
- (void)moveItemAtIndexPath:(id)from toIndexPath:(id)to userTriggered:(BOOL)triggered;
- (void)removeVideoID:(id)videoID;
- (void)insertQueueItems:(id)items atIndex:(unsigned long long)index;
@end

%group YouTubeMusicProvider

%hook YTQueueController

// --- Capture points: hold the controller from creation, before any change fires. ---

- (void)commonInit {
    %orig;
    [[NUYouTubeMusicProvider shared] captureController:self];
}

- (id)initWithAccountID:(id)accountID parentResponder:(id)responder {
    id r = %orig;
    [[NUYouTubeMusicProvider shared] captureController:self];
    return r;
}

- (id)initWithAccountID:(id)accountID restorableQueueState:(id)state parentResponder:(id)responder {
    id r = %orig;
    [[NUYouTubeMusicProvider shared] captureController:self];
    return r;
}

// --- Change points: a new item loaded, now-playing changed, navigation, or a queue edit.
// Each is an instance method, so `self` is the live controller — (re)capture + signal the display.
// Also fires for our own provider-driven skip/jump/previous (idempotent). ---

- (void)playbackControllerDidLoadPlayerWithPlaybackData:(id)data {
    %orig;
    [[NUYouTubeMusicProvider shared] captureController:self];
    [[NUYouTubeMusicProvider shared] changed];
}

- (void)updateNowPlayingVideoWithPlaylistPanelVideoRenderer:(id)renderer {
    %orig;
    [[NUYouTubeMusicProvider shared] captureController:self];
    [[NUYouTubeMusicProvider shared] changed];
}

- (void)playItemAtIndex:(unsigned long long)index {
    %orig;
    [[NUYouTubeMusicProvider shared] captureController:self];
    [[NUYouTubeMusicProvider shared] changed];
}

- (void)advanceToNextWithAutoplay:(BOOL)autoplay isPlaybackControllerInternalTransition:(BOOL)transition unplayableVideoID:(id)videoID {
    %orig;
    [[NUYouTubeMusicProvider shared] captureController:self];
    [[NUYouTubeMusicProvider shared] changed];
}

- (void)removeItemAtIndexPath:(id)path userTriggered:(BOOL)triggered {
    %orig;
    [[NUYouTubeMusicProvider shared] changed];
}

- (void)moveItemAtIndexPath:(id)from toIndexPath:(id)to userTriggered:(BOOL)triggered {
    %orig;
    [[NUYouTubeMusicProvider shared] changed];
}

- (void)removeVideoID:(id)videoID {
    %orig;
    [[NUYouTubeMusicProvider shared] changed];
}

// The single funnel every queue insert lands in — YTM's own "Play next" / "Add to queue" (via
// handleQueueModification:) as well as our -playPrevious. Catches queue edits made inside the app
// while the row is on screen.
- (void)insertQueueItems:(id)items atIndex:(unsigned long long)index {
    %orig;
    [[NUYouTubeMusicProvider shared] changed];
}

%end

%end // YouTubeMusicProvider

%ctor {
    @autoreleasepool {
        NUApplySandbox(); // grant shared mach service access (idempotent across ctors)
        if (!NUIsYouTubeMusic()) return;
        %init(YouTubeMusicProvider);
        [[NUYouTubeMusicProvider shared] startServer];
        NULog("loaded into YouTube Music (provider)");
#ifdef DEBUG
        // Interface drift probe (dev builds only): the provider is pinned against
        // YTM 9.28.4's private YT* stack. After an app update, a missing
        // class/selector here is the first thing to check when the row goes blank.
        Class qc = objc_getClass("YTQueueController");
        if (!qc) NULog("ytm probe: YTQueueController MISSING");
        else if (![qc instancesRespondToSelector:@selector(playbackQueueItems)])
            NULog("ytm probe: -playbackQueueItems MISSING");
#endif
    }
}
