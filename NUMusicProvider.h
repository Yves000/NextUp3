#import "NUProviderBase.h"

// Runs inside com.apple.Music. Reads the live MPCQueueController, serves the
// current "next up" over LightMessaging, and performs skip requests.
@interface NUMusicProvider : NUProviderBase
+ (instancetype)shared;
- (void)startServer;
// Called from the MPCQueueController hooks (Music process).
- (void)captureController:(id)queueController;
- (void)queueChanged;
// Called from the MPCPlayerResponseTracklist hook to grab a materialised response.
- (void)captureResponse:(id)response;
@end
