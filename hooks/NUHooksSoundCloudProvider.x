// SoundCloud-provider hooks (com.soundcloud.TouchApp). Parallel to NUHooksSpotifyProvider.x —
// but much thinner, because SoundCloud needs no capture: Playback.PlaybackService is an @objc
// class with a real +sharedInstance, so the provider resolves the live object itself. These
// hooks exist ONLY to learn that something changed.
//
// -playQueueManagerDidChangePlayQueue: is the PlayQueueManagerDelegate callback and fires on every
// queue mutation (append, next-up insert, shuffle, related-tracks fetch), whoever caused it. It is
// hookable because that callback comes from the ObjC PlayQueueManager, i.e. through objc_msgSend.
// Track transitions need a different signal entirely — see the SoundCloudNowPlaying group below.
//
// Deliberately NOT hooked: any PlayQueueManager class. There are four implementations
// (BasicPlayQueueManager, AdPlayQueueManager — the normal one on free accounts —
// GoogleCastPlayQueueManager, and the native queue player's own), and the service already
// forwards to whichever is live.
#import "NUHooksShared.h"
#import "NUSoundCloudProvider.h"
#import <mach-o/dyld.h>

@interface _TtC8Playback15PlaybackService : NSObject
- (void)playQueueManagerDidChangePlayQueue:(id)manager;
- (void)setCurrentPlayQueueItem:(id)item;
- (void)setRepeatMode:(long long)mode;
@end

// Self-declared, never linked: MediaPlayer must not reach the link line (ld64 would record it as
// an LC_LOAD_DYLIB and force-load it into every injected process). SoundCloud already links it
// itself, so the class is there at runtime.
@interface MPNowPlayingInfoCenter : NSObject
- (void)setNowPlayingInfo:(NSDictionary *)info;
@end

%group SoundCloudProvider

%hook _TtC8Playback15PlaybackService

- (void)playQueueManagerDidChangePlayQueue:(id)manager {
    %orig;
    NULog("soundcloud hook: playQueueManagerDidChangePlayQueue:");
    [[NUSoundCloudProvider shared] queueChanged];
}

// Never observed to fire on 8.75.0 (Swift writes the stored property directly); kept because an
// ObjC-side caller in a later build would go through this thunk, and it costs nothing.
- (void)setCurrentPlayQueueItem:(id)item {
    %orig;
    [[NUSoundCloudProvider shared] queueChanged];
}

// Repeat-one hides the row (nothing is up next), so a mode change has to re-broadcast.
- (void)setRepeatMode:(long long)mode {
    %orig;
    [[NUSoundCloudProvider shared] queueChanged];
}

%end

%end // SoundCloudProvider

// The track-TRANSITION signal, and the reason it is a separate group: nothing on the Playback
// classes reports one. -playQueueManagerDidChangePlayQueue: covers queue *edits*, and
// -setCurrentPlayQueueItem: never fires at all — PlaybackService is a Swift class, so its own
// assignments write the stored property directly and never reach that @objc thunk.
//
// MPNowPlayingInfoCenter is ObjC framework API, so Swift must call it through objc_msgSend, and
// SoundCloud re-publishes on every transition. It also re-publishes for elapsed time roughly once
// a second, which is why this goes to -signalIfChanged (deduplicated) rather than -queueChanged.
%group SoundCloudNowPlaying

%hook MPNowPlayingInfoCenter

- (void)setNowPlayingInfo:(NSDictionary *)info {
    %orig;
    [[NUSoundCloudProvider shared] signalIfChanged];
}

%end

%end // SoundCloudNowPlaying

// Playback.framework is a dependency of the main executable, but an inserted dylib's ctor can run
// before that image is initialised, so gate on the class actually existing.
// _dyld_register_func_for_add_image also replays already-loaded images, which covers both orders
// without a separate up-front check.
static void NUSCInitIfLoaded(void) {
    // Two independent gates: Playback and MediaPlayer are separate images and either can arrive
    // first, and a group whose class is not up yet would %init into nothing, silently.
    static BOOL didProvider = NO, didNowPlaying = NO;
    if (!didProvider && objc_getClass("_TtC8Playback15PlaybackService")) {
        didProvider = YES;
        %init(SoundCloudProvider);
        [[NUSoundCloudProvider shared] startServer];
        NULog("loaded into SoundCloud (provider)");
    }
    if (!didNowPlaying && objc_getClass("MPNowPlayingInfoCenter")) {
        didNowPlaying = YES;
        %init(SoundCloudNowPlaying);
        NULog("soundcloud: now-playing transition hook active");
    }
}

static void NUSCImageAdded(const struct mach_header *mh, intptr_t slide) {
    NUSCInitIfLoaded();
}

%ctor {
    @autoreleasepool {
        NUApplySandbox(); // grant shared mach service access (idempotent across ctors)
        if (!NUIsSoundCloud()) return;
        _dyld_register_func_for_add_image(NUSCImageAdded);
    }
}
