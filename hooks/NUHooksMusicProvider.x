// Music-provider hooks (com.apple.Music). Capture the live queue controller and
// its player response, and observe queue changes so the provider can serve the
// next-up snapshot and perform skips.
#import "NUHooksShared.h"
#import "NUMusicProvider.h"

%group MusicProvider

// Capture the materialised player response so the provider can remove the next
// track. Every tracklist is built from a response; the provider keeps the one
// that is system-music with a real forward queue.
%hook MPCPlayerResponseTracklist
- (id)initWithResponse:(id)response {
    id r = %orig;
    NULog("hook: tracklist initWithResponse %p", response);
    [[NUMusicProvider shared] captureResponse:response];
    return r;
}
%end

%hook MPCQueueController

- (void)_currentItemDidChangeFromItem:(id)from toItem:(id)to {
    %orig;
    [[NUMusicProvider shared] captureController:(id)self];
    [[NUMusicProvider shared] queueChanged];
}

- (void)didSignificantlyChangeItem:(id)item {
    %orig;
    [[NUMusicProvider shared] captureController:(id)self];
    [[NUMusicProvider shared] queueChanged];
}

- (void)performSetQueue:(id)queue loadingItemReady:(id)ready completion:(id)completion {
    %orig;
    [[NUMusicProvider shared] captureController:(id)self];
    [[NUMusicProvider shared] queueChanged];
}

// iOS 16: MPCQueueController lacks -didSignificantlyChangeItem: and
// -performSetQueue:loadingItemReady:completion: (those are iOS 17 selectors and
// the hooks above no-op there). The equivalent "a new queue was set / reloaded"
// entry points on iOS 16 are these two. Same idempotent capture; harmless on
// iOS 17 (extra, redundant capture) — Logos skips whichever selector is absent.
- (void)reloadItemsKeepingCurrentItem:(BOOL)keep {
    %orig;
    [[NUMusicProvider shared] captureController:(id)self];
    [[NUMusicProvider shared] queueChanged];
}

- (void)reloadWithPlaybackContext:(id)context completionHandler:(id)completion {
    %orig;
    [[NUMusicProvider shared] captureController:(id)self];
    [[NUMusicProvider shared] queueChanged];
}

%end

%end // MusicProvider

%ctor {
    @autoreleasepool {
        NUApplySandbox(); // grant shared-file access (idempotent across every hook file's ctor)
        // iOS 18 Podcasts dropped its MT* stack for the same MPCQueueController stack Music uses
        // (verified live: MTPlayerController/MTUpNextController are never instantiated; the queue
        // is a live MPCQueueController read identically). So this MPC provider serves Podcasts
        // there too — bound to the Podcasts LM service in -startServer. Pre-18 Podcasts keeps the
        // MT* provider in NUHooksPodcastProvider.
        BOOL runHere = NUIsMusic() || (NUIsPodcasts() && NUIOSMajor() >= 18);
        if (!runHere) return;
        %init(MusicProvider);
        [[NUMusicProvider shared] startServer];
        NULog("loaded MPC provider into %{public}@", NSBundle.mainBundle.bundleIdentifier);
    }
}
