#import "NUProviderBase.h"

// Runs inside com.spotify.client. Reads the live player's up-next queue, serves the current
// "next up" over LightMessaging, and performs skip / previous. Parallel to NUMusicProvider /
// NUPodcastProvider / NUYouTubeMusicProvider.
//
// Spotify's queue really lives in a C++/Rust core reached over esperanto protobuf RPC, but the
// app still ships the old SPT* Objective-C facade on top of it (SPTPlayer / SPTPlayerState /
// SPTPlayerTrack / SPTPlayerQueue), which is what we drive.
//
// Unlike Apple Music / Podcasts (local artwork), Spotify artwork is a remote URL: -[SPTPlayerTrack
// imageURL] is a `spotify:image:<hex>` URI that Spotify's own NSURL category rewrites to a public
// i.scdn.co CDN URL. The provider fetches and caches the bytes by track URI, like the YTM provider.
@interface NUSpotifyProvider : NUProviderBase
+ (instancetype)shared;
- (void)startServer;
// Called from the Spotify hooks so we always hold the live player service / player. The service is
// preferred: it owns the dedicated *observation* player, which is guaranteed to be subscribed to
// the core (an arbitrary per-feature player may not be).
- (void)captureService:(id)service;
- (void)capturePlayer:(id)player;
// -changed (queue changed → re-broadcast to the display) is inherited from NUProviderBase.
@end
