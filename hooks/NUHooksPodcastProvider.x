// Podcast-provider hooks (com.apple.podcasts). Capture the live MTPlayerController
// (a singleton) and observe up-next / current-item changes so the provider can
// serve the next-up snapshot and perform skips. Parallel to NUHooksMusicProvider.x;
// Podcasts uses its own MT* queue stack, not MPCQueueController.
#import "NUHooksShared.h"
#import "NUPodcastProvider.h"

@interface MTPlayerController : NSObject
- (void)currentItemDidChange;
- (id)initWithPlayer:(id)player;
@end

@interface MTUpNextController : NSObject
- (void)_upNextDidChange;
- (id)playerController;
- (void)setPlayerItems:(NSArray *)items;
@end

%group PodcastProvider

%hook MTPlayerController

// Capture at creation so we hold the controller from launch, before any change.
- (id)initWithPlayer:(id)player {
    id r = %orig;
    [[NUPodcastProvider shared] captureController:r];
    return r;
}

// Current episode changed (advanced to the next, or a new item started).
- (void)currentItemDidChange {
    %orig;
    [[NUPodcastProvider shared] captureController:(id)self];
    [[NUPodcastProvider shared] changed];
}

%end

%hook MTUpNextController

// Up-next edited (episode added/removed/reordered, incl. our own skip).
- (void)_upNextDidChange {
    %orig;
    // Hold the up-next controller itself: on iOS 14.2 there is no
    // -[MTPlayerController upNextController], so this receiver is the only handle on it.
    [[NUPodcastProvider shared] captureUpNext:self];
    // -playerController is absent on older Podcasts (verified: iOS 14.2, app 3.9) — and this
    // runs on a background AMS queue, so an unguarded call throws unrecognized-selector with
    // no @catch above us → SIGABRT (observed on adding an up-next item). The controller is
    // already captured via -initWithPlayer:/-currentItemDidChange, so skip re-capture where
    // the selector doesn't exist rather than depend on it.
    if ([self respondsToSelector:@selector(playerController)])
        [[NUPodcastProvider shared] captureController:[self playerController]];
    [[NUPodcastProvider shared] changed];
}

// The queue is (re)built through -setPlayerItems: — including on launch/restore before any
// user edit fires -_upNextDidChange. Capture here too so the provider has the controller as
// soon as a queue exists, not only after the first change.
- (void)setPlayerItems:(id)items {
    %orig;
    [[NUPodcastProvider shared] captureUpNext:self];
}

%end

%end // PodcastProvider

%ctor {
    @autoreleasepool {
        NUApplySandbox(); // grant shared mach service access (idempotent across ctors)
        if (!NUIsPodcasts()) return;
        // iOS 18 Podcasts uses the MPCQueueController stack instead (served by the MPC provider in
        // NUHooksMusicProvider). Its MT* controllers are never instantiated here, and starting this
        // server too would collide with the MPC provider on the Podcasts LM service name.
        if (NUIOSMajor() >= 18) { NULog("Podcasts iOS>=18: MT* provider disabled (MPC path)"); return; }
        %init(PodcastProvider);
        [[NUPodcastProvider shared] startServer];
        NULog("loaded into Podcasts (provider)");
    }
}
