#import <Foundation/Foundation.h>

// Shared plumbing for the per-app providers (Music/MPC, Podcasts/MT*, Spotify,
// YTM). Everything here used to be four near-identical copies — which is exactly
// how the Music provider missed the main-thread pin the Podcasts provider had:
// a fix that lands in the base lands everywhere. Subclasses keep everything
// app-specific: queue reading (-nextUpDictionary), the actions, and their own
// +shared (a plain dispatch_once each).
@interface NUProviderBase : NSObject

#pragma mark - LM server + display→provider notifications

// Registers the LightMessaging service on the main runloop (the reply to any
// request is -nextUpDictionary as a property list) and the given Darwin
// notification handlers on the main queue. A NULL name skips that capability —
// e.g. Spotify has no jump (the display sends the MediaRemote command directly)
// and Music enqueues 'previous' display-side. Idempotent via `serverStarted`.
- (void)startServerWithService:(const char *)service
                          skip:(const char *)skipName
                          prev:(const char *)prevName
                          jump:(const char *)jumpName;
@property (nonatomic, readonly) BOOL serverStarted;

#pragma mark - Enablement + display interest

// Is the row wanted at all for this app? (master toggle AND this app's toggle).
// Providers MUST gate their queue reading / artwork work on this: the Settings
// toggles used to gate only the display, so a "disabled" tweak still had the
// provider polling the app's media stack in the background.
- (BOOL)providerEnabled;
// Subclass: this app's Settings key ("enabledMusic", …). nil = no per-app gate.
- (NSString *)appPrefKey;
// Did a display query us recently (i.e. is anyone actually rendering the row)?
// Stamped by the LM server callback.
- (BOOL)displayRecentlyQueried;

#pragma mark - Subclass overrides

- (NSDictionary *)nextUpDictionary;  // base: @{ active: NO }
- (void)skipNext;                    // base: no-op
- (void)playPrevious;                // base: no-op
- (void)jumpToNext;                  // base: no-op

// Queue / now-playing changed → signal the display to re-query. Base just posts
// kNUChangedNotification (fits providers whose queue state lives in the app);
// a provider with self-tracked state overrides it (Podcasts pins its history
// mutation to main, Music routes to its queueChanged pipeline).
- (void)changed;
// Post a change now and again once a queue mutation settles (default 0.4 s).
- (void)changedSoon;
- (void)changedSoonAfter:(NSTimeInterval)settle;

#pragma mark - Keyed raw-bytes artwork cache (URL-fetch providers: Spotify / YTM)

// Async fetch → validate it decodes → cache the raw bytes by `key` on the main
// queue → prune (protecting -artworkKeysToProtect) → post a change so the
// display re-queries. No-ops when the key is cached or a fetch is in flight.
// All cache access is main-queue-confined, like the callers.
- (void)fetchArtworkAtURL:(NSURL *)url forKey:(NSString *)key;
- (NSData *)cachedArtworkForKey:(NSString *)key;
- (BOOL)artworkFetchInFlightForKey:(NSString *)key;
// Keys the prune must never evict (the on-screen next/fwd/back window) —
// allKeys is unordered, so an unprotected prune can evict the very artwork the
// row is showing, flashing the placeholder and immediately refetching it.
- (NSArray<NSString *> *)artworkKeysToProtect; // base: none
// Lazy ephemeral NSURLSession (return-cache-data-else-load) for those fetches.
- (NSURLSession *)session;

@end
