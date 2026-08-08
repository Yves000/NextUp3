// Spotify-provider hooks (com.spotify.client). Capture the live SPTPlayerService (and, as a
// fallback, any SPTEsperantoPlayer) so the provider can serve the next-up snapshot and edit the
// queue. Parallel to NUHooksMusicProvider.x / NUHooksPodcastProvider.x / NUHooksYouTubeMusicProvider.x.
//
// Unlike the other providers, there are NO change hooks here: Spotify ships a real observer
// protocol (SPTPlayerObserver -player:stateDidChange:), so the provider registers itself with the
// service and gets told. That is strictly better than hooking mutation methods — it also catches
// changes driven by Spotify Connect from another device, which no local hook would see.
//
// Reaching an instance requires hooking: every SPT* service is dependency-injected through
// SPTServiceProvider and there is no +sharedInstance anywhere in the app.
#import "NUHooksShared.h"
#import "NUSpotifyProvider.h"

@interface SPTPlayerServiceImplementation : NSObject
- (void)_injectDependenciesWithProvider:(id)provider;
- (void)loadLazily;
- (void)loadObservationPlayer;
@end

@interface SPTEsperantoPlayer : NSObject
- (id)initWithClient:(id)client interceptor:(id)interceptor viewURI:(id)uri
  referrerIdentifier:(id)referrerIdentifier featureIdentifier:(id)featureIdentifier
      featureVersion:(id)version timeGetter:(id)getter queue:(id)queue
  playerSubscription:(id)subscription;
@end

%group SpotifyProvider

// --- The player service: what we actually want. It owns the observation player, so it is both the
// state source and the way to mint a player for queue writes. All three are instance methods, so
// `self` is the live service; capture is idempotent. ---
%hook SPTPlayerServiceImplementation

- (void)_injectDependenciesWithProvider:(id)provider {
    %orig;
    [[NUSpotifyProvider shared] captureService:self];
}

- (void)loadLazily {
    %orig;
    [[NUSpotifyProvider shared] captureService:self];
}

- (void)loadObservationPlayer {
    %orig;
    [[NUSpotifyProvider shared] captureService:self];
}

%end

// --- Fallback: catch a player directly at birth, in case the service shape changes under a
// Spotify update. The provider prefers the service and only falls back to this. ---
%hook SPTEsperantoPlayer

- (id)initWithClient:(id)client interceptor:(id)interceptor viewURI:(id)uri
  referrerIdentifier:(id)referrerIdentifier featureIdentifier:(id)featureIdentifier
      featureVersion:(id)version timeGetter:(id)getter queue:(id)queue
  playerSubscription:(id)subscription {
    id r = %orig;
    if (r) [[NUSpotifyProvider shared] capturePlayer:r];
    return r;
}

%end

%end // SpotifyProvider

%ctor {
    @autoreleasepool {
        NUApplySandbox(); // grant shared mach service access (idempotent across ctors)
        if (!NUIsSpotify()) return;
        %init(SpotifyProvider);
        [[NUSpotifyProvider shared] startServer];
        NULog("loaded into Spotify (provider)");
#ifdef DEBUG
        // Interface drift probe (dev builds only): the provider is pinned against
        // Spotify 9.1.62's private SPT* facade. After an app update, a missing
        // class/selector here is the first thing to check when the row goes blank.
        Class svc = objc_getClass("SPTPlayerServiceImplementation");
        if (!svc) NULog("spotify probe: SPTPlayerServiceImplementation MISSING");
        else if (![svc instancesRespondToSelector:@selector(addPlayerObserver:)])
            NULog("spotify probe: -addPlayerObserver: MISSING");
#endif
    }
}
