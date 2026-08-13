// YouTube-provider hooks (com.google.ios.youtube). Capture the live YTQueueController and
// YTAutoplayAutonavController and observe queue / now-playing changes so the provider can
// serve the next-up snapshot and perform skips.
//
// Same YT* queue stack as YouTube Music, so the queue hook points match
// NUHooksYouTubeMusicProvider.x. The autoplay hooks are additional: a standalone video's
// next-up comes from the autonav controller and is refilled without any queue-edit method
// firing. Only one of the two %ctor gates passes per process, so both files hooking
// YTQueueController is safe as long as the Logos group names stay distinct.
#import "NUHooksShared.h"
#import "NUYouTubeProvider.h"

@interface YTQueueController : NSObject
- (void)commonInit;
- (id)initWithAccountID:(id)accountID parentResponder:(id)responder;
- (id)initWithAccountID:(id)accountID restorableQueueState:(id)state parentResponder:(id)responder;
- (void)playbackControllerDidLoadPlayerWithPlaybackData:(id)data;
- (void)updateNowPlayingVideoWithPlaylistPanelVideoRenderer:(id)renderer;
- (void)playItemAtIndex:(unsigned long long)index;
- (void)advanceToNextWithAutoplay:(BOOL)autoplay isPlaybackControllerInternalTransition:(BOOL)transition unplayableVideoID:(id)videoID;
- (void)setNowPlayingIndex:(unsigned long long)index;
- (void)updateReportedTrackIndexAndCount;
- (void)updateLockScreenTrackIndexAndCount;
- (void)removeItemAtIndexPath:(id)path userTriggered:(BOOL)triggered;
- (void)moveItemAtIndexPath:(id)from toIndexPath:(id)to userTriggered:(BOOL)triggered;
- (void)removeVideoID:(id)videoID;
- (void)insertQueueItems:(id)items atIndex:(unsigned long long)index;
- (void)autoplayController:(id)controller didInsertRenderersAtIndexes:(id)indexes response:(id)response;
- (void)autoplayController:(id)controller didRemoveRenderersAtIndexes:(id)indexes;
@end

@interface YTQueueAutoplayController : NSObject
- (void)setAutoplayItems:(id)items;
- (void)replaceAutoplayItemsWithWatchNextResponse:(id)response;
@end

@interface YTAutoplayAutonavController : NSObject
- (id)initWithParentResponder:(id)responder;
- (void)setAutoplayRenderer:(id)renderer;
- (void)setAutoplayRenderer:(id)renderer playerOverlayAutoplayRenderer:(id)overlayRenderer;
- (void)playbackControllerDidLoadPlayerWithPlaybackData:(id)data;
- (void)updateAutoplayTransition;
- (void)reset;
@end

%group YouTubeProvider

%hook YTQueueController

// --- Capture points: hold the controller from creation, before any change fires. ---

- (void)commonInit {
    %orig;
    [[NUYouTubeProvider shared] captureController:self];
}

- (id)initWithAccountID:(id)accountID parentResponder:(id)responder {
    id r = %orig;
    [[NUYouTubeProvider shared] captureController:self];
    return r;
}

- (id)initWithAccountID:(id)accountID restorableQueueState:(id)state parentResponder:(id)responder {
    id r = %orig;
    [[NUYouTubeProvider shared] captureController:self];
    return r;
}

// --- Change points: a new item loaded, now-playing changed, navigation, or a queue edit.
// Each is an instance method, so `self` is the live controller — (re)capture + signal the
// display. Also fires for our own provider-driven skip/jump/previous (idempotent). ---

- (void)playbackControllerDidLoadPlayerWithPlaybackData:(id)data {
    %orig;
    [[NUYouTubeProvider shared] captureController:self];
    [[NUYouTubeProvider shared] changed];
}

- (void)updateNowPlayingVideoWithPlaylistPanelVideoRenderer:(id)renderer {
    %orig;
    [[NUYouTubeProvider shared] captureController:self];
    [[NUYouTubeProvider shared] changed];
}

- (void)playItemAtIndex:(unsigned long long)index {
    %orig;
    [[NUYouTubeProvider shared] captureController:self];
    [[NUYouTubeProvider shared] changed];
}

- (void)advanceToNextWithAutoplay:(BOOL)autoplay isPlaybackControllerInternalTransition:(BOOL)transition unplayableVideoID:(id)videoID {
    %orig;
    [[NUYouTubeProvider shared] captureController:self];
    [[NUYouTubeProvider shared] changed];
}

// Where the current item actually moves. -advanceToNext… only marks the start of a
// transition: the app dispatches a navigation endpoint, loads a player over the network and
// moves the index after that, which outlasts -changedSoon's settle tick.
- (void)setNowPlayingIndex:(unsigned long long)index {
    %orig;
    [[NUYouTubeProvider shared] changed];
}

// Fires when the app reports the new track index/count to the system now-playing info.
// Index-driven rather than a playback-time tick, so following it is cheap.
- (void)updateReportedTrackIndexAndCount {
    %orig;
    [[NUYouTubeProvider shared] changed];
}

// The only chain that republishes now-playing info purely because the queue index or count
// moved: -> setPlaybackQueueIndex:playbackQueueCount: -> updateLockScreen -> updateInfoCenter,
// which rebuilds from a cached state carrying a stale currentTime. The -updateLockScreen calls
// that follow a real track change are a separate path and still run, so title and artwork are
// unaffected.
- (void)updateLockScreenTrackIndexAndCount {
    if ([[NUYouTubeProvider shared] suppressesLockScreenIndexUpdate]) return;
    %orig;
}

- (void)removeItemAtIndexPath:(id)path userTriggered:(BOOL)triggered {
    %orig;
    [[NUYouTubeProvider shared] changed];
}

- (void)moveItemAtIndexPath:(id)from toIndexPath:(id)to userTriggered:(BOOL)triggered {
    %orig;
    [[NUYouTubeProvider shared] changed];
}

- (void)removeVideoID:(id)videoID {
    %orig;
    [[NUYouTubeProvider shared] changed];
}

// The single funnel every queue insert lands in — the app's own "Play next" / "Add to
// queue" (via handleQueueModification:) as well as our -playPrevious. Catches queue edits
// made inside the app while the row is on screen.
- (void)insertQueueItems:(id)items atIndex:(unsigned long long)index {
    %orig;
    [[NUYouTubeProvider shared] changed];
}

// The autoplay section changed underneath us (the controller's own observer callbacks).
- (void)autoplayController:(id)controller didInsertRenderersAtIndexes:(id)indexes response:(id)response {
    %orig;
    [[NUYouTubeProvider shared] captureController:self];
    [[NUYouTubeProvider shared] changed];
}

- (void)autoplayController:(id)controller didRemoveRenderersAtIndexes:(id)indexes {
    %orig;
    [[NUYouTubeProvider shared] changed];
}

%end

// The autoplay section is refilled on the autoplay controller itself; for a standalone video
// nothing else changes when the suggestion arrives.
%hook YTQueueAutoplayController

- (void)setAutoplayItems:(id)items {
    %orig;
    [[NUYouTubeProvider shared] changed];
}

- (void)replaceAutoplayItemsWithWatchNextResponse:(id)response {
    %orig;
    [[NUYouTubeProvider shared] changed];
}

%end

// The standalone-video path: YTQueueController never fills for a plain video.
// -contentVideoMediaTimeDidChangeToTime:totalMediaTime: is deliberately not hooked — it is
// the playback tick and would post a change every frame.
%hook YTAutoplayAutonavController

- (id)initWithParentResponder:(id)responder {
    id r = %orig;
    [[NUYouTubeProvider shared] captureAutonavController:self];
    return r;
}

// The funnel the watch-next response lands in: autoplay sets and the player overlay
// renderer, which is the metadata source, are installed here.
- (void)setAutoplayRenderer:(id)renderer playerOverlayAutoplayRenderer:(id)overlayRenderer {
    %orig;
    [[NUYouTubeProvider shared] captureAutonavController:self];
    [[NUYouTubeProvider shared] changed];
}

- (void)setAutoplayRenderer:(id)renderer {
    %orig;
    [[NUYouTubeProvider shared] captureAutonavController:self];
    [[NUYouTubeProvider shared] changed];
}

- (void)playbackControllerDidLoadPlayerWithPlaybackData:(id)data {
    %orig;
    [[NUYouTubeProvider shared] captureAutonavController:self];
    [[NUYouTubeProvider shared] changed];
}

- (void)updateAutoplayTransition {
    %orig;
    [[NUYouTubeProvider shared] changed];
}

- (void)reset {
    %orig;
    [[NUYouTubeProvider shared] changed];
}

%end

%end // YouTubeProvider

%ctor {
    @autoreleasepool {
        NUApplySandbox(); // grant shared mach service access (idempotent across ctors)
        if (!NUIsYouTube()) return;
        %init(YouTubeProvider);
        [[NUYouTubeProvider shared] startServer];
        NULog("loaded into YouTube (provider)");
#ifdef DEBUG
        // Interface drift probe (dev builds only): the provider is pinned against
        // YouTube 21.32.4's private YT* stack. After an app update, a missing
        // class/selector here is the first thing to check when the row goes blank.
        Class qc = objc_getClass("YTQueueController");
        if (!qc) NULog("yt probe: YTQueueController MISSING");
        else if (![qc instancesRespondToSelector:@selector(queueItemAtIndex:includeAutoplaySection:)])
            NULog("yt probe: -queueItemAtIndex:includeAutoplaySection: MISSING");
        else if (![qc instancesRespondToSelector:@selector(nextNavigableVideoIndexWithAutoplay:)])
            NULog("yt probe: -nextNavigableVideoIndexWithAutoplay: MISSING");
        if (!objc_getClass("YTQueueAutoplayController"))
            NULog("yt probe: YTQueueAutoplayController MISSING");
        Class ac = objc_getClass("YTAutoplayAutonavController");
        if (!ac) NULog("yt probe: YTAutoplayAutonavController MISSING");
        else if (![ac instancesRespondToSelector:@selector(autonavRenderer)])
            NULog("yt probe: -autonavRenderer MISSING");
#endif
    }
}
