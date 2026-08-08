#import "NUProviderBase.h"

// Runs inside com.google.ios.youtubemusic. Reads the live YTQueueController's
// up-next queue, serves the current "next up" over LightMessaging, and performs
// skip / play-now / previous. Parallel to NUMusicProvider / NUPodcastProvider —
// YouTube Music drives its queue through its own YT* stack (YTQueueController),
// NOT MPCQueueController and NOT the low-level ML* player.
//
// Unlike Apple Music / Podcasts (local artwork), YTM artwork is a remote URL: the
// clean 1:1 cover comes from -[YTQueueItem rendererForContentMode:0] (art track),
// with the 16:9 i.ytimg.com video thumbnail as fallback. The provider fetches and
// caches PNGs by videoId.
@interface NUYouTubeMusicProvider : NUProviderBase
+ (instancetype)shared;
- (void)startServer;
// Called from the YTQueueController hooks (YTM process) so we always hold the live
// singleton controller.
- (void)captureController:(id)queueController;
// -changed (queue changed → re-broadcast to the display) is inherited from NUProviderBase.
@end
