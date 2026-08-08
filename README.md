<p align="center">
  <img src="assets/icon.png" width="120" alt="NextUp 3 icon">
</p>

<h1 align="center">NextUp 3</h1>

<p align="center">
  See and skip the upcoming track right from the Lock Screen, Control Center and Dynamic Island.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/iOS-14.2%20%E2%80%93%2026-blue" alt="iOS 14.2 – 26">
  <img src="https://img.shields.io/badge/jailbreak-rootful%20%7C%20rootless%20%7C%20roothide-green" alt="rootful | rootless | roothide">
  <img src="https://img.shields.io/badge/license-GPL--3.0-orange" alt="GPL-3.0">
</p>

NextUp 3 is a modern revival of the classic
[NextUp](https://github.com/Nosskirneh/NextUp) tweak (iOS 11 – 13). It adds
an **Up Next row** to the system now-playing UI showing the next track with its
artwork, so you always know what's coming and can act on it before it plays.

## Features

- **Works everywhere** — Lock Screen, Control Center, and the Dynamic
  Island expanded player (iOS 16+).
- **Skip ahead** — remove the upcoming track from the queue with one tap, or tap
  its artwork to play it right now.
- **Bring back the previous track** — re-queue what just played as the next track.
- **Swipe gestures** — swipe the row for an interactive carousel: ← skips the
  next track, → puts the track you just heard back into the queue as up next,
  with neighbour artwork sliding in as you drag.
- **Native look on every version** — the row adopts each iOS version's
  now-playing style (padding, corner radii, and button feedback are matched to
  Apple's own player), so it feels built-in everywhere.
- **Per-app and per-surface toggles** — a Settings pane lets you enable/disable
  each app and each surface (Lock Screen / Control Center / Dynamic Island);
  changes apply instantly, no respring. The pane lists only what your device
  has: apps that are actually installed, and the Dynamic Island row only where
  there is an island (including one enabled by a tweak such as VisibleIsland).
- **Accessible & localized** — VoiceOver, Reduce Motion, Increase Contrast and
  Dynamic Type support; 27 languages.

## Supported apps

| App | Notes |
|---|---|
| Apple Music | full support |
| Apple Podcasts | full support |
| YouTube Music | full support, built against 9.28.4 |
| Spotify | full support, built against 9.1.62 |

## Compatibility

**iOS 14.2 – 26**, on all jailbreak types (rootful, rootless, roothide).

## Screenshots

<table align="center">
  <tr>
    <td rowspan="2" align="center" valign="middle">
      <img src="assets/control-center.png" width="320" alt="Control Center player with NextUp 3"><br>
      <sub>Control Center</sub>
    </td>
    <td align="center">
      <img src="assets/lock-screen.png" width="430" alt="Lock Screen player with NextUp 3"><br>
      <sub>Lock Screen</sub>
    </td>
  </tr>
  <tr>
    <td align="center">
      <img src="assets/dynamic-island.png" width="430" alt="Dynamic Island expanded player with NextUp 3"><br>
      <sub>Dynamic Island</sub>
    </td>
  </tr>
</table>

## Install

- **[Havoc](https://havoc.app/package/nextup3)** (recommended) — search for
  *NextUp 3* in your package manager.
- Or grab the `.deb` from [Releases](https://github.com/Yves000/NextUp3/releases)
  and install it with Sileo / Filza / `dpkg -i`.

Dependencies (installed automatically): `libSandy`, `PreferenceLoader`, and
ElleKit or Substrate. The package restarts the media apps by itself; just
respring when your package manager asks. Uninstalling cleans up everything the
tweak wrote (settings and play history).

## Known issues

- Apple Podcasts is not yet verified on iOS 26 (every other app and surface is).
- Spotify and YouTube Music integrations are built against specific app versions
  (see table above); an app update can silently break them until the tweak is
  updated.

---

# For developers

NextUp 3 is a Theos tweak. One dylib is injected into six processes and behaves
differently per process:

- **Providers** (one per media app, inside `com.apple.Music`,
  `com.apple.podcasts`, `com.google.ios.youtubemusic`, `com.spotify.client`):
  read that app's live queue, serve the current "next up" (title / artist /
  artwork) over IPC, and perform skip / play-now / previous using the app's own
  in-process queue API.
- **Display side** (`com.apple.MediaRemoteUI` and `com.apple.springboard`):
  hooks the now-playing player per surface and iOS version, draws the row
  (`NUNextUpRowView`), and talks to whichever provider owns the current
  now-playing session (`NUNextUpManager`).

**IPC:** app sandboxes can't register bootstrap services, so each provider runs a
[LightMessaging](https://github.com/rpetrich/LightMessaging) (mach) server under
a [libSandy](https://github.com/opa334/libSandy) profile that grants the
mach-register/lookup extensions (`layout/Library/libSandy/com.yves.nextup3.plist`).
Darwin notifications signal "queue changed" (provider → display) and
skip / previous / jump (display → provider). Payload-free, sandbox-crossing,
instant.

## Repo structure

| Path | What it is |
|---|---|
| `hooks/*.x` | Logos hooks, split per process / surface / iOS version — each with its own `%ctor` gate. `NUHooksLockScreen{14,15,18}.x`, `NUHooksControlCenter{Legacy,18,26}.x`, `NUHooksDynamicIsland{16,17}.x`, `NUHooksNowPlaying.x` (shared player plumbing), `NUHooksSpringBoard.x` (swipe-vs-system-gesture arbitration), `NUHooksTCC.x` (iOS ≤ 16 usage-description shim), plus one `NUHooks<App>Provider.x` per app |
| `NU<App>Provider.{h,m}` | The four providers (`Music`, `Podcast`, `YouTubeMusic`, `Spotify`), all on `NUProviderBase` |
| `NUNextUpManager.{h,m}` | Display side: source tracking, per-source LightMessaging client, snapshot state |
| `NUNextUpRowView.{h,m}` | The row UI: artwork, labels, skip button, swipe carousel |
| `NUHooksShared.{h,m}` | Cross-hook helpers (process gates, view lookup, CC row layout) |
| `NUShared.h` | IPC service names, Darwin notification names, `NUApplySandbox()` |
| `NUPrefs.{h,m}` | Prefs: live state on a notify-state token, CFPreferences as persisted fallback |
| `NUPrivate.h` | Private-API interface declarations (class-dump + Frida-verified) |
| `NULocalization.h` / `NULogFile.m` | String lookup; DEBUG-only file log sink |
| `prefs/` | PreferenceLoader settings pane + 27 localizations |
| `layout/` | libSandy sandbox profile |
| `vendor/` | Vendored LightMessaging / libSandy headers (see `vendor/README.md`) |

## Build & deploy

Requires [Theos](https://theos.dev) (roothide fork for the roothide variant)
and Xcode. The tweak builds against whatever recent iOS SDK your Xcode ships;
no patched SDK is needed because every private interface is declared in the
source itself (`NUPrivate.h` and the provider files). Only the Settings pane
needs one SDK from [theos/sdks](https://github.com/theos/sdks) in
`$THEOS/sdks` (any iOS 1x version works), since Xcode SDKs ship no linker stub
for the private Preferences framework. Set `NUPREFS_PRIVATE_SDK=` to pick a
specific one.

```sh
make package FINALPACKAGE=1              # roothide (default)
make package ROOTLESS=1 FINALPACKAGE=1   # rootless (palera1n / Dopamine)
make package ROOTFUL=1 FINALPACKAGE=1    # rootful — the iOS 14.2 build
make package DEBUG=1                     # dev build with NULog logging

# install the .deb from packages/ — its postinst restarts the media apps and
# MediaRemoteUI. SpringBoard hosts hooks too, so finish with a respring:
killall SpringBoard
```

## Adding support for another app

The design is table-driven, so a new source stays localized:

1. **`NUShared.h`** — add `kNUServiceName<X>` (+ `kNUSkipNotification<X>` /
   `kNUPrevNotification<X>` as needed), following the
   `com.yves.nextup3.<kind>.<source>` naming convention.
2. **`NUNextUpManager.m`** — add a `NUSource<X>` enum case and a case in each
   per-source table function: `NUSourceForBundleID`, `NUConnectionForSource`
   (+ a `gConn<X>`), `NUAppPrefKeyForSource`, `NUSkipNotificationForSource`,
   `NUPrevNotificationForSource`. The callers need no edits.
3. **`NUPrefs.h` + `NUPrefs.m`** — add `kNUStateApp<X>` (next free bit), its
   `NUStateBitForKey` case, and its `NUPrefsPublishState()` line. *Easy to miss
   and a silent failure*: without these the Settings switch looks right but
   never takes effect live.
4. **`prefs/Resources/Root.plist`** — one `PSSwitchCell` in the "Apps" group
   (`key` = the same `enabled<X>` string from `NUAppPrefKeyForSource`).
5. **Provider** — new `NU<X>Provider.{h,m}` on `NUProviderBase` plus
   `hooks/NUHooks<X>Provider.x` (its `%ctor` calls `NUApplySandbox()` before
   gating on `NUIs<X>()`), and add `NUIs<X>()` to `NUHooksShared.h`.
   **Don't forget the `NUIsDisplaySide()` exclusion**, or every display hook
   initializes inside the new app too.
6. **Plumbing** — `NextUp3.plist` (bundle id), `Makefile` (source files +
   `INSTALL_TARGET_PROCESSES`, which takes *executable* names, not bundle ids),
   the libSandy profile (register/lookup extensions for the new service name and
   the app's signing identifier in `AllowedProcesses`), and `control`'s
   description.

## Credits

- The original **[NextUp / NextUp 2](https://github.com/Nosskirneh/NextUp)**
  (iOS 11 – 13) by Andreas Henriksson, which this tweak revives.
- [LightMessaging](https://github.com/rpetrich/LightMessaging) by Ryan Petrich.
- [libSandy](https://github.com/opa334/libSandy) by opa334.

## License

[GPL-3.0](LICENSE). Vendored third-party headers remain under their original
terms (see `vendor/README.md`).

---

*AI agents / LLM tooling: see [AGENTS.md](AGENTS.md) (identical to
[CLAUDE.md](CLAUDE.md)) for an LLM-oriented map of this repo.*
