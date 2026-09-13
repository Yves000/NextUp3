#import "NUProviderBase.h"

// Runs inside com.soundcloud.TouchApp. Reads the live play queue, serves the current "next up"
// over LightMessaging, and re-queues the previous track. Parallel to NUSpotifyProvider /
// NUYouTubeMusicProvider.
//
// SoundCloud is a Swift app, but its playback layer is deliberately @objc-exposed, so unlike
// Spotify there is no capture dance: Playback.PlaybackService is an @objc NSObject subclass with a
// real +sharedInstance, and it carries the whole surface we need (currentPlayQueueItem,
// playQueueItemAfter:/Before:, addSourceNextUp:position:). The hooks exist only to signal CHANGE.
//
// The @objc queue surface is add-only, so skip goes through a swiftcall shim on the Swift-only
// NewPlayQueueNextUp.removeItem (see NUSoundCloudProvider.m); unresolvable symbols degrade to
// canSkip = NO. Ads and proxy placeholders are real queue entries on free accounts, so every read
// walks past them to the next real track.
//
// Built against SoundCloud 8.75.0 (iOS 16.4+, the app's own minimum).
@interface NUSoundCloudProvider : NUProviderBase
+ (instancetype)shared;
- (void)startServer;
// Called from the SoundCloud hooks when the queue changed.
- (void)queueChanged;
// Same, but only broadcasts when the playing/next pair actually moved — for the now-playing-info
// hook, which also fires for elapsed-time updates about once a second.
- (void)signalIfChanged;
@end
