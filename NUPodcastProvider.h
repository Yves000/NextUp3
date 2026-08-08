#import "NUProviderBase.h"

// Runs inside com.apple.podcasts. Reads the live MTPlayerController's up-next
// queue, serves the current "next up" over LightMessaging, and performs skips.
// Parallel to NUMusicProvider (Music side) — Podcasts drives its queue through
// its own MT* stack, NOT MPCQueueController.
@interface NUPodcastProvider : NUProviderBase
+ (instancetype)shared;
- (void)startServer;
// Called from the MTPlayerController / MTUpNextController hooks (Podcasts process).
- (void)captureController:(id)playerController;
// Hold the MTUpNextController directly. On iOS 14.2 there is no
// -[MTPlayerController upNextController]; the controller is only reachable as the
// receiver of the MTUpNextController hooks, so we capture it there.
- (void)captureUpNext:(id)upNextController;
- (void)changed;
@end
