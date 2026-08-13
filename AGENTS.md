# NextUp3 — agent guide

(This file and CLAUDE.md are identical — edit both together.)

## What this is

An open-source iOS jailbreak tweak (Theos/Logos, Objective-C) that adds an
"Up Next" row to the system now-playing UI — Lock Screen, Control Center and
Dynamic Island — for Apple Music, Apple Podcasts, YouTube Music and Spotify on
iOS 14.2 – 26. It is an on-device UI enhancement for the user's own jailbroken
device: it customizes the now-playing interface by interoperating with Apple's
private MediaRemote / MediaControls frameworks. The private-API interface
declarations and version notes exist to make that UI integration line up across
iOS versions.

## Architecture (one dylib, six processes)

Two roles, decided per process in each hook file's `%ctor`:

- **Providers** — one per media app, each in its own process:
  `NUMusicProvider` (com.apple.Music; also serves Podcasts on iOS 18+, which
  moved to the same MPCQueueController stack), `NUPodcastProvider`
  (com.apple.podcasts, pre-iOS-18 MT* stack), `NUYouTubeMusicProvider`
  (com.google.ios.youtubemusic, YT* stack), `NUSpotifyProvider`
  (com.spotify.client, SPT* facade). All subclass `NUProviderBase`. A provider
  reads its app's live queue, serves title/artist/artwork snapshots over IPC,
  and performs skip / play-now / previous through the app's own in-process API.
- **Display** — `NUNextUpManager` (source tracking + LightMessaging client +
  snapshot cache) and `NUNextUpRowView` (the row UI) run inside
  com.apple.MediaRemoteUI and com.apple.springboard.

**IPC:** LightMessaging (mach, vendored headers in `vendor/`) under a libSandy
profile (`layout/Library/libSandy/com.yves.nextup3.plist`) that grants
mach-register/lookup for the per-source service names. Darwin notifications
carry the signals: "changed" (provider → display, shared by all providers) and
per-source skip / prev / jump (display → provider). Names live in `NUShared.h`.

**Prefs:** live state rides a Darwin notify-state token (cross-process,
instant); CFPreferences (domain `com.yves.nextup3`) is only the persisted
fallback. Canonical explanation at the top of `NUPrefs.h`.

## File map / grep entry points

| Where | What you'll find |
|---|---|
| `hooks/NUHooksNowPlaying.x` | Shared display plumbing: row attach, platter sizing, settle ticks |
| `hooks/NUHooksLockScreen14.x` / `15` / `18` | Lock screen platter growth where SpringBoard-side surgery is needed. 14/15: player hosted in-process in SpringBoard (CoverSheet), two different height levers. 16/17: no file — the player is a remote MediaRemoteUI scene that sizes itself, NUHooksNowPlaying.x draws the row inside it. 18+ (incl. 26, `NUIOSMajor() >= 18`): still MediaRemoteUI content, but hosted as a fixed-height Live Activity, so the row is rendered SpringBoard-side |
| `hooks/NUHooksControlCenterLegacy.x` / `18` / `26` | Control Center per version (26 = Swift rewrite, `%init` deferred via `_dyld_register_func_for_add_image`) |
| `hooks/NUHooksDynamicIsland16.x` / `17` | Dynamic Island expanded player (17 covers 18/26 too) |
| `hooks/NUHooksSpringBoard.x` | Fails the system's own gestures while our row swipe is active — reads the cross-process touch flag (`NUDITouchGet`; set row-side by the `NUFlagPan` recognizer in NUNextUpRowView.m) |
| `hooks/NUHooksTCC.x` | iOS ≤ 16 NSAppleMusicUsageDescription injection (`%group NUMediaTCC`) — without it queue reads get the process killed |
| `hooks/NUHooks<App>Provider.x` | Thin per-app `%ctor` gates that start the matching provider |
| `NUHooksShared.{h,m}` | Process gates (`NUIsMusic()`, `NUIsDisplaySide()`, …), view/VC ancestry helpers, `NUCCLayoutRow` (CC row layout shared by 18/26) |
| `NUShared.h` | Service names, notification names, snapshot dictionary keys, `NUApplySandbox()`, `NUDITouchSet/Get` |
| `NUPrivate.h` | Private-API @interface declarations (class-dump + Frida-verified) |
| `NUPrefs.{h,m}` | Pref keys, state-bit layout, `NUPrefBool` / `NUMasterEnabled` (`NUInterfaceEnabled` lives in NUHooksShared.h) |
| `prefs/` | PreferenceLoader pane; `Root.strings` keys must byte-exactly match `Root.plist` values. The controller filters `Root.plist` at runtime — rows for apps that aren't installed, and the Dynamic Island row without an island (MobileGestalt `ArtworkTraits` → subtype, then the panel's exclusion area), are dropped. `NUPrefsHeaderView` is the icon/name/version header above the first group: it is the table's `tableHeaderView`, so it must be measured and reassigned in `-viewDidLayoutSubviews` — but only when the size actually changed, since an unconditional reassignment inside a layout pass is a relayout loop — and the navigation title is handed over by KVO on the table's `contentOffset`, not `-scrollViewDidScroll:`, which needs a delegate Preferences does not promise. Its icon and the Source Code row share `-openSourceRepository`; that row's GitHub mark is a custom SF Symbol from `NUSymbols.xcassets` (actool step in `prefs/Makefile`) rather than a PNG, because Preferences rasterises an `icon` file at a size of its own choosing |

## Conventions

- **Comments state constraints, not history.** Keep "where this number comes
  from" and "what breaks on which iOS version"; never write changelog-style
  comments ("previously…", "fixed…").
- **`…2` suffix on private-class @interfaces** (e.g. `MPCPlayerChangeRequest2`):
  a shadow redeclaration that avoids colliding with interfaces the SDK/runtime
  already has. The `2` never appears at runtime — lookups go through the real
  class name.
- **Adding a media source:** follow the checklist in README.md ("Adding support
  for another app"). Step 3 (the `NUPrefs` state bit) fails *silently* if
  skipped — the Settings toggle will look right but never apply live.
- **Version gating is runtime, not compile-time:** hooks `%init` only where
  their classes exist; `NUIOSMajor()` gates the rest. One dylib covers
  iOS 14.2 – 26.
- **Never trust the other side of the IPC:** the display treats mach replies as
  untrusted input; providers must stay inert while disabled in prefs (no queue
  reads — a backgrounded app polling its media stack starved mediaserverd into
  a watchdog kill on iOS 14.2).

## Build & test

```sh
make package FINALPACKAGE=1              # roothide (default)
make package ROOTLESS=1 FINALPACKAGE=1   # rootless
make package ROOTFUL=1 FINALPACKAGE=1    # rootful — the iOS 14.2 variant
make package DEBUG=1                     # NULog enabled (os_log + per-process file sink)
# deploy: install the .deb (postinst restarts the media apps + MediaRemoteUI),
# then respring for the SpringBoard-side hooks:
killall SpringBoard
```

Maintainer scripts live in `layout/DEBIAN/`: postinst restarts the injected
media processes; postrm removes the prefs plist and the play-history directory
(`Application Support/NextUp3` in the Music container) on uninstall.

- Needs Theos + Xcode. The tweak builds against the newest SDK Theos finds
  (typically Xcode's own); private interfaces are all self-declared, so no
  patched SDK is required. Only `prefs/Makefile` needs a theos 1x SDK in
  `$THEOS/sdks` for the Preferences private-framework linker stub
  (`NUPREFS_PRIVATE_SDK` overrides which one).
- `-fno-ptrauth-objc-class-ro` (`NU_PTRAUTH_CFLAGS`, both Makefiles) is
  load-bearing on arm64e: clang 17 signs each class's `class_ro` pointer, and
  libobjc only authenticates that slot from iOS 17 on — older runtimes fault in
  `readClass()` while dyld maps the image, killing the injected process. PAC-less
  devices (A11 and older) run the arm64 slice and never expose it.
- Release builds must not link AVFoundation/CoreMedia/MediaPlayer/AudioToolbox:
  ld64 records every framework on the link line as LC_LOAD_DYLIB, which would
  force-load them into every injected process.
- `LIGHTMESSAGING_TIMEOUT=250` (Makefile) is load-bearing: without it a query
  against a suspended app blocks SpringBoard's main thread until the watchdog
  resprings.

## Repo etiquette

- Keep commit messages short and imperative, matching existing history.
