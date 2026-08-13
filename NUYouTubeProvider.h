#import "NUProviderBase.h"

// Runs inside com.google.ios.youtube. The main YouTube app ships the same YT* queue stack as
// YouTube Music (YTQueueController / YTQueueItem / YTIPlaylistPanelVideoRenderer), so this
// provider mirrors NUYouTubeMusicProvider apart from where "next" comes from.
//
// Two sources feed the row. A playlist, mix or queued item is a queue entry and fully
// mutable. A standalone video leaves the queue empty and the next-up comes from the app's
// autoplay renderer instead; that one can only be played, so skip and re-queue-previous are
// reported as unavailable for it.
@interface NUYouTubeProvider : NUProviderBase
+ (instancetype)shared;
- (void)startServer;
// Called from the YTQueueController hooks (YouTube process) so we always hold the
// live singleton controller.
- (void)captureController:(id)queueController;
// Called from the YTAutoplayAutonavController hooks. For a standalone video the queue
// controller stays empty and the next-up lives only in the autonav renderer.
- (void)captureAutonavController:(id)autonavController;

// A queue mutation makes the app republish its now-playing info purely because the index or
// count changed. That republish rebuilds the dictionary from a cached state whose currentTime
// only the playback observer refreshes, so it carries a stale elapsed time and the system
// progress bar snaps backwards until the next push. These bracket a row-driven mutation so
// that republish can be skipped for its duration.
- (void)beginQueueMutation;
- (BOOL)suppressesLockScreenIndexUpdate;
// -changed (queue changed → re-broadcast to the display) is inherited from NUProviderBase.
@end
