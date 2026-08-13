// User-preferences layer for NextUp 3.
//
// The Settings pane (prefs/, a PreferenceLoader bundle) persists booleans to the
// CFPreferences domain kNUPrefsDomain AND mirrors the live toggle state into a Darwin
// notify_state token (kNUStateNotify). The injected processes (Music / Podcasts /
// MediaRemoteUI / SpringBoard) read the token, which is global, immediate and
// sandbox-crossing — cross-process CFPreferences reads are cached/stale, so they can't
// drive a live toggle (they only update after a respring). Same trick the DITouch flag
// in NUShared.h already uses. CFPreferences remains the persisted fallback, read reliably
// at process start and after a reboot (the token's state is cleared by notifyd on reboot).
#import <Foundation/Foundation.h>

#define kNUPrefsDomain "com.yves.nextup3"        // CFPreferences app id / plist domain
#define kNUStateNotify "com.yves.nextup3.state"  // notify_state: live toggle bitmask + change signal

// Toggle bit layout in the notify_state word. Shared by the reader (NUPrefs.m) and the
// writer (NUPrefsPublishState / the Settings controller). bit63 marks the token as
// published — until Settings sets it, readers fall back to CFPreferences.
// Value bits are 0..31 — 32 toggles max (known-mask shift 32 and valid bit 63 set the ceiling).
#define kNUStateValidBit       (1ULL << 63)
#define kNUStateMaster         (1ULL << 0)   // "Enabled"
#define kNUStateAppMusic       (1ULL << 1)   // "enabledMusic"
#define kNUStateAppPodcasts    (1ULL << 2)   // "enabledPodcasts"
#define kNUStateLockScreen     (1ULL << 3)   // "showLockScreen"
#define kNUStateDynamicIsland  (1ULL << 4)   // "showDynamicIsland"
#define kNUStateControlCenter  (1ULL << 5)   // "showControlCenter"
#define kNUStateAppYouTubeMusic (1ULL << 6)  // "enabledYouTubeMusic"
#define kNUStateAppSpotify     (1ULL << 7)   // "enabledSpotify"
#define kNUStateAppYouTube     (1ULL << 8)   // "enabledYouTube"

// Known-keys mask: bit (n + 32) mirrors value bit n and means "the publishing Settings
// build knew this key"; a value bit whose known bit is 0 falls back to CFPreferences.
#define kNUStateKnownShift 32

// Settings key → its state bit (0 if the key has no bit).
static inline uint64_t NUStateBitForKey(NSString *key) {
    if ([key isEqualToString:@"Enabled"])           return kNUStateMaster;
    if ([key isEqualToString:@"enabledMusic"])      return kNUStateAppMusic;
    if ([key isEqualToString:@"enabledPodcasts"])   return kNUStateAppPodcasts;
    if ([key isEqualToString:@"enabledYouTubeMusic"]) return kNUStateAppYouTubeMusic;
    if ([key isEqualToString:@"enabledYouTube"])     return kNUStateAppYouTube;
    if ([key isEqualToString:@"enabledSpotify"])    return kNUStateAppSpotify;
    if ([key isEqualToString:@"showLockScreen"])    return kNUStateLockScreen;
    if ([key isEqualToString:@"showDynamicIsland"]) return kNUStateDynamicIsland;
    if ([key isEqualToString:@"showControlCenter"]) return kNUStateControlCenter;
    return 0;
}

// Read a boolean pref. Prefers the live notify-state token; falls back to CFPreferences
// (with `def`) before Settings has published or after a reboot. Fails OPEN — a fresh
// install with no plist behaves exactly as before.
BOOL NUPrefBool(NSString *key, BOOL def);

// Master on/off switch (key "Enabled", default YES).
BOOL NUMasterEnabled(void);

// Register once per process for the change signal; on fire, `onChange` (may be nil)
// runs on the main queue.
void NUPrefsObserve(dispatch_block_t onChange);

// Publish the current CFPreferences values into the notify-state token and post the
// change signal. Called by the Settings controller after each write, so already-running
// injected processes pick up the toggle without a respring.
void NUPrefsPublishState(void);
