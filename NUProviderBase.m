#import "NUProviderBase.h"
#import "NUShared.h"
#import "NUPrefs.h"
#import "LightMessaging.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h> // CACurrentMediaTime (monotonic query stamp)
#import <notify.h>

// One bound for every URL-fetch provider (raw full-size JPEG/PNG downloads, so
// the bound matters — unlike Music's 48pt PNGs).
static const NSUInteger kNUProviderArtworkCacheLimit = 24;

// How long after a display query we still consider a surface interested. Artwork
// work is only worth doing while something is actually rendering the row.
static const NSTimeInterval kNUDisplayInterestWindow = 20.0;

@interface NUProviderBase ()
@property (nonatomic, readwrite) BOOL serverStarted;
// Darwin tokens, kept so the registrations are owned somewhere (they are
// process-lifetime by design — providers live as long as their app).
@property (nonatomic) int skipToken;
@property (nonatomic) int prevToken;
@property (nonatomic) int jumpToken;
@property (nonatomic) CFTimeInterval lastQueryStamp; // last LM query served
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSData *> *artworkByKey;
@property (nonatomic, strong) NSMutableSet<NSString *> *artworkInFlight;
@property (nonatomic, strong) NSURLSession *urlSession;
@end

@implementation NUProviderBase

#pragma mark - LM server

static void NUProviderServerCallback(CFMachPortRef port, void *msg, CFIndex size, void *info) {
    LMMessage *message = (LMMessage *)msg;
    if (!message) return;
    mach_port_t replyPort = message->head.msgh_remote_port;
    NUProviderBase *provider = (__bridge NUProviderBase *)info;
    // A query means some display is rendering the row right now — stamp it so the
    // artwork paths can tell "someone is watching" from "nobody is looking".
    provider.lastQueryStamp = CACurrentMediaTime();
    // Only one request type: give the current next-up as a property list.
    LMSendPropertyListReply(replyPort, [provider nextUpDictionary]);
}

- (void)startServerWithService:(const char *)service
                          skip:(const char *)skipName
                          prev:(const char *)prevName
                          jump:(const char *)jumpName {
    if (self.serverStarted || !service) return;
    self.serverStarted = YES;
    // Distinct service name per app (all four can be alive at once → a shared
    // name would collide on registration; see NUShared.h).
    kern_return_t kr = LMStartServiceWithUserInfo((char *)service, CFRunLoopGetMain(),
                                                  NUProviderServerCallback, (__bridge void *)self);
    NULog("%{public}@: LMStartService '%s' kr=%d (0=ok)", self.class, service, kr);
    int token;
    if (skipName) {
        notify_register_dispatch(skipName, &token, dispatch_get_main_queue(), ^(int t) {
            [self skipNext];
        });
        self.skipToken = token;
    }
    if (prevName) {
        notify_register_dispatch(prevName, &token, dispatch_get_main_queue(), ^(int t) {
            [self playPrevious];
        });
        self.prevToken = token;
    }
    if (jumpName) {
        notify_register_dispatch(jumpName, &token, dispatch_get_main_queue(), ^(int t) {
            [self jumpToNext];
        });
        self.jumpToken = token;
    }
}

#pragma mark - Enablement + display interest

- (NSString *)appPrefKey { return nil; }

- (BOOL)providerEnabled {
    if (!NUMasterEnabled()) return NO;
    NSString *key = [self appPrefKey];
    return key ? NUPrefBool(key, YES) : YES;
}

- (BOOL)displayRecentlyQueried {
    return self.lastQueryStamp > 0
        && (CACurrentMediaTime() - self.lastQueryStamp) < kNUDisplayInterestWindow;
}

#pragma mark - Overrides (defaults)

- (NSDictionary *)nextUpDictionary { return @{ kNUKeyActive : @NO }; }
- (void)skipNext {}
- (void)playPrevious {}
- (void)jumpToNext {}

- (void)changed {
    // No self-tracked state here — just signal the display to re-query.
    notify_post(kNUChangedNotification);
}

// Post a change now and again shortly after the mutation settles (the app's own
// hooks usually also fire theirs).
- (void)changedSoon { [self changedSoonAfter:0.4]; }

- (void)changedSoonAfter:(NSTimeInterval)settle {
    dispatch_async(dispatch_get_main_queue(), ^{ [self changed]; });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(settle * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self changed]; });
}

#pragma mark - Keyed artwork cache

- (NSURLSession *)session {
    if (!_urlSession) {
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.requestCachePolicy = NSURLRequestReturnCacheDataElseLoad;
        _urlSession = [NSURLSession sessionWithConfiguration:cfg];
    }
    return _urlSession;
}

- (NSData *)cachedArtworkForKey:(NSString *)key {
    return key ? self.artworkByKey[key] : nil;
}

- (BOOL)artworkFetchInFlightForKey:(NSString *)key {
    return key && [self.artworkInFlight containsObject:key];
}

- (NSArray<NSString *> *)artworkKeysToProtect { return @[]; }

- (void)fetchArtworkAtURL:(NSURL *)url forKey:(NSString *)key {
    if (!url || key.length == 0) return;
    if (!self.artworkByKey) self.artworkByKey = [NSMutableDictionary dictionary];
    if (!self.artworkInFlight) self.artworkInFlight = [NSMutableSet set];
    if (self.artworkByKey[key]) return;               // cached (a track's cover never changes)
    if ([self.artworkInFlight containsObject:key]) return; // already fetching
    [self.artworkInFlight addObject:key];

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [self.session dataTaskWithURL:url
                                            completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        // Runs on a background delegate queue. Validate it decodes, then cache the raw bytes.
        UIImage *img = data.length ? [UIImage imageWithData:data] : nil;
        NSData *store = img ? data : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf; if (!self) return;
            [self.artworkInFlight removeObject:key];
            if (!store) return;
            self.artworkByKey[key] = store;
            // Bound the cache (each snapshot carries its own bytes on the wire, so
            // pruning is safe), protecting the on-screen window the subclass names.
            if (self.artworkByKey.count > kNUProviderArtworkCacheLimit) {
                NSMutableSet *keep = [NSMutableSet setWithObject:key];
                [keep addObjectsFromArray:[self artworkKeysToProtect]];
                for (NSString *k in self.artworkByKey.allKeys) {
                    if (self.artworkByKey.count <= kNUProviderArtworkCacheLimit) break;
                    if (![keep containsObject:k]) [self.artworkByKey removeObjectForKey:k];
                }
            }
            NULog("%{public}@: cached artwork for '%{public}@'", self.class, key);
            notify_post(kNUChangedNotification);
        });
    }];
    [task resume];
}

@end
