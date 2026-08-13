#import "NUPrefs.h"
#import <os/lock.h>
#import <notify.h>

#pragma mark - notify_state token

// One registration per process for the shared toggle word. Registering with
// notify_register_check gives a token usable for both get_state and set_state; the
// STATE itself is global to the name, so Settings' set_state is visible here.
static int NUStateToken(void) {
    static int token = -1;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (notify_register_check(kNUStateNotify, &token) != NOTIFY_STATUS_OK) token = -1;
    });
    return token;
}

static BOOL NUStateRead(uint64_t *out) {
    int t = NUStateToken();
    if (t == -1) return NO;
    uint64_t s = 0;
    if (notify_get_state(t, &s) != NOTIFY_STATUS_OK) return NO;
    *out = s;
    return YES;
}

#pragma mark - CFPreferences fallback (persisted; reliable at process start)

// Cached so the token-invalid path (pre-publish / just after reboot) doesn't hit cfprefsd
// on every layout. Once Settings publishes the token, reads never reach here.
static NSMutableDictionary<NSString *, NSNumber *> *gCFCache;
static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;

// `fresh`: Settings must CFPreferencesAppSynchronize before reading (its own writes);
// passive readers must not (cross-process cache).
static BOOL NUReadCF(NSString *key, BOOL def, BOOL fresh) {
    if (!fresh) {
        os_unfair_lock_lock(&gLock);
        if (!gCFCache) gCFCache = [NSMutableDictionary new];
        NSNumber *c = gCFCache[key];
        if (c) { BOOL v = c.boolValue; os_unfair_lock_unlock(&gLock); return v; }
        os_unfair_lock_unlock(&gLock);
    } else {
        CFPreferencesAppSynchronize(CFSTR(kNUPrefsDomain));
    }
    Boolean present = false;
    Boolean value = CFPreferencesGetAppBooleanValue((__bridge CFStringRef)key,
                                                    CFSTR(kNUPrefsDomain), &present);
    BOOL result = present ? (BOOL)value : def;
    if (!fresh) {
        os_unfair_lock_lock(&gLock);
        gCFCache[key] = @(result);
        os_unfair_lock_unlock(&gLock);
    }
    return result;
}

#pragma mark - Public

BOOL NUPrefBool(NSString *key, BOOL def) {
    uint64_t s = 0;
    if (NUStateRead(&s) && (s & kNUStateValidBit)) {
        uint64_t bit = NUStateBitForKey(key);
        // Only trust bits the publisher knew — see kNUStateKnownShift in NUPrefs.h.
        if (bit && (s & (bit << kNUStateKnownShift))) return (s & bit) != 0;
    }
    return NUReadCF(key, def, /*fresh=*/NO);
}

BOOL NUMasterEnabled(void) { return NUPrefBool(@"Enabled", YES); }

void NUPrefsObserve(dispatch_block_t onChange) {
    static int token;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        notify_register_dispatch(kNUStateNotify, &token, dispatch_get_main_queue(), ^(int t) {
            os_unfair_lock_lock(&gLock);
            [gCFCache removeAllObjects]; // token drives reads now; drop any stale fallback too
            os_unfair_lock_unlock(&gLock);
            if (onChange) onChange();
        });
    });
}

void NUPrefsPublishState(void) {
    // Build the word from the freshly-written plist (this is Settings' own process, so the
    // read is reliable), stamp it valid, publish, and signal.
    uint64_t mask = kNUStateValidBit;
    if (NUReadCF(@"Enabled",           YES, /*fresh=*/YES)) mask |= kNUStateMaster;
    if (NUReadCF(@"enabledMusic",      YES, YES))           mask |= kNUStateAppMusic;
    if (NUReadCF(@"enabledPodcasts",   YES, YES))           mask |= kNUStateAppPodcasts;
    if (NUReadCF(@"enabledYouTubeMusic", YES, YES))         mask |= kNUStateAppYouTubeMusic;
    if (NUReadCF(@"enabledYouTube",    YES, YES))           mask |= kNUStateAppYouTube;
    if (NUReadCF(@"enabledSpotify",    YES, YES))           mask |= kNUStateAppSpotify;
    if (NUReadCF(@"showLockScreen",    YES, YES))           mask |= kNUStateLockScreen;
    if (NUReadCF(@"showDynamicIsland", YES, YES))           mask |= kNUStateDynamicIsland;
    if (NUReadCF(@"showControlCenter", YES, YES))           mask |= kNUStateControlCenter;
    // Stamp every key this build knows into the known-keys mask (see kNUStateKnownShift in NUPrefs.h).
    mask |= (kNUStateMaster | kNUStateAppMusic | kNUStateAppPodcasts
             | kNUStateAppYouTubeMusic | kNUStateAppYouTube | kNUStateAppSpotify
             | kNUStateLockScreen | kNUStateDynamicIsland
             | kNUStateControlCenter) << kNUStateKnownShift;

    int t = NUStateToken();
    if (t != -1) notify_set_state(t, mask);
    notify_post(kNUStateNotify);
}
